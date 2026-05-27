# Design Doc — `hostex-context` Hermes skill (Hostex deep integration)

**Author:** Hostex-integration engineer  **Date:** 2026-05-25  **Status:** DRAFT — awaiting CEO approval gate
**Lane:** Hostex deep integration only. Isolated container `/tmp/plow-seeds-hostex/hermes-agent/`, DTU on `:8082`.
No edits to `airbnb:eng-1` (`/tmp/plow-seeds/`) or `seedlab:gbrain` (`/tmp/plow-seeds-mem/`) containers.

---

## 1. Problem (CEO's words, restated)

Hermes uses Hostex today only for **messaging** (send + receive). The boss cannot intelligently answer
guest questions because it has no view of live state:

- **Calendar / days** — which nights are booked, which are free.
- **Schedule** — who is checked in today / arriving tomorrow / due this week.
- **Guest state** — is this a curious browser, a past renter, currently checked in, mid-stay, or checking out today?
- **Occupancy adjacency** — for "early check-in?", is the *previous* night booked or free?
- **Property-level state** — maintenance flags, blocked dates.

Goal: a `hostex-context` skill that (a) documents the Hostex API surface and (b) provides **tools the boss calls
at classification + drafting time** to read live calendar / reservation / guest / occupancy state.

---

## 2. What exists today (grounding — verified in-container + against api-doc.hostex.io)

### 2.1 Hostex API surface (real)
- Base `https://api.hostex.io/v3`; auth header **`Hostex-Access-Token`**; envelope `{request_id, error_code, error_msg, data}`.
- `GET /v3/reservations` — filters: `property_id` (int), `status`, `start/end_check_in_date`, `start/end_check_out_date`,
  `reservation_code`, `channel_type`, `order_by`, `offset/limit`. Reservation object carries `reservation_code`,
  `status`, `check_in_date`, `check_out_date`, `number_of_guests/adults/children/infants/pets`, `guest_name/phone/email`,
  `guests[]`, `property_id`, `listing_id`, `channel_type`, `conversation_id`, `check_in_details{arrival_at, departure_at,
  lock_code, lock_code_visible_after}`, `rates`, `tags`, `remarks`. **Status enum:** `wait_accept`, `wait_pay`,
  `accepted`, `cancelled`, `denied`, `timeout`.
- `POST /v3/listings/calendar` — body `{start_date, end_date, listings:[{listing_id, channel_type}]}` →
  per-day `{date, price, inventory, restrictions{closed_on_arrival, closed_on_departure, min/max_stay_*, ...}}`.
  Note: `inventory == 0` is the "no availability that night" signal (no separate boolean).
- `GET /v3/availabilities?property_ids=&start_date=&end_date=` → per-property
  `{id, availabilities:[{date, available(bool), remarks}]}`. **This is the cleanest booked/free + maintenance signal**
  (`remarks` carries host notes / maintenance text).
- `GET /v3/listings`, `GET /v3/properties`, `GET /v3/conversations[/{id}]` — already in use.
- Webhooks fire on reservation create/update, availability update, calendar update, message create.

### 2.2 DTU (`~/.dtu/dtu.py`, host-side Flask, data dir `~/.dtu-hostex/data`, port 8082)
- Single-file Flask app. Storage = plain JSON / JSONL via `_read_json` / `_write_json_atomic` / `_append_jsonl`.
- Today stubs **only** properties, conversations, messages, webhooks. Routes: `/healthz`, `/v3/properties`,
  `/v3/conversations[/{id}]` (GET list/detail, POST host message), `/admin/guest-send`, `/v3/webhooks`,
  `/admin/reset`, `/admin/events`. CLI verbs mirror each route; `/admin/reset` + `/admin/events` exist for scripted
  setup/assertion.
- **Design ethos (verbatim):** *"Wire shapes deliberately aligned to the captured real Hostex contracts so the same
  agent code that talks to this DTU works unchanged against api.hostex.io."* My additions must honor this.
- **Reachability:** container → host DTU verified at `http://host.docker.internal:8082` (200).
- **Cross-lane note:** `dtu.py` is a *shared* host file; each lane runs it with its own `--data-dir`/`--port`.
  See §7 for how I keep edits safe.

### 2.3 Boss (the courier the CEO calls "the boss")
- `airbnb-courier/tick-loop.sh` — deterministic scheduler (SLA/escalation timers); **wakes a Hermes LLM agent**
  to draft; ships approved drafts to the guest via `POST /v3/conversations/{id}`.
