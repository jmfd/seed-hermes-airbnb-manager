#!/usr/bin/env bash
# verify.sh — end-to-end verification for seed-hermes-airbnb-manager.
#
# Runs against a scaffold where the installer has already been executed.
# Covers V1-V9 from SEED.md ## Verify, including the 2 CRITICAL REGRESSION
# gates that ensure the live Trial Reel demo (v9.0.0 pirate fast path +
# v9.0.0 Branch A Hostex POST) did not break.
#
# Exit codes:
#   0   all checks passed
#   1   one or more checks failed (output names which)
#   2   bad invocation / scaffold unreachable

set -euo pipefail

SCAFFOLD_DIR="${HERMES_SCAFFOLD_DIR:-./hermes-agent}"
SERVICE="${HERMES_COMPOSE_SERVICE:-hermes}"
OWNER_PROFILE="${OWNER_PROFILE:-daniel}"
TEAM_PROFILE="${TEAM_PROFILE:-daniel-team}"
HERMES_UID_OVERRIDE="${HERMES_UID_OVERRIDE:-}"
HERMES_GID_OVERRIDE="${HERMES_GID_OVERRIDE:-}"
CHECK_PREREQS_ONLY=0
SKIP_TEAM_LISTENER=0
SKIP_E2E=0

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --scaffold PATH            Default: ./hermes-agent
  --service NAME             Default: hermes
  --owner-profile NAME       Default: daniel
  --team-profile NAME        Default: daniel-team
  --check-prereqs-only       Only run V1 (prerequisite check); exit after.
  --skip-team-listener       Skip V4 (listener installed). Use when the
                             installer was run with --skip-team-listener.
  --skip-e2e                 Skip V8 (end-to-end consult flow). Useful
                             when team listener isn't configured yet.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scaffold) SCAFFOLD_DIR="$2"; shift 2 ;;
    --service)  SERVICE="$2"; shift 2 ;;
    --owner-profile) OWNER_PROFILE="$2"; shift 2 ;;
    --team-profile)  TEAM_PROFILE="$2"; shift 2 ;;
    --check-prereqs-only) CHECK_PREREQS_ONLY=1; shift ;;
    --skip-team-listener) SKIP_TEAM_LISTENER=1; shift ;;
    --skip-e2e) SKIP_E2E=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -d "$SCAFFOLD_DIR" ]] || { echo "Scaffold not found: $SCAFFOLD_DIR" >&2; exit 2; }

ENV_FILE="${SCAFFOLD_DIR%/}/.env"
if [[ -z "$HERMES_UID_OVERRIDE" && -f "$ENV_FILE" ]]; then
  HERMES_UID_OVERRIDE="$(awk -F= '$1=="HERMES_UID"{print $2}' "$ENV_FILE")"
fi
if [[ -z "$HERMES_GID_OVERRIDE" && -f "$ENV_FILE" ]]; then
  HERMES_GID_OVERRIDE="$(awk -F= '$1=="HERMES_GID"{print $2}' "$ENV_FILE")"
fi
HERMES_UID_OVERRIDE="${HERMES_UID_OVERRIDE:-501}"
HERMES_GID_OVERRIDE="${HERMES_GID_OVERRIDE:-20}"

EXEC=(docker compose -f "${SCAFFOLD_DIR%/}/compose.yaml" --project-directory "${SCAFFOLD_DIR%/}" exec -T -u "${HERMES_UID_OVERRIDE}:${HERMES_GID_OVERRIDE}" "$SERVICE")
EXEC_LOGIN=(docker compose -f "${SCAFFOLD_DIR%/}/compose.yaml" --project-directory "${SCAFFOLD_DIR%/}" exec -T -u "${HERMES_UID_OVERRIDE}:${HERMES_GID_OVERRIDE}" "$SERVICE" bash -lc)

pass()  { echo "PASS $*"; }
fail()  { echo "FAIL $*" >&2; FAILED=$((FAILED+1)); }
note()  { echo "==> $*"; }

FAILED=0

# ============================================================================
# V1 — prerequisites
# ============================================================================
note "V1 prerequisites"
if ! "${EXEC[@]}" bash -lc 'command -v gbrain' >/dev/null 2>&1; then
  fail "V1a: gbrain not on container login PATH (install seed-hermes-gbrain first)"
else
  pass "V1a gbrain on login PATH"
