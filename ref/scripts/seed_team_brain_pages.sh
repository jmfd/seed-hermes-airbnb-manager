#!/usr/bin/env bash
# seed_team_brain_pages.sh
#
# Interactive wizard: walks the operator through authoring the initial
# team/*.md and properties/*.md brain pages for their actual team + properties.
# Writes pages into the host bind-mount at <scaffold>/data/home/brain/, then
# git add + git commits them inside the container so gbrain-sync picks them up.
#
# Per-install config — pages are NOT committed to the seed-hermes-airbnb-manager
# repo; they're committed to the operator's brain repo.
#
# Re-runnable: skips members/properties whose pages already exist.

set -euo pipefail

SCAFFOLD_DIR="${HERMES_SCAFFOLD_DIR:-./hermes-agent}"
SERVICE="${HERMES_COMPOSE_SERVICE:-hermes}"
HERMES_UID_OVERRIDE="${HERMES_UID_OVERRIDE:-}"
HERMES_GID_OVERRIDE="${HERMES_GID_OVERRIDE:-}"

usage() {
  cat <<EOF
Usage: $0 [--scaffold PATH] [--service NAME]

Interactive wizard to seed team/*.md and properties/*.md brain pages.
Re-runnable; skips already-present pages.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scaffold) SCAFFOLD_DIR="$2"; shift 2 ;;
    --service)  SERVICE="$2"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -d "$SCAFFOLD_DIR" ]] || { echo "Scaffold not found: $SCAFFOLD_DIR" >&2; exit 1; }
[[ -t 0 ]] || { echo "stdin is not a TTY; wizard requires interactive input. Skipping." >&2; exit 0; }

ENV_FILE="${SCAFFOLD_DIR%/}/.env"
if [[ -z "$HERMES_UID_OVERRIDE" && -f "$ENV_FILE" ]]; then
  HERMES_UID_OVERRIDE="$(awk -F= '$1=="HERMES_UID"{print $2}' "$ENV_FILE")"
fi
if [[ -z "$HERMES_GID_OVERRIDE" && -f "$ENV_FILE" ]]; then
  HERMES_GID_OVERRIDE="$(awk -F= '$1=="HERMES_GID"{print $2}' "$ENV_FILE")"
fi
HERMES_UID_OVERRIDE="${HERMES_UID_OVERRIDE:-501}"
HERMES_GID_OVERRIDE="${HERMES_GID_OVERRIDE:-20}"

HOST_BRAIN_DIR="${SCAFFOLD_DIR%/}/data/home/brain"
HOST_TEAM_DIR="${HOST_BRAIN_DIR}/team"
HOST_PROPS_DIR="${HOST_BRAIN_DIR}/properties"
SECRETS_HOST="${SCAFFOLD_DIR%/}/data/home/.airbnb-coordinator/team-secrets.json"

mkdir -p "$HOST_TEAM_DIR" "$HOST_PROPS_DIR"

slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed 's/-\+/-/g; s/^-\|-$//g'
}

prompt() {
  local var=$1 prompt=$2 default=$3
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " val
    val="${val:-$default}"
  else
    read -r -p "$prompt: " val
  fi
  printf -v "$var" '%s' "$val"
}

prompt_secret() {
  local var=$1 prompt=$2
  read -r -s -p "$prompt: " val; echo
  printf -v "$var" '%s' "$val"
}

write_team_page() {
  local slug=$1 display=$2 uid=$3 role=$4 notes=$5
  local file="${HOST_TEAM_DIR}/${slug}.md"
  if [[ -f "$file" ]]; then
    echo "  skip team/${slug}.md (already exists)"
    return
  fi
  cat > "$file" <<EOF
---
title: "${display}"
member_uid: "${uid}"
role: ${role}
display_name: "${display}"
active: true
languages: [en]
---

# ${display} — ${role}

${notes}
EOF
  echo "  wrote team/${slug}.md"
}

write_property_page() {
  local slug=$1 nickname=$2 prop_id=$3 address=$4 notes=$5
  local file="${HOST_PROPS_DIR}/${slug}.md"
  if [[ -f "$file" ]]; then
    echo "  skip properties/${slug}.md (already exists)"
    return
  fi
  cat > "$file" <<EOF
---
title: "${nickname}"
property_id: "${prop_id}"
address: "${address}"
listing_links:
  hostex: "https://hostex.io/listings/${prop_id}"
---

# ${nickname}

${address}.

${notes}
EOF
  echo "  wrote properties/${slug}.md"
}

# ----------------------------------------------------------------------------
# Team members
# ----------------------------------------------------------------------------
echo
echo "=== TEAM MEMBERS ==="
echo "Enter each team member's display name, plow_chat uid, role, and X-Chat-Secret-Key."
echo "Press ENTER with no name to finish the team section."
echo

count=0
while :; do
  prompt display "Team member display name (or empty to stop)" ""
  [[ -z "$display" ]] && break
  prompt uid "  plow_chat uid (cht_...)" ""
  prompt role "  role" "cleaner"
  prompt notes "  one-line notes" "Handles ${role} tasks."
  prompt_secret secret "  X-Chat-Secret-Key (will be saved to ${SECRETS_HOST}, mode 600)"
  slug=$(slugify "$display")
  if [[ -z "$slug" ]]; then
    echo "  empty slug; skipping"
    continue
  fi
  write_team_page "$slug" "$display" "$uid" "$role" "$notes"
  # Append to secrets file (atomic via python).
  python3 - <<PY
import json, os, pathlib
p = pathlib.Path("${SECRETS_HOST}")
p.parent.mkdir(parents=True, exist_ok=True)
try:
    d = json.loads(p.read_text())
except Exception:
    d = {}
d["${uid}"] = "${secret}"
p.write_text(json.dumps(d, indent=2))
os.chmod(p, 0o600)
PY
  count=$((count+1))
done
echo "${count} team member(s) authored."

# ----------------------------------------------------------------------------
# Properties
# ----------------------------------------------------------------------------
echo
echo "=== PROPERTIES ==="
echo "Enter each property's nickname, Hostex property id, and address."
echo "Per-property team assignments are OPTIONAL — leave the team_assignments"
echo "block commented in the page and the boss skill falls back to global team."
echo "Press ENTER with no nickname to finish."
echo

count=0
while :; do
  prompt nickname "Property nickname (or empty to stop)" ""
  [[ -z "$nickname" ]] && break
  prompt prop_id "  Hostex property id" ""
  prompt address "  Address (one line)" ""
  prompt notes "  one-line notes (optional)" ""
  slug=$(slugify "$nickname")
  if [[ -z "$slug" ]]; then
    echo "  empty slug; skipping"
    continue
  fi
  write_property_page "$slug" "$nickname" "$prop_id" "$address" "$notes"
  count=$((count+1))
done
echo "${count} propert(y/ies) authored."

# ----------------------------------------------------------------------------
# Commit
# ----------------------------------------------------------------------------
echo
echo "=== COMMITTING TO BRAIN REPO ==="
docker compose -f "${SCAFFOLD_DIR%/}/compose.yaml" --project-directory "${SCAFFOLD_DIR%/}" \
  exec -T -u "${HERMES_UID_OVERRIDE}:${HERMES_GID_OVERRIDE}" "$SERVICE" \
  env HOME=/opt/data/home bash -c '
    cd /opt/data/home/brain && \
    git add team properties && \
    if ! git diff --cached --quiet; then \
      git commit -m "coordinator: seed team + properties (operator wizard)" >/dev/null && \
      echo "  committed."; \
    else \
      echo "  nothing to commit (pages may have been committed earlier)."; \
    fi
  '

echo
echo "DONE. Re-run this wizard anytime to add more team members or properties."
