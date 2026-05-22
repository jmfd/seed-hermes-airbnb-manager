#!/usr/bin/env bash
# install_airbnb_coordinator_into_compose.sh
#
# Installs the airbnb-coordinator boss + listener skills, brain page
# templates, and courier compose sidecar into a running seed-hermes
# scaffold. Idempotent: re-running against an installed scaffold exits
# zero without destructive changes.
#
# Prerequisites:
#   1. seed-hermes scaffold prepared (./hermes-agent/scripts/prepare.sh)
#   2. seed-hermes-plow-chat installed in the scaffold (plow-chat-platform
#      in data/config.yaml plugins.enabled)
#   3. seed-hermes-gbrain installed in the scaffold (gbrain on container
#      login-shell PATH, /opt/data/home/brain git-initialized)
#
# What it does:
#   - Refuses to proceed if the 3 prerequisites are not satisfied.
#   - Creates the team profile (default daniel-team) if missing.
#   - Mirrors the global model block into the team profile's config.yaml.
#   - Backs up + overwrites the owner profile's str-manager-approval/SKILL.md
#     and SOUL.md.
#   - Installs the team profile's airbnb-team-listener/SKILL.md and SOUL.md.
#   - Clears both profiles' skill snapshots so Hermes reloads on next session.
#   - Drops brain page templates into /opt/data/home/brain/{team,properties,queries}/
#     and creates the .gitkeep marker.
#   - Drops the courier script into /opt/data/home/airbnb-courier/tick-loop.sh.
#   - Writes <scaffold>/compose.airbnb-coordinator.yaml.
#   - Writes <scaffold>/data/.airbnb-courier.env (mode 600).
#   - Updates <scaffold>/.env COMPOSE_FILE to include the new override.
#   - Invokes ref/scripts/seed_team_brain_pages.sh if the brain/team/ dir is
#     empty AND --no-wizard was NOT passed.

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
  --scaffold PATH         seed-hermes scaffold dir (contains compose.yaml).
                          Default: ./hermes-agent
  --service NAME          Compose service name. Default: hermes
  --owner-profile NAME    Owner / boss Hermes profile name. Default: daniel
  --team-profile NAME     Team-listener Hermes profile name. Default: daniel-team
  --uid N                 Hermes UID in container. Default: read from .env (501)
  --gid N                 Hermes GID in container. Default: read from .env (20)
  --skip-team-listener    Install the boss + courier only; skip team profile
                          creation. Use this when seed-hermes-plow-chat's
                          multi-token PLOW_CHATS patch has not yet shipped.
  --no-wizard             Do not invoke seed_team_brain_pages.sh after install.
  -h, --help              Show this help.

Env overrides (same names as long options):
  HERMES_SCAFFOLD_DIR, HERMES_COMPOSE_SERVICE, OWNER_PROFILE, TEAM_PROFILE,
  HERMES_UID_OVERRIDE, HERMES_GID_OVERRIDE

Security:
  No secrets are written to .env files committed to the repo. The team
  member chat secrets file at /opt/data/home/.airbnb-coordinator/team-secrets.json
  is created with mode 600 inside the bind-mount.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scaffold)            SCAFFOLD_DIR="$2"; shift 2 ;;
    --service)             SERVICE="$2"; shift 2 ;;
    --owner-profile)       OWNER_PROFILE="$2"; shift 2 ;;
    --team-profile)        TEAM_PROFILE="$2"; shift 2 ;;
    --uid)                 HERMES_UID_OVERRIDE="$2"; shift 2 ;;
    --gid)                 HERMES_GID_OVERRIDE="$2"; shift 2 ;;
    --skip-team-listener)  SKIP_TEAM_LISTENER=1; shift ;;
    --no-wizard)           NO_WIZARD=1; shift ;;
    -h|--help)             usage; exit 0 ;;
    *)                     echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v docker >/dev/null 2>&1 || { echo "docker not found on host PATH" >&2; exit 1; }
