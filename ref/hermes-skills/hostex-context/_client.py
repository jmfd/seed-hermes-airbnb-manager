"""Live Hostex read client for hostex-context.

ARCHITECTURE (locked): Hostex is the single source of truth. Every call hits the
live API — no persistent cache, no mirror, no last-known-state file. The only
optimization is request-scope memoization: within a single process invocation
(one boss turn / one tool call) we will not fetch the identical URL twice.

Base URL + token resolve from, in order: explicit constructor args → environment
(`HOSTEX_BASE_URL`, `HOSTEX_ACCESS_TOKEN`). Point `HOSTEX_BASE_URL` at the DTU
(`http://host.docker.internal:8082`) for tests; leave it default for real Hostex.
The same client code works unchanged against both.
"""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_BASE_URL = "https://api.hostex.io"
USER_AGENT = "curl/8.7.1"  # boss skill hard-rule: every Hostex call sends this


class HostexError(RuntimeError):
    pass


class HostexClient:
    def __init__(self, base_url: str | None = None, token: str | None = None, timeout: int = 15):
        self.base_url = (base_url or os.environ.get("HOSTEX_BASE_URL") or DEFAULT_BASE_URL).rstrip("/")
        self.token = token or os.environ.get("HOSTEX_ACCESS_TOKEN") or ""
        self.timeout = timeout
        self._memo: dict[str, dict] = {}  # request-scope only; dies with the process

    # -- transport ---------------------------------------------------------

    def _request(self, method: str, path: str, body: dict | None = None) -> dict:
        url = self.base_url + path
        memo_key = None
        if method == "GET":
            memo_key = url
            if memo_key in self._memo:
                return self._memo[memo_key]
        data = json.dumps(body).encode() if body is not None else None
        headers = {"Hostex-Access-Token": self.token, "User-Agent": USER_AGENT}
        if data is not None:
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                raw = resp.read().decode("utf-8")
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", "replace")
            raise HostexError(f"HTTP {e.code} {method} {path}: {detail}") from e
        except urllib.error.URLError as e:
            raise HostexError(f"connection error {method} {url}: {e}") from e
        parsed = json.loads(raw) if raw else {}
        if memo_key is not None:
            self._memo[memo_key] = parsed
        return parsed

    @staticmethod
    def _qs(params: dict) -> str:
        clean = {k: v for k, v in params.items() if v is not None and v != ""}
        return ("?" + urllib.parse.urlencode(clean)) if clean else ""

    # -- read endpoints (data envelope unwrapped) --------------------------

    def reservations(self, **filters) -> list[dict]:
        """GET /v3/reservations. Accepts property_id, status, reservation_code,
        start/end_check_in_date, start/end_check_out_date, offset, limit."""
        filters.setdefault("limit", 100)
        d = self._request("GET", "/v3/reservations" + self._qs(filters))
        return (d.get("data") or {}).get("reservations", []) or []

    def listing_calendar(self, listings: list[dict], start_date: str, end_date: str) -> list[dict]:
        """POST /v3/listings/calendar. listings: [{listing_id, channel_type}]."""
        d = self._request("POST", "/v3/listings/calendar",
                          {"start_date": start_date, "end_date": end_date, "listings": listings})
        return (d.get("data") or {}).get("listings", []) or []

    def availabilities(self, property_ids: str, start_date: str, end_date: str) -> list[dict]:
        """GET /v3/availabilities. property_ids is a comma-joined string."""
        d = self._request("GET", "/v3/availabilities" + self._qs(
            {"property_ids": property_ids, "start_date": start_date, "end_date": end_date}))
        return (d.get("data") or {}).get("properties", []) or []

    def properties(self) -> list[dict]:
        d = self._request("GET", "/v3/properties")
        return (d.get("data") or {}).get("properties", []) or []

    def conversation(self, conv_id: str) -> dict:
        d = self._request("GET", f"/v3/conversations/{conv_id}")
        return d.get("data") or {}

    # -- helpers -----------------------------------------------------------

    @staticmethod
    def _slug(s) -> str:
        out = []
        for ch in str(s or "").lower():
            out.append(ch if ch.isalnum() else "-")
        return "-".join(filter(None, "".join(out).split("-")))

    def _property_matches(self, p: dict, token: str) -> bool:
        """A property matches a token by integer id, DTU slug/hostex_id/listing_id,
        exact title, or slug-of-title. The last is what makes `--property mtn-home`
        resolve against REAL Hostex, whose properties have only an integer `id` +
        `title` (no slug field)."""
        s = str(token)
        if s in (str(p.get("id")), str(p.get("hostex_id")), str(p.get("listing_id")), p.get("title")):
            return True
        return self._slug(p.get("title")) == self._slug(s)

    def resolve_property_id(self, token: str) -> str:
        """Map a slug / title / id to the integer hostex property_id (as str) the
        real API expects. Real: property `id` IS the integer. DTU: `hostex_id` is.
        Falls back to the token itself if no catalog match."""
        if token is None:
            return token
        for p in self.properties():
            if self._property_matches(p, token):
                return str(p.get("hostex_id") or p.get("id"))
        return str(token)

    def resolve_listing(self, token: str) -> dict:
        """Return {listing_id, channel_type} for the calendar endpoint.

        Real Hostex: a property maps to MANY channel listings, found in its
        `channels[]` ([{channel_type, listing_id, currency}]); the listing_id is
        channel-specific (NOT the property_id). We pick the first channel. DTU:
        the property carries a flat listing_id/channel_type. No match ⇒ treat the
        token itself as a listing_id."""
        for p in self.properties():
            if self._property_matches(p, token):
                channels = p.get("channels")
                if isinstance(channels, list) and channels:
                    c = channels[0]
                    return {"listing_id": str(c.get("listing_id")),
                            "channel_type": c.get("channel_type", "airbnb"),
                            "channels": channels}
                if p.get("listing_id"):
                    return {"listing_id": str(p["listing_id"]),
                            "channel_type": p.get("channel_type", "airbnb")}
                return {"listing_id": str(p.get("hostex_id") or p.get("id")),
                        "channel_type": p.get("channel_type", "airbnb")}
        return {"listing_id": str(token), "channel_type": "airbnb"}
