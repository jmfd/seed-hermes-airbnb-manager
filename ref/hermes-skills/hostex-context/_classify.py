"""Pure classification logic for hostex-context.

No I/O, no network — every function here is a deterministic function of its
arguments. This is the mechanical-state core the CEO's architectural rule lets
us assert structurally (see tests/test_classify.py). How the boss *phrases* a
reply from these results is behavioral and lives in SKILL.md, never here.
"""

from __future__ import annotations

from datetime import date, timedelta

# Guest-state vocabulary. Stable strings — the SKILL.md and tests depend on them.
CURIOUS_BROWSER = "curious_browser"
INQUIRY_PENDING = "inquiry_pending"
FUTURE_GUEST = "future_guest"
ARRIVING_TODAY = "arriving_today"
CHECKED_IN_MIDSTAY = "checked_in_midstay"
CHECKING_OUT_TODAY = "checking_out_today"
PAST_GUEST = "past_guest"
CANCELLED = "cancelled"

_PENDING_STATUSES = {"wait_accept", "wait_pay"}
_DEAD_STATUSES = {"cancelled", "denied", "timeout"}


def _date_state(ci: str | None, co: str | None, today: str) -> str:
    """Calendar-derived state from the stay's dates."""
    if not ci or not co:
        return CURIOUS_BROWSER
    if today < ci:
        return FUTURE_GUEST
    if today == ci:
        return ARRIVING_TODAY
    if ci < today < co:
        return CHECKED_IN_MIDSTAY
    if today == co:
        return CHECKING_OUT_TODAY
    return PAST_GUEST  # today > co


def _reconcile_stay_status(date_state: str, stay_status: str | None) -> str:
    """Real Hostex carries `stay_status` (the physical truth: did the guest
    actually check in?). When present it refines the calendar view; when absent
    (DTU / pure tests) the calendar view stands unchanged.

    - `stay_completed`  → past_guest (they're done, whatever the dates say).
    - `in_house`        → physically present: keep a same-day state if the dates
      agree, else checked_in_midstay (covers early check-in / late checkout).
    - `checkin_pending` → not yet checked in: keep the calendar view.
    """
    if not stay_status:
        return date_state
    if stay_status == "stay_completed":
        return PAST_GUEST
    if stay_status == "in_house":
        if date_state in (ARRIVING_TODAY, CHECKED_IN_MIDSTAY, CHECKING_OUT_TODAY):
            return date_state
        return CHECKED_IN_MIDSTAY
    return date_state  # checkin_pending or unknown → trust the calendar


def classify_guest_state(reservation: dict | None, today: str) -> str:
    """Classify a guest from their most-relevant reservation, as of `today`.

    `reservation` is a single Hostex reservation dict, or None when the guest
    has a conversation but no reservation at all. `today` is 'YYYY-MM-DD'.
    Uses real Hostex `stay_status` to override the calendar view when present.
    """
    if not reservation:
        return CURIOUS_BROWSER
    status = reservation.get("status")
    if status in _PENDING_STATUSES:
        return INQUIRY_PENDING
    if status in _DEAD_STATUSES:
        return CANCELLED
    if status == "accepted":
        date_state = _date_state(reservation.get("check_in_date"),
                                 reservation.get("check_out_date"), today)
        return _reconcile_stay_status(date_state, reservation.get("stay_status"))
    return CURIOUS_BROWSER


def _covers(reservation: dict, day: str) -> bool:
    """True if the reservation's stay [check_in, check_out) contains `day`
    (the checkout day itself is NOT covered — guest departs that morning)."""
    ci = reservation.get("check_in_date", "")
    co = reservation.get("check_out_date", "")
    return bool(ci) and bool(co) and ci <= day < co


def pick_relevant_reservation(reservations: list[dict], today: str) -> dict | None:
    """Choose the reservation that best describes the guest 'now'.

    Priority: a live (non-dead) stay covering today or whose checkout IS today,
    then the nearest upcoming live reservation, then the most recent past live
    reservation, and only if there are none of those, the most recent dead one.
    """
    if not reservations:
        return None
    live = [r for r in reservations if r.get("status") not in _DEAD_STATUSES]

    current = [
        r for r in live
        if _covers(r, today) or r.get("check_out_date") == today
    ]
    if current:
        return min(current, key=lambda r: r.get("check_in_date", ""))

    upcoming = [r for r in live if r.get("check_in_date", "") > today]
    if upcoming:
        return min(upcoming, key=lambda r: r.get("check_in_date", ""))

    past = [r for r in live if r.get("check_out_date", "") < today]
    if past:
        return max(past, key=lambda r: r.get("check_out_date", ""))

    if live:
        return max(live, key=lambda r: r.get("booked_at", "") or r.get("check_in_date", ""))

    # All dead — surface the most recent so the boss can say "that booking was cancelled".
    return max(reservations, key=lambda r: r.get("booked_at", "") or r.get("check_in_date", ""))


def occupancy_adjacency(available_by_date: dict[str, bool], check_date: str) -> dict:
    """Given a date->available map, answer the early-checkin / late-checkout question.

    early check-in on D depends on the NIGHT BEFORE D (D-1): if free, the unit was
    empty overnight and an early arrival is physically feasible.
    late check-out on D depends on the NIGHT OF D: if free, no one arrives that day.
    """
    d = date.fromisoformat(check_date)
    prev_night = (d - timedelta(days=1)).isoformat()
    same_night = check_date

    prev_free = bool(available_by_date.get(prev_night))
    same_free = bool(available_by_date.get(same_night))

    return {
        "date": check_date,
        "prev_night_date": prev_night,
        "prev_night": "free" if prev_free else "booked",
        "checkin_night_date": same_night,
        "checkin_night": "free" if same_free else "booked",
        "early_checkin_feasible": prev_free,
        "late_checkout_feasible": same_free,
        "note": (
            "Night before is free — early check-in is physically possible, but "
            "same-day bookings can still occur, so confirm the morning of."
            if prev_free else
            "Night before is occupied — early check-in is not available."
        ),
    }
