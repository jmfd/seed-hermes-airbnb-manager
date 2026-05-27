#!/usr/bin/env bash
# test-memory-first-e2e.sh — proves v11's Branch 0 (MEMORY HIT) short-circuit
# fires when the brain has the answer AND falls through to step 7 when it
# doesn't. Mirrors the spirit of scripts/test-e2e.sh (eng-1's auto-ack PR)
# but tests a smaller surface: the memory-first decision point only.
#
# What this proves:
#   STAGE A: guest 'What is the wifi password?' → boss step 6.5 returns
#            MEMORY_HIT(facts/<prop>/wifi.md) → Branch 0 stages a draft in
#            pirate-joker-pending.json with `memory_cite` block + the fact
#            body verbatim → mirrors to owner for approve. NO query page
#            written. NO plow_chat fan-out.
#   STAGE B: guest 'Is there a hot tub at the property?' → boss step 6.5
#            returns MEMORY_MISS → step 7 fires → 8a or 8b runs as in v10
#            → pending entry has no `memory_cite` block.
#
# Full owner-approve → Hostex POST round-trip is OUT OF SCOPE here; that
# path is unchanged from v9.0.0 Branch A and is covered by scripts/test-e2e.sh
# (eng-1's PR #1) once it lands.
#
# Usage:
#   ./scripts/test-memory-first-e2e.sh
#   ./scripts/test-memory-first-e2e.sh --scaffold <dir> --owner-profile <name>
#
# Exit codes:
#   0  both stages passed
#   1  stage A failed (no MEMORY_HIT or wrong branch fired)
#   2  stage B failed (no fall-through)
#   3  bad invocation / missing prerequisite

set -euo pipefail

SCAFFOLD="${HERMES_SCAFFOLD_DIR:-/tmp/plow-seeds/hermes-agent}"
HERMES_CONTAINER="${HERMES_CONTAINER:-seed-hermes-2568931506-hermes}"
# REQUIRED; resolved from env or <scaffold>/.env below.
OWNER_PROFILE="${OWNER_PROFILE:-}"
PROPERTY_SLUG="${PROPERTY_SLUG:-mtn-home}"
STUB_PORT="${STUB_PORT:-18080}"
STAGE_TIMEOUT="${STAGE_TIMEOUT:-180}"
CLEANUP="${CLEANUP:-1}"

while [ $# -gt 0 ]; do
  case "$1" in
    --scaffold) SCAFFOLD="$2"; shift 2 ;;
    --container) HERMES_CONTAINER="$2"; shift 2 ;;
    --owner-profile) OWNER_PROFILE="$2"; shift 2 ;;
    --property-slug) PROPERTY_SLUG="$2"; shift 2 ;;
    --stub-port) STUB_PORT="$2"; shift 2 ;;
    --no-cleanup) CLEANUP=0; shift ;;
    --help|-h) sed -n '2,30p' "$0" | sed 's/^# *//'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 3 ;;
  esac
done

# Resolve OWNER_PROFILE from env or scaffold .env. REQUIRED.
if [ -z "${OWNER_PROFILE:-}" ]; then
  _env_file="${SCAFFOLD%/}/.env"
  if [ -f "$_env_file" ]; then
    OWNER_PROFILE=$(awk -F= '$1=="OWNER_PROFILE"{ sub(/^[^=]*=/,"",$0); print; exit }' "$_env_file" \
                    | sed -E 's/^"//; s/"$//')
  fi
fi
if [ -z "${OWNER_PROFILE:-}" ]; then
  echo "FAIL: \$OWNER_PROFILE not set (env), and not found in ${SCAFFOLD%/}/.env." >&2
  echo "      Run the installer first, or pass --owner-profile <name>." >&2
  exit 3
fi

SCAFFOLD_ABS=$(cd "$SCAFFOLD" && pwd)
PENDING="/opt/data/home/.airbnb-manager/pirate-joker-pending.json"
FACTS_DIR="/opt/data/home/brain/facts"
QUERIES_DIR="/opt/data/home/brain/queries"

