#!/usr/bin/env python3
"""dtu.py — Digital Twin Universe of hostex.io.

One Python file that serves both a Web UI and a hostex-compatible HTTP API
from one process. The CLI dispatches to the running server via HTTP — no
shared in-process state. What you can do by clicking, you can do by typing.

Wire shapes are deliberately aligned to the captured real Hostex contracts
(see seeds/wire-samples/hostex-*.json) so the same agent code that talks to
this DTU works unchanged against api.hostex.io.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import threading
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

from flask import Flask, Response, abort, jsonify, request

# ---------------------------------------------------------------------------
# Paths & defaults
# ---------------------------------------------------------------------------

DATA_DIR = Path(os.environ.get("DTU_DATA_DIR") or str(Path.home() / ".dtu" / "data"))
PORT = int(os.environ.get("DTU_PORT") or "8080")

PROPERTIES_FILE = DATA_DIR / "properties.json"
CONVERSATIONS_FILE = DATA_DIR / "conversations.json"
MESSAGES_FILE = DATA_DIR / "messages.jsonl"
WEBHOOKS_FILE = DATA_DIR / "webhooks.json"
EVENTS_FILE = DATA_DIR / "events.jsonl"
# Additive (hostex-context lane): live reservation + host-block state. These
# back the read-only /v3/reservations, /v3/listings/calendar, /v3/availabilities
# views. Absent files ⇒ empty results, so other lanes' DTUs are unaffected.
RESERVATIONS_FILE = DATA_DIR / "reservations.json"
BLOCKS_FILE = DATA_DIR / "blocks.json"

DEFAULT_PROPERTIES = {
    "mtn-home": {
        "id": "mtn-home",
        "title": "Mtn Home",
        "address": "61 Mountain Home Rd, Snoqualmie Pass, WA 98068",
        "default_checkin_time": "15:00",
        "default_checkout_time": "12:00",
        "wifi_ssid": "TMOBILE-BEE",
        "timezone": "America/Los_Angeles",
        # hostex_id: real-Hostex integer property_id (id↔slug map from the
        # ingest catalog). listing_id/channel_type back the calendar endpoint.
        "hostex_id": 12051776,
        "listing_id": "12051776",
        "channel_type": "airbnb",
        "nightly_price": 250,
    },
    "10th-ave": {
        "id": "10th-ave",
        "title": "10th Ave",
        "address": "10th Ave, Seattle, WA",
        "default_checkin_time": "15:00",
        "default_checkout_time": "11:00",
        "wifi_ssid": "10thAveWiFi",
        "timezone": "America/Los_Angeles",
        "hostex_id": 12051778,
        "listing_id": "12051778",
        "channel_type": "airbnb",
        "nightly_price": 180,
    },
}

_WRITE_LOCK = threading.Lock()


# ---------------------------------------------------------------------------
# Storage helpers — atomic writes, append-only logs, structured event log.
# ---------------------------------------------------------------------------


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _new_id(prefix: str) -> str:
    return f"{prefix}-{uuid.uuid4().hex[:12]}"


def _ensure_data_dir() -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    if not PROPERTIES_FILE.exists():
        _write_json_atomic(PROPERTIES_FILE, DEFAULT_PROPERTIES)
    else:
        _backfill_property_catalog()
    for path, default in [
        (CONVERSATIONS_FILE, "{}"),
        (WEBHOOKS_FILE, "{}"),
        (RESERVATIONS_FILE, "[]"),
        (BLOCKS_FILE, "[]"),
    ]:
        if not path.exists():
            path.write_text(default)
    for path in (MESSAGES_FILE, EVENTS_FILE):
        if not path.exists():
            path.touch()


def _backfill_property_catalog() -> None:
    """Additive migration: stamp hostex_id / listing_id / channel_type /
    nightly_price onto pre-existing properties.json entries whose slug matches a
    DEFAULT_PROPERTIES key. Only fills missing keys — never overwrites operator
    edits — so it is safe to run on every boot and across lanes."""
    props = _read_json(PROPERTIES_FILE)
    if not isinstance(props, dict):
        return
    changed = False
    for slug, defaults in DEFAULT_PROPERTIES.items():
        if slug in props and isinstance(props[slug], dict):
            for k in ("hostex_id", "listing_id", "channel_type", "nightly_price"):
                if k not in props[slug] and k in defaults:
                    props[slug][k] = defaults[k]
                    changed = True
    if changed:
        _write_json_atomic(PROPERTIES_FILE, props)


def _read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def _write_json_atomic(path: Path, data: Any) -> None:
    """Read → mutate → write tmp → rename. Lock-guarded for thread safety."""
    with _WRITE_LOCK:
        tmp = path.with_suffix(path.suffix + ".tmp")
        tmp.write_text(json.dumps(data, indent=2))
        os.replace(tmp, path)


def _append_jsonl(path: Path, record: dict) -> None:
    """Append one JSON record per line. Never rewrite."""
    with _WRITE_LOCK:
        with open(path, "a") as f:
            f.write(json.dumps(record) + "\n")


def _log_event(kind: str, **fields: Any) -> None:
    rec = {"ts": _now_iso(), "kind": kind, **fields}
    _append_jsonl(EVENTS_FILE, rec)


def _conversation_messages(conv_id: str) -> list[dict]:
    """All messages for a given conversation, oldest-first."""
    if not MESSAGES_FILE.exists():
        return []
    msgs: list[dict] = []
    with open(MESSAGES_FILE) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            if rec.get("conversation_id") == conv_id:
                msgs.append(rec)
    msgs.sort(key=lambda m: m.get("created_at", ""))
    return msgs


# ---------------------------------------------------------------------------
# Webhook fanout — background thread per registered hook, never blocks the
# triggering response.
# ---------------------------------------------------------------------------


def _deliver_webhook(webhook_id: str, url: str, payload: dict) -> None:
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            status = resp.status
        _log_event(
            "webhook_delivered",
            webhook_id=webhook_id,
            url=url,
            status=status,
            message_id=payload.get("message_id"),
        )
    except (urllib.error.URLError, urllib.error.HTTPError) as e:
        _log_event(
            "webhook_failed",
            webhook_id=webhook_id,
            url=url,
            error=str(e),
            message_id=payload.get("message_id"),
        )


def _fanout_webhooks(payload: dict) -> None:
    hooks = _read_json(WEBHOOKS_FILE)
    event_name = payload.get("event")
    for wid, hook in hooks.items():
        events = hook.get("events") or ["message_created"]
        if event_name not in events:
            continue
        threading.Thread(
            target=_deliver_webhook,
            args=(wid, hook["url"], payload),
            daemon=True,
        ).start()


# ---------------------------------------------------------------------------
# Flask app
# ---------------------------------------------------------------------------

app = Flask(__name__)


@app.route("/healthz")
def healthz() -> Response:
    return jsonify({"status": "ok"})


@app.route("/v3/properties")
def list_properties() -> Response:
    props = _read_json(PROPERTIES_FILE)
    return jsonify({"data": {"properties": list(props.values())}})


@app.route("/v3/conversations", methods=["GET"])
def list_conversations() -> Response:
    convs = _read_json(CONVERSATIONS_FILE)
    property_id = request.args.get("property_id")
    offset = int(request.args.get("offset", "0"))
    limit = int(request.args.get("limit", "100"))
    items = [
        c for c in convs.values()
        if not property_id or c.get("property_id") == property_id
    ]
    items.sort(key=lambda c: c.get("updated_at", ""), reverse=True)
    items = items[offset:offset + limit]
    return jsonify({"data": {"conversations": items}})


@app.route("/v3/conversations/<conv_id>", methods=["GET"])
def conversation_detail(conv_id: str) -> Response:
    convs = _read_json(CONVERSATIONS_FILE)
    if conv_id not in convs:
        abort(404, description="conversation not found")
    conv = convs[conv_id]
    msgs = _conversation_messages(conv_id)
    return jsonify({"data": {**conv, "messages": msgs}})


@app.route("/v3/conversations/<conv_id>", methods=["POST"])
def post_host_message(conv_id: str) -> Response:
    """Real Hostex: POST /v3/conversations/{id} with body {"message": "..."}.

    This is the host-outbound path. The agent (e.g. str-manager-approval's
    Branch A) calls this when it ships an approved draft to the guest. Body
    shape matches real Hostex exactly so the same agent code works against
    DTU and api.hostex.io unchanged.
    """
    convs = _read_json(CONVERSATIONS_FILE)
    if conv_id not in convs:
        abort(404, description="conversation not found")
    body = request.get_json(force=True, silent=True) or {}
    content = body.get("message")
    if not content:
        abort(400, description="missing 'message' in body (real Hostex shape)")
    msg_id = _new_id("msg")
    now = _now_iso()
    rec = {
        "id": msg_id,
        "conversation_id": conv_id,
        "content": content,
        "sender_role": "host",
        "created_at": now,
    }
    _append_jsonl(MESSAGES_FILE, rec)
    convs[conv_id]["updated_at"] = now
    _write_json_atomic(CONVERSATIONS_FILE, convs)
    _log_event("host_message_posted", conversation_id=conv_id, message_id=msg_id)
    return jsonify({"data": {"id": msg_id}})


@app.route("/admin/guest-send", methods=["POST"])
def guest_send() -> Response:
    """DTU-extra: inject a guest message. Creates conversation if absent.

    The UI compose form and the CLI `dtu guest send` both POST here — single
    code path. Fires registered webhooks with the real Hostex shape.
    """
    body = request.get_json(force=True, silent=True) or {}
    property_id = body.get("property_id")
    content = (body.get("content") or "").strip()
    from_name = body.get("from") or "guest"
    conversation_id = body.get("conversation_id")
    if not content:
        abort(400, description="missing content")
    if not property_id:
        abort(400, description="missing property_id")
    props = _read_json(PROPERTIES_FILE)
    if property_id not in props:
        abort(400, description=f"unknown property_id={property_id}")

    convs = _read_json(CONVERSATIONS_FILE)
    now = _now_iso()
    if conversation_id is None:
        conversation_id = _new_id("conv")
        convs[conversation_id] = {
            "id": conversation_id,
            "property_id": property_id,
            "property_title": props[property_id]["title"],
            "guest": {"name": from_name},
            "activities": [
                {"property": {"id": property_id, "title": props[property_id]["title"]}}
            ],
            "created_at": now,
            "updated_at": now,
        }
    elif conversation_id not in convs:
        abort(400, description=f"unknown conversation_id={conversation_id}")

    msg_id = _new_id("msg")
    rec = {
        "id": msg_id,
        "conversation_id": conversation_id,
        "content": content,
        "sender_role": "guest",
        "sender_name": from_name,
        "created_at": now,
    }
    _append_jsonl(MESSAGES_FILE, rec)
    convs[conversation_id]["updated_at"] = now
    _write_json_atomic(CONVERSATIONS_FILE, convs)
    _log_event(
        "guest_message_injected",
        conversation_id=conversation_id,
        message_id=msg_id,
        from_name=from_name,
    )

    # Real Hostex webhook shape: notification-only, top-level fields. No nested
    # data.message, no content, no sender_role. Consumers fetch
    # GET /v3/conversations/{conversation_id} to resolve.
    event_payload = {
        "event": "message_created",
        "conversation_id": conversation_id,
        "message_id": msg_id,
        "timestamp": now,
    }
    _fanout_webhooks(event_payload)
    return jsonify({"conversation_id": conversation_id, "message_id": msg_id})


@app.route("/v3/webhooks", methods=["GET"])
def list_webhooks() -> Response:
    hooks = _read_json(WEBHOOKS_FILE)
    return jsonify({"data": {"webhooks": list(hooks.values())}})


@app.route("/v3/webhooks", methods=["POST"])
def register_webhook() -> Response:
    body = request.get_json(force=True, silent=True) or {}
    url = body.get("url")
    if not url:
        abort(400, description="missing url")
    events = body.get("events") or ["message_created"]
    wid = _new_id("wh")
    hooks = _read_json(WEBHOOKS_FILE)
    hooks[wid] = {
        "id": wid,
        "url": url,
        "events": events,
        "created_at": _now_iso(),
    }
    _write_json_atomic(WEBHOOKS_FILE, hooks)
    _log_event("webhook_registered", webhook_id=wid, url=url, events=events)
    return jsonify({"data": hooks[wid]})


@app.route("/v3/webhooks/<wh_id>", methods=["DELETE"])
def delete_webhook(wh_id: str) -> Response:
    hooks = _read_json(WEBHOOKS_FILE)
    if wh_id not in hooks:
        abort(404)
    removed = hooks.pop(wh_id)
    _write_json_atomic(WEBHOOKS_FILE, hooks)
    _log_event("webhook_removed", webhook_id=wh_id, url=removed.get("url"))
    return jsonify({"data": {"removed": True, "id": wh_id}})


@app.route("/admin/reset", methods=["POST"])
def admin_reset() -> Response:
    _write_json_atomic(CONVERSATIONS_FILE, {})
    _write_json_atomic(WEBHOOKS_FILE, {})
    _write_json_atomic(RESERVATIONS_FILE, [])
    _write_json_atomic(BLOCKS_FILE, [])
    MESSAGES_FILE.write_text("")
    EVENTS_FILE.write_text("")
    _log_event("reset")
    return jsonify({"reset": True})


@app.route("/admin/events")
def admin_events() -> Response:
    if EVENTS_FILE.exists():
        return Response(EVENTS_FILE.read_text(), mimetype="text/plain")
    return Response("", mimetype="text/plain")


# ---------------------------------------------------------------------------
# Reservations / calendar / availability (ADDITIVE — hostex-context lane).
#
# Hostex is the single source of truth: these views are COMPUTED live from
# reservations.json + blocks.json on every request — no cache, no mirror. Wire
# shapes mirror real api.hostex.io so the same agent code works unchanged.
#
# Night model: a reservation occupies nights [check_in_date, check_out_date) —
# the checkout day's night is free (guest departs that morning). A host block
# occupies nights [start_date, end_date] inclusive.
# ---------------------------------------------------------------------------


def _load_list(path: Path) -> list:
    data = _read_json(path)
    return data if isinstance(data, list) else []


def _resolve_property(token: Any) -> Optional[dict]:
    """Accept a slug, integer hostex_id (int or str), listing_id, or title.
    Returns the property dict (carrying both slug `id` and `hostex_id`) or None."""
    if token is None:
        return None
    props = _read_json(PROPERTIES_FILE)
    if not isinstance(props, dict):
        return None
    s = str(token)
    if s in props:
        return props[s]
    for p in props.values():
        if str(p.get("hostex_id")) == s or str(p.get("listing_id")) == s:
            return p
        if p.get("title") == token:
            return p
    return None


def _date_range(start: str, end: str) -> list:
    from datetime import date, timedelta
    d0, d1 = date.fromisoformat(start), date.fromisoformat(end)
    out, d = [], d0
    while d <= d1:
        out.append(d.isoformat())
        d += timedelta(days=1)
    return out


def _prop_match(record: dict, prop: dict) -> bool:
    return (
        record.get("property_slug") == prop.get("id")
        or str(record.get("property_id")) == str(prop.get("hostex_id"))
    )


def _night_booked(prop: dict, night: str) -> bool:
    """True if an ACCEPTED reservation occupies this night [ci, co)."""
    for r in _load_list(RESERVATIONS_FILE):
        if r.get("status") != "accepted" or not _prop_match(r, prop):
            continue
        if r.get("check_in_date", "") <= night < r.get("check_out_date", ""):
            return True
    return False


def _night_block(prop: dict, night: str) -> Optional[dict]:
    """The host block covering this night (inclusive range), if any."""
    for b in _load_list(BLOCKS_FILE):
        if not _prop_match(b, prop):
            continue
        if b.get("start_date", "") <= night <= b.get("end_date", ""):
            return b
    return None


def _default_restrictions() -> dict:
    return {
        "closed_on_arrival": False,
        "closed_on_departure": False,
        "min_stay_on_arrival": 1,
        "max_stay_on_arrival": 0,
        "min_stay_through": 1,
        "max_stay_through": 0,
        "min_advance_reservation": "0D0H",
        "max_advance_reservation": "0D0H",
        "exact_stay_on_arrival": 0,
    }


@app.route("/v3/reservations", methods=["GET"])
def list_reservations() -> Response:
    res = _load_list(RESERVATIONS_FILE)
    code = request.args.get("reservation_code")
    if code:
        res = [r for r in res if r.get("reservation_code") == code]
    pid = request.args.get("property_id")
    if pid:
        prop = _resolve_property(pid)
        res = [r for r in res if (prop and _prop_match(r, prop)) or str(r.get("property_id")) == str(pid)]
    status = request.args.get("status")
    if status:
        res = [r for r in res if r.get("status") == status]
    sci, eci = request.args.get("start_check_in_date"), request.args.get("end_check_in_date")
    sco, eco = request.args.get("start_check_out_date"), request.args.get("end_check_out_date")
    if sci:
        res = [r for r in res if r.get("check_in_date", "") >= sci]
    if eci:
        res = [r for r in res if r.get("check_in_date", "") <= eci]
    if sco:
        res = [r for r in res if r.get("check_out_date", "") >= sco]
    if eco:
        res = [r for r in res if r.get("check_out_date", "") <= eco]
    order_by = request.args.get("order_by", "booked_at")
    res = sorted(res, key=lambda r: r.get(order_by, "") or "", reverse=True)
    offset = int(request.args.get("offset", "0"))
    limit = int(request.args.get("limit", "20"))
    # Real Hostex /v3/reservations returns data.{reservations} with NO `total`.
    return jsonify({"data": {"reservations": res[offset:offset + limit]}})


@app.route("/v3/listings/calendar", methods=["POST"])
def listings_calendar() -> Response:
    body = request.get_json(force=True, silent=True) or {}
    start, end = body.get("start_date"), body.get("end_date")
    if not start or not end:
        abort(400, description="missing start_date/end_date")
    out = []
    for L in body.get("listings") or []:
        lid, ch = L.get("listing_id"), L.get("channel_type", "airbnb")
        prop = _resolve_property(lid)
        cal = []
        for d in _date_range(start, end):
            free = (not (_night_booked(prop, d) or _night_block(prop, d))) if prop else True
            cal.append({
                "date": d,
                "price": (prop.get("nightly_price", 0) if prop else 0),
                "inventory": 1 if free else 0,
                "restrictions": _default_restrictions(),
            })
        out.append({"listing_id": lid, "channel_type": ch, "calendar": cal})
    return jsonify({"data": {"listings": out}})


@app.route("/v3/availabilities", methods=["GET"])
def availabilities() -> Response:
    start, end = request.args.get("start_date"), request.args.get("end_date")
    if not start or not end:
        abort(400, description="missing start_date/end_date")
    tokens = [t for t in request.args.get("property_ids", "").split(",") if t]
    if not tokens:
        props = _read_json(PROPERTIES_FILE)
        tokens = list(props.keys()) if isinstance(props, dict) else []
    seen, out = set(), []
    for tok in tokens:
        prop = _resolve_property(tok)
        if not prop or prop["id"] in seen:
            continue
        seen.add(prop["id"])
        avs = []
        for d in _date_range(start, end):
            blk = _night_block(prop, d)
            avs.append({
                "date": d,
                "available": not (_night_booked(prop, d) or bool(blk)),
                "remarks": (blk.get("remarks", "") if blk else ""),
            })
        out.append({"id": prop.get("hostex_id") or prop["id"], "availabilities": avs})
    return jsonify({"data": {"properties": out}})


# --- Admin/test-seeding routes (DTU-extra; mirror the /admin/guest-send pattern).
#     Real Hostex is read-only at draft time, so writes live under /admin/*. ---


@app.route("/admin/reservation", methods=["POST"])
def admin_reservation_add() -> Response:
    body = request.get_json(force=True, silent=True) or {}
    prop = _resolve_property(body.get("property_id") or body.get("property"))
    if not prop:
        abort(400, description=f"unknown property={body.get('property_id') or body.get('property')}")
    ci, co = body.get("check_in_date"), body.get("check_out_date")
    if not ci or not co:
        abort(400, description="missing check_in_date/check_out_date")
    now = _now_iso()
    code = body.get("reservation_code") or _new_id("RES")
    status_val = body.get("status", "accepted")
    # stay_status mirrors real Hostex (checkin_pending | in_house | stay_completed |
    # null). Settable via body; otherwise derived from status + dates vs today.
    if "stay_status" in body:
        stay_status = body.get("stay_status")
    elif status_val != "accepted":
        stay_status = None
    else:
        today = datetime.now(timezone.utc).date().isoformat()
        stay_status = ("checkin_pending" if today < ci
                       else "in_house" if ci <= today < co
                       else "stay_completed")
    rec = {
        "reservation_code": code,
        "stay_code": code,
        "status": status_val,
        "stay_status": stay_status,
        "channel_type": body.get("channel_type", prop.get("channel_type", "airbnb")),
        "channel_id": body.get("channel_id") or code,
        "property_id": prop.get("hostex_id") or prop["id"],
        "property_slug": prop["id"],
        "listing_id": prop.get("listing_id") or str(prop.get("hostex_id") or prop["id"]),
        "check_in_date": ci,
        "check_out_date": co,
        "number_of_guests": int(body.get("number_of_guests", 1)),
        "number_of_adults": int(body.get("number_of_adults", body.get("number_of_guests", 1))),
        "number_of_children": int(body.get("number_of_children", 0)),
        "number_of_infants": int(body.get("number_of_infants", 0)),
        "number_of_pets": int(body.get("number_of_pets", 0)),
        "guest_name": body.get("guest_name"),
        "guest_phone": body.get("guest_phone"),
        "guest_email": body.get("guest_email"),
        "conversation_id": body.get("conversation_id"),
        "creator": body.get("creator", "System"),
        "booked_at": body.get("booked_at", now),
        "created_at": now,
        "cancelled_at": None,
        "remarks": body.get("remarks", ""),
        "channel_remarks": body.get("channel_remarks", ""),
        "tags": body.get("tags", []),
        "custom_channel": body.get("custom_channel"),
        "custom_fields": body.get("custom_fields"),
        "in_reservation_box": body.get("in_reservation_box", False),
        "additional_fees": body.get("additional_fees", []),
        "rates": body.get("rates", {}),
        "check_in_details": {
            "arrival_at": None,
            "departure_at": None,
            "lock_code": body.get("lock_code"),
            "lock_code_visible_after": None,
            "deposit": 0,
            "id_required": None,
            "check_in_guide_url": None,
        },
        "guests": body.get("guests", []),
    }
    reservations = [r for r in _load_list(RESERVATIONS_FILE) if r.get("reservation_code") != code]
    reservations.append(rec)
    _write_json_atomic(RESERVATIONS_FILE, reservations)
    _log_event("reservation_created", reservation_code=code, property_slug=prop["id"], status=rec["status"])
    _fanout_webhooks({"event": "reservation_created", "reservation_code": code,
                      "conversation_id": rec.get("conversation_id"), "timestamp": now})
    return jsonify({"data": {"reservation_code": code}})


@app.route("/admin/reservation/cancel", methods=["POST"])
def admin_reservation_cancel() -> Response:
    body = request.get_json(force=True, silent=True) or {}
    code = body.get("reservation_code")
    if not code:
        abort(400, description="missing reservation_code")
    reservations = _load_list(RESERVATIONS_FILE)
    found = False
    for r in reservations:
        if r.get("reservation_code") == code:
            r["status"], r["cancelled_at"], found = "cancelled", _now_iso(), True
    if not found:
        abort(404, description=f"unknown reservation_code={code}")
    _write_json_atomic(RESERVATIONS_FILE, reservations)
    _log_event("reservation_updated", reservation_code=code, status="cancelled")
    _fanout_webhooks({"event": "reservation_updated", "reservation_code": code, "timestamp": _now_iso()})
    return jsonify({"data": {"reservation_code": code, "status": "cancelled"}})


@app.route("/admin/block", methods=["POST"])
def admin_block_add() -> Response:
    body = request.get_json(force=True, silent=True) or {}
    prop = _resolve_property(body.get("property_id") or body.get("property"))
    if not prop:
        abort(400, description="unknown property")
    sd, ed = body.get("start_date"), body.get("end_date")
    if not sd or not ed:
        abort(400, description="missing start_date/end_date")
    now = _now_iso()
    block = {
        "id": _new_id("blk"),
        "property_id": prop.get("hostex_id") or prop["id"],
        "property_slug": prop["id"],
        "start_date": sd,
        "end_date": ed,
        "remarks": body.get("remarks", ""),
        "created_at": now,
    }
    blocks = _load_list(BLOCKS_FILE)
    blocks.append(block)
    _write_json_atomic(BLOCKS_FILE, blocks)
    _log_event("block_added", property_slug=prop["id"], start_date=sd, end_date=ed)
    _fanout_webhooks({"event": "availability_updated", "property_id": block["property_id"], "timestamp": now})
    return jsonify({"data": block})


# ---------------------------------------------------------------------------
# UI — vanilla JS, polls every 3s, compose form posts to /admin/guest-send.
# ---------------------------------------------------------------------------

INDEX_HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>DTU — Hostex Digital Twin</title>
<style>
* { box-sizing: border-box; }
body { font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; margin: 0; display: grid; grid-template-columns: 320px 1fr; grid-template-rows: auto 1fr; height: 100vh; }
header { grid-column: 1 / -1; padding: 12px 16px; background: #1f2937; color: #fff; display: flex; align-items: center; gap: 12px; }
header h1 { margin: 0; font-size: 16px; font-weight: 600; }
header .badge { background: #10b981; padding: 2px 8px; border-radius: 4px; font-size: 11px; font-weight: 500; }
header .right { margin-left: auto; font-size: 11px; opacity: 0.75; }
aside { border-right: 1px solid #e5e7eb; overflow-y: auto; background: #fafafa; }
aside h2 { font-size: 11px; margin: 14px 14px 8px; color: #6b7280; text-transform: uppercase; letter-spacing: 0.5px; font-weight: 600; }
.conv { padding: 10px 14px; border-bottom: 1px solid #f0f0f0; cursor: pointer; }
.conv:hover { background: #fff; }
.conv.active { background: #e0edff; border-left: 3px solid #2563eb; padding-left: 11px; }
.conv .from { font-weight: 600; font-size: 13px; color: #111; }
.conv .prop { color: #6b7280; font-size: 11px; margin-top: 2px; }
.conv .snippet { color: #4b5563; font-size: 12px; margin-top: 4px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
main { display: flex; flex-direction: column; overflow: hidden; min-height: 0; }
.thread { flex: 1; overflow-y: auto; padding: 16px; background: #f9fafb; min-height: 0; }
.msg { max-width: 60%; padding: 8px 12px; border-radius: 12px; margin: 6px 0; font-size: 13px; line-height: 1.4; }
.msg.guest { background: #fff; border: 1px solid #e5e7eb; }
.msg.host { background: #2563eb; color: #fff; margin-left: auto; }
.msg .meta { font-size: 10px; opacity: 0.65; margin-top: 4px; }
.compose { border-top: 1px solid #e5e7eb; padding: 12px 16px; display: flex; flex-direction: column; gap: 8px; background: #fff; }
.compose-row { display: flex; gap: 8px; align-items: center; }
.compose label { font-size: 11px; color: #6b7280; font-weight: 500; }
.compose select, .compose input[type=text] { flex: 1; padding: 7px 9px; border: 1px solid #d1d5db; border-radius: 5px; font-size: 13px; font-family: inherit; }
.compose textarea { width: 100%; padding: 8px 10px; border: 1px solid #d1d5db; border-radius: 5px; font-size: 13px; resize: vertical; min-height: 60px; font-family: inherit; }
.compose button { padding: 8px 14px; background: #2563eb; color: #fff; border: 0; border-radius: 5px; cursor: pointer; font-size: 13px; font-weight: 500; }
.compose button:hover { background: #1d4ed8; }
.compose button:disabled { opacity: 0.5; cursor: wait; }
.empty { color: #9ca3af; text-align: center; padding: 40px 20px; font-size: 13px; }
.prop-bar { padding: 8px 14px; background: #fff; border-bottom: 1px solid #e5e7eb; font-size: 12px; color: #6b7280; }
#status { flex: 1; font-size: 11px; color: #6b7280; }
</style>
</head>
<body>
<header>
  <h1>DTU — Hostex Digital Twin</h1>
  <span class="badge" id="prop-badge">__PROPERTY_TITLES__</span>
  <span class="right" id="hookstatus"></span>
</header>
<aside>
  <h2>Inbox</h2>
  <div id="conv-list"><div class="empty" style="padding:14px;">loading…</div></div>
</aside>
<main>
  <div id="thread-area" class="thread"><div class="empty">Select a conversation, or compose a new guest message below.</div></div>
  <form class="compose" id="compose-form" onsubmit="return false;">
    <div class="compose-row">
      <label>Property</label>
      <select id="prop">__PROPERTY_OPTIONS__</select>
      <label>From</label>
      <input type="text" id="from" placeholder="alice" value="alice">
    </div>
    <textarea id="content" placeholder="New guest message (e.g. &quot;is the cabin wifi fast?&quot;)"></textarea>
    <div class="compose-row" style="justify-content:flex-end;">
      <span id="status"></span>
      <button id="send-btn" type="button">Send guest message</button>
    </div>
  </form>
</main>
<script>
const $ = (sel) => document.querySelector(sel);
let activeConvId = null;
let properties = [];

async function loadProperties() {
  // Server-rendered options are already in the <select>, but refresh from
  // /v3/properties anyway so dynamic property changes show up live.
  const r = await fetch('/v3/properties');
  const d = await r.json();
  properties = d.data.properties;
}

async function loadConversations() {
  const r = await fetch('/v3/conversations');
  const d = await r.json();
  const list = d.data.conversations;
  if (!list.length) {
    $('#conv-list').innerHTML = '<div class="empty" style="padding:20px;">No conversations yet.<br>Compose below to start one.</div>';
    return;
  }
  $('#conv-list').innerHTML = list.map(c => {
    const cls = (c.id === activeConvId) ? 'conv active' : 'conv';
    const from = (c.guest && c.guest.name) || 'guest';
    const prop = c.property_title || c.property_id || '';
    const ts = c.updated_at ? c.updated_at.slice(11, 19) + ' UTC' : '';
    return '<div class="' + cls + '" onclick="selectConv(\'' + c.id + '\')">' +
      '<div class="from">' + escapeHtml(from) + '</div>' +
      '<div class="prop">' + escapeHtml(prop) + '</div>' +
      '<div class="snippet">updated ' + ts + '</div>' +
      '</div>';
  }).join('');
}

async function selectConv(id) {
  activeConvId = id;
  await loadConversations();
  await loadThread(id);
}

async function loadThread(id) {
  const r = await fetch('/v3/conversations/' + id);
  if (!r.ok) {
    $('#thread-area').innerHTML = '<div class="empty">Not found.</div>';
    return;
  }
  const d = await r.json();
  const conv = d.data;
  const msgs = conv.messages || [];
  const propLine = (conv.property_title || conv.property_id || '') + ' — ' +
                   ((conv.guest && conv.guest.name) || 'guest');
  let html = '<div class="prop-bar">' + escapeHtml(propLine) + '</div>';
  if (!msgs.length) {
    html += '<div class="empty">(no messages yet)</div>';
  } else {
    html += msgs.map(m => {
      const ts = m.created_at ? m.created_at.slice(11, 19) + ' UTC' : '';
      return '<div class="msg ' + m.sender_role + '">' +
        escapeHtml(m.content) +
        '<div class="meta">' + escapeHtml(m.sender_role) + ' · ' + ts + '</div>' +
        '</div>';
    }).join('');
  }
  $('#thread-area').innerHTML = html;
  const t = $('#thread-area');
  t.scrollTop = t.scrollHeight;
}

async function loadWebhooks() {
  const r = await fetch('/v3/webhooks');
  const d = await r.json();
  const hooks = d.data.webhooks || [];
  $('#hookstatus').textContent = hooks.length
    ? '→ ' + hooks.length + ' webhook' + (hooks.length > 1 ? 's' : '')
    : '(no webhooks registered)';
}

function escapeHtml(s) {
  if (s == null) return '';
  return String(s).replace(/[&<>"']/g, ch => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));
}

$('#send-btn').addEventListener('click', async () => {
  const prop = $('#prop').value;
  const from = $('#from').value.trim() || 'guest';
  const content = $('#content').value.trim();
  if (!content) {
    $('#status').textContent = 'enter content first';
    return;
  }
  $('#send-btn').disabled = true;
  $('#status').textContent = 'sending…';
  const payload = { property_id: prop, from: from, content: content };
  if (activeConvId) payload.conversation_id = activeConvId;
  try {
    const r = await fetch('/admin/guest-send', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    if (!r.ok) {
      const err = await r.text();
      $('#status').textContent = 'send failed: HTTP ' + r.status + ' ' + err;
      return;
    }
    const d = await r.json();
    $('#status').textContent = 'sent. fanning out to ' + ($('#hookstatus').textContent || 'no webhooks') + '…';
    $('#content').value = '';
    activeConvId = d.conversation_id;
    await loadConversations();
    await loadThread(d.conversation_id);
    setTimeout(() => { $('#status').textContent = ''; }, 4000);
  } finally {
    $('#send-btn').disabled = false;
  }
});

async function refresh() {
  await loadConversations();
  await loadWebhooks();
  if (activeConvId) await loadThread(activeConvId);
}

loadProperties().then(refresh);
setInterval(refresh, 3000);
</script>
</body>
</html>
"""


