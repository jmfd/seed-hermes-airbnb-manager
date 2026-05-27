#!/usr/bin/env bash
# airbnb-courier — PID 1 of the airbnb-courier compose sidecar.
#
# Per tick (default 60s):
#   1. Call query-edit.py tick which scans queries/q-*.md and emits one JSON
#      action per line on stdout. State is NOT mutated here — only DECIDED.
#   2. For each action, perform the side effect (plow_chat REST POST,
#      wakeAgent). On 2xx / success, re-invoke query-edit.py with the
#      corresponding mutation subcommand. State only advances AFTER the side
#      effect succeeds — this addresses the codex P1 finding about premature
#      state advance.
#
# Locking: query-edit.py flocks LOCK_EX on the page file itself. The skills
# do the same via query-edit.py. There is no /tmp-side lock; a single tool
# owns all read-modify-write through one flock surface.
#
# Reads its config from env (env_file in compose.airbnb-coordinator.yaml):
#   AIRBNB_OWNER_PROFILE              required (operator-chosen handle, e.g. "owner")
#   AIRBNB_OWNER_MIRROR_SESSION_KEY   required
#   AIRBNB_COURIER_TICK_SECONDS       default 60
#   AIRBNB_COURIER_SLA_MINUTES        default 30
#   AIRBNB_COURIER_ESCALATION_MINUTES default 60
#   AIRBNB_COURIER_PARTIAL_STALENESS_SECONDS default 300
#   PLOW_CHAT_BASE_URL                default https://api.plow.co
#   TEAM_CHAT_SECRETS_FILE            default /opt/data/home/.airbnb-coordinator/team-secrets.json
#   BRAIN_DIR                         default /opt/data/home/brain
#   AIRBNB_COURIER_DRY_RUN            set to 1 for a no-side-effects tick (verify.sh uses this)

set -euo pipefail

: "${AIRBNB_OWNER_PROFILE:?missing AIRBNB_OWNER_PROFILE}"
: "${AIRBNB_OWNER_MIRROR_SESSION_KEY:?missing AIRBNB_OWNER_MIRROR_SESSION_KEY}"
: "${AIRBNB_COURIER_TICK_SECONDS:=60}"
: "${AIRBNB_COURIER_SLA_MINUTES:=30}"
: "${AIRBNB_COURIER_ESCALATION_MINUTES:=60}"
: "${AIRBNB_COURIER_PARTIAL_STALENESS_SECONDS:=300}"
: "${PLOW_CHAT_BASE_URL:=https://api.plow.co}"
: "${TEAM_CHAT_SECRETS_FILE:=/opt/data/home/.airbnb-coordinator/team-secrets.json}"
: "${BRAIN_DIR:=/opt/data/home/brain}"
: "${AIRBNB_COURIER_DRY_RUN:=0}"

QUERY_EDIT="$(dirname "$0")/query-edit.py"
[[ -x "$QUERY_EDIT" ]] || QUERY_EDIT="/opt/data/home/airbnb-courier/query-edit.py"