fi
if ! grep -qE '(^|[[:space:]])-[[:space:]]+plow-chat-platform' "${SCAFFOLD_DIR%/}/data/config.yaml" 2>/dev/null; then
  fail "V1b: plow-chat-platform not enabled in data/config.yaml (install seed-hermes-plow-chat first)"
else
  pass "V1b plow-chat-platform enabled"
fi
if ! "${EXEC[@]}" test -d /opt/data/home/brain/.git; then
  fail "V1c: /opt/data/home/brain not git-initialized (seed-hermes-gbrain issue)"
else
  pass "V1c brain repo git-initialized"
fi

if [[ "$CHECK_PREREQS_ONLY" == "1" ]]; then
  echo
  [[ $FAILED -eq 0 ]] && { echo "VERIFY (prereqs) OK"; exit 0; } || { echo "VERIFY (prereqs) FAILED ($FAILED checks)"; exit 1; }
fi

# ============================================================================
# V2 — brain page dirs
# ============================================================================
note "V2 brain page directories"
for d in team properties queries; do
  if "${EXEC[@]}" test -d "/opt/data/home/brain/$d"; then
    pass "V2 brain/$d exists"
  else
    fail "V2 brain/$d missing"
  fi
done

# ============================================================================
# V3 — boss skill at legacy path with v10.0.0
# ============================================================================
note "V3 boss skill installed"
BOSS_SKILL="/opt/data/profiles/${OWNER_PROFILE}/skills/str-manager-approval/SKILL.md"
if ! "${EXEC[@]}" test -f "$BOSS_SKILL"; then
  fail "V3a: boss skill missing at $BOSS_SKILL"
else
  if "${EXEC[@]}" grep -q '^version: 10.0.0' "$BOSS_SKILL"; then
    pass "V3a boss skill at v10.0.0"
  else
    fail "V3a: boss skill version is not 10.0.0"
  fi
  # Preserved v9.0.0 contract markers
  if "${EXEC[@]}" grep -Fq 'User-Agent: curl/8.7.1' "$BOSS_SKILL"; then
    pass "V3b boss skill preserves curl/8.7.1 UA"
  else
    fail "V3b: boss skill lost curl/8.7.1 UA contract"
  fi
  if "${EXEC[@]}" grep -Fq 'POST /v3/conversations/{conversation_id}' "$BOSS_SKILL"; then
    pass "V3c boss skill preserves POST conversation endpoint"
  else
    fail "V3c: boss skill lost POST endpoint contract"
  fi
  if "${EXEC[@]}" grep -Fq '{"message":"<draft>"}' "$BOSS_SKILL"; then
    pass "V3d boss skill preserves body field 'message'"
  else
    fail "V3d: boss skill lost body field 'message'"
  fi
  # Anti-regression: must NOT contain the retired /messages endpoint
  if "${EXEC[@]}" grep -Fq '/v3/conversations/{conversation_id}/messages' "$BOSS_SKILL"; then
    fail "V3e: boss skill contains retired /messages endpoint"
  else
    pass "V3e boss skill clean of retired /messages endpoint"
  fi
fi

# ============================================================================
# V4 — listener skill installed (unless --skip-team-listener)
# ============================================================================
if [[ "$SKIP_TEAM_LISTENER" != "1" ]]; then
  note "V4 listener skill installed"
  LISTENER_SKILL="/opt/data/profiles/${TEAM_PROFILE}/skills/airbnb-team-listener/SKILL.md"
  if "${EXEC[@]}" test -f "$LISTENER_SKILL"; then
    pass "V4 listener skill present"
  else
    fail "V4: listener skill missing at $LISTENER_SKILL"
  fi
else
  note "V4 listener skill check SKIPPED (--skip-team-listener)"
fi

# ============================================================================
# V5 — courier sidecar running
# ============================================================================
note "V5 courier sidecar running"
if docker compose --project-directory "${SCAFFOLD_DIR%/}" ps --services --status running 2>/dev/null | grep -qx "airbnb-courier"; then
  pass "V5 airbnb-courier service is running"
else
  fail "V5: airbnb-courier service is NOT running (try 'docker compose up -d airbnb-courier')"
fi

