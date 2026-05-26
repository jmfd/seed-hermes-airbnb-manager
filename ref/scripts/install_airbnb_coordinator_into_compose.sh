#!/usr/bin/env bash
# install_airbnb_coordinator_into_compose.sh
#
# Installs the airbnb-coordinator boss + listener skills, the query-edit.py
# helper, brain page templates, and the courier compose sidecar into a
# running seed-hermes Compose scaffold. Idempotent: re-running is a no-op.
#
# Prerequisites (all checked at install time; refuse to proceed on fail):
#   1. seed-hermes scaffold prepared (./hermes-agent/scripts/prepare.sh)
#   2. Owner Hermes profile exists with Hostex webhook subscription bound to
#      a skill named str-manager-approval (the existing skill we will REPLACE)
#   3. seed-hermes-plow-chat installed (plow-chat-platform in
#      data/config.yaml plugins.enabled)
#   4. seed-hermes-gbrain installed (gbrain on container login PATH, brain
#      repo at /opt/data/home/brain git-initialized)
#   5. PyYAML available inside the container (we will pip install if not)
#
# Architectural enforcement:
#   - Team profile MUST NOT have client-facing platforms enabled (no Hostex
#     webhook, no telegram with owner allow-list). Installer reads
#     <scaffold>/data/profiles/<team>/config.yaml + .env and refuses if so.
#   - Owner profile .env gets PLOW_CHAT_BASE_URL, TEAM_CHAT_SECRETS_FILE,
#     AIRBNB_OWNER_MIRROR_SESSION_KEY, AIRBNB_COURIER_SLA_MINUTES,
#     AIRBNB_COURIER_ESCALATION_MINUTES, BRAIN_DIR.
#   - Sidecar env + secrets file get the right uid/gid via docker exec chown.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

SCAFFOLD_DIR="${HERMES_SCAFFOLD_DIR:-./hermes-agent}"
SERVICE="${HERMES_COMPOSE_SERVICE:-hermes}"
OWNER_PROFILE="${OWNER_PROFILE:-daniel}"
TEAM_PROFILE="${TEAM_PROFILE:-daniel-team}"
HERMES_UID_OVERRIDE="${HERMES_UID_OVERRIDE:-}"
HERMES_GID_OVERRIDE="${HERMES_GID_OVERRIDE:-}"
SKIP_TEAM_LISTENER=0
NO_WIZARD=0
SKIP_OWNER_WEBHOOK_CHECK=0

HERMES_HOME_IN_CONTAINER="/opt/data"
SUBPROCESS_HOME="${HERMES_HOME_IN_CONTAINER}/home"
BRAIN_DIR_IN_CONTAINER="${SUBPROCESS_HOME}/brain"
COURIER_DIR_IN_CONTAINER="${SUBPROCESS_HOME}/airbnb-courier"

usage() {
  cat <<EOF
Usage: $0 [options]

Installs the airbnb-coordinator boss + listener + courier on a running
seed-hermes scaffold. Idempotent.

Options:
  --scaffold PATH               seed-hermes scaffold dir. Default: ./hermes-agent
  --service NAME                Compose service name. Default: hermes
  --owner-profile NAME          Owner/boss Hermes profile. Default: daniel
  --team-profile NAME           Team-listener Hermes profile. Default: daniel-team
  --uid N                       Hermes UID. Default: read from .env (501)
  --gid N                       Hermes GID. Default: read from .env (20)
  --skip-team-listener          Boss + courier only; no team profile created
                                (use until seed-hermes-plow-chat's PLOW_CHATS
                                multi-token patch ships).
  --skip-owner-webhook-check    Allow install on an owner profile without an
                                existing Hostex webhook subscription. Use only
                                for fresh scaffolds where the webhook is set
                                up post-install.
  --no-wizard                   Do not invoke seed_team_brain_pages.sh after.
  -h, --help                    Show this help.

Env overrides (same names as long options):
  HERMES_SCAFFOLD_DIR, HERMES_COMPOSE_SERVICE, OWNER_PROFILE, TEAM_PROFILE,
  HERMES_UID_OVERRIDE, HERMES_GID_OVERRIDE
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scaffold)                  SCAFFOLD_DIR="$2"; shift 2 ;;
    --service)                   SERVICE="$2"; shift 2 ;;
    --owner-profile)             OWNER_PROFILE="$2"; shift 2 ;;
    --team-profile)              TEAM_PROFILE="$2"; shift 2 ;;
    --uid)                       HERMES_UID_OVERRIDE="$2"; shift 2 ;;
    --gid)                       HERMES_GID_OVERRIDE="$2"; shift 2 ;;
    --skip-team-listener)        SKIP_TEAM_LISTENER=1; shift ;;
    --skip-owner-webhook-check)  SKIP_OWNER_WEBHOOK_CHECK=1; shift ;;
    --no-wizard)                 NO_WIZARD=1; shift ;;
    -h|--help)                   usage; exit 0 ;;
    *)                           echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v docker >/dev/null 2>&1 || { echo "docker not found on host PATH" >&2; exit 1; }
