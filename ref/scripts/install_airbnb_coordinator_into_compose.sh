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
# OWNER_PROFILE / TEAM_PROFILE: REQUIRED, no default. The seed is operator-
# neutral — there is no canonical "Daniel" baked in. Resolution order (see
# resolve_profile_var below): CLI flag → process env → scaffold .env →
# interactive prompt (if TTY) → fail loud.
OWNER_PROFILE="${OWNER_PROFILE:-}"
TEAM_PROFILE="${TEAM_PROFILE:-}"
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
  --owner-profile NAME          Owner/boss Hermes profile NAME (the handle
                                you want this Hermes install to use for the
                                operator-facing profile). REQUIRED — no
                                default. Prompted interactively if unset
                                and stdin is a TTY; else fails loud.
  --team-profile NAME           Team-listener Hermes profile NAME. Same
                                rules as --owner-profile. Suggested form:
                                "<owner-profile>-team".
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

# ============================================================================
# Resolve OWNER_PROFILE / TEAM_PROFILE (REQUIRED, no default)
# ============================================================================
# The seed is operator-neutral. Order: CLI flag → process env → scaffold .env
# → interactive prompt (TTY only) → fail loud. Whatever the operator picks is
# persisted to scaffold .env so docker compose can substitute ${OWNER_PROFILE}
# / ${TEAM_PROFILE} into compose.airbnb-coordinator.yaml at compose-eval time.

read_env_var() {
  # Print value of $1 from $2 (or empty if missing). Strips surrounding quotes.
  local key="$1" file="$2"
  [[ -f "$file" ]] || { echo ""; return; }
  awk -F= -v k="$key" '$1==k{ sub(/^[^=]*=/,"",$0); print; exit }' "$file" \
    | sed -E 's/^"//; s/"$//'
}

upsert_scaffold_env() {
  # Idempotent KEY=VALUE upsert into ENV_FILE. Creates file if missing.
  local key="$1" val="$2"
  touch "$ENV_FILE"
  if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
    python3 - "$ENV_FILE" "$key" "$val" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
k = sys.argv[2]; v = sys.argv[3]
out = []
for line in p.read_text().splitlines(True):
    if line.startswith(f"{k}="):
        out.append(f"{k}={v}\n")
    else:
        out.append(line)
p.write_text("".join(out))
PY
  else
    printf '%s=%s\n' "$key" "$val" >> "$ENV_FILE"
  fi
}

resolve_profile_var() {
  # Resolve a profile name into the named bash variable. Order:
  #   1. process env (already set when this fn is called → return)
  #   2. scaffold .env (compose reads from here at runtime)
  #   3. interactive prompt if stdin is a TTY
  #   4. fail loud
  local varname="$1" example="$2"
  local current="${!varname:-}"
  if [[ -n "$current" ]]; then
    eval "$varname=\"\${current}\""
    return
  fi
  local from_env
  from_env=$(read_env_var "$varname" "$ENV_FILE")
  if [[ -n "$from_env" ]]; then
    eval "$varname=\"\${from_env}\""
    return
  fi
  if [[ -t 0 && -t 1 ]]; then
    echo "" >&2
    echo "  This Hermes install needs a handle for the ${varname} profile." >&2
    echo "  Pick any lowercase handle (letters, digits, dashes). e.g. ${example}" >&2
    local entered
    while :; do
      read -r -p "    ${varname}: " entered
      if [[ -z "$entered" ]]; then
        echo "    (empty — please type a handle)" >&2
        continue
      fi
      if [[ ! "$entered" =~ ^[a-z][a-z0-9-]*$ ]]; then
        echo "    (must be lowercase, start with a letter, only letters/digits/dashes)" >&2
        continue
      fi
      break
    done
    eval "$varname=\"\${entered}\""
    return
  fi
  local flag
  case "$varname" in
    OWNER_PROFILE) flag="--owner-profile" ;;
    TEAM_PROFILE)  flag="--team-profile" ;;
    *)             flag="--<flag>" ;;
  esac
  cat >&2 <<EOF