[[ -d "$SCAFFOLD_DIR" ]] || { echo "Scaffold directory not found: $SCAFFOLD_DIR" >&2; exit 1; }
[[ -f "${SCAFFOLD_DIR%/}/compose.yaml" ]] || { echo "compose.yaml not found in $SCAFFOLD_DIR" >&2; exit 1; }

# Discover uid/gid from scaffold .env if not provided.
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

# ============================================================================
# Prerequisite checks
# ============================================================================
echo ">>> Checking prerequisites…"

echo "   - seed-hermes scaffold reachable"
hermes_user_home="$("${EXEC[@]}" bash -c 'echo $HOME' | tr -d '\r')"
if [[ "$hermes_user_home" != "${HERMES_HOME_IN_CONTAINER}" ]]; then
  echo "FAIL: hermes user HOME is '$hermes_user_home', expected '${HERMES_HOME_IN_CONTAINER}'." >&2
  echo "      This seed requires the official nousresearch/hermes-agent image." >&2
  exit 1
fi

echo "   - seed-hermes-gbrain installed (gbrain on container login PATH)"
if ! "${EXEC[@]}" bash -lc 'command -v gbrain >/dev/null 2>&1'; then
  echo "FAIL: gbrain not on container login-shell PATH." >&2
  echo "      Install seed-hermes-gbrain first:" >&2
  echo "        git clone https://github.com/plow-pbc/seed-hermes-gbrain" >&2
  echo "        ./seed-hermes-gbrain/ref/scripts/install_gbrain_into_compose.sh --scaffold ${SCAFFOLD_DIR}" >&2
  exit 1
fi

echo "   - seed-hermes-plow-chat installed (plow-chat-platform in config.yaml plugins.enabled)"
if ! grep -qE '(^|[[:space:]])-[[:space:]]+plow-chat-platform' "${SCAFFOLD_DIR%/}/data/config.yaml" 2>/dev/null; then
  echo "FAIL: 'plow-chat-platform' not enabled in ${SCAFFOLD_DIR%/}/data/config.yaml plugins.enabled." >&2
  echo "      Install seed-hermes-plow-chat first:" >&2
  echo "        git clone https://github.com/plow-pbc/seed-hermes-plow-chat" >&2
  echo "        ./seed-hermes-plow-chat/ref/scripts/install_direct_mount.sh --scaffold ${SCAFFOLD_DIR}" >&2
  exit 1
fi

echo "   - brain repo exists at ${BRAIN_DIR_IN_CONTAINER}"
if ! "${EXEC[@]}" test -d "${BRAIN_DIR_IN_CONTAINER}/.git"; then
  echo "FAIL: brain repo not git-initialized at ${BRAIN_DIR_IN_CONTAINER}/.git" >&2
  echo "      Re-run the seed-hermes-gbrain installer." >&2
  exit 1
fi

if [[ "$SKIP_TEAM_LISTENER" == "1" ]]; then
  echo ">>> --skip-team-listener: will install boss + courier only; team profile NOT created."
fi

# ============================================================================
# 1. Brain page directories + .gitkeep
# ============================================================================
echo ">>> Creating brain page directories…"
run_in_subprocess_home "mkdir -p ${BRAIN_DIR_IN_CONTAINER}/team ${BRAIN_DIR_IN_CONTAINER}/properties ${BRAIN_DIR_IN_CONTAINER}/queries"
run_in_subprocess_home "touch ${BRAIN_DIR_IN_CONTAINER}/queries/.gitkeep"
# Legacy v9.0.0 state dirs used by the pirate fast path inside the boss skill.
# Pre-create so the LLM's first write doesn't ENOENT.
run_in_subprocess_home "mkdir -p ${SUBPROCESS_HOME}/.airbnb-manager"
run_in_subprocess_home "touch ${SUBPROCESS_HOME}/.airbnb-manager/pirate-joker-pending.json"
run_in_subprocess_home "test -s ${SUBPROCESS_HOME}/.airbnb-manager/pirate-joker-pending.json || echo '{}' > ${SUBPROCESS_HOME}/.airbnb-manager/pirate-joker-pending.json"
run_in_subprocess_home "touch ${SUBPROCESS_HOME}/.airbnb-manager/outbox.jsonl"

