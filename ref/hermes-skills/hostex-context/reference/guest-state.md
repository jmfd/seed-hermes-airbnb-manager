# Guest-state model (reference)

A deterministic function of `(reservation.status, check_in_date, check_out_date,
today)` plus "does the guest have any reservation at all". Implemented in
`_classify.py::classify_guest_state` and exercised by the full matrix in
`tests/test_classify.py`.

| State | Condition |
|-------|-----------|
| `curious_browser` | conversation exists, **no** reservation linked (or dates missing) |
| `inquiry_pending` | most-relevant reservation `status ∈ {wait_accept, wait_pay}` |
| `future_guest` | `status=accepted` and `today < check_in_date` |
| `arriving_today` | `status=accepted` and `today == check_in_date` |
| `checked_in_midstay` | `status=accepted` and `check_in_date < today < check_out_date` |
| `checking_out_today` | `status=accepted` and `today == check_out_date` |
| `past_guest` | `status=accepted` and `today > check_out_date` |
| `cancelled` | most-relevant reservation `status ∈ {cancelled, denied, timeout}` |

## Choosing the "most-relevant" reservation

When several reservations link to one guest/conversation
(`_classify.py::pick_relevant_reservation`):

1. A **live** (non-cancelled/denied/timeout) reservation whose stay covers today,
   or whose check-out **is** today — earliest such wins.
2. Else the **nearest upcoming** live reservation.
3. Else the **most recent past** live reservation.
4. Else (only dead reservations exist) the most recently booked one — so the boss
   can say "that booking was cancelled".

## Why this is mechanical, not behavioral

State assignment and reservation selection are pure functions with a fixed truth
table — tested by structural assertions. The *behavioral* part (how the boss
phrases a reply for each state) lives in `SKILL.md` and is validated by eyeball or
LLM-as-judge, never by regex on the model's output.