[[ -d "$SCAFFOLD_DIR" ]] || { echo "Scaffold directory not found: $SCAFFOLD_DIR" >&2; exit 1; }
[[ -f "${SCAFFOLD_DIR%/}/compose.yaml" ]] || { echo "compose.yaml not found in $SCAFFOLD_DIR" >&2; exit 1; }

ENV_FILE="${SCAFFOLD_DIR%/}/.env"
if [[ -z "$HERMES_UID_OVERRIDE" && -f "$ENV_FILE" ]]; then
  HERMES_UID_OVERRIDE="$(awk -F= '$1=="HERMES_UID"{print $2}' "$ENV_FILE")"
fi
if [[ -z "$HERMES_GID_OVERRIDE" && -f "$ENV_FILE" ]]; then
  HERMES_GID_OVERRIDE="$(awk -F= '$1=="HERMES_GID"{print $2}' "$ENV_FILE")"
fi
HERMES_UID_OVERRIDE="${HERMES_UID_OVERRIDE:-501}"
HERMES_GID_OVERRIDE="${HERMES_GID_OVERRIDE:-20}"

EXEC=(docker compose -f "${SCAFFOLD_DIR%/}/compose.yaml" --project-directory "${SCAFFOLD_DIR%/}" exec -T -u "${HERMES_UID_OVERRIDE}:${HERMES_GID_OVERRIDE}" "$SERVICE")
EXEC_ROOT=(docker compose -f "${SCAFFOLD_DIR%/}/compose.yaml" --project-directory "${SCAFFOLD_DIR%/}" exec -T -u 0:0 "$SERVICE")

run_in_subprocess_home() {
  "${EXEC[@]}" env HOME="${SUBPROCESS_HOME}" bash -c "$1"
}

# Ensure a file is owned by HERMES_UID:HERMES_GID inside the container. The
# host bind-mount preserves the host UID on file creation; the sidecar runs
# as HERMES_UID:HERMES_GID so unreadable secrets cause a silent broken pipe.
chown_inside_container() {
  local path_in_container="$1"
  "${EXEC_ROOT[@]}" chown "${HERMES_UID_OVERRIDE}:${HERMES_GID_OVERRIDE}" "$path_in_container" || true
}

# Convert a host-side scaffold path to the container's view via the
# ./data:/opt/data bind-mount.
host_to_container_path() {
  local host="$1"
  echo "${host}" | sed "s|^${SCAFFOLD_DIR%/}/data/|/opt/data/|"
}

# ============================================================================
# Prerequisite checks
# ============================================================================
echo ">>> Checking prerequisites…"

echo "   - hermes container reachable + bind-mount sane"
hermes_user_home="$("${EXEC[@]}" bash -c 'echo $HOME' | tr -d '\r')"
if [[ "$hermes_user_home" != "${HERMES_HOME_IN_CONTAINER}" ]]; then
  echo "FAIL: hermes user HOME is '$hermes_user_home', expected '${HERMES_HOME_IN_CONTAINER}'." >&2
  echo "      This seed requires the official nousresearch/hermes-agent image." >&2
  exit 1
