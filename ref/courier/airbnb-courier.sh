#!/usr/bin/env bash
# airbnb-courier — PID 1 of the airbnb-courier compose sidecar.
#
# Loops forever; every AIRBNB_COURIER_TICK_SECONDS (default 60), scans
# /opt/data/home/brain/queries/q-*.md, processes open asks (re-ping at
# AIRBNB_COURIER_SLA_MINUTES, escalate at AIRBNB_COURIER_ESCALATION_MINUTES),
# and wakes the owner Hermes profile via `hermes -p <owner> wakeAgent` when
# a query is ready to draft.
#
# Reads its config from env (set by env_file in compose.airbnb-coordinator.yaml):
#   AIRBNB_OWNER_PROFILE              required, e.g. "daniel"
#   AIRBNB_OWNER_MIRROR_SESSION_KEY   required, e.g. "agent:main:telegram:dm:123456789"
#   AIRBNB_COURIER_TICK_SECONDS       default 60
#   AIRBNB_COURIER_SLA_MINUTES        default 30
#   AIRBNB_COURIER_ESCALATION_MINUTES default 60
#   AIRBNB_COURIER_PARTIAL_STALENESS_SECONDS default 300
#   PLOW_CHAT_BASE_URL                default https://chat.plow.co
#   TEAM_CHAT_SECRETS_FILE            default /opt/data/home/.airbnb-coordinator/team-secrets.json
#   BRAIN_DIR                         default /opt/data/home/brain
#   AIRBNB_COURIER_DRY_RUN            set to 1 for a no-side-effects tick (useful in tests)
#
# Exit codes:
#   The script does not exit cleanly under normal operation — Compose's
#   restart:unless-stopped re-launches on crash. Errors during a single
#   page's processing are logged and skipped; only signal-induced shutdown
#   (SIGTERM from `docker compose down`) ends the loop.

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

QUERIES_DIR="${BRAIN_DIR}/queries"

log() {
  # ISO 8601 UTC + tag + message — friendly for `docker compose logs`.
  printf '[%s] airbnb-courier: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

trap 'log "SIGTERM received, exiting cleanly"; exit 0' TERM
trap 'log "SIGINT received, exiting cleanly"; exit 0' INT

log "starting; tick=${AIRBNB_COURIER_TICK_SECONDS}s sla=${AIRBNB_COURIER_SLA_MINUTES}m escalation=${AIRBNB_COURIER_ESCALATION_MINUTES}m owner=${AIRBNB_OWNER_PROFILE} brain=${BRAIN_DIR} dry_run=${AIRBNB_COURIER_DRY_RUN}"

# ============================================================================
# Helpers
# ============================================================================

# Compute UTC seconds-since-epoch from an ISO 8601 string. GNU date and BSD date
# disagree on -d vs -j; we shell out to python3 for portability since the
# container image always ships python3.
iso_to_epoch() {
  local iso="$1"
  python3 -c "
import sys, datetime
try:
    s = sys.argv[1].rstrip('Z').rstrip()
    print(int(datetime.datetime.fromisoformat(s).replace(tzinfo=datetime.timezone.utc).timestamp()))
except Exception as e:
    print('0')
    sys.exit(0)
" "$iso"
}

utc_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
utc_now_epoch() { date -u +%s; }

# Plus-N-minutes from now in ISO 8601 UTC. Pure-Python for portability.
utc_plus_minutes_iso() {
  local mins="$1"
  python3 -c "
import datetime
print((datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=${mins})).strftime('%Y-%m-%dT%H:%M:%SZ'))
"
}

# Read X-Chat-Secret-Key for a given team_member_uid from the secrets file.
# Returns empty string on miss (caller logs).
get_team_secret() {
  local uid="$1"
  [[ -f "$TEAM_CHAT_SECRETS_FILE" ]] || { echo ""; return; }
  python3 -c "
import json, sys
try:
    d = json.load(open('${TEAM_CHAT_SECRETS_FILE}'))
    print(d.get('${uid}', ''))
except Exception:
    print('')
"
}

# wakeAgent in the owner profile. The owner profile's Hermes runtime picks
# this up and routes the prompt into the session referenced by
# AIRBNB_OWNER_MIRROR_SESSION_KEY. The boss skill's Trigger 3 fires on the
# `query_id=` token.
wake_owner_for_draft() {
  local query_id="$1"
  local file="$2"
  local prompt="draft reply for query_id=${query_id}; read ${file}"
  if [[ "$AIRBNB_COURIER_DRY_RUN" == "1" ]]; then
    log "DRY_RUN would wake: hermes -p ${AIRBNB_OWNER_PROFILE} wakeAgent --session ${AIRBNB_OWNER_MIRROR_SESSION_KEY} --prompt '${prompt}'"
    return 0
  fi
  if ! hermes -p "$AIRBNB_OWNER_PROFILE" wakeAgent \
        --session "$AIRBNB_OWNER_MIRROR_SESSION_KEY" \
        --prompt "$prompt" >/dev/null 2>&1; then
    log "WARN wakeAgent FAILED for query=${query_id} (will retry next tick)"
    return 1
  fi
  log "woke owner for draft: query=${query_id}"
}

