# Hostex API surface (reference)

The endpoints `hostex-context` consumes. Base URL `https://api.hostex.io/v3`
(override with `HOSTEX_BASE_URL`; the DTU mirrors these paths exactly). Auth:
header `Hostex-Access-Token: <token>`. Every request also sends
`User-Agent: curl/8.7.1`. Responses use the envelope:

```json
{ "request_id": "...", "error_code": 0, "error_msg": "...", "data": { ... } }
```

The DTU returns the same `data` payloads (it omits the metadata fields, which the
agent does not read).

## GET /v3/reservations

Filters (all optional): `reservation_code`, `channel_id`, `property_id` (integer),
`status`, `start_check_in_date`, `end_check_in_date`, `start_check_out_date`,
`end_check_out_date`, `order_by` (`booked_at`|`check_in_date`|`check_out_date`|
`cancelled_at`|`created_at`), `channel_type`, `offset`, `limit` (≤100, default 20).

`data.reservations[]` each:

```
reservation_code, stay_code, status, channel_type, channel_id,
property_id (int), listing_id, check_in_date, check_out_date,
number_of_guests/adults/children/infants/pets,
guest_name, guest_phone, guest_email, guests[]{name,phone,email,...},
conversation_id, booked_at, created_at, cancelled_at,
remarks, channel_remarks, tags[],
check_in_details{ arrival_at, departure_at, lock_code, lock_code_visible_after },
rates{ total_rate, rate, commission, details[] }
```

**Status enum:** `wait_accept`, `wait_pay`, `accepted`, `cancelled`, `denied`,
`timeout`. Only `accepted` reservations occupy nights.

## POST /v3/listings/calendar

Body: `{ start_date, end_date, listings:[{ listing_id, channel_type }] }`
(`start_date` within 1 year, `end_date` within 3 years). Returns
`data.listings[].calendar[]` of `{ date, price, inventory, restrictions{...} }`.
`inventory == 0` ⇒ that night is unavailable (booked or blocked); `>= 1` ⇒ free.

## GET /v3/availabilities

Query: `property_ids` (comma-joined integers, ≤100), `start_date`, `end_date`.
Returns `data.properties[]` of `{ id, availabilities:[{ date, available, remarks }] }`.
`available` is the clean per-night free/occupied boolean; `remarks` carries host
notes — **this is the canonical source for maintenance / blocked-date reasons**.

## GET /v3/properties

`data.properties[]` — the property catalog. Carries the slug `id`, `title`,
`hostex_id` (integer), `listing_id`, `channel_type`, default check-in/out times.
Used to map a friendly slug to the integer `property_id` the API expects.

## GET /v3/conversations/{id}

Existing messaging endpoint (owned by `str-manager-approval`). `data.guest`,
`data.activities[].property`, `data.messages[]`. Reservations carry
`conversation_id`, so guest-state-by-conversation matches a reservation to a
conversation locally.

## Night model (occupancy semantics)

- A reservation occupies nights **[check_in_date, check_out_date)** — the
  checkout day's night is free (the guest leaves that morning).
- A host block occupies nights **[start_date, end_date]** inclusive.
- Early check-in on date D depends on the night of **D-1** (the night before).
- Late check-out on date D depends on the night of **D** (the checkin night).

## Webhooks (for reference)

Real Hostex fires `reservation_created`, `reservation_updated`,
`availability_updated`, `listing_calendar_updated`, `message_created`. The boss
already subscribes to `message_created`; the others can drive future
event-driven refresh but are not required for live-pull reads.