fi

echo "   - seed-hermes-gbrain installed (gbrain on container login PATH)"
if ! "${EXEC[@]}" bash -lc 'command -v gbrain >/dev/null 2>&1'; then
  echo "FAIL: gbrain not on container login-shell PATH." >&2
  echo "      Install seed-hermes-gbrain first." >&2
  exit 1
fi

echo "   - seed-hermes-plow-chat installed (plow-chat-platform in config.yaml plugins.enabled)"
if ! grep -qE '(^|[[:space:]])-[[:space:]]+plow-chat-platform' "${SCAFFOLD_DIR%/}/data/config.yaml" 2>/dev/null; then
  echo "FAIL: 'plow-chat-platform' not enabled in ${SCAFFOLD_DIR%/}/data/config.yaml plugins.enabled." >&2
  echo "      Install seed-hermes-plow-chat first." >&2
  exit 1
fi

echo "   - brain repo git-initialized at ${BRAIN_DIR_IN_CONTAINER}"
if ! "${EXEC[@]}" test -d "${BRAIN_DIR_IN_CONTAINER}/.git"; then
  echo "FAIL: brain repo not git-initialized at ${BRAIN_DIR_IN_CONTAINER}/.git" >&2
  echo "      Re-run the seed-hermes-gbrain installer." >&2
  exit 1
fi

echo "   - owner profile '${OWNER_PROFILE}' exists on the scaffold"
OWNER_PROFILE_DIR_HOST="${SCAFFOLD_DIR%/}/data/profiles/${OWNER_PROFILE}"
if [[ ! -d "$OWNER_PROFILE_DIR_HOST" ]]; then
  echo "FAIL: owner profile directory missing: ${OWNER_PROFILE_DIR_HOST}" >&2
  echo "      Create the profile first: docker compose exec ${SERVICE} hermes profile create ${OWNER_PROFILE}" >&2
  exit 1
fi

if [[ "$SKIP_OWNER_WEBHOOK_CHECK" != "1" ]]; then
  echo "   - owner profile has a Hostex webhook subscription bound to str-manager-approval"
  SUB_JSON_HOST="${OWNER_PROFILE_DIR_HOST}/webhook_subscriptions.json"
  if [[ ! -s "$SUB_JSON_HOST" ]] || ! grep -q 'str-manager-approval' "$SUB_JSON_HOST"; then
    echo "FAIL: owner profile webhook subscription bound to str-manager-approval not found." >&2
    echo "      Looked at: $SUB_JSON_HOST" >&2
    echo "      This skill REPLACES str-manager-approval; if the subscription doesn't exist," >&2
    echo "      installing the skill will leave it unreachable. Set up the webhook first or" >&2
    echo "      pass --skip-owner-webhook-check if you intend to wire it post-install." >&2
    exit 1
  fi
fi

if [[ "$SKIP_TEAM_LISTENER" == "1" ]]; then
  echo ">>> --skip-team-listener: will install boss + courier only; team profile NOT created."
fi

# Ensure PyYAML is available in the container (query-edit.py needs it).
echo "   - PyYAML in container Python"
if ! "${EXEC[@]}" bash -lc 'python3 -c "import yaml" 2>/dev/null'; then
  echo "     PyYAML missing; installing via pip…"
  "${EXEC[@]}" bash -lc 'pip install --user --quiet pyyaml' || {
    "${EXEC_ROOT[@]}" bash -lc 'pip install --quiet pyyaml --break-system-packages 2>/dev/null || pip install --quiet pyyaml' || {
      echo "FAIL: could not install PyYAML in the container." >&2
      echo "      Run: docker compose exec ${SERVICE} pip install pyyaml" >&2
      exit 1
    }
  }
fi

