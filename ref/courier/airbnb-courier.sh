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
#   AIRBNB_OWNER_PROFILE              required (e.g. "daniel")
#   AIRBNB_OWNER_MIRROR_SESSION_KEY   required
#   AIRBNB_COURIER_TICK_SECONDS       default 60
#   AIRBNB_COURIER_SLA_MINUTES        default 30
#   AIRBNB_COURIER_ESCALATION_MINUTES default 60
#   AIRBNB_COURIER_PARTIAL_STALENESS_SECONDS default 300
#   PLOW_CHAT_BASE_URL                default https://chat.plow.co
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
: "${PLOW_CHAT_BASE_URL:=https://chat.plow.co}"
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
    -H "X-Chat-Secret-Key: ${secret}" \
    -H 'Content-Type: application/json' \
    --max-time 15 \
    --data-binary "$body" || echo "000")
  [[ "$code" =~ ^2 ]] && return 0
  log "WARN plow_chat POST HTTP ${code} for uid=${team_member_uid}"
  return 1
}

wake_owner() {
  local prompt="$1"
  if [[ "$AIRBNB_COURIER_DRY_RUN" == "1" ]]; then
    log "DRY_RUN would wake: hermes -p ${AIRBNB_OWNER_PROFILE} wakeAgent --session ${AIRBNB_OWNER_MIRROR_SESSION_KEY} --prompt '${prompt}'"
    return 0
  fi
  if hermes -p "$AIRBNB_OWNER_PROFILE" wakeAgent \
       --session "$AIRBNB_OWNER_MIRROR_SESSION_KEY" \
       --prompt "$prompt" >/dev/null 2>&1; then
    return 0
  fi
  log "WARN wakeAgent FAILED prompt=${prompt}"
  return 1
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
    wake_for_draft)
      local query_id file prompt
      query_id=$(echo "$line" | python3 -c "import json,sys;print(json.loads(sys.stdin.read())['query_id'])")
      file=$(echo "$line" | python3 -c "import json,sys;print(json.loads(sys.stdin.read())['file'])")
      prompt="draft reply for query_id=${query_id}; read ${file}"
      if wake_owner "$prompt"; then
        log "woke owner for draft: query_id=${query_id}"
      fi
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
  if ! python3 "$QUERY_EDIT" --brain-dir "$BRAIN_DIR" \
        --sla-minutes "$AIRBNB_COURIER_SLA_MINUTES" \
        --escalation-minutes "$AIRBNB_COURIER_ESCALATION_MINUTES" \
        --partial-staleness-seconds "$AIRBNB_COURIER_PARTIAL_STALENESS_SECONDS" \
        tick > "$actions_tmp" 2>&1; then
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