dce() { ( cd "$SCAFFOLD_ABS" && docker compose exec "$@" ); }
log() { echo "[T+$(($(date +%s) - T0))s] $*"; }
ok()  { log "✓ $*"; }
fail() { log "✗ FAIL: $*" >&2; exit "${2:-1}"; }
T0=$(date +%s)

# ────────────────────────────────────────────────────────────────────────────
# Pre-flight
# ────────────────────────────────────────────────────────────────────────────
log "preflight"
( cd "$SCAFFOLD_ABS" && docker compose ps hermes 2>/dev/null | grep -q Up ) \
  || fail "hermes service not running in scaffold $SCAFFOLD_ABS" 3
SKILL_PATH="$SCAFFOLD_ABS/data/profiles/$OWNER_PROFILE/skills/str-manager-approval/SKILL.md"
[ -f "$SKILL_PATH" ] || fail "skill file missing: $SKILL_PATH" 3
grep -qE "^version: (1[1-9]|[2-9][0-9])\." "$SKILL_PATH" || fail "boss skill at $SKILL_PATH is not v11+ (run installer first)" 3
ok "v11 boss skill present on $OWNER_PROFILE"

# ────────────────────────────────────────────────────────────────────────────
# Stand up stub-Hostex inside the container (loopback only)
# ────────────────────────────────────────────────────────────────────────────
log "starting stub-Hostex on :$STUB_PORT inside container"
cat > "$SCAFFOLD_ABS/data/stub-hostex.py" <<'STUB'
import http.server, json, sys
CONV_A = {"request_id":"R-A","error_code":200,"error_msg":"Done.","data":{
  "id":"STUB-CONV-A","channel_type":"airbnb",
  "guest":{"name":"TestGuest","phone":None,"email":""},
  "activities":[{"property":{"id":12051776,"title":"Mtn Home"}}],
  "messages":[{"id":"STUB-MSG-A","sender_role":"guest",
               "content":"Hi! What is the wifi password at the cabin?",
               "created_at":"2026-05-25T12:00:00+00:00"}]}}
CONV_B = {"request_id":"R-B","error_code":200,"error_msg":"Done.","data":{
  "id":"STUB-CONV-B","channel_type":"airbnb",
  "guest":{"name":"TestGuest2","phone":None,"email":""},
  "activities":[{"property":{"id":12051776,"title":"Mtn Home"}}],
  "messages":[{"id":"STUB-MSG-B","sender_role":"guest",
               "content":"Hi! Is there a hot tub at the property?",
               "created_at":"2026-05-25T12:00:00+00:00"}]}}
POSTS = []
class H(http.server.BaseHTTPRequestHandler):
  def log_message(self,*a,**k): pass
  def do_GET(self):
    if self.path.startswith("/v3/conversations/STUB-CONV-A"): body=json.dumps(CONV_A).encode()
    elif self.path.startswith("/v3/conversations/STUB-CONV-B"): body=json.dumps(CONV_B).encode()
    elif self.path=="/_recent_posts": body=json.dumps(POSTS).encode()
    else: body=b'{"error_code":404,"error_msg":"not found"}'
    self.send_response(200); self.send_header("Content-Type","application/json"); self.end_headers(); self.wfile.write(body)
  def do_POST(self):
    ln=int(self.headers.get("Content-Length","0"))
    raw=self.rfile.read(ln).decode("utf-8","replace") if ln else ""
    POSTS.append({"path":self.path,"body":raw})
    self.send_response(200); self.send_header("Content-Type","application/json"); self.end_headers()
    self.wfile.write(b'{"request_id":"OK","error_code":200,"error_msg":"Done.","data":{"id":"stub-msg-out"}}')