# ============================================================================
# 1. Brain page directories + legacy v9 state dirs
# ============================================================================
echo ">>> Creating brain page directories + legacy state dirs…"
run_in_subprocess_home "mkdir -p ${BRAIN_DIR_IN_CONTAINER}/team ${BRAIN_DIR_IN_CONTAINER}/properties ${BRAIN_DIR_IN_CONTAINER}/queries"
run_in_subprocess_home "touch ${BRAIN_DIR_IN_CONTAINER}/queries/.gitkeep"
# Legacy v9.0.0 state dirs used by the pirate fast path inside the boss skill.
run_in_subprocess_home "mkdir -p ${SUBPROCESS_HOME}/.airbnb-manager"
run_in_subprocess_home "[ -s ${SUBPROCESS_HOME}/.airbnb-manager/pirate-joker-pending.json ] || echo '{}' > ${SUBPROCESS_HOME}/.airbnb-manager/pirate-joker-pending.json"
run_in_subprocess_home "touch ${SUBPROCESS_HOME}/.airbnb-manager/outbox.jsonl"

# Drop the brain page templates into a non-indexed cache dir so operators have
# something to copy from when running the wizard. They are NOT committed
# automatically — that's the wizard's job — to keep the operator in control
# of what their actual team roster looks like.
HOST_BRAIN_DIR="${SCAFFOLD_DIR%/}/data/home/brain"
mkdir -p "${HOST_BRAIN_DIR}/.airbnb-coordinator-templates"
cp -R "${REPO_DIR}/ref/brain-templates/." "${HOST_BRAIN_DIR}/.airbnb-coordinator-templates/"

# Commit only the .gitkeep on first install so queries/ exists in git HEAD
# (gbrain syncs from HEAD, not the worktree).
run_in_subprocess_home "cd ${BRAIN_DIR_IN_CONTAINER} && \
  if ! git ls-files --error-unmatch queries/.gitkeep >/dev/null 2>&1; then \
    git add queries/.gitkeep && \
    git -c user.email='coordinator@plow.co' -c user.name='airbnb-coordinator' \
      commit -m 'coordinator: init queries/ dir' >/dev/null; \
  fi"

# ============================================================================
# 2. Drop the query-edit.py helper + courier script
# ============================================================================
echo ">>> Installing query-edit.py + courier into ${COURIER_DIR_IN_CONTAINER}…"
HOST_COURIER_DIR="${SCAFFOLD_DIR%/}/data/home/airbnb-courier"
mkdir -p "$HOST_COURIER_DIR"
cp -f "${REPO_DIR}/ref/courier/query-edit.py" "${HOST_COURIER_DIR}/query-edit.py"
cp -f "${REPO_DIR}/ref/courier/airbnb-courier.sh" "${HOST_COURIER_DIR}/tick-loop.sh"
chmod 0755 "${HOST_COURIER_DIR}/query-edit.py" "${HOST_COURIER_DIR}/tick-loop.sh"
# Make sure the sidecar uid can read+exec these inside the container.
chown_inside_container "${COURIER_DIR_IN_CONTAINER}/query-edit.py"
chown_inside_container "${COURIER_DIR_IN_CONTAINER}/tick-loop.sh"

# ============================================================================
# 2b. Drop the hostex-context skill (live Hostex reads at classify/draft time)
# ============================================================================
echo ">>> Installing hostex-context into ${SUBPROCESS_HOME}/hostex-context…"
HOST_HOSTEX_CTX_DIR="${SCAFFOLD_DIR%/}/data/home/hostex-context"
HOSTEX_CTX_DIR_IN_CONTAINER="${SUBPROCESS_HOME}/hostex-context"
mkdir -p "$HOST_HOSTEX_CTX_DIR"
cp -R "${REPO_DIR}/ref/hermes-skills/hostex-context/." "${HOST_HOSTEX_CTX_DIR}/"
chmod 0755 "${HOST_HOSTEX_CTX_DIR}/hxctx"
# The boss agent reads + execs these inside the container as the sidecar uid.
for f in hxctx _client.py _classify.py SKILL.md; do
  chown_inside_container "${HOSTEX_CTX_DIR_IN_CONTAINER}/${f}"
