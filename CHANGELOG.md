# Changelog

## 0.3.0 — 2026-06-02

### Fixed — owner-approve auto-ship "false sent" (delivery reliability)

- **Root cause:** Branch A had the boss build an ad-hoc curl/python wrapper to POST the
  approved reply to Hostex. The wrapper could fail silently on Unicode em-dash / curly
  quotes in drafts, yet the boss still wrote `outbox delivered:true` and replied "Sent" —
  so the owner saw "sent" while the guest received nothing.
- **Fix:** new deterministic `ref/courier/ship-reply.sh` (POST -> require http 200 +
  `error_code:200` -> RE-VERIFY via GET that the host reply landed, polling for Hostex's
  async propagation -> only then append the outbox row). Branch A in
  `ref/hermes-skills/airbnb-coordinator-boss/SKILL.md` now calls this script and only says
  "Sent" on `SHIP_OK`; on `SHIP_FAILED` it reports the error to the owner and keeps the
  draft pending. Installer deploys `ship-reply.sh` alongside `query-edit.py`.

### Added — owner phone-number swap procedure

- `docs/owner-number-swap.md`: reproducible runbook to move the owner's plow_chat approval
  channel to a new phone — device-code re-bind, authorize the new `cp_` identity on inbound
  pairing, propagate the new channel to all baked locations (.env + webhook_subscriptions.json
  + channel_directory.json + .airbnb-courier.env), restart, verify both directions, rollback.


## 0.2.0 — 2026-05-25

### Added — hostex-context (Hostex deep integration)

- New read-only skill `ref/hermes-skills/hostex-context/` giving the boss **live
  Hostex state at classification + drafting time**: `hxctx guest-state`,
  `occupancy`, `calendar`, `reservations`, `schedule`. Hostex is the single
  source of truth — the tools pull live on every call; no cache, mirror, or store
  (only request-scope memoization within one process).
- Guest-state model (8 states) and occupancy-adjacency (early-checkin /
  late-checkout feasibility) implemented as **pure functions** (`_classify.py`),
  with a full unit-test matrix (`tests/test_classify.py`, no network) and an
  end-to-end DTU validator (`tests/validate.sh`). Mechanical state is asserted
  structurally; draft phrasing is left to eyeball / LLM-as-judge — no regex on
  model output.
- Boss skill (`airbnb-coordinator-boss`, installed as `str-manager-approval`)
  taught to consult hostex-context at classify + draft time; live state overrides
  static brain facts on conflict. The v9.0.0 Hostex contract is preserved
  verbatim (callback parser, `User-Agent: curl/8.7.1`,
  `POST /v3/conversations/{id}` body `message`). Credentials flow from the webhook
  prompt via `--base-url`/`--token` — never hardcoded.
- Installer deploys hostex-context to `/opt/data/home/hostex-context/` (new
  install step); `verify.sh` gains check **V3f**; SEED.md gains the
  hostex-context-installed object, the boss's hostex-context lookup action, and
  a hostex-context verify check.
- `ref/dev-harness/dtu.py` — the DTU (Digital Twin of hostex.io) **as real,
  runnable code in this project** (not a patch). Implements `GET /v3/reservations`,
  `POST /v3/listings/calendar`, `GET /v3/availabilities`, and `/admin` + CLI
  seeding verbs (`dtu reservation add|list|cancel`, `dtu block add`).
  Backward-compatible: no pre-existing route, response shape, or the UI changed;
  absent data files yield empty results. This is the canonical DTU source for the
  project — the skill needs these endpoints, so the project ships them.

### Hardened against real api.hostex.io (DTU-vs-real divergence audit)

All five tools were run against the live Hostex API and reconciled with the DTU
stub (see PR description for the full audit). Fixes:
- **`stay_status`** (`checkin_pending`/`in_house`/`stay_completed`) — real Hostex's
  authoritative occupancy signal. Now classified (overrides calendar dates for
  early check-in / late checkout) and stubbed in the DTU.
- **Property resolution** — real `/v3/properties` keys on the integer `id` (no
  slug); `--property mtn-home` now resolves via slug-of-title, working on both
  real and DTU.
- **Channel-specific `listing_id`** — real listing ids live in the property's
  `channels[]` (one property → many channel listings); `calendar` now leads
  booked/free from `/v3/availabilities` (property-level) and treats listing price
  as best-effort enrichment.
- **No `total`** in real `/v3/reservations`; DTU response corrected to match.
- DTU reservation records extended (`stay_status`, `creator`, `rates`,
  `channel_remarks`, fuller `check_in_details`, …) to mirror real shape.
- `reservations --upcoming --limit N` added (the "next N bookings" scenario).

## 0.1.0

- Initial airbnb-coordinator boss + team-listener + courier sidecar seed.
