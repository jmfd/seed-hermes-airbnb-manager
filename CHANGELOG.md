# Changelog

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
- `ref/dev-harness/dtu-hostex-endpoints.diff` — **additive** DTU patch adding
  `GET /v3/reservations`, `POST /v3/listings/calendar`, `GET /v3/availabilities`,
  and `/admin` + CLI seeding verbs (`dtu reservation add|list|cancel`,
  `dtu block add`). Backward-compatible: no existing route, response shape, or the
  UI is changed; absent data files yield empty results, so other lanes' DTUs are
  unaffected.

## 0.1.0

- Initial airbnb-coordinator boss + team-listener + courier sidecar seed.