done

# ============================================================================
# 3. Install boss skill at the legacy str-manager-approval path
# ============================================================================
echo ">>> Installing boss skill into owner profile '${OWNER_PROFILE}'…"
OWNER_SKILL_DIR_HOST="${OWNER_PROFILE_DIR_HOST}/skills/str-manager-approval"
mkdir -p "$OWNER_SKILL_DIR_HOST"
# Back up the prior skill (if any) once per upgrade.
if [[ -f "${OWNER_SKILL_DIR_HOST}/SKILL.md" ]] && \
     ! grep -q "version: 10.0.0" "${OWNER_SKILL_DIR_HOST}/SKILL.md"; then
  cp -n "${OWNER_SKILL_DIR_HOST}/SKILL.md" "${OWNER_SKILL_DIR_HOST}/SKILL.md.bak.$(date +%s)"
fi
cp -f "${REPO_DIR}/ref/hermes-skills/airbnb-coordinator-boss/SKILL.md" "${OWNER_SKILL_DIR_HOST}/SKILL.md"

OWNER_SOUL_HOST="${OWNER_PROFILE_DIR_HOST}/SOUL.md"
mkdir -p "$(dirname "$OWNER_SOUL_HOST")"
if [[ -f "$OWNER_SOUL_HOST" ]] && ! grep -q "boss persona for a short-term rental" "$OWNER_SOUL_HOST"; then
  cp -n "$OWNER_SOUL_HOST" "${OWNER_SOUL_HOST}.bak.$(date +%s)"
fi
cp -f "${REPO_DIR}/ref/hermes-soul/owner-SOUL.md" "$OWNER_SOUL_HOST"

rm -f "${OWNER_PROFILE_DIR_HOST}/.skills_prompt_snapshot.json"

# ============================================================================
# 3b. Owner profile .env — write boss skill env vars
# ============================================================================
echo ">>> Writing owner profile .env (boss skill runtime config)…"
OWNER_ENV_HOST="${OWNER_PROFILE_DIR_HOST}/.env"
touch "$OWNER_ENV_HOST"
upsert_env() {
  local file="$1" key="$2" val="$3"
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    # Preserve any existing user-set value — only set if missing.
    return
  fi
  printf '%s=%s\n' "$key" "$val" >> "$file"
}
upsert_env "$OWNER_ENV_HOST" PLOW_CHAT_BASE_URL https://chat.plow.co
upsert_env "$OWNER_ENV_HOST" TEAM_CHAT_SECRETS_FILE /opt/data/home/.airbnb-coordinator/team-secrets.json
upsert_env "$OWNER_ENV_HOST" AIRBNB_OWNER_MIRROR_SESSION_KEY ""
upsert_env "$OWNER_ENV_HOST" AIRBNB_COURIER_SLA_MINUTES 30
upsert_env "$OWNER_ENV_HOST" AIRBNB_COURIER_ESCALATION_MINUTES 60
upsert_env "$OWNER_ENV_HOST" BRAIN_DIR /opt/data/home/brain
chmod 600 "$OWNER_ENV_HOST"
chown_inside_container "/opt/data/profiles/${OWNER_PROFILE}/.env"
echo "   - owner .env wired. NOTE: set AIRBNB_OWNER_MIRROR_SESSION_KEY before first wake (see end-of-install message)."

