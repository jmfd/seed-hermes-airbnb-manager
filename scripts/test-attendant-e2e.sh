#!/usr/bin/env bash
# test-attendant-e2e.sh — behavioral validation of v12 attendant rules.
#
# Architectural principle (CEO 2026-05-25): no regex on draft text. The model
# is supposed to produce attendant behavior because it understands the role
# (via SKILL.md §"v12 change: attendant, not pigeon-carrier" + few-shot
# examples), NOT because a sanitizer catches violations.
#
# This script captures actual drafts from a live DTU flow and prints them
# for operator (or LLM-as-judge) review. The single hard check is the
# AUDIT vs. DRAFT separation: cleaner's verbatim text MUST remain in
# query page asks[].answer, and MUST NOT be the text of drafts[].content.
#
# Stage A — Branch 0 memory hit (wifi question, host voice if style.md present)
# Stage B — Trigger 3 bag-drop (CEO's canonical pigeon-carrier scenario)
#
# Pass = drafts look attendant-shaped to a human reader, AND the audit-vs-
# draft separation holds. Failure mode = SKILL.md teaching needs fixing,
# NOT a regex addition.

set -euo pipefail

SCAFFOLD="${HERMES_SCAFFOLD_DIR:-/private/tmp/plow-seeds/hermes-agent}"
OWNER_PROFILE="${OWNER_PROFILE:-daniel}"
STAGE_TIMEOUT="${STAGE_TIMEOUT:-240}"

while [ $# -gt 0 ]; do
  case "$1" in
    --scaffold) SCAFFOLD="$2"; shift 2 ;;
    --owner-profile) OWNER_PROFILE="$2"; shift 2 ;;
    --help|-h) sed -n '2,20p' "$0" | sed 's/^# *//'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 3 ;;
  esac
done

SCAFFOLD_ABS=$(cd "$SCAFFOLD" && pwd)
T0=$(date +%s)
log() { echo "[T+$(($(date +%s) - T0))s] $*"; }

dce() { ( cd "$SCAFFOLD_ABS" && docker compose exec "$@" ); }

# Preflight
log "preflight"
( cd "$SCAFFOLD_ABS" && docker compose ps hermes 2>/dev/null | grep -q Up ) \
  || { echo "hermes service not running in $SCAFFOLD_ABS" >&2; exit 3; }
SKILL="$SCAFFOLD_ABS/data/profiles/$OWNER_PROFILE/skills/str-manager-approval/SKILL.md"
[ -f "$SKILL" ] || { echo "skill missing: $SKILL" >&2; exit 3; }
grep -q "^version: 12\." "$SKILL" || { echo "boss skill is not v12 (see frontmatter)" >&2; exit 3; }
log "v12 boss skill present on $OWNER_PROFILE"

# Stage B (the CEO scenario) — run first because it's the hardest case
log "Stage B: bag-drop with synthetic cleaner answer (CEO scenario)"
QID="q-V12ATTENDANT-bagdrop-$(date +%H%M%S)"
dce -T -u 501:20 -e HOME=/opt/data/home hermes bash -lc "
python3 /opt/data/home/airbnb-courier/query-edit.py create-query \
  --query-id '$QID' \
  --conv-id 'TEST-CONV-BAGDROP' \
  --msg-id 'TEST-MSG-BAGDROP' \
  --content 'Hi! Can we drop bags at 11:30 before check-in?' \
  --property-id '12051776' \
  --owner-mirror-key 'agent:main:plow_chat:dm:cht_TEST' \
  --asks-json '[{\"team_member_uid\":\"cht_TEST_CLEANER\",\"role\":\"cleaner\",\"question\":\"Can guest drop bags at 11:30?\",\"sla_minutes\":30,\"escalation_minutes\":60}]' \
  --title 'Q: Bag drop timing' >/dev/null
python3 /opt/data/home/airbnb-courier/query-edit.py write-answer \
  --query-id '$QID' --ask-id ask-1 \
  --answer-text 'Yes that is doable; Actually the earliest we can do is 11:30' >/dev/null
"

PROMPT="draft reply for query_id=$QID; read /opt/data/home/brain/queries/$QID.md"
log "firing Trigger 3 (Stage B; budget ${STAGE_TIMEOUT}s)"
( cd "$SCAFFOLD_ABS" && timeout "$STAGE_TIMEOUT" docker compose exec -T -u 501:20 -e HOME=/opt/data/home hermes \
    bash -lc "/opt/hermes/.venv/bin/hermes -p $OWNER_PROFILE chat -q '$PROMPT' 2>&1" ) \
    > /tmp/attendant-stage-b.log 2>&1 || true

VERBATIM_ANSWER=$(dce -T -u 501:20 hermes bash -lc "python3 /opt/data/home/airbnb-courier/query-edit.py show --query-id '$QID' | python3 -c 'import sys,json; print(json.load(sys.stdin)[\"asks\"][0].get(\"answer\",\"\"))'" | tr -d '\r')
DRAFT_CONTENT=$(dce -T -u 501:20 hermes bash -lc "python3 /opt/data/home/airbnb-courier/query-edit.py show --query-id '$QID' | python3 -c 'import sys,json; d=json.load(sys.stdin); ds=d.get(\"drafts\",[]); print(ds[0][\"content\"] if ds else \"\")'" | tr -d '\r')

echo
echo "════════════════════════════════════════════════════════════════════════"
echo "STAGE B — BAG-DROP RESULT"
echo "════════════════════════════════════════════════════════════════════════"
echo
echo "CLEANER'S VERBATIM ANSWER (in audit trail — should NOT appear in draft):"
echo "  $VERBATIM_ANSWER"
echo
echo "BOSS-DRAFTED FINAL (the guest-facing text):"
echo "  $DRAFT_CONTENT"
echo
echo "CEO REFERENCE GOOD DRAFT:"
echo "  Hi Alice — 11:30 works for bag drop, see you then."
echo
echo "CEO REFERENCE BAD DRAFT (pigeon-carrier — what NOT to produce):"
echo "  I checked on the bag drop timing. The cleaner confirmed: \"Yes that is"
echo "  doable; Actually the earliest we can do is 11:30\"."
echo

# Single hard check: audit vs draft separation. NOT a regex on draft text;
# checks that draft is materially different text from the verbatim audit.
if [ -z "$DRAFT_CONTENT" ]; then
  echo "✗ Stage B: no draft produced. Boss did not engage." >&2
  exit 2
fi
if [ "$DRAFT_CONTENT" = "$VERBATIM_ANSWER" ]; then
  echo "✗ Stage B: draft text IS the verbatim cleaner answer." >&2
  echo "  Audit-vs-draft separation violated. Fix SKILL.md Trigger 3 step 4." >&2
  exit 2
fi
echo "✓ Stage B: audit-vs-draft separation OK (different text)."
echo
echo "OPERATOR EYEBALL: does the BOSS-DRAFTED FINAL above sound like the host"
echo "answering the guest, or like a pipeline relaying a check? If the latter,"
echo "the SKILL.md §'v12 change: attendant, not pigeon-carrier' few-shot"
echo "examples need sharpening — NOT a regex addition."
echo
echo "(LLM-as-judge: scripts/test-attendant-llm-judge.sh — TODO)"
echo "════════════════════════════════════════════════════════════════════════"