# Copy templates so operators have something to start from (the wizard
# below uses these too).
HOST_BRAIN_DIR="${SCAFFOLD_DIR%/}/data/home/brain"
mkdir -p "${HOST_BRAIN_DIR}/.airbnb-coordinator-templates"
cp -R "${REPO_DIR}/ref/brain-templates/." "${HOST_BRAIN_DIR}/.airbnb-coordinator-templates/"

# Commit the gitkeep on first install so the queries/ dir is reachable
# from git HEAD (gbrain syncs from HEAD, not the worktree).
run_in_subprocess_home "cd ${BRAIN_DIR_IN_CONTAINER} && \
  if ! git ls-files --error-unmatch queries/.gitkeep >/dev/null 2>&1; then \
    git add queries/.gitkeep && \
    git commit -m 'coordinator: init queries/ dir' >/dev/null; \
  fi"

# ============================================================================
# 2. Install boss skill at the legacy str-manager-approval path
# ============================================================================
echo ">>> Installing boss skill into owner profile '${OWNER_PROFILE}'…"
OWNER_SKILL_DIR_HOST="${SCAFFOLD_DIR%/}/data/profiles/${OWNER_PROFILE}/skills/str-manager-approval"
mkdir -p "$OWNER_SKILL_DIR_HOST"
# Back up the prior skill (if any) once per install run.
if [[ -f "${OWNER_SKILL_DIR_HOST}/SKILL.md" ]] && \
     ! grep -q "version: 10.0.0" "${OWNER_SKILL_DIR_HOST}/SKILL.md"; then
  cp -n "${OWNER_SKILL_DIR_HOST}/SKILL.md" "${OWNER_SKILL_DIR_HOST}/SKILL.md.bak.$(date +%s)"
fi
cp -f "${REPO_DIR}/ref/hermes-skills/airbnb-coordinator-boss/SKILL.md" "${OWNER_SKILL_DIR_HOST}/SKILL.md"

OWNER_SOUL_HOST="${SCAFFOLD_DIR%/}/data/profiles/${OWNER_PROFILE}/SOUL.md"
mkdir -p "$(dirname "$OWNER_SOUL_HOST")"
if [[ -f "$OWNER_SOUL_HOST" ]] && ! grep -q "boss persona for a short-term rental" "$OWNER_SOUL_HOST"; then
  cp -n "$OWNER_SOUL_HOST" "${OWNER_SOUL_HOST}.bak.$(date +%s)"
fi
cp -f "${REPO_DIR}/ref/hermes-soul/owner-SOUL.md" "$OWNER_SOUL_HOST"

# Clear owner skill snapshot so the new SKILL.md is reloaded.
rm -f "${SCAFFOLD_DIR%/}/data/profiles/${OWNER_PROFILE}/.skills_prompt_snapshot.json"