- `airbnb-courier/query-edit.py` — flock-guarded read-modify-write for brain "query pages"
  (`brain/queries/q-*.md`): create-query → append-draft `{partial|final|escalate-notice}` → owner mirror/approve/reject
  → deliver. This is the storage CLI, not the reasoning.
- `brain/facts/mtn-home/*.md` — the static knowledge base the boss drafts from (e.g. `check_in.md`, `access_code.md`,
  **`early_check_in.md`**). These come from `hostex-ingest/` (periodic Hostex → distill → facts).
- **There is no literal boss `SKILL.md` today** — `SOUL.md` is the empty default persona; the boss is the Hermes
  agent under the owner profile (`$OWNER_PROFILE`). So `hostex-context` *is* the skill that arms the draft-time agent.

### 2.4 The canonical gap (real artifact)
`brain/facts/mtn-home/early_check_in.md` currently says, verbatim:
> *"Early check-in may be available if the cabin was not occupied the night before, but it cannot be confirmed until
> the morning of check-in because same-day bookings are allowed."*

The boss can recite this static caveat but **cannot actually check** whether last night is free. `hostex-context`
closes exactly this loop.

### 2.5 Client seam + id mapping
- `hostex-ingest/ingest-lib.sh::hostex_get <path>` uses `HOSTEX_BASE_URL` (default `api.hostex.io`) +
  `Hostex-Access-Token`. For DTU testing, `HOSTEX_BASE_URL=http://host.docker.internal:8082`. My tools reuse this seam.
- Property id↔slug map (`.hostex-ingest/state.json`): `12051776 ↔ mtn-home`, `12051778 ↔ 10th-ave`.
  Real Hostex keys on **integer** `property_id`; the DTU currently keys on **slug** (`mtn-home`). See §6.

---

## 3. Design principles (locked ground rules applied)

1. **Read-only at draft time.** `hostex-context` only *reads* Hostex state. No writes (no booking edits, no calendar
   mutation) — messaging writes stay owned by the existing courier path.
2. **Same code, real or DTU.** Tools call the existing `hostex_get` seam; switching `HOSTEX_BASE_URL` between the DTU
   and `api.hostex.io` changes nothing in tool code.
3. **Mechanical vs behavioral split (architectural rule).** Guest-state classification + occupancy adjacency are
   *deterministic pure functions* of (status, dates, today) → tested with **structural assertions**. How the boss
   *phrases* a reply is **behavioral** → validated by **LLM-as-judge or eyeball, never regex**.
4. **Additive, backward-compatible DTU.** New routes return graceful-empty when their data file is absent, so other
   lanes' DTUs are unaffected even though the file is shared.
5. **No manual tests proposed to the CEO.** All validation is scripted (`validate.sh` + an LLM-judge harness).

---

## 4. `hostex-context` skill structure

```
hostex-context/
  SKILL.md                 # teaches the draft-time boss WHEN/HOW to pull live state (behavior, not gates)
  reference/
    hostex-api.md          # the documented API surface from §2.1 (the "what endpoints exist" deliverable)
    guest-state.md         # the state model + decision table (§5.2)
  tools/
    hxctx                  # single entrypoint dispatcher (python3, query-edit.py style), subcommands below
    _client.py             # thin wrapper over hostex_get seam (reads HOSTEX_BASE_URL + token)
    _classify.py           # pure guest-state + occupancy functions (no I/O — unit-testable)
  tests/
    test_classify.py       # structural assertions over the full state matrix (no network)
    validate.sh            # end-to-end: reset DTU → seed → hit endpoints → assert shapes
    judge/                 # LLM-as-judge fixtures for draft behavior (optional, behavioral)
```

`SKILL.md` is loaded into the draft-time agent's context. It teaches: *recognize* occupancy/timing/guest-state
questions, *call* the relevant `hxctx` tool, *fold* the JSON result into the draft, and *defer* to live state over
static facts (e.g. `early_check_in.md` becomes "consult `hxctx occupancy` before answering"). It contains **no regex
and no output-shape gates** — it teaches behavior in prose, as the rule requires.

---

## 5. Tool definitions

All tools print **JSON to stdout** (machine-consumable by the agent) and accept a property **slug or integer id**
(resolved via the properties catalog). All are read-only.

### 5.1 The four capabilities

