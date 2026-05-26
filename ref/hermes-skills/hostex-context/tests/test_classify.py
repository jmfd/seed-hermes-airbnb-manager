#!/usr/bin/env python3
"""Tier-1 structural tests for the pure classification core. No network.

Runnable with `python3 tests/test_classify.py` (self-contained) or under pytest.
Asserts mechanical state only — exactly what the architectural rule permits.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import _classify as C  # noqa: E402


def _res(status="accepted", ci="2026-06-10", co="2026-06-13", **extra):
    r = {"status": status, "check_in_date": ci, "check_out_date": co}
    r.update(extra)
    return r


def test_guest_state_full_matrix():
    # accepted reservation 06-10 -> 06-13 across every 'today' position
    cases = {
        "2026-06-09": C.FUTURE_GUEST,
        "2026-06-10": C.ARRIVING_TODAY,
        "2026-06-11": C.CHECKED_IN_MIDSTAY,
        "2026-06-12": C.CHECKED_IN_MIDSTAY,
        "2026-06-13": C.CHECKING_OUT_TODAY,
        "2026-06-14": C.PAST_GUEST,
    }
    for today, expected in cases.items():
        got = C.classify_guest_state(_res(), today)
        assert got == expected, f"{today}: expected {expected}, got {got}"


def test_guest_state_statuses():
    assert C.classify_guest_state(None, "2026-06-10") == C.CURIOUS_BROWSER
    for s in ("wait_accept", "wait_pay"):
        assert C.classify_guest_state(_res(status=s), "2026-06-01") == C.INQUIRY_PENDING
    for s in ("cancelled", "denied", "timeout"):
        assert C.classify_guest_state(_res(status=s), "2026-06-11") == C.CANCELLED


def test_guest_state_missing_dates():
    assert C.classify_guest_state(_res(ci=None, co=None), "2026-06-10") == C.CURIOUS_BROWSER


def test_pick_empty_and_single():
    assert C.pick_relevant_reservation([], "2026-06-10") is None
    one = _res()
    assert C.pick_relevant_reservation([one], "2026-06-11") is one


def test_pick_prefers_current_over_upcoming_and_past():
    past = _res(ci="2026-05-01", co="2026-05-05", booked_at="2026-04-01")
    current = _res(ci="2026-06-10", co="2026-06-13", booked_at="2026-05-01")
    upcoming = _res(ci="2026-07-01", co="2026-07-03", booked_at="2026-05-02")
    picked = C.pick_relevant_reservation([past, upcoming, current], "2026-06-11")
    assert picked is current


def test_pick_checkout_today_counts_as_current():
    leaving = _res(ci="2026-06-08", co="2026-06-11")
    picked = C.pick_relevant_reservation([leaving], "2026-06-11")
    assert picked is leaving
    assert C.classify_guest_state(picked, "2026-06-11") == C.CHECKING_OUT_TODAY


def test_pick_nearest_upcoming_when_no_current():
    near = _res(ci="2026-06-20", co="2026-06-22")
    far = _res(ci="2026-08-01", co="2026-08-03")
    assert C.pick_relevant_reservation([far, near], "2026-06-11") is near


def test_pick_most_recent_past_when_no_current_or_upcoming():
    older = _res(ci="2026-04-01", co="2026-04-03")
    newer = _res(ci="2026-05-01", co="2026-05-03")
    assert C.pick_relevant_reservation([older, newer], "2026-06-11") is newer


def test_pick_all_dead_returns_most_recent():
    a = _res(status="cancelled", ci="2026-05-01", co="2026-05-03", booked_at="2026-04-01")
    b = _res(status="denied", ci="2026-06-01", co="2026-06-03", booked_at="2026-05-15")
    picked = C.pick_relevant_reservation([a, b], "2026-06-11")
    assert picked is b
    assert C.classify_guest_state(picked, "2026-06-11") == C.CANCELLED


def test_pick_live_beats_dead_for_current():
    dead = _res(status="cancelled", ci="2026-06-10", co="2026-06-13")
    live = _res(status="accepted", ci="2026-06-10", co="2026-06-13")
    assert C.pick_relevant_reservation([dead, live], "2026-06-11") is live


def test_stay_status_in_house_overrides_future_dates():
    # early check-in: dates say future, but Hostex says they're physically in_house
    r = _res(ci="2026-06-20", co="2026-06-23", stay_status="in_house")
    assert C.classify_guest_state(r, "2026-06-10") == C.CHECKED_IN_MIDSTAY


def test_stay_status_in_house_keeps_same_day_states():
    r = _res(ci="2026-06-10", co="2026-06-13", stay_status="in_house")
    assert C.classify_guest_state(r, "2026-06-10") == C.ARRIVING_TODAY
    assert C.classify_guest_state(r, "2026-06-13") == C.CHECKING_OUT_TODAY
    assert C.classify_guest_state(r, "2026-06-11") == C.CHECKED_IN_MIDSTAY


def test_stay_status_completed_overrides_to_past():
    r = _res(ci="2026-06-10", co="2026-06-13", stay_status="stay_completed")
    # even mid-window dates yield past_guest once Hostex says the stay completed
    assert C.classify_guest_state(r, "2026-06-11") == C.PAST_GUEST


def test_stay_status_checkin_pending_keeps_calendar_view():
    r = _res(ci="2026-06-10", co="2026-06-13", stay_status="checkin_pending")
    assert C.classify_guest_state(r, "2026-06-09") == C.FUTURE_GUEST
    assert C.classify_guest_state(r, "2026-06-10") == C.ARRIVING_TODAY


def test_stay_status_absent_is_pure_date_math():
    r = _res(ci="2026-06-10", co="2026-06-13")  # no stay_status (DTU / pre-checkin)
    assert C.classify_guest_state(r, "2026-06-11") == C.CHECKED_IN_MIDSTAY


def test_occupancy_prev_free_enables_early_checkin():
    # early check-in on 06-10 depends on the night of 06-09
    o = C.occupancy_adjacency({"2026-06-09": True, "2026-06-10": True}, "2026-06-10")
    assert o["prev_night"] == "free"
    assert o["early_checkin_feasible"] is True
    assert o["late_checkout_feasible"] is True
    assert o["prev_night_date"] == "2026-06-09"


def test_occupancy_prev_booked_blocks_early_checkin():
    o = C.occupancy_adjacency({"2026-06-09": False, "2026-06-10": True}, "2026-06-10")
    assert o["prev_night"] == "booked"
    assert o["early_checkin_feasible"] is False


def test_occupancy_checkin_night_booked_blocks_late_checkout():
    o = C.occupancy_adjacency({"2026-06-09": True, "2026-06-10": False}, "2026-06-10")
    assert o["early_checkin_feasible"] is True
    assert o["late_checkout_feasible"] is False


def test_occupancy_missing_dates_default_booked():
    o = C.occupancy_adjacency({}, "2026-06-10")
    assert o["early_checkin_feasible"] is False
    assert o["late_checkout_feasible"] is False


def _run():
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    passed = 0
    for fn in fns:
        try:
            fn()
        except AssertionError as e:
            print(f"FAIL {fn.__name__}: {e}")
            return 1
        passed += 1
        print(f"ok   {fn.__name__}")
    print(f"\n{passed}/{len(fns)} passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(_run())
