# dev-harness — DTU additive endpoints for hostex-context

The `hostex-context` skill reads live calendar / reservation / availability state
from Hostex. For local + CI testing we point `HOSTEX_BASE_URL` at the **DTU**
(Digital Twin of hostex.io), whose canonical source is
`seedlab/seeds/dev-harness/dtu-hostex.seed.md`. The DTU today stubs only
properties + conversations + messages + webhooks.

`dtu-hostex-endpoints.diff` is the **additive** patch that teaches the DTU the
read endpoints `hostex-context` needs, plus admin/CLI verbs for scripted seeding.

## What the patch adds (and nothing else)

- `GET  /v3/reservations` — filterable reservation list, real-Hostex wire shape.
- `POST /v3/listings/calendar` — per-night price + inventory + restrictions.
- `GET  /v3/availabilities` — per-night `{available, remarks}` (the maintenance/
  blocked-date signal).
- `/admin/reservation`, `/admin/reservation/cancel`, `/admin/block` + the CLI
  verbs `dtu reservation add|list|cancel` and `dtu block add` for test seeding.
- Lazy `reservations.json` / `blocks.json`; `hostex_id` / `listing_id` stamped
  onto the property catalog (int↔slug map); `/admin/reset` + webhook fanout
  extended to the new event types.

## Backward compatibility (verified)

The diff is **purely additive** — it introduces new routes, helpers, CLI verbs,
and lazily-created data files. It changes no existing route, response shape, or
the UI. Absent data files ⇒ endpoints return empty, so other lanes' DTUs (which
share the same `dtu.py` with their own data dirs) are unaffected. Confirm with:

```sh
grep -E '^-' dtu-hostex-endpoints.diff | grep -vE '^--- '   # → no output
```

## Applying

Against a checkout of the canonical DTU:

```sh
cd <seedlab>/seeds/dev-harness
patch -p1 < <this-repo>/ref/dev-harness/dtu-hostex-endpoints.diff
# restart only your instance: <python-with-flask> dtu.py serve --port <port>
```

The patch targets `b/seeds/dev-harness/dtu.py`. Night model and full endpoint
contracts are documented in
`ref/hermes-skills/hostex-context/reference/hostex-api.md`.