# ============================================================================
# 4. Create team profile, install listener skill, ENFORCE PLATFORM BOUNDARY
# ============================================================================
if [[ "$SKIP_TEAM_LISTENER" != "1" ]]; then
  echo ">>> Creating team profile '${TEAM_PROFILE}' if missing…"
  if ! "${EXEC[@]}" bash -lc "hermes profile list 2>&1 | grep -qE '^\s*${TEAM_PROFILE}\b'"; then
    "${EXEC[@]}" bash -lc "hermes profile create ${TEAM_PROFILE}" >/dev/null
    echo "   - created profile ${TEAM_PROFILE}"
  else
    echo "   - profile ${TEAM_PROFILE} already exists; preserve"
  fi

  TEAM_PROFILE_DIR_HOST="${SCAFFOLD_DIR%/}/data/profiles/${TEAM_PROFILE}"
  TEAM_CFG_HOST="${TEAM_PROFILE_DIR_HOST}/config.yaml"
  GLOBAL_CFG_HOST="${SCAFFOLD_DIR%/}/data/config.yaml"
  mkdir -p "$(dirname "$TEAM_CFG_HOST")"

  # Architectural enforcement: team profile MUST NOT have Hostex webhook OR
  # a telegram platform that could reach the owner. The profile's config.yaml
  # is the platform list; reject if either is present.
  echo "   - enforcing team platform boundary"
  if [[ -f "$TEAM_CFG_HOST" ]]; then
    if grep -qE '^[[:space:]]*webhook:[[:space:]]*$' "$TEAM_CFG_HOST" 2>/dev/null && \
       awk '/^[[:space:]]*webhook:[[:space:]]*$/{f=1;next} /^[[:space:]]+enabled:[[:space:]]+true/{if(f){found=1;exit}} /^[^[:space:]]/{f=0}END{exit !found}' "$TEAM_CFG_HOST"; then
      echo "FAIL: team profile '${TEAM_PROFILE}' has webhook platform enabled in config.yaml." >&2
      echo "      The team listener MUST NOT receive Hostex callbacks. Remove the webhook block from $TEAM_CFG_HOST and retry." >&2
      exit 1
    fi
    if grep -qE '^[[:space:]]*telegram:[[:space:]]*$' "$TEAM_CFG_HOST" 2>/dev/null && \
       awk '/^[[:space:]]*telegram:[[:space:]]*$/{f=1;next} /^[[:space:]]+enabled:[[:space:]]+true/{if(f){found=1;exit}} /^[^[:space:]]/{f=0}END{exit !found}' "$TEAM_CFG_HOST"; then
      echo "FAIL: team profile '${TEAM_PROFILE}' has telegram platform enabled in config.yaml." >&2
      echo "      The team listener MUST NOT mirror to the owner channel. Remove the telegram block from $TEAM_CFG_HOST and retry." >&2
      exit 1
    fi
  fi

  # Mirror the global model block (always sync, not skip-if-present, per codex P2).
  if [[ -f "$GLOBAL_CFG_HOST" ]] && grep -qE '^\s*model:' "$GLOBAL_CFG_HOST"; then
    MODEL_BLOCK=$(awk '/^model:[[:space:]]*$/{flag=1;print;next} /^[^[:space:]]/{flag=0} flag' "$GLOBAL_CFG_HOST")
    [[ -n "$MODEL_BLOCK" ]] || { echo "FAIL: no model: block in $GLOBAL_CFG_HOST" >&2; exit 1; }
    # Strip any existing model block and prepend the fresh one.
    if [[ -f "$TEAM_CFG_HOST" ]]; then
      python3 - "$TEAM_CFG_HOST" <<'PY'