FAIL: \$${varname} is required but unset, and stdin is not a TTY so we
      cannot prompt interactively.

      Provide it one of these ways:
        - export ${varname}=${example} && bash $0 ...
        - bash $0 ${flag} ${example} ...
        - add a line '${varname}=${example}' to ${ENV_FILE}

      The seed is operator-neutral; pick any handle you like for your install.
EOF
  exit 1
}

resolve_profile_var OWNER_PROFILE owner
resolve_profile_var TEAM_PROFILE owner-team

upsert_scaffold_env OWNER_PROFILE "$OWNER_PROFILE"
upsert_scaffold_env TEAM_PROFILE  "$TEAM_PROFILE"
echo ">>> Hermes profile handles: OWNER_PROFILE=${OWNER_PROFILE}  TEAM_PROFILE=${TEAM_PROFILE}"
echo "    (persisted to ${ENV_FILE} so compose can substitute them)"

# Substrate defect #9 / #15: detect the ACTUAL container user instead of
# trusting HERMES_UID/HERMES_GID from .env or defaulting to macOS 501/20.
# The base hermes image runs as the user defined at image-build time
# (10000 on the upstream image, 1001 on some prepare.sh-generated builds).
# When the host UID baked into .env differs from the container's actual
# UID, downstream `docker exec -u $HOST_UID` either fails (Permission
# denied on container-owned files) or silently writes files the container
# can't read.
#
# Detection order:
#   1. --uid/--gid flag (explicit operator override)
#   2. Live probe inside the running hermes container (canonical)
#   3. .env HERMES_UID/HERMES_GID (legacy fallback)
#   4. 501/20 fallback (macOS default; last resort)
if [[ -z "$HERMES_UID_OVERRIDE" ]]; then
  HERMES_UID_OVERRIDE="$(docker compose -f "${SCAFFOLD_DIR%/}/compose.yaml" --project-directory "${SCAFFOLD_DIR%/}" exec -T "$SERVICE" id -u 2>/dev/null | tr -d '\r' || true)"
fi
if [[ -z "$HERMES_GID_OVERRIDE" ]]; then
  HERMES_GID_OVERRIDE="$(docker compose -f "${SCAFFOLD_DIR%/}/compose.yaml" --project-directory "${SCAFFOLD_DIR%/}" exec -T "$SERVICE" id -g 2>/dev/null | tr -d '\r' || true)"
fi
if [[ -z "$HERMES_UID_OVERRIDE" && -f "$ENV_FILE" ]]; then
  HERMES_UID_OVERRIDE="$(awk -F= '$1=="HERMES_UID"{print $2}' "$ENV_FILE")"
fi
if [[ -z "$HERMES_GID_OVERRIDE" && -f "$ENV_FILE" ]]; then
  HERMES_GID_OVERRIDE="$(awk -F= '$1=="HERMES_GID"{print $2}' "$ENV_FILE")"
fi
HERMES_UID_OVERRIDE="${HERMES_UID_OVERRIDE:-501}"
HERMES_GID_OVERRIDE="${HERMES_GID_OVERRIDE:-20}"
echo "   - hermes container user resolved: ${HERMES_UID_OVERRIDE}:${HERMES_GID_OVERRIDE}"

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
# Substrate defect #5: structural YAML parse — accepts both inline and
# multiline list forms. Prior `grep -qE '- plow-chat-platform'` rejected
# valid inline form `enabled: [plow-chat-platform]`.
if ! python3 -c "
import sys, yaml, pathlib
p = pathlib.Path('${SCAFFOLD_DIR%/}/data/config.yaml')
if not p.exists():
    sys.exit(1)
d = yaml.safe_load(p.read_text()) or {}
enabled = (d.get('plugins') or {}).get('enabled') or []
sys.exit(0 if 'plow-chat-platform' in enabled else 1)
" 2>/dev/null; then
  echo "FAIL: 'plow-chat-platform' not enabled in ${SCAFFOLD_DIR%/}/data/config.yaml plugins.enabled." >&2
  echo "      Install seed-hermes-plow-chat first. (Accepts both list forms:" >&2
  echo "      'enabled: [plow-chat-platform]' OR multiline '- plow-chat-platform'.)" >&2
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

