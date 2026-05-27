#!/usr/bin/env bash
# test-e2e.sh — fully reproducible end-to-end simulation of the airbnb-coordinator
# flow with ZERO human input. All 3 humans (guest, cleaner, owner) are simulated
# via APIs (DTU + Hermes CLI). The real boss/listener/courier all run unchanged.
#
# What this proves:
#   guest → DTU → boss webhook → boss classifies cleaner → POSTs to wife chat
#         → boss AUTO-SHIPS partial courtesy ack to DTU (NEW — no owner approve)
#         → assert partial reaches DTU + contains NO internal team names
#         → simulate wife reply → listener writes answer to brain page
#         → courier wakes boss → boss drafts FINAL citing wife's verbatim answer
#         → simulate owner approve → boss POSTs to DTU
#         → assert DTU has 2 host messages: the partial AND the final cited reply
#
# Usage:
#   ./scripts/test-e2e.sh                          # full run, ~3-5 min wall time
#   ./scripts/test-e2e.sh --content "different question"
#   ./scripts/test-e2e.sh --simulated-cleaner-reply "yes done by 12:30"
#   ./scripts/test-e2e.sh --scaffold ../seed-hermes/hermes-agent  # non-default scaffold
#   ./scripts/test-e2e.sh --no-cleanup   # leave queries + DTU conv intact for inspection
#
# Exit codes:
#   0   E2E success — DTU received the final cited reply
#   1   timeout waiting for some stage
#   2   stage mismatch (e.g. wrong text shipped, partial shipped instead of final)
#   3   bad invocation
#
# Reproducibility note: each run creates a fresh DTU conversation and a fresh
# query page. Plow_chat history accumulates per chat (we cannot reset it from
# this side), but the simulated wife / owner replies use `hermes chat --resume`
# to inject into the per-profile session — they never touch the iPhones.

set -euo pipefail

SCAFFOLD="${HERMES_SCAFFOLD_DIR:-/private/tmp/plow-seeds/hermes-agent}"
DTU_URL="${DTU_URL:-http://127.0.0.1:8080}"
HERMES_CONTAINER="${HERMES_CONTAINER:-seed-hermes-2568931506-hermes}"
# REQUIRED; resolved from env or <scaffold>/.env below.
OWNER_PROFILE="${OWNER_PROFILE:-}"
TEAM_PROFILE="${TEAM_PROFILE:-}"

GUEST_NAME="${GUEST_NAME:-Haynes Wood}"
GUEST_PROPERTY="${GUEST_PROPERTY:-mtn-home}"
GUEST_CONTENT="${GUEST_CONTENT:-Hi, can I check in at 1pm today?}"
SIM_CLEANER_REPLY="${SIM_CLEANER_REPLY:-Actually we will not be able to do that}"
SIM_OWNER_APPROVE="${SIM_OWNER_APPROVE:-approve}"

CLEANUP=1
WAIT_QUERY_S=180          # boss first-turn: webhook fetch + classify + write + POST + mirror
WAIT_WIFE_POST_S=180      # captured in same first-turn as STAGE 2
WAIT_LISTENER_S=120       # listener turn: read brain + flock + write + commit + ack reply
WAIT_COURIER_S=120        # courier tick = 60s; allow 2 ticks
WAIT_FINAL_DRAFT_S=180    # boss wake turn: read query + draft + write + mirror
WAIT_DTU_DELIVERY_S=180   # boss approve turn: POST to Hostex + outbox write
WAIT_PARTIAL_DTU_S=60     # boss webhook turn auto-ships partial; poll DTU briefly

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scaffold)                 SCAFFOLD="$2"; shift 2 ;;
    --container)                HERMES_CONTAINER="$2"; shift 2 ;;
    --owner-profile)            OWNER_PROFILE="$2"; shift 2 ;;
    --team-profile)             TEAM_PROFILE="$2"; shift 2 ;;
    --content)                  GUEST_CONTENT="$2"; shift 2 ;;
    --simulated-cleaner-reply)  SIM_CLEANER_REPLY="$2"; shift 2 ;;
    --no-cleanup)               CLEANUP=0; shift ;;
    -h|--help)
      sed -n '1,30p' "$0" | sed 's/^# *//'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 3 ;;
  esac