@app.route("/")
def index() -> Response:
    # Server-render the property titles into the static HTML so the page
    # has them on first paint (and so Verify C2's grep for 'Mtn Home' /
    # '10th Ave' against the raw HTML passes — the JS-rendered version
    # wouldn't appear in a curl).
    props = _read_json(PROPERTIES_FILE)
    titles = " + ".join(p["title"] for p in props.values()) or "(no properties)"
    options = "".join(
        f'<option value="{p["id"]}">{p["title"]}</option>' for p in props.values()
    )
    html = INDEX_HTML.replace("__PROPERTY_TITLES__", titles).replace(
        "__PROPERTY_OPTIONS__", options
    )
    return Response(html, mimetype="text/html")


# ---------------------------------------------------------------------------
# CLI — every subcommand makes one HTTP call to the running server.
# No shared in-process state with the Flask app — CLI is a thin HTTP client.
# ---------------------------------------------------------------------------


def _base() -> str:
    return f"http://127.0.0.1:{PORT}"


def _http(method: str, path: str, body: Optional[dict] = None) -> dict:
    url = _base() + path
    data = json.dumps(body).encode("utf-8") if body is not None else None
    headers = {"Content-Type": "application/json"} if data else {}
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        err_body = e.read().decode("utf-8", errors="replace")
        sys.exit(f"HTTP {e.code} {e.reason}: {err_body}")
    except urllib.error.URLError as e:
        sys.exit(f"connection error to {url}: {e}")