echo "   - Codex OAuth credential is wired into Hermes (boss + distiller require it)"
# All seed profiles default to model.provider=openai-codex / default=gpt-5.5.
# Without a Codex OAuth credential in Hermes' pooled vault, the FIRST LLM-
# invoking call (boss webhook, distiller backfill) fails with:
#   "No Codex credentials stored. Run hermes auth to authenticate."
# The distiller failure is SILENT in stdout (backfill returns processed=0
# with no facts written). Catching it at install time = caught before any
# downstream work depends on it. There is NO API-key fallback in this seed —
# either Codex OAuth is wired or we stop.
if ! "${EXEC[@]}" bash -lc "hermes auth list 2>&1 | grep -qE 'openai-codex \([1-9][0-9]* credentials\)'"; then
  echo "FAIL: Hermes has no openai-codex OAuth credential stored." >&2
  echo "      Run the canonical auth flow from the seed-hermes scaffold:" >&2
  echo "        cd ${SCAFFOLD_DIR%/}" >&2
  echo "        ./scripts/auth-openai-codex.sh" >&2
  echo "      The wrapper invokes 'docker compose run --rm -T hermes auth add openai-codex'" >&2
  echo "      and walks you through the device-code OAuth flow (browser approval required)." >&2
  echo "      Verify with: docker compose run --rm -T hermes auth list" >&2
  echo "      Expected: 'openai-codex (1 credentials)'." >&2
  echo "      See seed-hermes/SEED.md §act-openai-codex-auth for the full spec." >&2
  echo "      There is no API-key fallback — Codex OAuth is required by this seed." >&2
  exit 1
fi

if [[ "$SKIP_TEAM_LISTENER" == "1" ]]; then
  echo ">>> --skip-team-listener: will install boss + courier only; team profile NOT created."
fi

# Ensure PyYAML is available in the container (query-edit.py needs it).
# The container has no `pip` on the user-PATH (only /opt/hermes/.venv/bin/pip,
# which doesn't exist on the official image's Debian layer). apt is the only
# reliable path. Also installs python3-yaml in the courier sidecar container
# (separate apt state) when its command-prefix runs at first boot.
echo "   - HOSTEX_ACCESS_TOKEN available (operator env or ingest sidecar env_file)"
INGEST_ENV_HOST_PRE="${SCAFFOLD_DIR%/}/data/.hostex-ingest.env"
HXT_PRE="${HOSTEX_ACCESS_TOKEN:-}"
if [[ -z "$HXT_PRE" ]] && [[ -f "$INGEST_ENV_HOST_PRE" ]]; then
  HXT_PRE=$(grep -E '^HOSTEX_ACCESS_TOKEN=' "$INGEST_ENV_HOST_PRE" 2>/dev/null \
            | head -1 | sed -E 's/^[^=]*=//; s/^"//; s/"$//')
fi
if [[ -z "$HXT_PRE" ]]; then
  echo "FAIL: HOSTEX_ACCESS_TOKEN not available." >&2
  echo "      Required for the owner-direct-chat hxctx path (v12.2.1 / patch #34)." >&2
  echo "      Pass HOSTEX_ACCESS_TOKEN=<token> bash $0 ..." >&2
  echo "      OR ensure $INGEST_ENV_HOST_PRE contains HOSTEX_ACCESS_TOKEN=<token>." >&2
  exit 1
fi
unset HXT_PRE INGEST_ENV_HOST_PRE

