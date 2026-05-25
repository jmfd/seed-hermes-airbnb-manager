#!/usr/bin/env bash
# Tier-2 end-to-end validation for hostex-context against a running DTU.
#
# Seeds a deterministic world (asof = 2026-05-25), then asserts the mechanical
# state returned by the hxctx tools + the raw /v3 endpoints. Mechanical only —
# no assertions on any LLM-generated text. Exit non-zero on any failure.
#
# Env: DTU_BASE (default http://127.0.0.1:8082), PYTHON (default python3).
set -u

DTU_BASE="${DTU_BASE:-http://127.0.0.1:8082}"
PYTHON="${PYTHON:-python3}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
HXCTX="$HERE/hxctx"
ASOF="2026-05-25"

export HOSTEX_BASE_URL="$DTU_BASE"
export HOSTEX_ACCESS_TOKEN="${HOSTEX_ACCESS_TOKEN:-validate-token}"
export HXCTX_TODAY="$ASOF"

FAILS=0
post() { curl -fsS -X POST "$DTU_BASE$1" -H 'Content-Type: application/json' -d "$2" >/dev/null; }
hx()   { "$PYTHON" "$HXCTX" "$@"; }

# check <label> <json> <python-bool-expr-over-d>   — no pipe, so FAILS propagates.
check() {
  local label="$1" json="$2" expr="$3" res
  res=$("$PYTHON" -c '
import sys, json
label, expr = sys.argv[1], sys.argv[2]
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception as e:
    print(f"FAIL {label}: bad JSON ({e}); raw={raw[:160]!r}"); sys.exit(1)
try:
    ok = bool(eval(expr, {"d": d}))
except Exception as e:
    print(f"FAIL {label}: expr error {e}; got={json.dumps(d)[:200]}"); sys.exit(1)
print(("PASS " if ok else "FAIL ") + label + ("" if ok else f": got={json.dumps(d)[:240]}"))
sys.exit(0 if ok else 1)
' "$label" "$expr" <<<"$json")
  echo "$res"
  case "$res" in FAIL*) FAILS=$((FAILS+1)) ;; esac
}

echo "== reset =="
curl -fsS -X POST "$DTU_BASE/admin/reset" >/dev/null && echo "reset ok"

echo "== seed =="
post /admin/reservation '{"property":"mtn-home","reservation_code":"R-MID","status":"accepted","check_in_date":"2026-05-20","check_out_date":"2026-05-26","conversation_id":"C-MID","guest_name":"Alice","number_of_guests":2}'
post /admin/reservation '{"property":"mtn-home","reservation_code":"R-FUT","status":"accepted","check_in_date":"2026-06-10","check_out_date":"2026-06-13","conversation_id":"C-FUT","guest_name":"Frank"}'
post /admin/block '{"property":"mtn-home","start_date":"2026-06-01","end_date":"2026-06-03","remarks":"deep clean"}'
post /admin/reservation '{"property":"10th-ave","reservation_code":"R-ARR","status":"accepted","check_in_date":"2026-05-25","check_out_date":"2026-05-28","conversation_id":"C-ARR","guest_name":"Arno"}'
post /admin/reservation '{"property":"10th-ave","reservation_code":"R-PAST","status":"accepted","check_in_date":"2026-04-01","check_out_date":"2026-04-05","conversation_id":"C-PAST","guest_name":"Pat"}'
post /admin/reservation '{"property":"10th-ave","reservation_code":"R-PEND","status":"wait_accept","check_in_date":"2026-07-01","check_out_date":"2026-07-03","conversation_id":"C-PEND","guest_name":"Penny"}'
echo "seeded"

echo "== guest-state matrix =="
check "midstay"          "$(hx guest-state --conversation C-MID)"  "d['state']=='checked_in_midstay' and d['nights_remaining']==1"
check "arriving_today"   "$(hx guest-state --conversation C-ARR)"  "d['state']=='arriving_today'"
check "future_guest"     "$(hx guest-state --conversation C-FUT)"  "d['state']=='future_guest'"
check "past_guest"       "$(hx guest-state --conversation C-PAST)" "d['state']=='past_guest'"
check "inquiry_pending"  "$(hx guest-state --conversation C-PEND)" "d['state']=='inquiry_pending'"
check "curious_browser"  "$(hx guest-state --conversation C-NONE)" "d['state']=='curious_browser' and d['reservation'] is None"
check "by-reservation"   "$(hx guest-state --reservation R-MID)"   "d['state']=='checked_in_midstay' and d['by']=='reservation'"

echo "== occupancy adjacency =="
check "occ-checkout-day" "$(hx occupancy --property mtn-home --date 2026-05-26)" "d['early_checkin_feasible']==False and d['late_checkout_feasible']==True"
check "occ-both-free"    "$(hx occupancy --property mtn-home --date 2026-05-27)" "d['early_checkin_feasible']==True and d['late_checkout_feasible']==True"

echo "== calendar =="
check "cal-booked-then-free"    "$(hx calendar --property mtn-home --start 2026-05-24 --end 2026-05-27)" "[x['status'] for x in d['days']]==['booked','booked','free','free']"
check "cal-maintenance-blocked" "$(hx calendar --property mtn-home --start 2026-06-01 --end 2026-06-03)" "all(x['status']=='blocked' and x['remarks']=='deep clean' for x in d['days'])"

echo "== reservations / schedule =="
check "res-on-date"   "$(hx reservations --property mtn-home --on 2026-05-25)" "any(r['reservation_code']=='R-MID' for r in d['reservations']) and d['count']==1"
check "sched-arriving" "$(hx schedule --property 10th-ave --day today)" "any(r['reservation_code']=='R-ARR' for r in d['arriving'])"
check "sched-in-house" "$(hx schedule --property mtn-home --day today)" "any(r['reservation_code']=='R-MID' for r in d['in_house'])"

echo "== raw endpoint shapes =="
check "avail-shape" "$(curl -fsS "$DTU_BASE/v3/availabilities?property_ids=12051776&start_date=2026-05-25&end_date=2026-05-25")" "isinstance(d['data']['properties'][0]['availabilities'][0]['available'], bool)"
check "res-shape"   "$(curl -fsS "$DTU_BASE/v3/reservations?property_id=12051776&status=accepted")" "d['data']['total']>=1 and 'check_in_date' in d['data']['reservations'][0]"

echo ""
if [ "$FAILS" -eq 0 ]; then echo "ALL CHECKS PASSED"; else echo "$FAILS CHECK(S) FAILED"; fi
exit "$FAILS"