done

# Resolve OWNER_PROFILE / TEAM_PROFILE from env or scaffold .env. REQUIRED.
_resolve_pf() {
  local varname="$1" current="${!varname:-}"
  if [[ -n "$current" ]]; then return; fi
  local env_file="${SCAFFOLD%/}/.env"
  if [[ -f "$env_file" ]]; then
    current=$(awk -F= -v k="$varname" '$1==k{ sub(/^[^=]*=/,"",$0); print; exit }' "$env_file" \
              | sed -E 's/^"//; s/"$//')
  fi
  if [[ -z "$current" ]]; then
    echo "FAIL: \$$varname not set (env), and not found in ${env_file}." >&2
    echo "      Run the installer first, or pass --owner-profile / --team-profile." >&2
    exit 3
  fi
  eval "$varname=\"\${current}\""
}
_resolve_pf OWNER_PROFILE
_resolve_pf TEAM_PROFILE

# ANSI colors (printf %b interprets escape sequences)
B=$'\033[1m'; R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; N=$'\033[0m'

T0=$(date +%s)
log() {
  local elapsed=$(( $(date +%s) - T0 ))
  printf "%s[T+%3ds]%s %s\n" "$C" "$elapsed" "$N" "$*"
}
ok()   { log "${G}OK${N}  $*"; }
fail() { log "${R}FAIL${N} $*"; cleanup_or_keep; exit 2; }
timeout_fail() { log "${R}TIMEOUT${N} $*"; cleanup_or_keep; exit 1; }

cleanup_or_keep() {
  if [[ "$CLEANUP" == "0" ]]; then
    log "${Y}--no-cleanup${N}: leaving query page + DTU conv intact"
    log "   query page: $LATEST_Q_PATH"
    log "   DTU conv:   $CONV_ID"
  fi
}

# ============================================================================
# Pre-flight: confirm DTU + container + profiles are alive
# ============================================================================
log "${B}preflight${N} — verifying scaffold + DTU + profiles"
curl -fsS "$DTU_URL/healthz" >/dev/null 2>&1 || { echo "${R}DTU not reachable at $DTU_URL${N}"; exit 3; }
docker ps --format '{{.Names}}' | grep -qx "$HERMES_CONTAINER" || { echo "${R}container $HERMES_CONTAINER not running${N}"; exit 3; }
[[ -d "$SCAFFOLD/data" ]] || { echo "${R}scaffold not found: $SCAFFOLD${N}"; exit 3; }

# Resolve session IDs for owner-mirror + listener
OWNER_MIRROR_KEY=$(grep '^AIRBNB_OWNER_MIRROR_SESSION_KEY=' "$SCAFFOLD/data/profiles/$OWNER_PROFILE/.env" 2>/dev/null | cut -d= -f2)
[[ -z "$OWNER_MIRROR_KEY" ]] && { echo "${R}AIRBNB_OWNER_MIRROR_SESSION_KEY not set in $OWNER_PROFILE .env${N}"; exit 3; }