# ============================================================================
# 3. Create team profile, install listener skill (unless --skip-team-listener)
# ============================================================================
if [[ "$SKIP_TEAM_LISTENER" != "1" ]]; then
  echo ">>> Creating team profile '${TEAM_PROFILE}' if missing…"
  if ! "${EXEC[@]}" bash -lc "hermes profile list 2>&1 | grep -qE '^\s*${TEAM_PROFILE}\b'"; then
    "${EXEC[@]}" bash -lc "hermes profile create ${TEAM_PROFILE}" >/dev/null
    echo "   - created profile ${TEAM_PROFILE}"
  else
    echo "   - profile ${TEAM_PROFILE} already exists; preserve"
  fi

  # Mirror the global model block into team profile's config.yaml
  # (per seed-hermes-gbrain ^act-profile-model-mirror).
  TEAM_CFG_HOST="${SCAFFOLD_DIR%/}/data/profiles/${TEAM_PROFILE}/config.yaml"
  GLOBAL_CFG_HOST="${SCAFFOLD_DIR%/}/data/config.yaml"
  mkdir -p "$(dirname "$TEAM_CFG_HOST")"
  if [[ -f "$GLOBAL_CFG_HOST" ]] && grep -qE '^\s*model:' "$GLOBAL_CFG_HOST"; then
    if [[ -f "$TEAM_CFG_HOST" ]] && grep -qE '^\s*model:' "$TEAM_CFG_HOST"; then
      echo "   - team profile config.yaml already has model block; skip"
    else
      MODEL_BLOCK=$(awk '/^model:[[:space:]]*$/{flag=1;print;next} /^[^[:space:]]/{flag=0} flag' "$GLOBAL_CFG_HOST")
      [[ -n "$MODEL_BLOCK" ]] || { echo "FAIL: no model: block in $GLOBAL_CFG_HOST" >&2; exit 1; }
      { printf '%s\n' "$MODEL_BLOCK"; [[ -f "$TEAM_CFG_HOST" ]] && cat "$TEAM_CFG_HOST"; } > "${TEAM_CFG_HOST}.tmp"
      mv -f "${TEAM_CFG_HOST}.tmp" "$TEAM_CFG_HOST"
      echo "   - mirrored model block into $TEAM_CFG_HOST"
    fi
  fi

  echo ">>> Installing listener skill into team profile '${TEAM_PROFILE}'…"
  TEAM_SKILL_DIR_HOST="${SCAFFOLD_DIR%/}/data/profiles/${TEAM_PROFILE}/skills/airbnb-team-listener"
  mkdir -p "$TEAM_SKILL_DIR_HOST"
  cp -f "${REPO_DIR}/ref/hermes-skills/airbnb-team-listener/SKILL.md" "${TEAM_SKILL_DIR_HOST}/SKILL.md"

  TEAM_SOUL_HOST="${SCAFFOLD_DIR%/}/data/profiles/${TEAM_PROFILE}/SOUL.md"
  if [[ -f "$TEAM_SOUL_HOST" ]] && ! grep -q "team-listener persona" "$TEAM_SOUL_HOST"; then
    cp -n "$TEAM_SOUL_HOST" "${TEAM_SOUL_HOST}.bak.$(date +%s)"
  fi
  cp -f "${REPO_DIR}/ref/hermes-soul/team-SOUL.md" "$TEAM_SOUL_HOST"

  rm -f "${SCAFFOLD_DIR%/}/data/profiles/${TEAM_PROFILE}/.skills_prompt_snapshot.json"

  echo "   - listener installed. Reminder: configure the team profile's plow_chat adapter"
  echo "     with PLOW_CHATS=<uid1>:<key1>,<uid2>:<key2>,... once the multi-token patch ships."
fi

# ============================================================================
# 4. Drop the courier script into the bind-mount
# ============================================================================
echo ">>> Installing courier sidecar script…"
HOST_COURIER_DIR="${SCAFFOLD_DIR%/}/data/home/airbnb-courier"
mkdir -p "$HOST_COURIER_DIR"
cp -f "${REPO_DIR}/ref/courier/airbnb-courier.sh" "${HOST_COURIER_DIR}/tick-loop.sh"
chmod 0755 "${HOST_COURIER_DIR}/tick-loop.sh"

# ============================================================================
# 5. Write compose override + sidecar env file
# ============================================================================
echo ">>> Writing compose.airbnb-coordinator.yaml override…"
cp -f "${REPO_DIR}/ref/compose/compose.airbnb-coordinator.yaml" "${SCAFFOLD_DIR%/}/compose.airbnb-coordinator.yaml"

SIDECAR_ENV_HOST="${SCAFFOLD_DIR%/}/data/.airbnb-courier.env"
if [[ ! -f "$SIDECAR_ENV_HOST" ]]; then
  cat > "$SIDECAR_ENV_HOST" <<EOF
# airbnb-courier sidecar config. Mode 600 — sidecar reads via env_file.
# Edit values as needed; the sidecar re-reads on container restart.
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
  chmod 600 "$SIDECAR_ENV_HOST"
  echo "   - wrote ${SIDECAR_ENV_HOST}. Set AIRBNB_OWNER_MIRROR_SESSION_KEY before bringing the sidecar up."