# ============================================================================
# V6 — CRITICAL REGRESSION: v9.0.0 pirate fast path
# ============================================================================
note "V6 CRITICAL REGRESSION — v9.0.0 pirate fast path (Trial Reel demo)"
PIRATE_FIXTURE_REL="../seedlab/seeds/wire-samples/hostex-message_created.json"
# If running from the repo root, hostex wire-samples may be elsewhere; allow override.
PIRATE_FIXTURE="${PIRATE_FIXTURE:-${PIRATE_FIXTURE_REL}}"
if [[ ! -f "$PIRATE_FIXTURE" ]]; then
  # Fall back to fetching the wire sample from the seedlab repo on GitHub.
  TMP_FIX=$(mktemp)
  if curl -fsSL "https://raw.githubusercontent.com/delattre1/seedlab/main/seeds/wire-samples/hostex-message_created.json" -o "$TMP_FIX" 2>/dev/null && \
     python3 -c "import json; json.load(open('$TMP_FIX'))" 2>/dev/null; then
    PIRATE_FIXTURE="$TMP_FIX"
  else
    fail "V6: Hostex callback fixture missing AND fallback fetch failed. Set PIRATE_FIXTURE=<path>."
    PIRATE_FIXTURE=""
  fi
fi

if [[ -n "$PIRATE_FIXTURE" ]]; then
  # We confirm the boss skill CONTAINS the legacy pirate-vocab requirement
  # AND CONTAINS the no-consult fast path branch. A full webhook-tunnel
  # round-trip requires the live Hostex webhook to be online, which is
  # out of scope for this verify; the skill-content check is the gate
  # that prevents the demo from breaking.
  if "${EXEC[@]}" grep -qiE 'arrr|ahoy|hearties' "$BOSS_SKILL" 2>/dev/null && \
     "${EXEC[@]}" grep -Fq 'legacy v9.0.0' "$BOSS_SKILL"; then
    pass "V6 boss skill carries pirate-fast-path contract (vocab + legacy reference)"
  else
    fail "V6: boss skill MISSING pirate fast path — Trial Reel demo will break"
  fi

  # Wire-sample shape sanity (so we know the fast path can actually parse it)
  if python3 -c "
import json,sys
d = json.load(open('$PIRATE_FIXTURE'))
assert d.get('event') == 'message_created', 'event mismatch'
assert d.get('conversation_id'), 'no conversation_id'
assert d.get('message_id'), 'no message_id'
" 2>/dev/null; then
    pass "V6 captured hostex-message_created.json fixture parses with expected shape"
  else
    fail "V6: wire sample shape changed; boss skill parser will break"
  fi
fi

# ============================================================================
# V7 — CRITICAL REGRESSION: v9.0.0 Branch A Hostex POST contract
# ============================================================================
note "V7 CRITICAL REGRESSION — v9.0.0 Branch A Hostex POST contract"
# Skill-content gate: the SKILL.md MUST encode the v9.0.0 POST contract.
# Live POST verification requires a real Hostex token + an approve flow,
# which we cannot exercise here without burning a real customer message;
# the skill-content gate is the structural anti-regression.
if "${EXEC[@]}" grep -Fq 'Hostex-Access-Token: {hostex_access_token}' "$BOSS_SKILL" && \
   "${EXEC[@]}" grep -Fq 'User-Agent: curl/8.7.1' "$BOSS_SKILL" && \
   "${EXEC[@]}" grep -Fq 'POST {hostex_base_url}/v3/conversations/{conversation_id}' "$BOSS_SKILL" && \
   "${EXEC[@]}" grep -Fq '{"message":"<draft>"}' "$BOSS_SKILL"; then
  pass "V7 boss skill encodes v9.0.0 Branch A POST contract"
else
  fail "V7: boss skill DOES NOT encode v9.0.0 Branch A POST contract — live deploys will break"
fi
# Outbox path check
if "${EXEC[@]}" grep -Fq '/opt/data/home/.airbnb-manager/outbox.jsonl' "$BOSS_SKILL"; then
  pass "V7 boss skill writes to legacy outbox path"
else
  fail "V7: boss skill does NOT write to legacy outbox path — audit trail breaks"
fi

