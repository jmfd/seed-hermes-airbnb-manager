#!/usr/bin/env bash
# uninstall.sh
#
# Gentle by default: removes the courier sidecar + compose override + skill
# files, but PRESERVES the team profile (sessions, plow_chat pairing), the
# brain pages (team/*.md, properties/*.md, queries/q-*.md), and the team
# secrets file.
#
# Flags:
#   --purge          Also delete the team profile (DESTRUCTIVE).
#   --purge-queries  Also delete /opt/data/home/brain/queries/q-*.md
#                    (DESTRUCTIVE; loses in-flight state).
#   --restore-legacy Restore the most recent SKILL.md.bak.* if present,
#                    bringing back the v9.0.0 str-manager-approval skill.

set -euo pipefail

SCAFFOLD_DIR="${HERMES_SCAFFOLD_DIR:-./hermes-agent}"
SERVICE="${HERMES_COMPOSE_SERVICE:-hermes}"
# REQUIRED; resolved below from env or scaffold .env.
OWNER_PROFILE="${OWNER_PROFILE:-}"
TEAM_PROFILE="${TEAM_PROFILE:-}"
PURGE=0
PURGE_QUERIES=0
RESTORE_LEGACY=0

usage() {
  cat <<EOF
Usage: $0 [options]

Gentle uninstall by default. Removes the courier sidecar + compose override
+ skill installs but preserves the team profile, brain pages, and team secrets.

Options:
  --scaffold PATH    seed-hermes scaffold dir. Default: ./hermes-agent
  --service NAME     Compose service. Default: hermes
  --owner-profile N  Owner profile name. REQUIRED (no default — install-time
                     value persisted to <scaffold>/.env as OWNER_PROFILE=).
  --team-profile N   Team profile name. REQUIRED.
  --purge            DESTRUCTIVE: also delete the team Hermes profile.
  --purge-queries    DESTRUCTIVE: also delete brain/queries/q-*.md
                     (loses in-flight conversation state).
  --restore-legacy   Restore the most recent SKILL.md.bak.* under the owner
                     profile's str-manager-approval/ dir, bringing back the
                     v9.0.0 pirate-only skill.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scaffold)        SCAFFOLD_DIR="$2"; shift 2 ;;
    --service)         SERVICE="$2"; shift 2 ;;
    --owner-profile)   OWNER_PROFILE="$2"; shift 2 ;;
    --team-profile)    TEAM_PROFILE="$2"; shift 2 ;;
    --purge)           PURGE=1; shift ;;
    --purge-queries)   PURGE_QUERIES=1; shift ;;
    --restore-legacy)  RESTORE_LEGACY=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -d "$SCAFFOLD_DIR" ]] || { echo "Scaffold not found: $SCAFFOLD_DIR" >&2; exit 1; }
ENV_FILE="${SCAFFOLD_DIR%/}/.env"

# Resolve OWNER_PROFILE / TEAM_PROFILE from env or scaffold .env. Fail loud if
# missing — operator must know which profile they installed against.
resolve_from_env_file() {
  local varname="$1" current="${!varname:-}"
  if [[ -n "$current" ]]; then return; fi
  if [[ -f "$ENV_FILE" ]]; then
    current=$(awk -F= -v k="$varname" '$1==k{ sub(/^[^=]*=/,"",$0); print; exit }' "$ENV_FILE" \
              | sed -E 's/^"//; s/"$//')
  fi
  if [[ -z "$current" ]]; then
    echo "FAIL: \$$varname not set (env), and not found in ${ENV_FILE}." >&2
    echo "      The installer writes OWNER_PROFILE / TEAM_PROFILE into the scaffold .env." >&2
    echo "      Pass --owner-profile / --team-profile, or export the var." >&2
    exit 2
  fi
  eval "$varname=\"\${current}\""
}
resolve_from_env_file OWNER_PROFILE
resolve_from_env_file TEAM_PROFILE

# 1. Stop + remove the airbnb-courier sidecar.
echo ">>> Stopping airbnb-courier sidecar…"
docker compose -f "${SCAFFOLD_DIR%/}/compose.yaml" --project-directory "${SCAFFOLD_DIR%/}" \
  stop airbnb-courier 2>/dev/null || true