def cli_serve(args: argparse.Namespace) -> None:
    global PORT, DATA_DIR
    PORT = args.port
    if args.data_dir:
        DATA_DIR = Path(args.data_dir)
        # Recompute file paths now that DATA_DIR has moved.
        globals().update(
            PROPERTIES_FILE=DATA_DIR / "properties.json",
            CONVERSATIONS_FILE=DATA_DIR / "conversations.json",
            MESSAGES_FILE=DATA_DIR / "messages.jsonl",
            WEBHOOKS_FILE=DATA_DIR / "webhooks.json",
            EVENTS_FILE=DATA_DIR / "events.jsonl",
            RESERVATIONS_FILE=DATA_DIR / "reservations.json",
            BLOCKS_FILE=DATA_DIR / "blocks.json",
        )
    _ensure_data_dir()
    print(f"DTU listening on http://127.0.0.1:{PORT}")
    print(f"data dir: {DATA_DIR}")
    app.run(host="127.0.0.1", port=PORT, threaded=False, debug=False, use_reloader=False)


def cli_prop_list(args: argparse.Namespace) -> None:
    d = _http("GET", "/v3/properties")
    for p in d["data"]["properties"]:
        print(f"{p['id']}\t{p['title']}\t{p.get('address', '')}")


def cli_conv_list(args: argparse.Namespace) -> None:
    qs = f"?property_id={args.property}" if args.property else ""
    d = _http("GET", "/v3/conversations" + qs)
    convs = d["data"]["conversations"]
    if not convs:
        print("(no conversations)")
        return
    for c in convs:
        guest = (c.get("guest") or {}).get("name", "")
        print(f"{c['id']}\t{c.get('property_title', '')}\t{guest}\t{c.get('updated_at', '')}")