http.server.HTTPServer(("127.0.0.1",int(sys.argv[1])),H).serve_forever()
STUB
# Use raw `docker exec --detach` instead of `docker compose exec -d` — the latter
# doesn't always cleanly background a setsid'd python under `bash -lc`. The container
# name pattern is the compose project + service.
HCN=$( ( cd "$SCAFFOLD_ABS" && docker compose ps hermes --format '{{.Name}}' 2>/dev/null | head -1 ) )
[ -n "$HCN" ] || fail "could not resolve hermes container name" 3
docker exec -u 501:20 "$HCN" pkill -f stub-hostex.py 2>/dev/null || true
sleep 1
docker exec -d -u 501:20 "$HCN" python3 /opt/data/stub-hostex.py "$STUB_PORT" >/dev/null
sleep 3
dce -T -u 501:20 hermes bash -lc "curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:$STUB_PORT/v3/conversations/STUB-CONV-A" | grep -q '^200$' \
  || fail "stub-Hostex didn't come up on :$STUB_PORT" 3
ok "stub-Hostex healthy on :$STUB_PORT"

# Snapshot brain pre-stages
PENDING_PRE=$(dce -T -u 501:20 hermes bash -lc "jq length $PENDING 2>/dev/null || echo 0" | tr -d '[:space:]')
QUERIES_PRE=$(dce -T -u 501:20 hermes bash -lc "ls $QUERIES_DIR/q-*.md 2>/dev/null | wc -l" | tr -d '[:space:]')
log "pre-stages: pending=$PENDING_PRE queries=$QUERIES_PRE"

build_prompt() {
  local conv_id="$1" msg_id="$2"
  printf 'Hostex webhook callback payload (must be JSON with event=message_created, top-level conversation_id, and top-level message_id; fetch GET /v3/conversations/{conversation_id} before deciding; ignore if fetched sender_role is not guest): {"event":"message_created","conversation_id":"%s","message_id":"%s","timestamp":"2026-05-25T12:00:00Z"}. Use platform=plow_chat chat_id=cht_TEST hostex_base_url=http://127.0.0.1:%s hostex_access_token=stub-token-not-used.' \
    "$conv_id" "$msg_id" "$STUB_PORT"
}

fire_stage() {
  local conv_id="$1" msg_id="$2" out_log="$3"
  # `timeout` can't wrap a shell function, so inline the cd + docker compose exec.
  local prompt; prompt=$(build_prompt "$conv_id" "$msg_id")
  ( cd "$SCAFFOLD_ABS" && timeout "$STAGE_TIMEOUT" docker compose exec -T -u 501:20 -e HOME=/opt/data/home hermes \
      bash -lc "/opt/hermes/.venv/bin/hermes -p $OWNER_PROFILE chat -q '$prompt' 2>&1" ) \
    > "$out_log" 2>&1 || true
}

# ────────────────────────────────────────────────────────────────────────────
# STAGE A — wifi question → expect Branch 0 MEMORY HIT
# ────────────────────────────────────────────────────────────────────────────
log "STAGE A — guest asks wifi (memory has facts/$PROPERTY_SLUG/wifi.md → expect Branch 0)"
fire_stage "STUB-CONV-A" "STUB-MSG-A" /tmp/v11-stage-a.log

A_ENTRY=$(dce -T -u 501:20 hermes bash -lc "jq '.[\"STUB-MSG-A\"] // {}' $PENDING 2>/dev/null")
A_HAS_CITE=$(echo "$A_ENTRY" | jq 'has("memory_cite")')
A_DRAFT=$(echo "$A_ENTRY" | jq -r '.draft // ""')
A_TOPIC=$(echo "$A_ENTRY" | jq -r '.memory_cite.topic_slug // ""')

[ "$A_HAS_CITE" = "true" ] || fail "Stage A: pending entry has no memory_cite — Branch 0 did NOT fire" 1
[ "$A_TOPIC" = "wifi" ] || fail "Stage A: memory_cite.topic_slug='$A_TOPIC', expected 'wifi'" 1
echo "$A_DRAFT" | grep -q "TMOBILE-BEE\\|wifi\\|password\\|network" \
  || fail "Stage A: draft doesn't look like a wifi fact: $A_DRAFT" 1