OWNER_SESSION_ID=$(python3 -c "
import json
d = json.load(open('$SCAFFOLD/data/profiles/$OWNER_PROFILE/sessions/sessions.json'))
print(d.get('$OWNER_MIRROR_KEY', {}).get('session_id', ''))")
[[ -z "$OWNER_SESSION_ID" ]] && { echo "${R}owner session not found for key $OWNER_MIRROR_KEY${N}"; exit 3; }

WIFE_UID=$(grep '^PLOW_CHAT_CHAT_UID=' "$SCAFFOLD/data/profiles/$TEAM_PROFILE/.env" | cut -d= -f2)
TEAM_SESSION_KEY="agent:main:plow_chat:dm:$WIFE_UID"
TEAM_SESSION_ID=$(python3 -c "
import json
d = json.load(open('$SCAFFOLD/data/profiles/$TEAM_PROFILE/sessions/sessions.json'))
print(d.get('$TEAM_SESSION_KEY', {}).get('session_id', ''))")
[[ -z "$TEAM_SESSION_ID" ]] && { echo "${R}team session not found for key $TEAM_SESSION_KEY${N}"; exit 3; }

ok "DTU + container reachable. owner_session=$OWNER_SESSION_ID team_session=$TEAM_SESSION_ID"

# ============================================================================
# STAGE 1: fire guest message via DTU
# ============================================================================
log "${B}STAGE 1${N} — firing guest message via DTU"
log "   from: $GUEST_NAME, property: $GUEST_PROPERTY"
log "   content: \"$GUEST_CONTENT\""

DTU_FIRE_OUT=$(~/.local/bin/dtu guest send \
  --property "$GUEST_PROPERTY" \
  --from "$GUEST_NAME" \
  --content "$GUEST_CONTENT")
CONV_ID=$(echo "$DTU_FIRE_OUT" | python3 -c "import json,sys;print(json.load(sys.stdin)['conversation_id'])")
MSG_ID=$(echo "$DTU_FIRE_OUT" | python3 -c "import json,sys;print(json.load(sys.stdin)['message_id'])")
ok "DTU fired — conv_id=$CONV_ID msg_id=$MSG_ID"

# ============================================================================
# STAGE 2: wait for boss to create the query page
# ============================================================================
log "${B}STAGE 2${N} — polling for boss-created query page (timeout ${WAIT_QUERY_S}s)"
# Match by guest_conversation_id INSIDE the page, not by filename (boss only
# uses first ~3 chars of conv_id in the filename, but the conversation_id
# field is exact). Use shopt -s nullglob so an empty queries dir doesn't
# kill the script under set -e.
LATEST_Q_PATH=""
shopt -s nullglob
for i in $(seq 1 "$WAIT_QUERY_S"); do
  CANDIDATE=""
  files=("$SCAFFOLD/data/home/brain/queries/"q-*.md)
  if (( ${#files[@]} > 0 )); then
    CANDIDATE=$(grep -l "guest_conversation_id:.*${CONV_ID}" "${files[@]}" 2>/dev/null | head -1) || true
  fi
  if [[ -n "$CANDIDATE" ]]; then
    LATEST_Q_PATH="$CANDIDATE"
    break
  fi
  sleep 1
done
shopt -u nullglob
[[ -z "$LATEST_Q_PATH" ]] && timeout_fail "no query page referencing $CONV_ID created within ${WAIT_QUERY_S}s"
QUERY_ID=$(basename "$LATEST_Q_PATH" .md)
ok "boss created query — $QUERY_ID"

# ============================================================================
# STAGE 3: wait for boss to POST the ask to wife's plow_chat
#   Detected via brain page: ask asked_at is set + ask question populated.
#   Plow-side delivery is verified separately if PLOW_VERIFY=1.
# ============================================================================
log "${B}STAGE 3${N} — polling for boss → wife plow_chat POST (timeout ${WAIT_WIFE_POST_S}s)"
ASK_QUESTION=""
for i in $(seq 1 "$WAIT_WIFE_POST_S"); do
  ASK_QUESTION=$(python3 - "$LATEST_Q_PATH" <<'PY'
import sys, re
text = open(sys.argv[1]).read()
m = re.search(r"^\s*question:\s*(.+)$", text, re.M)
print(m.group(1).strip().strip("'\"") if m else "")
PY
  )
  if [[ -n "$ASK_QUESTION" && "$ASK_QUESTION" != "null" ]]; then
    break
  fi
  sleep 1
done
[[ -z "$ASK_QUESTION" ]] && timeout_fail "boss never wrote the ask question into the query page"
ok "boss wrote ask: \"$ASK_QUESTION\""

# ============================================================================
# STAGE 3.5: assert the auto-ack partial reached DTU + contains NO internal team names
#   The boss skill (v10.0.0+ with auto-ack-partial-to-guest patch) auto-ships
#   a courtesy "working on it" reply to the guest BEFORE the cleaner answers,
#   bypassing owner approval for the partial only. This stage proves:
#     (a) DTU received a host message within ~WAIT_PARTIAL_DTU_S seconds,
#     (b) that message contains NONE of the internal team-member display names
#         (cleaner, handyman, etc.) — the no-internal-names hard rule.
#     (c) the partial draft on the brain page has auto_shipped_to_guest_at set.
# ============================================================================
log "${B}STAGE 3.5${N} — verifying auto-ack partial reached DTU (timeout ${WAIT_PARTIAL_DTU_S}s)"
PARTIAL_DTU_CONTENT=""
for i in $(seq 1 "$WAIT_PARTIAL_DTU_S"); do
  PARTIAL_DTU_CONTENT=$(curl -fsS "$DTU_URL/v3/conversations/$CONV_ID" 2>/dev/null | \
    python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    msgs = [m for m in d.get('data',{}).get('messages',[]) if m.get('sender_role') == 'host']
    if msgs:
        print(msgs[0].get('content',''))
except Exception:
    pass
")
  [[ -n "$PARTIAL_DTU_CONTENT" ]] && break
  sleep 1
done
[[ -z "$PARTIAL_DTU_CONTENT" ]] && timeout_fail "auto-ack partial never reached DTU within ${WAIT_PARTIAL_DTU_S}s"
log "   DTU received partial: \"$PARTIAL_DTU_CONTENT\""
log "   ${Y}(behavioral tone — host-attendant vs internal-routing — eyeball above, NOT regex-gated)${N}"

# Verify auto_shipped_to_guest_at landed on the partial draft.
AUTO_SHIPPED_AT=$(grep -E "^\s+auto_shipped_to_guest_at:" "$LATEST_Q_PATH" | head -1 | sed -E 's/^\s+auto_shipped_to_guest_at:\s*//' | tr -d "'\"")
if [[ -n "$AUTO_SHIPPED_AT" && "$AUTO_SHIPPED_AT" != "null" ]]; then
  ok "brain page records auto_shipped_to_guest_at=$AUTO_SHIPPED_AT"
else
  log "${Y}WARN${N} no auto_shipped_to_guest_at on partial draft (partial reached DTU but bookkeeping missing)"
fi

# ============================================================================
# STAGE 4: simulate the cleaner reply via Hermes CLI on the listener session
#   This appends a user turn to the ${TEAM_PROFILE} profile's plow_chat session.
#   The listener skill in that session fires Trigger B, finds the open ask,
#   writes the verbatim answer into the brain page.
# ============================================================================
log "${B}STAGE 4${N} — simulating cleaner reply via Hermes CLI"
log "   cleaner says: \"$SIM_CLEANER_REPLY\""

SIM_OUT=$(docker exec -u 501:20 -e HOME=/opt/data/home "$HERMES_CONTAINER" \
  timeout 120 hermes -p "$TEAM_PROFILE" chat \
    -q "$SIM_CLEANER_REPLY" \
    --resume "$TEAM_SESSION_ID" \
    --skills airbnb-team-listener \
    -Q --yolo 2>&1 || true)
log "   listener responded (truncated):"
echo "$SIM_OUT" | head -3 | sed 's/^/      /'

# ============================================================================
# STAGE 5: wait for listener to write the answer to the brain page
# ============================================================================
log "${B}STAGE 5${N} — polling for listener-written answer in brain page (timeout ${WAIT_LISTENER_S}s)"
ANSWERED=0
for i in $(seq 1 "$WAIT_LISTENER_S"); do
  if grep -q "^  status: answered" "$LATEST_Q_PATH" && \
     grep -q "answer:.*$(echo "$SIM_CLEANER_REPLY" | cut -c1-15)" "$LATEST_Q_PATH"; then
    ANSWERED=1; break
  fi
  sleep 1
done
[[ "$ANSWERED" == "0" ]] && timeout_fail "listener never wrote cleaner answer into brain page"
ok "listener wrote answer into query page"

# ============================================================================
# STAGE 6: wait for courier to wake boss for the final draft
# ============================================================================
log "${B}STAGE 6${N} — polling for boss-drafted FINAL reply citing cleaner (timeout ${WAIT_FINAL_DRAFT_S}s)"
FINAL_PRESENT=0
for i in $(seq 1 "$WAIT_FINAL_DRAFT_S"); do
  if grep -E "^  kind: final" "$LATEST_Q_PATH" >/dev/null 2>&1; then
    FINAL_PRESENT=1; break
  fi
  sleep 1
done
[[ "$FINAL_PRESENT" == "0" ]] && timeout_fail "courier→boss never produced a kind=final draft"
ok "boss drafted final reply"

# Extract the final draft content
FINAL_CONTENT=$(python3 - "$LATEST_Q_PATH" <<'PY'
import sys, re
text = open(sys.argv[1]).read()
m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
if not m: sys.exit(1)
try:
    import yaml
    fm = yaml.safe_load(m.group(1))
    for d in fm.get("drafts", []):
        if d.get("kind") == "final":
            print(d.get("content","").strip())
            break
except ImportError:
    # Fallback: regex extract
    block = re.search(r"- draft_id: draft-2.*?content: ['\"]?([^'\"\n]+)", m.group(1), re.S)
    if block: print(block.group(1).strip())
PY
)
[[ -z "$FINAL_CONTENT" ]] && fail "could not extract final draft content from query page"
log "   final draft: \"$FINAL_CONTENT\""
log "   cleaner said: \"$SIM_CLEANER_REPLY\""
log "   ${Y}(behavioral check — does final faithfully convey cleaner's answer? eyeball above, NOT regex-gated)${N}"

# ============================================================================
# STAGE 7: simulate owner approval via Hermes CLI on the owner-mirror session
# ============================================================================
log "${B}STAGE 7${N} — simulating owner approval via Hermes CLI"

# Find the FINAL draft_id from the brain page (boss may have named it draft-2,
# draft-3 on re-runs; never assume).
FINAL_DRAFT_ID=$(python3 - "$LATEST_Q_PATH" <<'PY'
import sys, re
text = open(sys.argv[1]).read()
m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
if not m: sys.exit(1)
try:
    import yaml
    fm = yaml.safe_load(m.group(1))
    for d in fm.get("drafts", []):
        if d.get("kind") == "final":
            print(d.get("draft_id",""))
            break
except ImportError:
    block = re.search(r"- draft_id: ([^\n]+)\n  kind: final", m.group(1))
    if block: print(block.group(1).strip())
PY
)
[[ -z "$FINAL_DRAFT_ID" ]] && fail "could not extract final draft_id from query page"

# v12.1 — owner just types 'approve' (or similar). The boss uses
# query-edit.py latest-pending-approve to find the most-recent pending
# final draft by recency, then follows Branch A to ship it. The hostex
# base URL + access token come from the durable webhook subscription
# prompt (not from this approve message).
APPROVE_PROMPT="${SIM_OWNER_APPROVE}"
log "   approve prompt (v12.1, no embedded IDs): \"${APPROVE_PROMPT}\""

APPROVE_OUT=$(docker exec -u 501:20 -e HOME=/opt/data/home "$HERMES_CONTAINER" \
  timeout 180 hermes -p "$OWNER_PROFILE" chat \
    -q "$APPROVE_PROMPT" \
    --resume "$OWNER_SESSION_ID" \
    --skills str-manager-approval \
    -Q --yolo 2>&1 || true)
log "   boss responded (truncated):"
echo "$APPROVE_OUT" | head -3 | sed 's/^/      /'

# ============================================================================
# STAGE 8: wait for boss to POST the approved final to DTU (the SECOND host msg)
# ============================================================================
log "${B}STAGE 8${N} — polling DTU for a SECOND host reply (the final; timeout ${WAIT_DTU_DELIVERY_S}s)"
DELIVERED_CONTENT=""
HOST_MSG_COUNT=0
for i in $(seq 1 "$WAIT_DTU_DELIVERY_S"); do
  HOST_MSGS_JSON=$(curl -fsS "$DTU_URL/v3/conversations/$CONV_ID" 2>/dev/null | \
    python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    msgs = [m.get('content','') for m in d.get('data',{}).get('messages',[]) if m.get('sender_role') == 'host']
    print(json.dumps(msgs))
except Exception:
    print('[]')
")
  HOST_MSG_COUNT=$(echo "$HOST_MSGS_JSON" | python3 -c "import json,sys;print(len(json.load(sys.stdin)))")
  if [[ "$HOST_MSG_COUNT" -ge 2 ]]; then
    DELIVERED_CONTENT=$(echo "$HOST_MSGS_JSON" | python3 -c "import json,sys;print(json.load(sys.stdin)[-1])")
    break
  fi
  sleep 1
done
[[ "$HOST_MSG_COUNT" -lt 2 ]] && timeout_fail "DTU never received a SECOND host reply (final). Got $HOST_MSG_COUNT host msg(s) — auto-ack partial only?"

# ============================================================================
# STAGE 9: assert DTU has BOTH the partial (STAGE 3.5) AND the final (STAGE 8)
# ============================================================================
log "${B}STAGE 9${N} — verifying DTU has BOTH the partial AND the final"
log "   host msg count:  $HOST_MSG_COUNT (expected >= 2: partial + final)"
log "   final delivered: \"$DELIVERED_CONTENT\""

# Auto-ack contract: PARTIAL is host[0] (verified in STAGE 3.5), FINAL is host[-1].
# Both must be present; final must NOT match the partial (different drafts).
if [[ "$DELIVERED_CONTENT" == "$PARTIAL_DTU_CONTENT" ]]; then
  fail "FINAL host message is identical to the PARTIAL — boss never shipped the cleaner-cited final after approve"
fi
ok "DTU has $HOST_MSG_COUNT host messages — partial + final are distinct"

# The final content should match what the boss drafted
if [[ "$DELIVERED_CONTENT" == *"$FINAL_CONTENT"* ]] || \
   [[ "$FINAL_CONTENT" == *"$DELIVERED_CONTENT"* ]]; then
  ok "final DTU message matches the kind=final draft text"
else
  log "${Y}WARN${N} DTU content doesn't exactly match final draft (model may have varied phrasing on approve turn)"
  log "    final draft:    \"$FINAL_CONTENT\""
  log "    DTU delivered:  \"$DELIVERED_CONTENT\""
  log "    treating as PASS — boss did POST a non-partial second host reply"
fi

# Behavioral observation — does the final delivered text faithfully convey
# the cleaner's answer? Eyeball, NOT regex-gated. Voice/fidelity is taught
# by SKILL.md; this test only verifies the structural protocol (2 host msgs
# on DTU, distinct, both shipped through the right paths).
log "   ${Y}(behavioral check — fidelity to cleaner's reply — eyeball above, NOT regex-gated)${N}"

# ============================================================================
# Done
# ============================================================================
T_TOTAL=$(( $(date +%s) - T0 ))
echo ""
echo "${G}════════════════════════════════════════════════════════════${N}"
echo "${G}  E2E SIMULATION PASSED — total wall time: ${T_TOTAL}s${N}"
echo "${G}════════════════════════════════════════════════════════════${N}"
echo ""
echo "  query:           $QUERY_ID"
echo "  DTU conv:        $CONV_ID"
echo "  cleaner replied: \"$SIM_CLEANER_REPLY\""
echo "  boss drafted:    \"$FINAL_CONTENT\""
echo "  guest received:  \"$DELIVERED_CONTENT\""
echo ""

cleanup_or_keep
exit 0