import sys, re, pathlib
p = pathlib.Path(sys.argv[1])
text = p.read_text()
# Drop any existing top-level model: block.
text = re.sub(r"^model:[ \t]*\n(?:[ \t]+\S.*\n?)+", "", text, flags=re.M)
p.write_text(text)
PY
    fi
    { printf '%s\n' "$MODEL_BLOCK"; [[ -f "$TEAM_CFG_HOST" ]] && cat "$TEAM_CFG_HOST"; } > "${TEAM_CFG_HOST}.tmp"
    mv -f "${TEAM_CFG_HOST}.tmp" "$TEAM_CFG_HOST"
    echo "   - synced model block into $TEAM_CFG_HOST"
  fi

  echo ">>> Installing listener skill into team profile '${TEAM_PROFILE}'…"
  TEAM_SKILL_DIR_HOST="${TEAM_PROFILE_DIR_HOST}/skills/airbnb-team-listener"
  mkdir -p "$TEAM_SKILL_DIR_HOST"
  cp -f "${REPO_DIR}/ref/hermes-skills/airbnb-team-listener/SKILL.md" "${TEAM_SKILL_DIR_HOST}/SKILL.md"

  TEAM_SOUL_HOST="${TEAM_PROFILE_DIR_HOST}/SOUL.md"
  if [[ -f "$TEAM_SOUL_HOST" ]] && ! grep -q "team-listener persona" "$TEAM_SOUL_HOST"; then
    cp -n "$TEAM_SOUL_HOST" "${TEAM_SOUL_HOST}.bak.$(date +%s)"
  fi
  cp -f "${REPO_DIR}/ref/hermes-soul/team-SOUL.md" "$TEAM_SOUL_HOST"

  # Team profile .env — make sure PLOW_CHATS is set (REQUIRED) or refuse later.
  TEAM_ENV_HOST="${TEAM_PROFILE_DIR_HOST}/.env"
  touch "$TEAM_ENV_HOST"
  if ! grep -q '^PLOW_CHATS=' "$TEAM_ENV_HOST"; then
    cat >> "$TEAM_ENV_HOST" <<'EOF'
# PLOW_CHATS: comma-separated list of <chat_uid>:<X-Chat-Secret-Key> pairs,
# one per team member. The patched seed-hermes-plow-chat adapter reads this
# and binds N plow_chat instances to this profile. REQUIRED for the team
# listener to function with > 1 team member.
PLOW_CHATS=
EOF
  fi
  chmod 600 "$TEAM_ENV_HOST"
  chown_inside_container "/opt/data/profiles/${TEAM_PROFILE}/.env"

  rm -f "${TEAM_PROFILE_DIR_HOST}/.skills_prompt_snapshot.json"

  echo "   - listener installed."
  echo "   - REMINDER: set PLOW_CHATS in ${TEAM_ENV_HOST} before bringing the team listener up."
  echo "     This REQUIRES the seed-hermes-plow-chat multi-token patch (Stream #1)."
fi

# ============================================================================
# 5. Compose override + sidecar env file + secrets file
# ============================================================================
echo ">>> Writing compose.airbnb-coordinator.yaml override…"
cp -f "${REPO_DIR}/ref/compose/compose.airbnb-coordinator.yaml" "${SCAFFOLD_DIR%/}/compose.airbnb-coordinator.yaml"

SIDECAR_ENV_HOST="${SCAFFOLD_DIR%/}/data/.airbnb-courier.env"
if [[ ! -f "$SIDECAR_ENV_HOST" ]]; then
  cat > "$SIDECAR_ENV_HOST" <<EOF
# airbnb-courier sidecar config. Mode 600 — sidecar reads via env_file.
AIRBNB_OWNER_PROFILE=${OWNER_PROFILE}
AIRBNB_OWNER_MIRROR_SESSION_KEY=
AIRBNB_COURIER_TICK_SECONDS=60
AIRBNB_COURIER_SLA_MINUTES=30
AIRBNB_COURIER_ESCALATION_MINUTES=60
AIRBNB_COURIER_PARTIAL_STALENESS_SECONDS=300
PLOW_CHAT_BASE_URL=https://chat.plow.co
TEAM_CHAT_SECRETS_FILE=/opt/data/home/.airbnb-coordinator/team-secrets.json
BRAIN_DIR=/opt/data/home/brain
EOF
  echo "   - wrote ${SIDECAR_ENV_HOST}. Set AIRBNB_OWNER_MIRROR_SESSION_KEY before sidecar boot."
fi
chmod 600 "$SIDECAR_ENV_HOST"
chown_inside_container "/opt/data/.airbnb-courier.env"

SECRETS_HOST="${SCAFFOLD_DIR%/}/data/home/.airbnb-coordinator/team-secrets.json"
mkdir -p "$(dirname "$SECRETS_HOST")"
if [[ ! -f "$SECRETS_HOST" ]]; then
  echo '{}' > "$SECRETS_HOST"