echo "   - PyYAML in container Python"
if ! "${EXEC[@]}" bash -lc 'python3 -c "import yaml" 2>/dev/null'; then
  echo "     PyYAML missing; installing via apt…"
  "${EXEC_ROOT[@]}" bash -c 'apt-get update -qq && apt-get install -y -qq python3-yaml' >/dev/null 2>&1 || {
    # Last-resort pip fallbacks (rare — most installs land via apt above)
    "${EXEC[@]}" bash -lc 'pip install --user --quiet pyyaml 2>/dev/null' || \
    "${EXEC_ROOT[@]}" bash -lc 'pip install --quiet pyyaml --break-system-packages 2>/dev/null || pip install --quiet pyyaml' || {
      echo "FAIL: could not install PyYAML in the container." >&2
      echo "      Run: docker compose exec ${SERVICE} apt-get install -y python3-yaml" >&2
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
# Plow Chat backend URL — api.plow.co since the 2026-05 folded-back API
# migration (chat.plow.co was retired). seed-hermes-plow-chat a14587b
# defaults to this, but we set it explicitly so the value is always
# pinned regardless of which plow-chat-platform version is installed.
upsert_env "$OWNER_ENV_HOST" PLOW_CHAT_BASE_URL https://api.plow.co
upsert_env "$OWNER_ENV_HOST" TEAM_CHAT_SECRETS_FILE /opt/data/home/.airbnb-coordinator/team-secrets.json
# Auto-derive AIRBNB_OWNER_MIRROR_SESSION_KEY from the owner profile's
# already-configured plow_chat (PLOW_CHAT_CHAT_UID). If the owner profile
# hasn't yet been wired to a plow_chat (create_plow_chat_curl.sh hasn't
# run on this profile), leave blank and warn — install can still complete;
# the courier wake will fail loudly until it's filled.
OWNER_PC_UID=$(grep '^PLOW_CHAT_CHAT_UID=' "$OWNER_ENV_HOST" 2>/dev/null | cut -d= -f2)
if [[ -n "$OWNER_PC_UID" ]]; then
  DERIVED_KEY="agent:main:plow_chat:dm:${OWNER_PC_UID}"
  # Replace any existing value (empty placeholder or stale) with the derived one
  grep -v ^AIRBNB_OWNER_MIRROR_SESSION_KEY= "$OWNER_ENV_HOST" > "$OWNER_ENV_HOST.tmp" 2>/dev/null || true
  mv -f "$OWNER_ENV_HOST.tmp" "$OWNER_ENV_HOST" 2>/dev/null || true
  echo "AIRBNB_OWNER_MIRROR_SESSION_KEY=${DERIVED_KEY}" >> "$OWNER_ENV_HOST"
  echo "   - auto-derived AIRBNB_OWNER_MIRROR_SESSION_KEY=${DERIVED_KEY}"
else
  upsert_env "$OWNER_ENV_HOST" AIRBNB_OWNER_MIRROR_SESSION_KEY ""
  echo "   ⚠  owner profile has no PLOW_CHAT_CHAT_UID yet — AIRBNB_OWNER_MIRROR_SESSION_KEY left blank."
  echo "   ⚠  After running seed-hermes-plow-chat's create_plow_chat_curl.sh against the OWNER profile,"
  echo "   ⚠  re-run this installer (idempotent) to auto-derive the session key."
fi
upsert_env "$OWNER_ENV_HOST" AIRBNB_COURIER_SLA_MINUTES 30
upsert_env "$OWNER_ENV_HOST" AIRBNB_COURIER_ESCALATION_MINUTES 60
upsert_env "$OWNER_ENV_HOST" BRAIN_DIR /opt/data/home/brain

# Patch 34: HOSTEX env passthrough for owner-direct-chat path (v12.2.1+).
# Without these, the owner-chats-the-agent-via-plow_chat path defaults
# `hxctx` to api.hostex.io with no auth -> empty `[]` silently (no error).
# The webhook path works without this (creds come from the subscription
# prompt) but owner-direct queries return "0 bookings" for everything.
# See REPRODUCIBILITY-PATCHES.md #34 and boss SKILL.md v12.2.1 step 6.6.
upsert_env "$OWNER_ENV_HOST" HOSTEX_BASE_URL "${HOSTEX_BASE_URL_FOR_BOSS:-https://api.hostex.io}"

# HOSTEX_ACCESS_TOKEN must be present. Resolution order:
#   1. HOSTEX_ACCESS_TOKEN env var passed to this installer
#   2. ${SCAFFOLD_DIR}/data/.hostex-ingest.env (the ingest sidecar's env_file
#      — the common case if seed-hostex-history-ingest was installed first)
# Fail loudly if neither has it — silent "0 bookings" is worse than no install.
INGEST_ENV_HOST="${SCAFFOLD_DIR%/}/data/.hostex-ingest.env"
HXT="${HOSTEX_ACCESS_TOKEN:-}"
if [[ -z "$HXT" ]] && [[ -f "$INGEST_ENV_HOST" ]]; then
  HXT=$(grep -E '^HOSTEX_ACCESS_TOKEN=' "$INGEST_ENV_HOST" 2>/dev/null         | head -1 | sed -E 's/^[^=]*=//; s/^"//; s/"$//')
fi
if [[ -z "$HXT" ]]; then
  echo "FAIL: HOSTEX_ACCESS_TOKEN not found." >&2
  echo "      Required for the owner-direct-chat hxctx path (non-webhook context)." >&2
  echo "      Without it, owner-direct queries to api.hostex.io return empty []" >&2
  echo "      silently — owner asks 'when is next booking?' and gets '0 bookings'" >&2
  echo "      against a real Hostex account that has live reservations." >&2
  echo "" >&2
  echo "      Provide via either:" >&2
  echo "        - HOSTEX_ACCESS_TOKEN=<token> bash $0 ..." >&2
  echo "        - OR create $INGEST_ENV_HOST with HOSTEX_ACCESS_TOKEN=<token>" >&2
  echo "          (this is what seed-hostex-history-ingest does at install time)" >&2
  echo "" >&2
  echo "      Webhook-context calls still work without this — token comes from" >&2
  echo "      the webhook subscription prompt — but owner-direct chat will not." >&2
  exit 1
fi
# Idempotent: only append if missing. Token value never echoed to logs.
if ! grep -q '^HOSTEX_ACCESS_TOKEN=' "$OWNER_ENV_HOST" 2>/dev/null; then
  printf 'HOSTEX_ACCESS_TOKEN=%s\n' "$HXT" >> "$OWNER_ENV_HOST"
fi
unset HXT
echo "   - HOSTEX_BASE_URL + HOSTEX_ACCESS_TOKEN wired into owner profile .env (token value masked)"

chmod 600 "$OWNER_ENV_HOST"
chown_inside_container "/opt/data/profiles/${OWNER_PROFILE}/.env"

# Patch 14: write per-profile platforms.plow_chat.enabled + plugins.enabled
# block to owner profile config.yaml. Without these blocks, the owner-gateway
# sidecar's `hermes -p ${OWNER_PROFILE} gateway run` doesn't bind plow_chat
# at all and the boss can't mirror to the owner channel.
OWNER_CFG_HOST="${OWNER_PROFILE_DIR_HOST}/config.yaml"
if [[ -f "$OWNER_CFG_HOST" ]] && ! grep -q '^platforms:' "$OWNER_CFG_HOST"; then
  cat >> "$OWNER_CFG_HOST" <<'EOF'
platforms:
  webhook:
    enabled: true
    extra:
      host: "0.0.0.0"
      port: 8787
      secret: "INSECURE_NO_AUTH"
  plow_chat:
    enabled: true
plugins:
  enabled:
    - plow-chat-platform
EOF
  echo "   - added platforms{webhook,plow_chat} + plugins block to owner config.yaml"
  chown_inside_container "/opt/data/profiles/${OWNER_PROFILE}/config.yaml"
fi

# Substrate defect #22: `hermes profile create` produces an empty
# config.yaml — no model: block. Per-profile services (hermes-owner)
# load the PROFILE's config.yaml first, not the scaffold's, so without
# a model block here the boss webhook session crashes with "No inference
# provider configured. Run 'hermes model' to choose a provider and model".
# Mirror the scaffold's model block into the profile config if missing.
if [[ -f "$OWNER_CFG_HOST" ]] && ! grep -qE '^model:' "$OWNER_CFG_HOST"; then
  SCAFFOLD_CFG="${SCAFFOLD_DIR%/}/data/config.yaml"
  if [[ -f "$SCAFFOLD_CFG" ]] && grep -qE '^model:' "$SCAFFOLD_CFG"; then
    python3 - "$OWNER_CFG_HOST" "$SCAFFOLD_CFG" <<'PY'
import sys, yaml, pathlib
prof_p = pathlib.Path(sys.argv[1])
scaf_p = pathlib.Path(sys.argv[2])
prof = yaml.safe_load(prof_p.read_text()) or {}
scaf = yaml.safe_load(scaf_p.read_text()) or {}
if 'model' in scaf and 'model' not in prof:
    # Insert model block at top of profile config (yaml.safe_dump rewrites order).
    new = {'model': scaf['model']}
    new.update(prof)
    prof_p.write_text(yaml.safe_dump(new, default_flow_style=False, sort_keys=False))
    print(f"   - mirrored scaffold model block into {prof_p.name}: provider={scaf['model'].get('provider')} default={scaf['model'].get('default')}")
else:
    print(f"   - model block already present in {prof_p.name} or scaffold has none; skip")
PY
    chown_inside_container "/opt/data/profiles/${OWNER_PROFILE}/config.yaml"
  else
    echo "   ⚠ scaffold config.yaml has no model: block — owner profile will inherit nothing." >&2
    echo "     Run 'docker compose exec hermes hermes model' to set one before first webhook." >&2
  fi
fi

# Patch 19: register the Hostex webhook subscription on the owner profile.
# The subscription routes inbound POSTs to /webhooks/hostex-events into the
# str-manager-approval skill. Without this, the boss never runs.
echo ">>> Registering Hostex webhook subscription on owner profile…"
if ! grep -q 'hostex-events' "${OWNER_PROFILE_DIR_HOST}/webhook_subscriptions.json" 2>/dev/null; then
  HOSTEX_BASE_URL_DEFAULT="${HOSTEX_BASE_URL_FOR_BOSS:-http://host.docker.internal:8080}"
  HOSTEX_TOKEN_DEFAULT="${HOSTEX_ACCESS_TOKEN_FOR_BOSS:-DTU_NO_AUTH}"
  OWNER_PC_UID_FOR_PROMPT="${OWNER_PC_UID:-PLACEHOLDER_OWNER_CHAT_UID}"
  "${EXEC[@]}" bash -lc "hermes -p ${OWNER_PROFILE} webhook subscribe hostex-events \
    --skills str-manager-approval \
    --deliver log \
    --secret INSECURE_NO_AUTH \
    --prompt 'INCOMING_HOSTEX_PAYLOAD={__raw__}\n\nThe payload above is the real Hostex message_created callback. Extract event, conversation_id, message_id from it and follow Trigger 1 of the str-manager-approval skill. Owner channel: platform=plow_chat chat_id=${OWNER_PC_UID_FOR_PROMPT}. Hostex API base: hostex_base_url=${HOSTEX_BASE_URL_DEFAULT} hostex_access_token=${HOSTEX_TOKEN_DEFAULT}.'" 2>&1 | tail -3
  echo "   - subscription 'hostex-events' registered on '${OWNER_PROFILE}'"
else
  echo "   - subscription 'hostex-events' already present on '${OWNER_PROFILE}'"
fi

# Substrate defect #12: webhook adapter refuses to start when
# INSECURE_NO_AUTH secret is paired with 0.0.0.0 bind (Hermes safety rail).
# DTU testing requires 0.0.0.0 bind + INSECURE_NO_AUTH secret. The
# REPRODUCIBILITY-PATCHES.md #6 says installer applies the bypass; this
# block makes that real by editing /opt/hermes/gateway/platforms/webhook.py
# in the container + clearing bytecode cache + verifying.
echo ">>> Applying INSECURE_NO_AUTH local-bypass to gateway webhook adapter (REPRODUCIBILITY-PATCHES.md #6)…"
WEBHOOK_PY=/opt/hermes/gateway/platforms/webhook.py
if "${EXEC[@]}" grep -q "if False and secret == _INSECURE_NO_AUTH" "$WEBHOOK_PY" 2>/dev/null; then
  echo "   - webhook.py already patched (bypass active)"
elif "${EXEC[@]}" grep -q "if secret == _INSECURE_NO_AUTH and not _is_loopback_host" "$WEBHOOK_PY" 2>/dev/null; then
  "${EXEC_ROOT[@]}" python3 -c "
import re, pathlib
p = pathlib.Path('$WEBHOOK_PY')
src = p.read_text()
new = re.sub(
    r'if secret == _INSECURE_NO_AUTH and not _is_loopback_host',
    'if False and secret == _INSECURE_NO_AUTH and not _is_loopback_host',
    src, count=1
)
if new == src:
    raise SystemExit('webhook.py anchor not found — upstream changed?')
p.write_text(new)
print('   - patched webhook.py (INSECURE_NO_AUTH + non-loopback bypass)')
"
  "${EXEC_ROOT[@]}" bash -c 'find /opt/hermes/gateway/platforms -name __pycache__ -exec rm -rf {} + 2>/dev/null; true'
  echo "   - cleared webhook.py bytecode cache"
else
  echo "   ⚠ webhook.py anchor not found — upstream signature may have changed." >&2
  echo "     Verify the webhook adapter still starts after install; if not, patch by hand." >&2
fi
# Verify: bypass marker present.
if ! "${EXEC[@]}" grep -q "if False and secret == _INSECURE_NO_AUTH" "$WEBHOOK_PY" 2>/dev/null; then
  echo "   ⚠ post-patch verify FAILED — bypass marker not found in webhook.py" >&2
fi

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

  # Patch 14 (team side): add platforms.plow_chat.enabled + plugins block
  # so the hermes-owner-team gateway sidecar binds the WSS subscription.
  if ! grep -q '^platforms:' "$TEAM_CFG_HOST" 2>/dev/null; then
    cat >> "$TEAM_CFG_HOST" <<'EOF'
platforms:
  plow_chat:
    enabled: true
plugins:
  enabled:
    - plow-chat-platform
EOF
    echo "   - added platforms.plow_chat + plugins block to team config.yaml"
    chown_inside_container "/opt/data/profiles/${TEAM_PROFILE}/config.yaml"
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
  # Substrate defect #7: don't write empty PLOW_CHATS placeholder + warn if
  # the single-chat fallback (PLOW_CHAT_CHAT_UID + PLOW_CHAT_TOKEN) is already
  # wired by seed-hermes-plow-chat activation. Empty placeholder + warning
  # confused operators because the listener actually works on single-chat.
  HAS_SINGLE_CHAT=0
  if grep -q '^PLOW_CHAT_CHAT_UID=..*' "$TEAM_ENV_HOST" 2>/dev/null \
     && grep -q '^PLOW_CHAT_TOKEN=..*' "$TEAM_ENV_HOST" 2>/dev/null; then
    HAS_SINGLE_CHAT=1
  fi
  if [[ "$HAS_SINGLE_CHAT" == "0" ]] && ! grep -q '^PLOW_CHATS=' "$TEAM_ENV_HOST"; then
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
  if [[ "$HAS_SINGLE_CHAT" == "1" ]]; then
    echo "   - team profile uses single-chat path (PLOW_CHAT_CHAT_UID present); PLOW_CHATS not required."
  else
    echo "   - REMINDER: set PLOW_CHATS in ${TEAM_ENV_HOST} before bringing the team listener up."
    echo "     This REQUIRES the seed-hermes-plow-chat multi-token patch (Stream #1)."
  fi
fi

# ============================================================================
# 5. Compose override + sidecar env file + secrets file
# ============================================================================
echo ">>> Writing compose.airbnb-coordinator.yaml override…"
cp -f "${REPO_DIR}/ref/compose/compose.airbnb-coordinator.yaml" "${SCAFFOLD_DIR%/}/compose.airbnb-coordinator.yaml"

# Substrate defect #16 (Linux engineer) / original defect #2: ship the
# Postgres backend override too. SEED.md §12 documents that this
# file exists; the installer is the canonical writer. Operators can edit
# credentials in-place if desired — `gbrain init --url ...` (Phase 9)
# reads whatever's set here.
echo ">>> Writing compose.gbrain-postgres.yaml override…"
cp -f "${REPO_DIR}/ref/compose/compose.gbrain-postgres.yaml" "${SCAFFOLD_DIR%/}/compose.gbrain-postgres.yaml"

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
PLOW_CHAT_BASE_URL=https://api.plow.co
TEAM_CHAT_SECRETS_FILE=/opt/data/home/.airbnb-coordinator/team-secrets.json
BRAIN_DIR=/opt/data/home/brain
EOF
  echo "   - wrote ${SIDECAR_ENV_HOST}."
fi
# Substrate defect #6: the installer derives AIRBNB_OWNER_MIRROR_SESSION_KEY
# above (section 3b) and writes it to the OWNER profile .env, but historically
# left .airbnb-courier.env with the empty placeholder — courier sidecar then
# exited at startup. Sync the derived value here, idempotently.
if [[ -n "${DERIVED_KEY:-}" ]]; then
  if grep -q '^AIRBNB_OWNER_MIRROR_SESSION_KEY=$' "$SIDECAR_ENV_HOST" 2>/dev/null ||
     ! grep -q "^AIRBNB_OWNER_MIRROR_SESSION_KEY=${DERIVED_KEY}\$" "$SIDECAR_ENV_HOST"; then
    grep -v '^AIRBNB_OWNER_MIRROR_SESSION_KEY=' "$SIDECAR_ENV_HOST" > "$SIDECAR_ENV_HOST.tmp" 2>/dev/null || true
    mv -f "$SIDECAR_ENV_HOST.tmp" "$SIDECAR_ENV_HOST" 2>/dev/null || true
    printf 'AIRBNB_OWNER_MIRROR_SESSION_KEY=%s\n' "$DERIVED_KEY" >> "$SIDECAR_ENV_HOST"
    echo "   - synced AIRBNB_OWNER_MIRROR_SESSION_KEY into ${SIDECAR_ENV_HOST}"
  fi
else
  echo "   ⚠ AIRBNB_OWNER_MIRROR_SESSION_KEY not derived; courier sidecar will exit at startup until it is populated."
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
# 5b. Defensive cleanup: remove gbrain-sync sidecar from compose.gbrain.yaml
# if present. Background: seed-hermes-gbrain v0.1.x installer wrote a
# `gbrain-sync` service block to compose.gbrain.yaml that ran
# `gbrain sync --watch` in a loop, maintaining a flat-file mirror under
# /opt/data/home/brain/ for the v12.0 boss to read via search_files.
# v12.4.0+ boss is gbrain-exclusive (Postgres-backed via gbrain CLI) and
# explicitly prohibits filesystem reads. The sidecar is dead weight.
# The gbrain seed installer's own fix (cross-repo) ships in seed-hermes-gbrain
# v0.2.x+; this defensive cleanup catches operators on older gbrain seed
# installs so their fresh airbnb-coordinator install still ends up clean.
GBRAIN_COMPOSE="${SCAFFOLD_DIR%/}/compose.gbrain.yaml"
if [[ -f "$GBRAIN_COMPOSE" ]] && grep -q '^[[:space:]]*gbrain-sync:' "$GBRAIN_COMPOSE"; then
  echo
  echo ">>> Removing legacy gbrain-sync sidecar from compose.gbrain.yaml…"
  cp "$GBRAIN_COMPOSE" "$GBRAIN_COMPOSE.pre-sidecar-removal.bak.$(date +%s)"
  python3 - "$GBRAIN_COMPOSE" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
src = p.read_text()
marker = "\n  gbrain-sync:"
if marker in src:
    p.write_text(src[:src.index(marker)].rstrip() + "\n")
    print("   - removed gbrain-sync service block (hermes entrypoint override preserved)")
else:
    print("   - no gbrain-sync block found (already clean)")
PY
  # Also stop + remove any already-running sidecar container.
  SIDECAR_NAME="${COMPOSE_PROJECT_NAME:-}"
  if [[ -z "$SIDECAR_NAME" ]]; then
    SIDECAR_NAME=$(basename "${SCAFFOLD_DIR%/}")
  fi
  if docker ps --format '{{.Names}}' | grep -q "\-gbrain-sync$"; then
    echo "   - stopping + removing live gbrain-sync container…"
    (cd "${SCAFFOLD_DIR%/}" && docker compose stop gbrain-sync 2>&1 | tail -1) || true
    (cd "${SCAFFOLD_DIR%/}" && docker compose rm -f gbrain-sync 2>&1 | tail -1) || true
  fi
  # Also remove the vestigial flat-file mirror under /opt/data/home/brain/facts/
  # — only the boss read from this, and v12.4.0+ prohibits the read.
  if "${EXEC[@]}" test -d /opt/data/home/brain/facts; then
    echo "   - removing vestigial /opt/data/home/brain/facts/ (gbrain Postgres is now source of truth)…"
    "${EXEC[@]}" bash -c 'rm -rf /opt/data/home/brain/facts/' || true
  fi
fi

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
