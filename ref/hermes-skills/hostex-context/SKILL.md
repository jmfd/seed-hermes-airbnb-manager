---
name: hostex-context
description: Live Hostex state for short-term-rental coordination. Gives the boss read-only tools to pull calendar, reservations, guest state, and occupancy adjacency at classification + drafting time, so guest replies reflect who is actually booked, checked in, arriving, or departing — instead of static facts. Companion to str-manager-approval. Read-only; never sends guest-facing messages itself.
version: 1.0.0
---

# hostex-context

The messaging skill (`str-manager-approval`) knows how to *talk* to guests. This
skill lets it know *what is true right now*: which nights are booked, who is in
the house, whether tonight's guest leaves tomorrow, and whether an early check-in
is even physically possible. It documents the Hostex API surface (see
`reference/hostex-api.md`) and ships five read-only tools.

## Single source of truth (architectural rule)

Hostex is the **only** source of reservation / calendar / availability truth.
These tools pull **live on every call**. There is no local store, no cache file,
no mirror, no periodic sync. If you need the same fact twice in one turn, the
client memoizes within the process — but nothing survives the turn. Never write
reservation/calendar state to disk and read it back later; always ask Hostex.

## When to reach for live state

Call a tool whenever the guest's question, or your draft, depends on time- or
occupancy-sensitive facts. Signals:

- **Timing of access** — "Can I check in early?", "Late checkout?", "What time
  can I drop bags?" → `occupancy`.
- **Who/when** — "Is the place free next weekend?", "We arrive Friday, right?" →
  `calendar`, `reservations`, `schedule`.
- **Stay-aware tone** — before classifying or drafting, knowing whether you are
  talking to a *curious browser*, a *confirmed future guest*, someone *mid-stay*,
  or a *past guest* changes both who to consult and how to answer →`guest-state`.
- **Operations** — "who's arriving today / tomorrow / this week" → `schedule`.

If a question is purely static (wifi password, address, house rules), answer from
the brain facts as before — do not call these tools.

## The tools

Run them as `python3 <skill-dir>/hxctx <subcommand> [flags]`. When installed in
the boss container the path is `/opt/data/home/hostex-context/hxctx`. Each prints
one JSON object to stdout. Property may be a slug (`mtn-home`), an integer Hostex
id (`12051776`), or a title.

```
# Guest state — anchor tone + consult decision. By conversation or reservation.
hxctx guest-state --conversation <conversation_id>
hxctx guest-state --reservation <reservation_code>
#   → {"state": "...", "reservation": {...}, "nights_remaining"?: N, "asof": "..."}
#   state ∈ curious_browser | inquiry_pending | future_guest | arriving_today
#         | checked_in_midstay | checking_out_today | past_guest | cancelled

# Occupancy adjacency — the early-checkin / late-checkout answer.
hxctx occupancy --property mtn-home --date 2026-06-10
#   → early_checkin_feasible (is the night BEFORE free?),
#     late_checkout_feasible (is the checkin-night free?), + a guidance note.

# Calendar — per-night booked / blocked / free + price, over a range.
hxctx calendar --property mtn-home --start 2026-06-01 --end 2026-06-14

# Reservations — normalized, filterable by date / status.
hxctx reservations --property mtn-home --on 2026-06-10
hxctx reservations --property mtn-home --from 2026-06-01 --to 2026-06-30 --status accepted

# Schedule — who is arriving / in-house / departing in a window.
hxctx schedule --property mtn-home --day today      # or: tomorrow | week
```

## Folding results into a draft

- **Ground the claim, don't dump JSON.** Turn `early_checkin_feasible: false`
  into "the cabin is booked the night before, so we can't offer an early
  check-in this time." Never paste raw tool output to the guest.
- **Respect the caveat the data carries.** For early check-in, even when the
  night before is free, same-day bookings remain possible — the `note` field
  says so; reflect that ("looks possible — I'll confirm the morning of").
- **Match state to tone.** A `past_guest` asking about amenities is likely
  planning a return — be warm, not logistical. An `arriving_today` guest gets
  door-code/access logistics. A `curious_browser` gets a sell, not a lock code.
- **Maintenance = blocked.** A `blocked` calendar night or an `availabilities`
  remark (e.g. "deep clean") means the unit is unavailable for operational
  reasons, not a guest booking. Don't offer those nights.

## Integration with `str-manager-approval`

This skill does not change the messaging contract. It feeds the boss's existing
steps:

- **Trigger 1 (classification).** After fetching the conversation, call
  `hxctx guest-state --conversation <id>` to anchor the consult decision and the
  draft's tone. A question the live data already answers (e.g. early check-in
  with the night before booked) may need **no** team consult — draft directly.
- **Trigger 1 §8a / Trigger 3 (drafting).** Before composing, call `occupancy`,
  `calendar`, or `reservations` for any timing/occupancy claim, and cite the live
  state in the draft. Live state overrides static brain facts when they conflict
  (e.g. `brain/facts/<prop>/early_check_in.md` describes the *policy*; this skill
  tells you the *current answer*).
- All guest delivery still flows through the owner-approval + Hostex POST path in
  `str-manager-approval`. This skill is **read-only** and never messages a guest.

## Config

- `HOSTEX_BASE_URL` — live Hostex (`https://api.hostex.io`) or the DTU
  (`http://host.docker.internal:8082`) for tests. Flag override: `--base-url`.
- `HOSTEX_ACCESS_TOKEN` — Hostex token, sent as `Hostex-Access-Token`. Flag: `--token`.
- `HXCTX_TODAY` — override "today" (tests/determinism). Per-call: `--asof`.

Every Hostex call sends `User-Agent: curl/8.7.1`, matching the boss contract.

## Hard rules

- Read-only. This skill never POSTs guest-facing content and never mutates Hostex.
- Live every time. No persistent cache / mirror / store of Hostex state.
- Never fabricate occupancy. If a tool errors, say you couldn't confirm and fall
  back to the policy caveat — do not guess a date is free.
- English in / English out, matching the boss skill.