# wakeAgent in the owner profile for an escalation notice.
wake_owner_for_escalation() {
  local query_id="$1"
  local role="$2"
  local question="$3"
  local prompt="ESCALATE: query_id=${query_id} role=${role} question=\"${question}\" — team member did not reply within SLA. Mirror to owner."
  if [[ "$AIRBNB_COURIER_DRY_RUN" == "1" ]]; then
    log "DRY_RUN would escalate: hermes -p ${AIRBNB_OWNER_PROFILE} wakeAgent --session ${AIRBNB_OWNER_MIRROR_SESSION_KEY} --prompt '${prompt}'"
    return 0
  fi
  if ! hermes -p "$AIRBNB_OWNER_PROFILE" wakeAgent \
        --session "$AIRBNB_OWNER_MIRROR_SESSION_KEY" \
        --prompt "$prompt" >/dev/null 2>&1; then
    log "WARN wakeAgent FAILED for escalation query=${query_id} (will retry next tick)"
    return 1
  fi
  log "woke owner for escalation: query=${query_id} role=${role}"
}

# Re-ping a team member on plow_chat. Returns 0 on HTTP 2xx, non-zero otherwise.
plow_chat_repinging() {
  local team_member_uid="$1"
  local question="$2"
  local secret
  secret="$(get_team_secret "$team_member_uid")"
  if [[ -z "$secret" ]]; then
    log "WARN no secret for team_member_uid=${team_member_uid} in ${TEAM_CHAT_SECRETS_FILE}; cannot re-ping"
    return 1
  fi
  if [[ "$AIRBNB_COURIER_DRY_RUN" == "1" ]]; then
    log "DRY_RUN would re-ping ${team_member_uid}: ${question}"
    return 0
  fi
  local body
  body=$(python3 -c "
import json, sys
print(json.dumps({'content': 'Reminder — still need an answer to: ' + sys.argv[1]}))
" "$question")
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' \
    -X POST "${PLOW_CHAT_BASE_URL%/}/v1/chats/${team_member_uid}/messages" \
    -H "X-Chat-Secret-Key: ${secret}" \
    -H 'Content-Type: application/json' \
    --max-time 15 \
    --data-binary "$body" || echo "000")
  if [[ "$code" =~ ^2 ]]; then
    log "re-ping OK ${team_member_uid} (HTTP ${code})"
    return 0
  fi
  log "WARN re-ping FAILED ${team_member_uid} (HTTP ${code})"
  return 1
}

# ============================================================================
# Per-page processing — runs under flock.
# Inputs:  $1 = absolute path to a queries/q-*.md page.
# Side effects: rewrites the page in place; may shell out to wake/re-ping;
#   appends a single git commit if anything changed.
# Process flow (read-modify-write):
#   1. Re-read frontmatter under the flock.
#   2. For each pending ask: compare deadlines, re-ping or escalate.
#   3. After ask loop: evaluate ready_to_draft, wake owner if so.
#   4. Write back, commit.
# ============================================================================
process_page() {
  local page="$1"
  local query_id; query_id=$(basename "${page}" .md)
  local now_iso; now_iso=$(utc_now_iso)
  local now_epoch; now_epoch=$(utc_now_epoch)
  local partial_stale=$AIRBNB_COURIER_PARTIAL_STALENESS_SECONDS

  # Hand the whole page to python3 for parse + mutate. Round-tripping YAML in
  # bash is unhappiness; python's friendlier and the page is < 8 KB.
  local changed_marker
  changed_marker="$(python3 <<PY
import datetime, json, os, re, sys, pathlib

PAGE = pathlib.Path("${page}")
NOW_EPOCH = ${now_epoch}
NOW_ISO = "${now_iso}"
PARTIAL_STALE = ${partial_stale}

text = PAGE.read_text()
m = re.match(r"^---\n(.*?)\n---\n(.*)$", text, re.S)
if not m:
    print("ERROR_NOFRONTMATTER")
    sys.exit(0)

# Minimal YAML-ish parser. We control the schema (boss + listener write
# it); no nested-list-of-dicts contortions needed beyond asks[] / drafts[].
# Keep this tiny on purpose so the courier image needs no pip installs.
def parse_fm(s):
    out = {"asks": [], "drafts": []}
    lines = s.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        if not line.strip() or line.lstrip().startswith("#"):
            i += 1; continue
        if line.startswith("asks:") or line.startswith("drafts:"):
            key = "asks" if line.startswith("asks:") else "drafts"
            i += 1
            items = []
            while i < len(lines) and (lines[i].startswith("  - ") or lines[i].startswith("    ")):
                if lines[i].startswith("  - "):
                    items.append({})
                    kv = lines[i][4:].strip()
                    if ":" in kv:
                        k, _, v = kv.partition(":")
                        items[-1][k.strip()] = parse_scalar(v.strip())
                else:
                    kv = lines[i][4:].strip()
                    if ":" in kv:
                        k, _, v = kv.partition(":")
                        items[-1][k.strip()] = parse_scalar(v.strip())
                i += 1
            out[key] = items
            continue
        if ":" in line:
            k, _, v = line.partition(":")
            out[k.strip()] = parse_scalar(v.strip())
        i += 1
    return out

def parse_scalar(v):
    if v in ("null", "~", ""):
        return None
    if v in ("true", "false"):
        return v == "true"
    if v.startswith('"') and v.endswith('"'):
        return v[1:-1]
    try:
        if v.isdigit() or (v.startswith("-") and v[1:].isdigit()):
            return int(v)
    except Exception:
        pass
    return v

def dump_fm(fm):
    # Preserve key order roughly matching the schema in SEED.md.
    scalar_keys = [
        "title", "query_id", "guest_conversation_id", "guest_message_id",
        "guest_property_id", "status", "created_at", "updated_at",
        "owner_mirror_session_key", "guest_message_content", "closed_at",
    ]
    out = []
    for k in scalar_keys:
        if k in fm and fm[k] is not None:
            out.append(f'{k}: {fmt_scalar(fm[k])}')
    out.append("asks:")
    for a in fm.get("asks", []):
        out.append(f'  - ask_id: {fmt_scalar(a.get("ask_id"))}')
        for k in ("team_member_uid","role","question","asked_at","original_asked_at",
                  "ping_count","sla_deadline","escalation_deadline","status",
                  "answer","answered_at","notes"):
            if k in a and a[k] is not None:
                out.append(f'    {k}: {fmt_scalar(a[k])}')
    out.append("drafts:")
    for d in fm.get("drafts", []):
        out.append(f'  - draft_id: {fmt_scalar(d.get("draft_id"))}')
        for k in ("kind","content","drafted_at","mirrored_to_owner_at",
                  "approved_at","rejected_at","delivered_at"):
            if k in d and d[k] is not None:
                out.append(f'    {k}: {fmt_scalar(d[k])}')
    return "\n".join(out)

def fmt_scalar(v):
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    # quote strings that contain : or # or leading/trailing space
    s = str(v).replace('"', '\\"')
    return f'"{s}"'

fm = parse_fm(m.group(1))
body = m.group(2)

actions = []  # list of (kind, payload) -> deferred external calls

def iso_to_epoch(s):
    if not s: return 0
    try:
        return int(datetime.datetime.fromisoformat(str(s).rstrip("Z")).replace(tzinfo=datetime.timezone.utc).timestamp())
    except Exception:
        return 0

# 1. Iterate asks, evaluate deadlines.
for ask in fm.get("asks", []):
    if ask.get("status") != "pending":
        continue
    sla = iso_to_epoch(ask.get("sla_deadline"))
    esc = iso_to_epoch(ask.get("escalation_deadline"))
    pc = int(ask.get("ping_count", 1))
    if NOW_EPOCH < sla:
        continue
    if sla <= NOW_EPOCH < esc and pc == 1:
        ask["ping_count"] = 2
        ask["asked_at"] = NOW_ISO
        actions.append(("repinging", {"team_member_uid": ask.get("team_member_uid"), "question": ask.get("question")}))
        continue
    if NOW_EPOCH >= esc and pc >= 2:
        ask["status"] = "escalated"
        fm.setdefault("drafts", []).append({
            "draft_id": f'draft-{len(fm["drafts"]) + 1}',
            "kind": "escalate-notice",
            "content": f'Escalating: {ask.get("role")} did not reply to "{ask.get("question")}"',
            "drafted_at": NOW_ISO,
        })
        actions.append(("escalate", {"query_id": "${query_id}", "role": ask.get("role"), "question": ask.get("question")}))

# 2. ready_to_draft predicate.
def has_draft_kind(kind):
    return any(d.get("kind") == kind for d in fm.get("drafts", []))

def has_recent_partial(stale_secs):
    for d in fm.get("drafts", []):
        if d.get("kind") != "partial": continue
        ts = iso_to_epoch(d.get("drafted_at"))
        if NOW_EPOCH - ts < stale_secs:
            return True
    return False

asks = fm.get("asks", [])
all_resolved = asks and all(a.get("status") in ("answered","escalated","timed_out") for a in asks)
any_answered = any(a.get("status") == "answered" for a in asks)
any_pending = any(a.get("status") == "pending" for a in asks)

if all_resolved and not has_draft_kind("final"):
    actions.append(("wake_for_draft", {"query_id": "${query_id}", "file": "${page}"}))
elif any_answered and any_pending and not has_recent_partial(PARTIAL_STALE):
    actions.append(("wake_for_draft", {"query_id": "${query_id}", "file": "${page}"}))

# 3. Update top-level status if a transition happened.
if all_resolved and fm.get("status") not in ("closed",):
    # The boss will close on final draft delivery; the courier just records "all asks resolved".
    pass

# 4. Update updated_at if anything changed.
new_text = dump_fm(fm) + "\n"
if new_text != m.group(1) + "\n":
    fm["updated_at"] = NOW_ISO
    new_text = dump_fm(fm) + "\n"
    PAGE.write_text(f"---\n{new_text}---\n{body}")
    print("CHANGED")
else:
    print("NOOP")

# Emit deferred actions for the bash side to execute.
with open("/tmp/.airbnb-courier-actions.json", "w") as f:
    json.dump(actions, f)
PY
)"

  if [[ "$changed_marker" == "ERROR_NOFRONTMATTER" ]]; then
    log "WARN ${page} has no frontmatter; skipping"
    return 0
  fi

  # Execute deferred external actions OUTSIDE the page write so a transient
  # plow_chat / hermes failure doesn't roll back the state change.
  local actions_file=/tmp/.airbnb-courier-actions.json
  if [[ -s "$actions_file" ]]; then
    python3 -c "
import json
actions = json.load(open('$actions_file'))
for kind, payload in actions:
    print(kind + '\t' + json.dumps(payload))
" | while IFS=$'\t' read -r kind payload; do
      case "$kind" in
        repinging)
          local tm; tm=$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['team_member_uid'])" "$payload")
          local q;  q=$(python3 -c  "import json,sys;print(json.loads(sys.argv[1])['question'])" "$payload")
          plow_chat_repinging "$tm" "$q" || true
          ;;
        escalate)
          local qid; qid=$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['query_id'])" "$payload")
          local rl;  rl=$(python3 -c  "import json,sys;print(json.loads(sys.argv[1])['role'])" "$payload")
          local qu;  qu=$(python3 -c  "import json,sys;print(json.loads(sys.argv[1])['question'])" "$payload")
          wake_owner_for_escalation "$qid" "$rl" "$qu" || true
          ;;
        wake_for_draft)
          local qid; qid=$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['query_id'])" "$payload")
          local fl;  fl=$(python3 -c  "import json,sys;print(json.loads(sys.argv[1])['file'])" "$payload")
          wake_owner_for_draft "$qid" "$fl" || true
          ;;
      esac
    done
    rm -f "$actions_file"
  fi

  if [[ "$changed_marker" == "CHANGED" && "$AIRBNB_COURIER_DRY_RUN" != "1" ]]; then
    if command -v git >/dev/null 2>&1; then
      ( cd "$BRAIN_DIR" && git add "queries/$(basename "$page")" && \
        git commit -m "coordinator: courier tick on $(basename "$page" .md)" >/dev/null 2>&1 ) || true
    fi
  fi
}