else
  echo "   - ${SIDECAR_ENV_HOST} already exists; preserve"
fi

# Team secrets file: created empty, owner fills via the wizard.
SECRETS_HOST="${SCAFFOLD_DIR%/}/data/home/.airbnb-coordinator/team-secrets.json"
mkdir -p "$(dirname "$SECRETS_HOST")"
if [[ ! -f "$SECRETS_HOST" ]]; then
  echo '{}' > "$SECRETS_HOST"
  chmod 600 "$SECRETS_HOST"
fi

# ============================================================================
# 6. Update scaffold .env COMPOSE_FILE to include the override
# ============================================================================
echo ">>> Updating ${ENV_FILE} COMPOSE_FILE…"
if [[ ! -f "$ENV_FILE" ]]; then
  touch "$ENV_FILE"
fi
if grep -q '^COMPOSE_FILE=' "$ENV_FILE"; then
  current=$(awk -F= '$1=="COMPOSE_FILE"{print $2}' "$ENV_FILE")
  if [[ ":${current}:" != *":compose.airbnb-coordinator.yaml:"* ]]; then
    new="${current}:compose.airbnb-coordinator.yaml"
    awk -v new="$new" 'BEGIN{FS=OFS="="} $1=="COMPOSE_FILE"{$2=new}1' "$ENV_FILE" > "${ENV_FILE}.tmp"
    mv -f "${ENV_FILE}.tmp" "$ENV_FILE"
    echo "   - appended compose.airbnb-coordinator.yaml to COMPOSE_FILE"
  else
    echo "   - COMPOSE_FILE already includes the override; skip"
  fi
else
  echo "COMPOSE_FILE=compose.yaml:compose.airbnb-coordinator.yaml" >> "$ENV_FILE"
  echo "   - wrote COMPOSE_FILE=compose.yaml:compose.airbnb-coordinator.yaml"
fi

# ============================================================================
# 7. Run the team brain-page seed wizard, unless suppressed
# ============================================================================
TEAM_DIR_HOST="${SCAFFOLD_DIR%/}/data/home/brain/team"
if [[ "$NO_WIZARD" != "1" ]] && [[ -t 0 ]] && [[ -z "$(ls -A "$TEAM_DIR_HOST" 2>/dev/null | grep -v '^.gitkeep$')" ]]; then
  echo ">>> No team/ pages found; launching the team-brain-page wizard."
  "${SCRIPT_DIR}/seed_team_brain_pages.sh" --scaffold "$SCAFFOLD_DIR" || \
    echo "WARN: wizard exited non-zero; you can re-run it later via ${SCRIPT_DIR}/seed_team_brain_pages.sh"
else
  echo ">>> Skipping wizard (--no-wizard, non-TTY, or team/ already populated)."
  echo "    Author your team/*.md and properties/*.md pages then 'cd /opt/data/home/brain && git add team properties && git commit -m \"team setup\"'"
fi

cat <<EOF

============================================================================
DONE. airbnb-coordinator installed in ${SCAFFOLD_DIR}.

Next steps:
  1. Edit ${SIDECAR_ENV_HOST} and set AIRBNB_OWNER_MIRROR_SESSION_KEY to
     the session key for the owner approval channel (e.g.
     'agent:main:telegram:dm:<chat_id>'). Look it up in
     ${SCAFFOLD_DIR%/}/data/profiles/${OWNER_PROFILE}/sessions/sessions.json.
  2. Fill ${SECRETS_HOST} with the per-team-member X-Chat-Secret-Key values
     (one per team member listed in your brain/team/*.md pages).
  3. (If team listener was installed) configure the team profile's plow_chat
     adapter with the multi-token PLOW_CHATS env var. NOTE: requires the
     patched seed-hermes-plow-chat — see README for status.
  4. Run 'docker compose up -d' in ${SCAFFOLD_DIR} — the airbnb-courier sidecar
     starts automatically alongside hermes and gbrain-sync.
  5. Verify with: ${REPO_DIR}/ref/verify.sh --scaffold ${SCAFFOLD_DIR}
============================================================================
EOF