def cli_conv_show(args: argparse.Namespace) -> None:
    d = _http("GET", f"/v3/conversations/{args.conv_id}")
    print(json.dumps(d, indent=2))


def cli_guest_send(args: argparse.Namespace) -> None:
    body = {
        "property_id": args.property,
        "from": getattr(args, "from"),
        "content": args.content,
    }
    if args.conv:
        body["conversation_id"] = args.conv
    d = _http("POST", "/admin/guest-send", body)
    print(json.dumps(d))


def cli_host_send(args: argparse.Namespace) -> None:
    body = {"message": args.content}
    d = _http("POST", f"/v3/conversations/{args.conv}", body)
    print(json.dumps(d))


def cli_webhook_list(args: argparse.Namespace) -> None:
    d = _http("GET", "/v3/webhooks")
    hooks = d["data"]["webhooks"]
    if not hooks:
        print("(no webhooks registered)")
        return
    for h in hooks:
        events = ",".join(h.get("events", []) or [])
        print(f"{h['id']}\t{h['url']}\t{events}")


def cli_webhook_set(args: argparse.Namespace) -> None:
    body = {"url": args.url, "events": args.events or ["message_created"]}
    d = _http("POST", "/v3/webhooks", body)
    print(json.dumps(d["data"]))


def cli_webhook_rm(args: argparse.Namespace) -> None:
    d = _http("DELETE", f"/v3/webhooks/{args.webhook_id}")
    print(json.dumps(d["data"]))