log() {
  printf '[%s] airbnb-courier: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

trap 'log "SIGTERM received, exiting cleanly"; exit 0' TERM
trap 'log "SIGINT received, exiting cleanly"; exit 0' INT

log "starting; tick=${AIRBNB_COURIER_TICK_SECONDS}s sla=${AIRBNB_COURIER_SLA_MINUTES}m escalation=${AIRBNB_COURIER_ESCALATION_MINUTES}m owner=${AIRBNB_OWNER_PROFILE} brain=${BRAIN_DIR} dry_run=${AIRBNB_COURIER_DRY_RUN}"

# Single trusted source for the chat secret. jq is shipped in the hermes image;
# if missing, fall back to python.
get_team_secret() {
  local uid="$1"
  [[ -f "$TEAM_CHAT_SECRETS_FILE" ]] || { echo ""; return; }
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg uid "$uid" '.[$uid] // ""' "$TEAM_CHAT_SECRETS_FILE"
  else
    python3 -c "import json,sys; print(json.load(open('$TEAM_CHAT_SECRETS_FILE')).get('$uid',''))"
  fi
}

# plow_chat POST. Returns 0 only on HTTP 2xx so the caller can defer state
# advance. Body is the literal string passed in.
plow_chat_post() {
  local team_member_uid="$1"
  local body="$2"
  local secret
  secret="$(get_team_secret "$team_member_uid")"
  if [[ -z "$secret" ]]; then
    log "WARN no secret for team_member_uid=${team_member_uid} in ${TEAM_CHAT_SECRETS_FILE}"
    return 1
  fi
  if [[ "$AIRBNB_COURIER_DRY_RUN" == "1" ]]; then
    log "DRY_RUN would POST to plow_chat: uid=${team_member_uid} body=${body}"
    return 0
  fi
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' \
    -X POST "${PLOW_CHAT_BASE_URL%/}/v1/chats/${team_member_uid}/messages" \
    -H "Authorization: Bearer ${secret}" \
    -H 'Content-Type: application/json' \
    --max-time 15 \
    --data-binary "$body" || echo "000")
  [[ "$code" =~ ^2 ]] && return 0
  log "WARN plow_chat POST HTTP ${code} for uid=${team_member_uid}"
  return 1
}

# Resolve session_id from session_key by reading the profile's sessions.json
resolve_session_id() {
  local profile="$1"
  local session_key="$2"
  python3 -c "
import json, sys
try:
    d = json.load(open(f'/opt/data/profiles/${profile}/sessions/sessions.json'))
    print(d.get('${session_key}', {}).get('session_id', ''))
except Exception as e:
    print('', file=sys.stderr)
" 2>/dev/null
}

# Real wake: append a non-interactive turn to the owner-mirror session.
# Replaces the made-up `hermes wakeAgent` with the real CLI: `hermes chat -q ... --resume <session_id>`.
# Boss skill (loaded into that session by SOUL+skill auto-load) sees the prompt
# and fires Trigger 3 to draft the final reply.
wake_owner() {
  local prompt="$1"
  local session_id
  session_id=$(resolve_session_id "$AIRBNB_OWNER_PROFILE" "$AIRBNB_OWNER_MIRROR_SESSION_KEY")
  if [[ -z "$session_id" ]]; then
    log "WARN wake: could not resolve session_id for ${AIRBNB_OWNER_MIRROR_SESSION_KEY} in ${AIRBNB_OWNER_PROFILE}"
    return 1
  fi
  if [[ "$AIRBNB_COURIER_DRY_RUN" == "1" ]]; then
    log "DRY_RUN would wake: hermes -p ${AIRBNB_OWNER_PROFILE} chat -q '${prompt}' --resume ${session_id} -Q --yolo"
    return 0
  fi
  # -q PROMPT: non-interactive single turn
  # --resume SESSION_ID: append to existing session (owner-mirror)
  # -Q: quiet mode (no banner/spinner/previews)
  # --yolo: bypass approval prompts in non-TTY
  # --skills: ensure the boss skill is loaded into the session for this turn
  # 5-minute timeout: the LLM draft + mirror should finish well within this
  if timeout 300 hermes -p "$AIRBNB_OWNER_PROFILE" chat \
       -q "$prompt" \
       --resume "$session_id" \
       --skills str-manager-approval \
       -Q --yolo >/dev/null 2>&1; then
    return 0
  fi
  log "WARN wake: hermes chat --resume failed for session ${session_id}"
  return 1
}


# Deterministically mirror the most recent unmirrored draft to the owner channel
# via Plow Chat REST API. Reads the brain page, finds the newest draft without
# mirrored_to_owner_at, formats the standard mirror string, POSTs to owner chat,
# then calls query-edit.py mark-mirrored.
# This replaces the boss skill's send_message call which is unreliable under
# `hermes chat --resume -q -Q` (tool calls don't persist to session log,
# and the LLM sometimes skips the call entirely).
mirror_unmirrored_draft() {
  local query_id="$1"
  local owner_uid
  owner_uid=$(python3 -c "
import json
d = json.load(open('/opt/data/profiles/${AIRBNB_OWNER_PROFILE}/.env'.replace('//','/')))
" 2>/dev/null)
  # Cheaper to grep the .env directly:
  local owner_token owner_chat_uid
  owner_token=$(grep '^PLOW_CHAT_TOKEN=' "/opt/data/profiles/${AIRBNB_OWNER_PROFILE}/.env" | cut -d= -f2)
  owner_chat_uid=$(grep '^PLOW_CHAT_CHAT_UID=' "/opt/data/profiles/${AIRBNB_OWNER_PROFILE}/.env" | cut -d= -f2)
  if [[ -z "$owner_token" || -z "$owner_chat_uid" ]]; then
    log "WARN mirror: no owner plow_chat creds in /opt/data/profiles/${AIRBNB_OWNER_PROFILE}/.env"
    return 1
  fi
  # Extract draft via query-edit.py show + JSON parse
  local payload
  payload=$(python3 - "$query_id" <<'PYEOF'
import json, os, subprocess, sys
qid = sys.argv[1]
out = subprocess.run(
    ["python3", "/opt/data/home/airbnb-courier/query-edit.py",
     "--brain-dir", os.environ.get("BRAIN_DIR","/opt/data/home/brain"),
     "show", "--query-id", qid],
    capture_output=True, text=True
)
if out.returncode != 0:
    print(json.dumps({"err": out.stderr.strip()})); sys.exit(0)
fm = json.loads(out.stdout)
# Find the freshest draft with no mirrored_to_owner_at
candidates = [d for d in fm.get("drafts",[]) if not d.get("mirrored_to_owner_at")]
if not candidates:
    print(json.dumps({"skip": "no_unmirrored"})); sys.exit(0)
draft = sorted(candidates, key=lambda d: d.get("drafted_at",""))[-1]
kind = draft.get("kind","?")
draft_id = draft.get("draft_id","?")
guest = fm.get("guest_message_content","")
mirror_body = (
    f"[B] external #{draft_id} query={qid} from guest: \"{guest}\"\n"
    f"{'FINAL' if kind == 'final' else 'PARTIAL'} DRAFT: \"{draft.get('content','')}\"\n"
    f"query_id=\"{qid}\"\n"
    f"draft_id=\"{draft_id}\"\n"
    f"Reply: approve / reject / edit <text>"
)
print(json.dumps({"body": mirror_body, "draft_id": draft_id, "kind": kind}))
PYEOF
)
  local skip_or_err
  skip_or_err=$(echo "$payload" | python3 -c "import json,sys;d=json.loads(sys.stdin.read());print(d.get('skip','') or d.get('err',''))")
  if [[ -n "$skip_or_err" ]]; then
    log "mirror: $skip_or_err for $query_id"
    return 0
  fi
  local body draft_id_v kind_v
  body=$(echo "$payload" | python3 -c "import json,sys;print(json.loads(sys.stdin.read())['body'])")
  draft_id_v=$(echo "$payload" | python3 -c "import json,sys;print(json.loads(sys.stdin.read())['draft_id'])")
  kind_v=$(echo "$payload" | python3 -c "import json,sys;print(json.loads(sys.stdin.read())['kind'])")
  # POST to owner plow_chat
  local req
  req=$(python3 -c "import json,sys;print(json.dumps({'body': sys.argv[1]}))" "$body")
  if [[ "$AIRBNB_COURIER_DRY_RUN" == "1" ]]; then
    log "DRY_RUN would POST mirror to owner ${owner_chat_uid}: ${draft_id_v} kind=${kind_v}"
  else
    local code
    code=$(curl -sS -o /dev/null -w '%{http_code}' \
      -X POST "${PLOW_CHAT_BASE_URL%/}/v1/chats/${owner_chat_uid}/messages" \
      -H "Authorization: Bearer ${owner_token}" \
      -H 'Content-Type: application/json' \
      --max-time 15 \
      --data-binary "$req" || echo 000)
    if [[ ! "$code" =~ ^2 ]]; then
      log "WARN mirror POST HTTP $code for $query_id/$draft_id_v"
      return 1
    fi
    log "mirrored draft $draft_id_v (kind=$kind_v) to owner for $query_id"
  fi
  # Mark mirrored in brain page
  if [[ "$AIRBNB_COURIER_DRY_RUN" != "1" ]]; then
    python3 /opt/data/home/airbnb-courier/query-edit.py \
      mark-mirrored --query-id "$query_id" --draft-id "$draft_id_v" >/dev/null 2>&1 || \
      log "WARN mark-mirrored failed for $query_id/$draft_id_v"
  fi
  return 0
}

handle_action() {
  local line="$1"
  local action
  action=$(echo "$line" | python3 -c "import json,sys;print(json.loads(sys.stdin.read()).get('action',''))")
  case "$action" in
    repinging)
      local query_id ask_id uid question new_pc body
      query_id=$(echo "$line" | python3 -c "import json,sys;print(json.loads(sys.stdin.read())['query_id'])")
      ask_id=$(echo "$line" | python3 -c "import json,sys;print(json.loads(sys.stdin.read())['ask_id'])")
      uid=$(echo "$line" | python3 -c "import json,sys;print(json.loads(sys.stdin.read())['team_member_uid'])")
      question=$(echo "$line" | python3 -c "import json,sys;print(json.loads(sys.stdin.read())['question'])")
      new_pc=$(echo "$line" | python3 -c "import json,sys;print(json.loads(sys.stdin.read())['new_ping_count'])")
      body=$(python3 -c "import json,sys;print(json.dumps({'content': 'Reminder — still need an answer to: ' + sys.argv[1]}))" "$question")
      if plow_chat_post "$uid" "$body"; then
        # ONLY advance state after the POST succeeded.
        local new_asked_at
        new_asked_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        if [[ "$AIRBNB_COURIER_DRY_RUN" != "1" ]]; then
          python3 "$QUERY_EDIT" --brain-dir "$BRAIN_DIR" repinging \
            --query-id "$query_id" --ask-id "$ask_id" \
            --new-ping-count "$new_pc" --new-asked-at "$new_asked_at"
        fi
        log "re-pinged ${query_id}/${ask_id} (uid=${uid})"
      else
        log "skip state advance: re-ping POST failed for ${query_id}/${ask_id}"
      fi
      ;;
    escalate)
      local query_id ask_id role question prompt content
      query_id=$(echo "$line" | python3 -c "import json,sys;print(json.loads(sys.stdin.read())['query_id'])")
      ask_id=$(echo "$line" | python3 -c "import json,sys;print(json.loads(sys.stdin.read())['ask_id'])")
      role=$(echo "$line" | python3 -c "import json,sys;print(json.loads(sys.stdin.read())['role'])")
      question=$(echo "$line" | python3 -c "import json,sys;print(json.loads(sys.stdin.read())['question'])")
      prompt="ESCALATE: query_id=${query_id} role=${role} question=\"${question}\" — team member did not reply within SLA. Mirror to owner."
      if wake_owner "$prompt"; then
        content="Escalating: ${role} did not reply to \"${question}\""
        if [[ "$AIRBNB_COURIER_DRY_RUN" != "1" ]]; then
          python3 "$QUERY_EDIT" --brain-dir "$BRAIN_DIR" escalate \
            --query-id "$query_id" --ask-id "$ask_id" \
            --draft-content "$content"
        fi
        log "escalated ${query_id}/${ask_id} (role=${role})"
      else
        log "skip state advance: escalate wakeAgent failed for ${query_id}/${ask_id}"
      fi
      ;;
    mirror_now)
      local query_id
      query_id=$(echo "$line" | python3 -c "import json,sys;print(json.loads(sys.stdin.read())['query_id'])")
      mirror_unmirrored_draft "$query_id" || log "WARN mirror_now failed for $query_id"
      ;;
    wake_for_draft)
      local query_id file prompt
      query_id=$(echo "$line" | python3 -c "import json,sys;print(json.loads(sys.stdin.read())['query_id'])")
      file=$(echo "$line" | python3 -c "import json,sys;print(json.loads(sys.stdin.read())['file'])")
      # Step A: wake boss to draft. Boss writes draft into brain page via
      #         query-edit.py append-draft. (Skill does NOT mirror reliably
      #         in chat --resume mode; we mirror deterministically in step B.)
      prompt="TRIGGER 3 — courier wake. query_id=${query_id}. Read ${file}. Compose the appropriate draft (final if all asks resolved and no existing final draft, partial only if some answered + some pending + no recent partial). Cite team answers VERBATIM. Append the draft via: python3 /opt/data/home/airbnb-courier/query-edit.py append-draft --query-id ${query_id} --kind <KIND> --content-file /tmp/draft.txt   The courier will mirror the new draft to the owner channel; you do NOT need to call send_message."
      wake_owner "$prompt" || log "WARN wake call returned non-zero; checking brain page anyway"
      # Step B: deterministically mirror the freshest unmirrored draft to owner
      #         via direct REST POST. No send_message involvement.
      mirror_unmirrored_draft "$query_id" || log "WARN mirror failed for $query_id"
      log "wake+mirror completed for query_id=${query_id}"
      ;;
    "")
      log "WARN unparseable action line: ${line}"
      ;;
    *)
      log "WARN unknown action: ${action}"
      ;;
  esac
}