| Tool | Invocation | Backing endpoint(s) | Returns |
|------|-----------|---------------------|---------|
| **calendar** | `hxctx calendar --property mtn-home --start D1 --end D2` | `POST /v3/listings/calendar` (+ `/v3/availabilities` for the boolean) | per-night `{date, status: booked\|free\|blocked, price, restrictions}` |
| **reservations** | `hxctx reservations --property mtn-home [--on DATE] [--status accepted] [--window N]` | `GET /v3/reservations` | matching reservations, normalized (`reservation_code, status, check_in_date, check_out_date, guest_name, conversation_id, nights`) |
| **guest-state** | `hxctx guest-state (--conversation CONV \| --reservation CODE) [--asof DATE]` | `GET /v3/reservations` (+ conversation linkage) | `{state, reservation_code?, check_in_date?, check_out_date?, nights_remaining?, evidence{...}}` |
| **occupancy-adjacency** | `hxctx occupancy --property mtn-home --date DATE` | `/v3/availabilities` + `/v3/reservations` | `{date, prev_night: booked\|free, next_night: booked\|free, same_day_booking_possible, early_checkin_feasible, late_checkout_feasible}` |

Plus one **composite** for the common "who's around" question:

| **schedule** | `hxctx schedule --property mtn-home [--day today\|tomorrow\|week]` | `GET /v3/reservations` | `{arriving:[…], in_house:[…], departing:[…]}` for the window |

### 5.2 Guest-state model (deterministic; the classification deliverable)

State is a pure function of `(reservation.status, check_in_date, check_out_date, today)` plus "has a reservation at all":

| State | Condition |
|-------|-----------|
| `curious_browser` | conversation exists, **no** reservation linked |
| `inquiry_pending` | latest reservation `status ∈ {wait_accept, wait_pay}` |
| `future_guest` | `status=accepted` and `today < check_in_date` |
| `arriving_today` | `status=accepted` and `today == check_in_date` |
| `checked_in_midstay` | `status=accepted` and `check_in_date < today < check_out_date` |
| `checking_out_today` | `status=accepted` and `today == check_out_date` |
| `past_guest` | `status=accepted` and `today > check_out_date` |
| `cancelled` | `status ∈ {cancelled, denied, timeout}` (most recent) |

Tie-break when multiple reservations link to one guest/conversation: prefer the reservation whose
`[check_in_date, check_out_date]` contains `today`, else the nearest upcoming, else the most recent past. This table
is the unit-test oracle (§9).

---

## 6. Property id / slug fidelity (decision needed — recommendation below)

Real Hostex keys reservations/availabilities on **integer** `property_id`; the DTU currently keys conversations and
`/v3/properties` on **slug** (`mtn-home`). To honor "same code works against real api.hostex.io" without forking the
DTU's existing slug data:

**Recommendation:** New DTU reservation/availability records carry **both** `property_id` (integer, real-Hostex-faithful)
and `property_slug`. The new endpoints accept **either** an integer id or a slug (tolerant lookup via the catalog).
`hxctx` tools pass the **integer** `property_id` (real-API behavior), resolving slug→id through `/v3/properties`/catalog.
Result: records look exactly like real Hostex, the boss code is real-API-faithful, and the DTU's existing slug-centric
data is untouched.

---

## 7. DTU endpoint additions (additive-only, backward-compatible)

New data files (created lazily; absent ⇒ endpoints return empty): `reservations.json`, `blocks.json`
(host/maintenance blocks; powers `remarks` + blocked status). Calendar/availability are **computed** from
reservations + blocks so the three views can never disagree.

New routes (real wire shapes from §2.1):
- `GET  /v3/reservations` — filters: `property_id` (int **or** slug), `status`, `start/end_check_in_date`,
  `start/end_check_out_date`, `reservation_code`, `offset/limit`. → `{data:{reservations:[…]}}`.
- `POST /v3/listings/calendar` — `{data:{listings:[{listing_id, channel_type, calendar:[{date, price, inventory,
  restrictions}]}]}}`; `inventory=0` where a reservation/block covers the night.
- `GET  /v3/availabilities` — `{data:{properties:[{id, availabilities:[{date, available, remarks}]}]}}`;
  `available=false` where booked/blocked, `remarks` from the block (maintenance note).

New CLI verbs (scripted seeding for tests):
- `dtu reservation add --property … --code … --status accepted --check-in D1 --check-out D2 [--conversation CONV] [--guest NAME]`
- `dtu reservation list [--property …]` · `dtu reservation cancel --code …`
- `dtu block add --property … --start D1 --end D2 [--remarks "deep clean"]` (maintenance/blocked dates)

Extend `/admin/reset` to also clear `reservations.json` + `blocks.json`. Add webhook event names already in real
Hostex: `reservation_created`, `reservation_updated`, `availability_updated` (fanout reuses existing machinery).