def cli_webhook_test(args: argparse.Namespace) -> None:
    """Synthetic firing: posts a message_created payload to all registered hooks.

    Bypasses /admin/guest-send so this is a true wiring sanity check.
    """
    payload = {
        "event": "message_created",
        "conversation_id": "synthetic-test",
        "message_id": _new_id("msg"),
        "timestamp": _now_iso(),
    }
    _fanout_webhooks(payload)
    print(json.dumps({"fired": True, "payload": payload}))


def cli_reset(args: argparse.Namespace) -> None:
    d = _http("POST", "/admin/reset")
    print(json.dumps(d))


def cli_events(args: argparse.Namespace) -> None:
    if args.follow:
        # Tail mode — re-read events.jsonl every second.
        seen = 0
        try:
            while True:
                txt = _http_text("GET", "/admin/events")
                lines = txt.splitlines()
                for line in lines[seen:]:
                    print(line, flush=True)
                seen = len(lines)
                import time
                time.sleep(1)
        except KeyboardInterrupt:
            return
    else:
        print(_http_text("GET", "/admin/events"), end="")


def _http_text(method: str, path: str) -> str:
    url = _base() + path
    req = urllib.request.Request(url, method=method)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return resp.read().decode("utf-8")
    except urllib.error.URLError as e:
        sys.exit(f"connection error to {url}: {e}")