# ============================================================================
# Main loop
# ============================================================================
while true; do
  if [[ ! -d "$QUERIES_DIR" ]]; then
    log "queries dir ${QUERIES_DIR} missing; sleeping"
    sleep "$AIRBNB_COURIER_TICK_SECONDS"
    continue
  fi
  # Filter by mtime — only pages touched in the last 24h are worth opening.
  # This keeps the per-tick cost bounded even at 10k+ historical pages.
  shopt -s nullglob
  for page in "$QUERIES_DIR"/q-*.md; do
    # mtime older than 24h AND status is closed by name pattern? cheap skip.
    if [[ $(find "$page" -mmin +1440 -print 2>/dev/null) ]]; then
      # Even old pages may need attention if status is open/partial; do a
      # cheap grep to avoid opening a fully closed page.
      if ! grep -qE '^status:[[:space:]]+(open|partial)' "$page"; then
        continue
      fi
    fi
    # flock per page; non-blocking — skip if listener / boss is currently
    # writing. The next tick will get it. Lockfile lives outside the brain
    # repo so it doesn't pollute `git status` and isn't picked up by
    # gbrain sync.
    lock_file="/tmp/airbnb-courier-$(basename "$page").lock"
    (
      if flock -n 9; then
        process_page "$page"
      else
        log "skip locked: $(basename "$page")"
      fi
    ) 9>"$lock_file" || true
  done
  shopt -u nullglob
  sleep "$AIRBNB_COURIER_TICK_SECONDS"
done