**Safety for the shared file:** all edits are new routes/functions/CLI verbs + lazy data files. Existing routes,
shapes, and the UI are untouched; other lanes' DTUs reading their own (reservation-less) data dirs simply get
empty arrays. I restart **only** my `:8082` process. (See Open Question Q2.)

---

## 8. Integration points with the boss

1. **Draft-time skill availability.** `hostex-context/SKILL.md` is mounted where the courier's woken agent loads it
   (proposed: alongside `airbnb-courier/`, i.e. `/opt/data/home/hostex-context/`, surfaced into the draft-time
   context the same way brain facts are).
2. **Static-fact deferral.** Facts that depend on live occupancy (canonically `early_check_in.md`, and check-out
   timing) get a pointer line: *"Before answering, call `hxctx occupancy`/`hxctx guest-state` — live state overrides
   this caveat."* Prose only; no behavioral gate.
3. **Classification hook.** When the courier wakes the agent on a new guest message, the agent can call
   `hxctx guest-state --conversation <id>` to anchor tone/eligibility (e.g. don't pitch amenities to a `past_guest`;
   give door-code logistics to `arriving_today`).
4. **No change to the messaging write path** — delivery still flows through the existing
   `query-edit.py` → `POST /v3/conversations/{id}` path.

---

## 9. Validation plan (scripted; no manual tests; no regex on LLM output)

**Tier 1 — pure-function unit tests (`tests/test_classify.py`, no network).** A fixture table enumerating every row
of §5.2 across `today` positions → assert exact `state`. Same for occupancy (`prev_night`/`next_night`
booked/free permutations → expected `early_checkin_feasible`). Deterministic, fast, runs in CI.

**Tier 2 — end-to-end DTU contract (`tests/validate.sh`).** `POST /admin/reset` → seed via `dtu reservation add` /
`dtu block add` → call each new endpoint + each `hxctx` tool → **structural assertions** on JSON shape, field
presence, and computed status (e.g. a night with an `accepted` reservation reports `available=false` in
`/v3/availabilities`, `inventory=0` in the calendar, and `booked` from `hxctx calendar`). Mechanical state only.

**Tier 3 — draft behavior (LLM-as-judge, optional/at CEO discretion).** Seed two worlds — prev night *free* vs
*booked* — feed the same "can I check in early?" guest message, and have an LLM judge confirm the draft's *stance*
flips appropriately (offers vs declines/defers). This is the only behavioral check; it is judge-based, never a regex
gate, and runs as a script.

---

## 10. Shipping

- **Skill + courier integration → `plow-pbc/seed-hermes-airbnb-manager`** (the boss seed; default branch `main`) as
  `skills/hostex-context/` plus the static-fact deferral edits.
- **DTU → vendored as real code in THIS repo** at `ref/dev-harness/dtu.py` (RESOLVED). No standalone DTU repo
  exists and `seedlab` is not a reachable GitHub org, so the canonical home for the project's DTU is this seed —
  the one whose skill needs the endpoints. The full `dtu.py` (with the reservation/calendar/availability endpoints +
  CLI seeding verbs) ships here as runnable Python, not a patch. The skill needs the endpoint ⇒ the project
  implements the endpoint.
- I default to extending the existing seed(s); a brand-new seed repo does **not** look warranted by current scope.

---

## 11. Open questions for the CEO (the only gates I need answered)

- **Q1.** (RESOLVED) `dtu.py` is in no git repo and `seedlab` is not a reachable GitHub org, so the DTU is vendored
  into this seed as real code at `ref/dev-harness/dtu.py` — the project that needs the endpoints implements them.
- **Q2.** `dtu.py` is shared across all three lanes' DTUs. Confirm additive-only edits to the shared file are
  acceptable (my analysis: fully backward-compatible), or do you want a forked `dtu-hostex.py` for this lane only?
- **Q3.** OK with the id/slug fidelity recommendation in §6 (records carry both; endpoints accept either; tools use
  integer id)?
- **Q4.** Is `/v3/availabilities.remarks` + host blocks the intended source for "maintenance flags / blocked dates",
  or is there a separate maintenance system I should read instead?

---

## 12. Build sequence (post-approval)

1. DTU: add data files + 3 routes + CLI verbs + reset/webhook extensions; restart `:8082`; run Tier-2 shape probes.
2. Skill: `_client.py`, `_classify.py` (+ Tier-1 unit tests), `hxctx` dispatcher, `SKILL.md`, `reference/*`.
3. Wire `HOSTEX_BASE_URL → host.docker.internal:8082`; run `validate.sh` green.
4. Courier integration (§8) + static-fact deferral edits.
5. (Optional) Tier-3 judge harness.
6. PR(s) per §10; ping CEO to test.