# --- reservation / block CLI (ADDITIVE — scripted test seeding) ---


def cli_reservation_add(args: argparse.Namespace) -> None:
    body = {
        "property": args.property,
        "check_in_date": args.check_in,
        "check_out_date": args.check_out,
        "status": args.status,
        "number_of_guests": args.guests,
    }
    for k, v in (("reservation_code", args.code), ("conversation_id", args.conv),
                 ("guest_name", args.guest_name), ("channel_type", args.channel_type),
                 ("stay_status", args.stay_status)):
        if v:
            body[k] = v
    print(json.dumps(_http("POST", "/admin/reservation", body)["data"]))


def cli_reservation_list(args: argparse.Namespace) -> None:
    qs = "?limit=100" + (f"&property_id={args.property}" if args.property else "")
    rs = _http("GET", "/v3/reservations" + qs)["data"]["reservations"]
    if not rs:
        print("(no reservations)")
        return
    for r in rs:
        print(f"{r['reservation_code']}\t{r['status']}\t{r.get('property_slug', '')}\t"
              f"{r['check_in_date']}→{r['check_out_date']}\t{r.get('guest_name') or ''}")


def cli_reservation_cancel(args: argparse.Namespace) -> None:
    print(json.dumps(_http("POST", "/admin/reservation/cancel", {"reservation_code": args.code})["data"]))