# ============================================================================
# Main loop
# ============================================================================
while true; do
  if [[ ! -d "$BRAIN_DIR/queries" ]]; then
    log "queries dir ${BRAIN_DIR}/queries missing; sleeping"
    sleep "$AIRBNB_COURIER_TICK_SECONDS"
    continue
  fi
  # Get the action list for this tick. query-edit.py emits one JSON per line.
  # Read into an array first so a tick failure doesn't kill the loop.
  actions_tmp=$(mktemp /tmp/airbnb-courier-actions.XXXXXX)
  if ! python3 "$QUERY_EDIT" --brain-dir "$BRAIN_DIR" tick \
        --sla-minutes "$AIRBNB_COURIER_SLA_MINUTES" \
        --escalation-minutes "$AIRBNB_COURIER_ESCALATION_MINUTES" \
        --partial-staleness-seconds "$AIRBNB_COURIER_PARTIAL_STALENESS_SECONDS" \
        > "$actions_tmp" 2>&1; then
    log "WARN query-edit tick failed: $(head -c 200 "$actions_tmp")"
    rm -f "$actions_tmp"
    sleep "$AIRBNB_COURIER_TICK_SECONDS"
    continue
  fi
  if [[ -s "$actions_tmp" ]]; then
    while IFS= read -r action_line; do
      [[ -z "$action_line" ]] && continue
      handle_action "$action_line" || log "WARN handler raised for: $action_line"
    done < "$actions_tmp"
  fi
  rm -f "$actions_tmp"
  sleep "$AIRBNB_COURIER_TICK_SECONDS"
done