fi
chmod 600 "$SECRETS_HOST"
chown_inside_container "/opt/data/home/.airbnb-coordinator/team-secrets.json"
chown_inside_container "/opt/data/home/.airbnb-coordinator"

# ============================================================================
# 6. Update scaffold .env COMPOSE_FILE
# ============================================================================
echo ">>> Updating ${ENV_FILE} COMPOSE_FILE…"
if [[ ! -f "$ENV_FILE" ]]; then
  touch "$ENV_FILE"
fi
if grep -q '^COMPOSE_FILE=' "$ENV_FILE"; then
  current=$(awk -F= '$1=="COMPOSE_FILE"{ sub(/^COMPOSE_FILE=/,"",$0); print }' "$ENV_FILE" | head -1)
  if [[ ":${current}:" != *":compose.airbnb-coordinator.yaml:"* ]]; then
    new="${current}:compose.airbnb-coordinator.yaml"
    # Use python for the rewrite — awk -F= mishandles values with =.
    python3 - "$ENV_FILE" "$new" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
new_val = sys.argv[2]
out = []
seen = False
for line in p.read_text().splitlines(True):
    if line.startswith("COMPOSE_FILE="):
        out.append(f"COMPOSE_FILE={new_val}\n")
        seen = True
    else:
        out.append(line)
if not seen:
    out.append(f"COMPOSE_FILE={new_val}\n")
p.write_text("".join(out))
PY
    echo "   - appended compose.airbnb-coordinator.yaml to COMPOSE_FILE"
  else
    echo "   - COMPOSE_FILE already includes the override; skip"
  fi
else
  echo "COMPOSE_FILE=compose.yaml:compose.airbnb-coordinator.yaml" >> "$ENV_FILE"
  echo "   - wrote COMPOSE_FILE=compose.yaml:compose.airbnb-coordinator.yaml"
fi

# ============================================================================
# 7. Team brain-page wizard
# ============================================================================
TEAM_DIR_HOST="${SCAFFOLD_DIR%/}/data/home/brain/team"
if [[ "$NO_WIZARD" != "1" ]] && [[ -t 0 ]] && [[ -z "$(ls -A "$TEAM_DIR_HOST" 2>/dev/null | grep -v '^.gitkeep$')" ]]; then
  echo ">>> No team/ pages found; launching the team-brain-page wizard."
  "${SCRIPT_DIR}/seed_team_brain_pages.sh" --scaffold "$SCAFFOLD_DIR" || \
    echo "WARN: wizard exited non-zero; you can re-run it later via ${SCRIPT_DIR}/seed_team_brain_pages.sh"
else
  echo ">>> Skipping wizard (--no-wizard, non-TTY, or team/ already populated)."
fi

cat <<EOF

============================================================================
DONE. airbnb-coordinator installed in ${SCAFFOLD_DIR}.

REQUIRED NEXT STEPS before bringing the sidecar up:

  1. Set AIRBNB_OWNER_MIRROR_SESSION_KEY in BOTH:
       - ${OWNER_ENV_HOST}
       - ${SIDECAR_ENV_HOST}
     The value is the Hermes session key for the owner approval channel
     (typically 'agent:main:telegram:dm:<chat_id>'). Find it in:
       ${OWNER_PROFILE_DIR_HOST}/sessions/sessions.json

  2. Fill ${SECRETS_HOST} with the per-team-member X-Chat-Secret-Key values
     (one entry per team member listed in your brain/team/*.md pages).

  3. (If team listener was installed) Set PLOW_CHATS in
     ${SCAFFOLD_DIR%/}/data/profiles/${TEAM_PROFILE}/.env to:
       PLOW_CHATS=<uid1>:<key1>,<uid2>:<key2>,...
     This REQUIRES the patched seed-hermes-plow-chat — see README.

  4. Run 'docker compose up -d' in ${SCAFFOLD_DIR} — the airbnb-courier
     sidecar starts automatically alongside hermes and gbrain-sync.

  5. Verify with: ${REPO_DIR}/ref/verify.sh --scaffold ${SCAFFOLD_DIR}
============================================================================
EOF