ok "Stage A: Branch 0 fired (topic_slug=wifi, draft cites wifi fact)"

QUERIES_AFTER_A=$(dce -T -u 501:20 hermes bash -lc "ls $QUERIES_DIR/q-*.md 2>/dev/null | wc -l" | tr -d '[:space:]')
[ "$QUERIES_AFTER_A" = "$QUERIES_PRE" ] \
  || fail "Stage A: queries dir grew ($QUERIES_PRE → $QUERIES_AFTER_A) — Branch 0 should NOT create a query page" 1
ok "Stage A: no query page created (no team consult fired)"

# ────────────────────────────────────────────────────────────────────────────
# STAGE B — hot tub question → expect MEMORY_MISS + fall-through to v10 path
# ────────────────────────────────────────────────────────────────────────────
log "STAGE B — guest asks about hot tub (no hot tub fact → expect MEMORY_MISS + fall-through)"
fire_stage "STUB-CONV-B" "STUB-MSG-B" /tmp/v11-stage-b.log

# Either 8a (pirate fast path → pending entry, NO memory_cite) OR 8b (consult
# path → new query page) is valid "fell through to v10 path". Check both.
B_ENTRY=$(dce -T -u 501:20 hermes bash -lc "jq '.[\"STUB-MSG-B\"] // {}' $PENDING 2>/dev/null")
B_HAS_CITE=$(echo "$B_ENTRY" | jq 'has("memory_cite")')
B_HAS_DRAFT=$(echo "$B_ENTRY" | jq 'has("draft")')
QUERIES_AFTER_B=$(dce -T -u 501:20 hermes bash -lc "ls $QUERIES_DIR/q-*.md 2>/dev/null | wc -l" | tr -d '[:space:]')

# MEMORY_HIT contamination guard: pending entry with memory_cite would mean Branch 0 fired wrongly.
[ "$B_HAS_CITE" = "false" ] || fail "Stage B: pending entry has memory_cite — Branch 0 fired on a MEMORY_MISS question" 2

# Engagement check: EITHER pending entry exists (8a) OR new query page (8b).
if [ "$B_HAS_DRAFT" = "true" ]; then
  ok "Stage B: fall-through to 8a (no-consult pirate fast path) — pending entry written, no memory_cite"
elif [ "$QUERIES_AFTER_B" -gt "$QUERIES_PRE" ]; then
  ok "Stage B: fall-through to 8b (team consult) — new query page created ($QUERIES_PRE → $QUERIES_AFTER_B)"
else
  fail "Stage B: boss didn't engage at all — no pending entry AND no new query page" 2
fi

# ────────────────────────────────────────────────────────────────────────────
# Optional cleanup — leave brain pages alone; clear pending entries we created.
# ────────────────────────────────────────────────────────────────────────────
if [ "$CLEANUP" = "1" ]; then
  dce -T -u 501:20 hermes bash -lc "jq 'del(.\"STUB-MSG-A\", .\"STUB-MSG-B\")' $PENDING > ${PENDING}.tmp && mv -f ${PENDING}.tmp $PENDING" || true
  dce -T -u 0:0 hermes pkill -f stub-hostex.py 2>/dev/null || true
  ok "cleaned up pending STUB entries + killed stub-Hostex"
fi

echo
echo "════════════════════════════════════════════════════════════════════════"
echo "MEMORY_FIRST_E2E_PASS: v11 Branch 0 fires on MEMORY_HIT, falls through on MEMORY_MISS"
echo "  Stage A: wifi → topic=$A_TOPIC, draft=\"$A_DRAFT\""
echo "  Stage B: hot tub → MEMORY_MISS confirmed, fell to v10 path"
echo "════════════════════════════════════════════════════════════════════════"
