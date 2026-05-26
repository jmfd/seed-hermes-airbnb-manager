# dev-harness — DTU (Digital Twin of hostex.io)

`dtu.py` is the **Digital Twin** of `api.hostex.io`: a single-file Flask app that
serves a hostex-compatible HTTP API (and a small web UI) from local JSON state.
It is the test stand-in for live Hostex — point `HOSTEX_BASE_URL` at it and the
same agent/skill code that talks to real Hostex works unchanged.

**This is the real implementation, not a patch.** The `hostex-context` skill
needs calendar / reservation / availability endpoints, so this project
implements them — here, as runnable Python. There is no diff-for-another-team.

## Endpoints (wire shapes mirror real api.hostex.io)

Read (used by `hostex-context`):
- `GET  /v3/reservations` — filter by `property_id` (int **or** slug), `status`,
  `reservation_code`, `start/end_check_in_date`, `start/end_check_out_date`,
  `offset/limit`. Reservation objects carry the real fields incl. `stay_status`
  (`checkin_pending`/`in_house`/`stay_completed`), `check_in_details`, `rates`.
- `POST /v3/listings/calendar` — per-night `{date, price, inventory, restrictions}`.
- `GET  /v3/availabilities` — per-night `{date, available, remarks}` (the
  maintenance / blocked-date signal). Authoritative booked/free source.
- `GET  /v3/properties`, `GET /v3/conversations[/{id}]`, `/v3/webhooks` — pre-existing.

Admin / test-seeding (DTU-only; real Hostex is read-only at draft time):
- `POST /admin/reservation`, `POST /admin/reservation/cancel`, `POST /admin/block`
- `POST /admin/reset`, `POST /admin/guest-send`, `GET /admin/events`

CLI verbs (thin HTTP clients over the admin routes — used for scripted seeding):
```
dtu reservation add  --property <slug|id> --check-in D1 --check-out D2 \
                     [--status accepted] [--stay-status …] [--conv C] [--guest-name N]
dtu reservation list [--property …]
dtu reservation cancel --code …
dtu block add        --property <slug|id> --start D1 --end D2 [--remarks "deep clean"]
```

## Run

```sh
# venv with flask (the repo's harness venv, or any python3 + flask)
DTU_DATA_DIR=~/.dtu-hostex/data python3 ref/dev-harness/dtu.py serve --port 8082
```
Each instance is one process with its own `--port` + `DTU_DATA_DIR`; the same
`dtu.py` file backs every instance. Data files (`reservations.json`,
`blocks.json`, …) are created lazily in the data dir.

## Night model
A reservation occupies nights `[check_in_date, check_out_date)` (the checkout
day's night is free — guest departs that morning). A host block occupies
`[start_date, end_date]` inclusive. Early check-in on D depends on the night of
D-1; late checkout on D depends on the night of D.

## Backward compatibility
The reservation/calendar/availability routes + CLI verbs were added without
changing any pre-existing route, response shape, or the UI. Absent data files
yield empty results, so an instance pointed at a data dir with no reservations
simply returns empty arrays. Validated against real `api.hostex.io` (PR #4
divergence audit); shapes reconciled with reality.

Full endpoint contracts + the guest-state model:
`ref/hermes-skills/hostex-context/reference/hostex-api.md` and `…/guest-state.md`.
End-to-end validation harness: `ref/hermes-skills/hostex-context/tests/validate.sh`.