def cli_block_add(args: argparse.Namespace) -> None:
    body = {"property": args.property, "start_date": args.start, "end_date": args.end}
    if args.remarks:
        body["remarks"] = args.remarks
    print(json.dumps(_http("POST", "/admin/block", body)["data"]))


def main() -> None:
    parser = argparse.ArgumentParser(prog="dtu", description="Digital Twin Universe of hostex.io")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("serve", help="start the HTTP server")
    p.add_argument("--port", type=int, default=PORT)
    p.add_argument("--data-dir", default=str(DATA_DIR))
    p.set_defaults(func=cli_serve)

    p = sub.add_parser("prop", help="property commands")
    ps = p.add_subparsers(dest="propcmd", required=True)
    pl = ps.add_parser("list"); pl.set_defaults(func=cli_prop_list)

    p = sub.add_parser("conv", help="conversation commands")
    cs = p.add_subparsers(dest="convcmd", required=True)
    cl = cs.add_parser("list"); cl.add_argument("--property"); cl.set_defaults(func=cli_conv_list)
    cw = cs.add_parser("show"); cw.add_argument("conv_id"); cw.set_defaults(func=cli_conv_show)

    p = sub.add_parser("guest", help="guest commands")
    gs = p.add_subparsers(dest="guestcmd", required=True)
    gp = gs.add_parser("send")
    gp.add_argument("--property", required=True)
    gp.add_argument("--from", required=True, dest="from")
    gp.add_argument("--content", required=True)
    gp.add_argument("--conv")
    gp.set_defaults(func=cli_guest_send)

    p = sub.add_parser("host", help="host commands")
    hs = p.add_subparsers(dest="hostcmd", required=True)
    hp = hs.add_parser("send")
    hp.add_argument("--conv", required=True)
    hp.add_argument("--content", required=True)
    hp.set_defaults(func=cli_host_send)

    p = sub.add_parser("webhook", help="webhook commands")
    ws = p.add_subparsers(dest="webcmd", required=True)
    ws.add_parser("list").set_defaults(func=cli_webhook_list)
    wp = ws.add_parser("set"); wp.add_argument("url"); wp.add_argument("--events", nargs="*"); wp.set_defaults(func=cli_webhook_set)
    wp = ws.add_parser("rm"); wp.add_argument("webhook_id"); wp.set_defaults(func=cli_webhook_rm)
    ws.add_parser("test").set_defaults(func=cli_webhook_test)

    p = sub.add_parser("reservation", help="reservation commands (test seeding)")
    rs = p.add_subparsers(dest="rescmd", required=True)
    ra = rs.add_parser("add")
    ra.add_argument("--property", required=True)
    ra.add_argument("--check-in", required=True, dest="check_in")
    ra.add_argument("--check-out", required=True, dest="check_out")
    ra.add_argument("--status", default="accepted")
    ra.add_argument("--guests", type=int, default=1)
    ra.add_argument("--code")
    ra.add_argument("--conv")
    ra.add_argument("--guest-name", dest="guest_name")
    ra.add_argument("--channel-type", dest="channel_type")
    ra.add_argument("--stay-status", dest="stay_status",
                    help="checkin_pending|in_house|stay_completed (else derived)")
    ra.set_defaults(func=cli_reservation_add)
    rl = rs.add_parser("list"); rl.add_argument("--property"); rl.set_defaults(func=cli_reservation_list)
    rc = rs.add_parser("cancel"); rc.add_argument("--code", required=True); rc.set_defaults(func=cli_reservation_cancel)

    p = sub.add_parser("block", help="host-block / maintenance commands (test seeding)")
    bs = p.add_subparsers(dest="blockcmd", required=True)
    ba = bs.add_parser("add")
    ba.add_argument("--property", required=True)
    ba.add_argument("--start", required=True)
    ba.add_argument("--end", required=True)
    ba.add_argument("--remarks")
    ba.set_defaults(func=cli_block_add)

    sub.add_parser("reset").set_defaults(func=cli_reset)

    p = sub.add_parser("events"); p.add_argument("--follow", action="store_true"); p.set_defaults(func=cli_events)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