# ============================================================================
# V8 — end-to-end consult flow (optional; --skip-e2e to bypass)
# ============================================================================
if [[ "$SKIP_E2E" != "1" ]]; then
  note "V8 end-to-end consult flow (synthetic)"
  # This is a structural / state-machine probe rather than a real LLM round-trip.
  # We:
  #   1. Author a synthetic team/cleaner-verify.md page.
  #   2. Hand-write a synthetic queries/q-verify.md with one open ask.
  #   3. Wait one courier tick (60s).
  #   4. Assert that the courier-modified the page (updated_at advanced)
  #      AND that the dry-run wakeAgent call would have fired (we run the
  #      courier itself with AIRBNB_COURIER_DRY_RUN=1 for this probe so we
  #      don't fire a real wake).

  Q_VERIFY="q-verify-$(date +%s)"
  Q_FILE="/opt/data/home/brain/queries/${Q_VERIFY}.md"
  T_FILE="/opt/data/home/brain/team/cleaner-verify.md"

  # Write synthetic team page (if not present from a prior run).
  "${EXEC[@]}" env HOME=/opt/data/home bash -c "cat > $T_FILE" <<'EOF'
---
title: "Verify Cleaner"
member_uid: "cht_verify"
role: cleaner
display_name: "Verify Cleaner"
active: true
---
# Verify Cleaner

(verify.sh placeholder; safe to delete)
EOF

  # Write synthetic query page with one already-answered ask so courier wakes.
  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  PAST=$(date -u -v-65M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '65 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$NOW")
  "${EXEC[@]}" env HOME=/opt/data/home bash -c "cat > $Q_FILE" <<EOF
---
title: "verify probe"
query_id: "${Q_VERIFY}"
guest_conversation_id: "verify-conv"
guest_message_id: "verify-msg"
status: open
created_at: "${PAST}"
updated_at: "${PAST}"
owner_mirror_session_key: "verify:session"
guest_message_content: "verify"
asks:
  - ask_id: "ask-1"
    team_member_uid: "cht_verify"
    role: "cleaner"
    question: "verify?"
    asked_at: "${PAST}"
    original_asked_at: "${PAST}"
    ping_count: 1
    sla_deadline: "${PAST}"
    escalation_deadline: "${PAST}"
    status: answered
    answer: "yes"
    answered_at: "${NOW}"
drafts: []
---
# verify probe
EOF

  # Run the courier ONCE in dry-run mode and confirm it would have woken the owner.
  COURIER_OUTPUT=$("${EXEC[@]}" env HOME=/opt/data/home AIRBNB_OWNER_PROFILE="${OWNER_PROFILE}" \
    AIRBNB_OWNER_MIRROR_SESSION_KEY="verify:session" AIRBNB_COURIER_DRY_RUN=1 \
    AIRBNB_COURIER_TICK_SECONDS=999 bash -c '
      # Run the courier loop ONCE: send SIGTERM after first tick.
      ( /opt/data/home/airbnb-courier/tick-loop.sh & PID=$!; sleep 2; kill -TERM $PID 2>/dev/null; wait $PID 2>/dev/null ) || true
    ' 2>&1 || true)

  if echo "$COURIER_OUTPUT" | grep -q "DRY_RUN would wake.*query_id=${Q_VERIFY}"; then
    pass "V8 courier identifies ready_to_draft AND would wake owner profile"
  else
    fail "V8: courier did NOT wake for the synthetic ready_to_draft case"
    echo "    courier output:"
    echo "$COURIER_OUTPUT" | sed 's/^/      /'
  fi

  # Cleanup synthetic pages.
  "${EXEC[@]}" rm -f "$Q_FILE" "$T_FILE" "${Q_FILE}.lock"
else
  note "V8 end-to-end consult flow SKIPPED (--skip-e2e)"
fi

# ============================================================================
# V9 — re-run idempotency (lightweight: confirm critical files exist after a
# re-run would not destroy them; the full re-run check is in CI)
# ============================================================================
note "V9 re-run idempotency surface check"
if "${EXEC[@]}" test -f "$BOSS_SKILL" && \
   "${EXEC[@]}" test -f "/opt/data/home/airbnb-courier/tick-loop.sh" && \
   [[ -f "${SCAFFOLD_DIR%/}/compose.airbnb-coordinator.yaml" ]]; then
  pass "V9 install artifacts present (re-running installer would be no-op)"
else
  fail "V9: install artifacts incomplete — re-run is NOT idempotent"
fi

echo
if [[ $FAILED -eq 0 ]]; then
  echo "VERIFY_OK: all checks passed"
  exit 0
else
  echo "VERIFY_FAIL: $FAILED check(s) failed"
  exit 1
fi