docker compose -f "${SCAFFOLD_DIR%/}/compose.yaml" --project-directory "${SCAFFOLD_DIR%/}" \
  rm -f airbnb-courier 2>/dev/null || true

# 2. Remove compose override.
echo ">>> Removing compose override + sidecar env file…"
rm -f "${SCAFFOLD_DIR%/}/compose.airbnb-coordinator.yaml"
rm -f "${SCAFFOLD_DIR%/}/data/.airbnb-courier.env"

# 3. Strip from COMPOSE_FILE in scaffold .env.
if [[ -f "$ENV_FILE" ]] && grep -q '^COMPOSE_FILE=' "$ENV_FILE"; then
  current=$(awk -F= '$1=="COMPOSE_FILE"{print $2}' "$ENV_FILE")
  new=$(echo ":${current}:" | sed 's|:compose.airbnb-coordinator.yaml:|:|g' | sed 's|^:||;s|:$||')
  if [[ "$new" != "$current" ]]; then
    awk -v new="$new" 'BEGIN{FS=OFS="="} $1=="COMPOSE_FILE"{$2=new}1' "$ENV_FILE" > "${ENV_FILE}.tmp"
    mv -f "${ENV_FILE}.tmp" "$ENV_FILE"
    echo "   - stripped compose.airbnb-coordinator.yaml from COMPOSE_FILE"
  fi
fi

# 4. Restore legacy SKILL.md backup, if requested.
OWNER_SKILL_HOST="${SCAFFOLD_DIR%/}/data/profiles/${OWNER_PROFILE}/skills/str-manager-approval"
if [[ "$RESTORE_LEGACY" == "1" ]]; then
  LATEST_BAK=$(ls -t "${OWNER_SKILL_HOST}/SKILL.md.bak."* 2>/dev/null | head -1 || true)
  if [[ -n "$LATEST_BAK" ]]; then
    cp -f "$LATEST_BAK" "${OWNER_SKILL_HOST}/SKILL.md"
    rm -f "${SCAFFOLD_DIR%/}/data/profiles/${OWNER_PROFILE}/.skills_prompt_snapshot.json"
    echo "   - restored ${LATEST_BAK} -> ${OWNER_SKILL_HOST}/SKILL.md"
  else
    echo "   - no SKILL.md.bak.* under ${OWNER_SKILL_HOST}; nothing to restore"
  fi
else
  echo ">>> NOT restoring legacy boss SKILL.md (pass --restore-legacy to do that)."
fi

# 5. Remove listener skill + team SOUL.md (gentle — leaves profile intact).
TEAM_SKILL_HOST="${SCAFFOLD_DIR%/}/data/profiles/${TEAM_PROFILE}/skills/airbnb-team-listener"
rm -rf "$TEAM_SKILL_HOST"
rm -f "${SCAFFOLD_DIR%/}/data/profiles/${TEAM_PROFILE}/SOUL.md"
rm -f "${SCAFFOLD_DIR%/}/data/profiles/${TEAM_PROFILE}/.skills_prompt_snapshot.json"

# 6. Remove courier script from bind-mount.
rm -rf "${SCAFFOLD_DIR%/}/data/home/airbnb-courier"

# 7. Destructive ops, opt-in.
if [[ "$PURGE" == "1" ]]; then
  echo ">>> --purge: deleting team profile ${TEAM_PROFILE} (DESTRUCTIVE)…"
  docker compose -f "${SCAFFOLD_DIR%/}/compose.yaml" --project-directory "${SCAFFOLD_DIR%/}" \
    exec -T "$SERVICE" bash -lc "echo ${TEAM_PROFILE} | hermes profile delete ${TEAM_PROFILE}" 2>/dev/null || true
fi

if [[ "$PURGE_QUERIES" == "1" ]]; then
  echo ">>> --purge-queries: deleting brain/queries/q-*.md (DESTRUCTIVE)…"
  rm -f "${SCAFFOLD_DIR%/}/data/home/brain/queries/q-"*.md
  # Don't touch the .gitkeep.
fi

echo
echo "DONE. airbnb-coordinator uninstalled."
echo "PRESERVED: brain/team/*.md, brain/properties/*.md, brain/queries/q-*.md"
echo "           (unless --purge-queries was passed), team-secrets.json."
echo "Re-running the installer is safe and idempotent."
