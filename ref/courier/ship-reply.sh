#!/usr/bin/env bash
# Deterministic, self-verifying Hostex reply shipper for owner-approve (Branch A).
# Replaces the boss's ad-hoc inline curl wrapper, which could fail silently on
# Unicode em-dash / curly quotes yet still let the boss mark delivered:true + say "Sent".
#
# Usage:  ship-reply.sh <conversation_id> <content_file> [<ref_id>]
#   <content_file> = path to a file containing the EXACT draft text (UTF-8).
# Behavior: POST the reply, REQUIRE http 2xx + error_code 200, then RE-VERIFY via GET
#   that a fresh host message actually landed, and ONLY THEN append outbox delivered:true.
#   On ANY failure: append delivered:false + print "SHIP_FAILED: ..." + exit non-zero.
#   Caller MUST NOT say "Sent" unless this prints "SHIP_OK" and exits 0.
set -uo pipefail

CID="${1:?conversation_id required}"
CONTENT_FILE="${2:?content file required}"
REF_ID="${3:-$CID}"
OWNER_ENV="/opt/data/profiles/owner/.env"

# Resolve Hostex creds: env first, else fall back to the owner profile .env.
BASE="${HOSTEX_BASE_URL:-}"
TOKEN="${HOSTEX_ACCESS_TOKEN:-}"
[ -z "$BASE" ]  && BASE="$(grep -E '^HOSTEX_BASE_URL='  "$OWNER_ENV" 2>/dev/null | cut -d= -f2-)"
[ -z "$TOKEN" ] && TOKEN="$(grep -E '^HOSTEX_ACCESS_TOKEN=' "$OWNER_ENV" 2>/dev/null | cut -d= -f2-)"
BASE="${BASE:-https://api.hostex.io}"; BASE="${BASE%/}"
if [ -z "$TOKEN" ]; then echo "SHIP_FAILED: no HOSTEX_ACCESS_TOKEN in env or $OWNER_ENV"; exit 10; fi

OUTBOX=/opt/data/home/.airbnb-manager/outbox.jsonl
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
CONTENT="$(cat "$CONTENT_FILE")"
BODY="$(python3 -c 'import json,sys;print(json.dumps({"message":sys.stdin.read()}))' < "$CONTENT_FILE")"

append_outbox() { # $1=delivered(true/false)  $2=errnote
  OB="$OUTBOX" TS="$TS" RID="$REF_ID" CID="$CID" DEL="$1" ERR="$2" CONTENT="$CONTENT" python3 - <<'PY'
import json,os
row={"ts":os.environ["TS"],"id":os.environ["RID"],"conversation_id":os.environ["CID"],
     "approved":True,"delivered":os.environ["DEL"]=="true","sent_content":os.environ["CONTENT"]}
if os.environ["ERR"]: row["error"]=os.environ["ERR"]
open(os.environ["OB"],"a").write(json.dumps(row)+"\n")
PY
}

# --- 1) POST the reply ---
RESP="$(mktemp)"
CODE="$(curl -sS -o "$RESP" -w '%{http_code}' --max-time 20 \
  -X POST "$BASE/v3/conversations/$CID" \
  -H "Hostex-Access-Token: $TOKEN" -H "User-Agent: curl/8.7.1" -H "Content-Type: application/json" \
  --data-binary "$BODY" 2>/dev/null || echo 000)"
RBODY="$(cat "$RESP" 2>/dev/null)"; rm -f "$RESP"
ECODE="$(printf '%s' "$RBODY" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("error_code",""))
except Exception: print("")' 2>/dev/null)"

if ! printf '%s' "$CODE" | grep -qE '^2'  || [ "$ECODE" != "200" ]; then
  append_outbox false "hostex_post_http_${CODE}_ecode_${ECODE}"
  echo "SHIP_FAILED: Hostex POST returned http=$CODE error_code=$ECODE body=${RBODY:0:160}"
  exit 11
fi

# --- 2) RE-VERIFY the reply actually landed as a host message (Hostex propagation is
#        async and can take ~45-60s, so poll up to ~80s before giving up) ---
verify_landed() {
  local i get
  for i in $(seq 1 20); do
    sleep 4
    get="$(curl -sS --max-time 15 -H "Hostex-Access-Token: $TOKEN" -H "User-Agent: curl/8.7.1" \
            "$BASE/v3/conversations/$CID" 2>/dev/null)"
    if printf '%s' "$get" | CF="$CONTENT_FILE" python3 -c '
import json,sys,os,re
def ascii_prefix(s,n=18):
    return re.sub(r"[^a-zA-Z0-9 ]","", s)[:n].strip()
want=ascii_prefix(open(os.environ["CF"],encoding="utf-8").read())
try: msgs=json.load(sys.stdin)["data"]["messages"][:5]
except Exception: sys.exit(1)
for m in msgs:
    if m.get("sender_role")=="host" and want and want in ascii_prefix(m.get("content") or "",60):
        sys.exit(0)
sys.exit(1)
'; then return 0; fi
  done
  return 1
}

if verify_landed; then
  append_outbox true ""
  echo "SHIP_OK: delivered to $CID and VERIFIED present in Hostex (http=$CODE, error_code=$ECODE)"
  exit 0
else
  append_outbox false "verify_no_host_message_after_post_http_${CODE}"
  echo "SHIP_FAILED: POST returned $CODE/$ECODE but the host reply did NOT appear in conversation $CID on re-GET"
  exit 12
fi
