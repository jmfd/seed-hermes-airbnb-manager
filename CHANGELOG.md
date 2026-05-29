# Changelog

## Unreleased

### Added — optional plow-airbnb-dashboard sub-seed (SEED §16)

- SEED.md now integrates `plow-pbc/seed-plow-airbnb-dashboard` as an
  OPTIONAL trailing **sub-seed**. New `^optional-dashboard-subseed` /
  `^optional-dashboard-handoff` (§1.1) introduce it as a host-level
  dashboard service (+ Chromium kiosk when the host has a display)
  installed *after* the §15 acceptance gates — on **this main host**
  (`local` mode), not into the compose stack and not onto a separate Pi.
- New `^phase0-dashboard-optin` (§2.1) makes installation an **up-front
  opt-in** (`INSTALL_DASHBOARD=yes`). The only added host prereqs are
  passwordless `sudo` (`^prereq-dash-sudo`, REQUIRED) and an optional
  display for the kiosk (`^prereq-dash-display`); the calendar source is
  satisfied automatically by reusing the Hostex token (`^prereq-dash-source`).
- New phase **§16** (`^phase12-*`, verify `^v-phase12`) runs the dashboard
  SEED **fully non-interactively**: after the single `[y/N]` opt-in it
  never prompts again — `local` mode, `id -un` target, `tier-2`
  confirmations waived, the reused `HOSTEX_ACCESS_TOKEN` as the **sole**
  source (no `.ics`/Guesty prompt, `^phase12-cred-reuse`), and a
  best-effort kiosk that is skipped on a headless host. Secret hygiene is
  preserved across the hand-off (`^phase12-secret-hygiene`); the §16.4
  verify relaxes the kiosk gate for headless hosts.
- §16/§17/§18 renumber (old §16 Known limitations → §17; old §17 Open +
  Non-Goals → §18). Added `^o-dashboard-subseed-script` (a future scripted
  wrapper) and `^ng-dashboard-colocation` (host-level install, not the
  compose stack and not a separate Pi). Companion changes in the dashboard
  SEED: `^dep-subseed` (non-interactive sub-seed contract + `local`
  default), `^o-subseed`, and best-effort-kiosk notes on
  `^act-deploy-kiosk` / `^v-kiosk-active`.

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
- Installer deploys hostex-context to `/opt/data/home/hostex-context/`
  (`^act-hostex-context-install`); `verify.sh` gains check **V3f**; SEED.md gains
  `^obj-hostex-context-installed`, `^act-boss-hostex-context`, and
  `^v-hostex-context`.
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
