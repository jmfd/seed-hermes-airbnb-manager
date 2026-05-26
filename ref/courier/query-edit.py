#!/usr/bin/env python3
"""
query-edit.py — single owner of read-modify-write for queries/q-*.md brain pages.

All three actors (boss skill, listener skill, courier sidecar) MUST mutate query
pages through this tool. Single mutation surface = single lock surface = no
roundtrip-YAML bugs.

Locking: every mutation flocks the page file directly (LOCK_EX). Readers may
flock LOCK_SH if needed; the helper always uses LOCK_EX for write paths.

YAML preservation: uses PyYAML with safe_dump(default_flow_style=False,
sort_keys=False, allow_unicode=True, width=10000). Multi-line strings round-trip
as block scalars when needed; unknown frontmatter keys are preserved.

Subcommands (all take --brain-dir, default /opt/data/home/brain):

  create-query --query-id ID --conv-id C --msg-id M --content TEXT
               --owner-mirror-key K --asks-json '[{...},{...}]'
               [--title T] [--property-id P]

  write-answer --query-id ID --ask-id A --answer-file PATH
               [--answer-text TEXT]   # use --answer-file for multi-line

  repinging --query-id ID --ask-id A --new-ping-count N --new-asked-at ISO

  escalate --query-id ID --ask-id A --draft-content TEXT

  append-draft --query-id ID --kind {partial|final|escalate-notice}
               --content-file PATH    # multi-line safe
               [--draft-id D]          # auto-assigned if omitted

  mark-mirrored --query-id ID --draft-id D
  mark-approved --query-id ID --draft-id D
  mark-rejected --query-id ID --draft-id D
  mark-delivered --query-id ID --draft-id D [--close]   # --close sets status=closed
  mark-auto-shipped --query-id ID --draft-id D          # partial sent to guest without owner approval

  latest-pending-approve [--kind final]
      # Read-only: scan queries/q-*.md and emit JSON for the SINGLE most-recent
      # draft where mirrored_to_owner_at is set, approved_at/rejected_at/
      # delivered_at are NOT set, and (default) kind == 'final'. Used by the
      # boss skill's approve session to find which draft the owner is approving
      # WITHOUT requiring the owner to type the draft_id verbatim. Emits {} on
      # no match (caller treats as 'nothing pending').

  tick   # courier per-tick processing; mutates pages in-place, emits actions to stdout

  show --query-id ID    # print frontmatter as JSON (read-only, debugging)

Exit codes:
  0   success
  1   error (message on stderr)
  2   bad invocation
  3   query not found / ask not found
"""
from __future__ import annotations

import argparse
import datetime as _dt
import fcntl
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
from typing import Any

try:
    import yaml  # PyYAML
except ImportError:
    print(
        "query-edit.py: PyYAML not installed. The install script runs "
        "'pip install --user pyyaml' inside the container; if that failed, "
        "run it manually and re-try.",
        file=sys.stderr,
    )
    sys.exit(1)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

FRONTMATTER_RE = re.compile(r"^---\n(.*?)\n---\n?(.*)$", re.S)


def utc_now_iso() -> str:
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def utc_plus_minutes_iso(mins: int) -> str:
    return (
        _dt.datetime.now(_dt.timezone.utc) + _dt.timedelta(minutes=mins)
    ).strftime("%Y-%m-%dT%H:%M:%SZ")


def iso_to_epoch(s: str | None) -> int:
    if not s:
        return 0
    try:
        s = str(s).rstrip("Z")
        return int(
            _dt.datetime.fromisoformat(s)
            .replace(tzinfo=_dt.timezone.utc)
            .timestamp()
        )
    except Exception:
        return 0


def utc_epoch() -> int:
    return int(_dt.datetime.now(_dt.timezone.utc).timestamp())


def yaml_dump(d: dict) -> str:
    return yaml.safe_dump(
        d,
        default_flow_style=False,
        sort_keys=False,
        allow_unicode=True,
        width=10000,
    )


def query_path(brain_dir: pathlib.Path, query_id: str) -> pathlib.Path:
    if not query_id.startswith("q-"):
        raise SystemExit(f"query_id must start with 'q-': got {query_id!r}")
    return brain_dir / "queries" / f"{query_id}.md"


def read_page(path: pathlib.Path) -> tuple[dict, str]:
    """Read a query page; return (frontmatter_dict, body_str)."""
    if not path.exists():
        raise SystemExit(3)
    text = path.read_text()
    m = FRONTMATTER_RE.match(text)
    if not m:
        raise SystemExit(f"page {path} has no frontmatter")
    fm = yaml.safe_load(m.group(1)) or {}
    return fm, m.group(2)


def write_page_atomic(path: pathlib.Path, fm: dict, body: str) -> None:
    """Write a query page atomically via tmpfile + rename."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp.", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as f:
            f.write("---\n")
            f.write(yaml_dump(fm))
            f.write("---\n")
            f.write(body or "")
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


class FlockedPage:
    """Context manager: flock the query page LOCK_EX for the duration."""

    def __init__(self, path: pathlib.Path, timeout: int = 10):
        self.path = path
        self.timeout = timeout
        self.fd = None

    def __enter__(self):
        # Create the file if missing so we can flock it (for the create-query
        # path; mutation paths already require the file to exist).
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.touch(exist_ok=True)
        self.fd = os.open(str(self.path), os.O_RDWR | os.O_CREAT, 0o644)
        deadline = time.time() + self.timeout
        while True:
            try:
                fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return self
            except BlockingIOError:
                if time.time() > deadline:
                    raise SystemExit(
                        f"query-edit: could not acquire flock on {self.path} "
                        f"within {self.timeout}s (another writer holds it)"
                    )
                time.sleep(0.1)

    def __exit__(self, exc_type, exc, tb):
        if self.fd is not None:
            try:
                fcntl.flock(self.fd, fcntl.LOCK_UN)
            except OSError:
                pass
            try:
                os.close(self.fd)
            except OSError:
                pass


def git_commit_brain(brain_dir: pathlib.Path, relpath: str, message: str) -> None:
    """git add + commit a single file in the brain repo.

    Fails LOUDLY if commit fails — SEED contract says modified pages MUST be
    committed. Caller can catch SystemExit and decide to retry.
    """
    if not (brain_dir / ".git").exists():
        # No brain repo — skip commit silently. Useful in tests.
        return
    try:
        subprocess.run(
            ["git", "-C", str(brain_dir), "add", relpath],
            check=True,
            capture_output=True,
            text=True,
        )
        # If nothing staged (e.g. content unchanged), don't error.
        diff = subprocess.run(
            ["git", "-C", str(brain_dir), "diff", "--cached", "--quiet"],
            capture_output=True,
        )
        if diff.returncode == 0:
            return
        subprocess.run(
            ["git", "-C", str(brain_dir), "commit", "-m", message],
            check=True,
            capture_output=True,
            text=True,
        )
    except subprocess.CalledProcessError as e:
        msg = (e.stderr or e.stdout or "").strip()
        raise SystemExit(
            f"query-edit: git commit FAILED for {relpath}: {msg}"
        ) from e


def find_ask(fm: dict, ask_id: str) -> dict:
    for a in fm.get("asks", []) or []:
        if a.get("ask_id") == ask_id:
            return a
    raise SystemExit(3)


def find_draft(fm: dict, draft_id: str) -> dict:
    for d in fm.get("drafts", []) or []:
        if d.get("draft_id") == draft_id:
            return d
    raise SystemExit(3)


def next_draft_id(fm: dict) -> str:
    return f"draft-{len(fm.get('drafts', []) or []) + 1}"


# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

def cmd_create_query(args, brain_dir):
    path = query_path(brain_dir, args.query_id)
    now = utc_now_iso()
    asks_in = json.loads(args.asks_json)
    if not isinstance(asks_in, list):
        raise SystemExit("--asks-json must be a JSON array")
    asks_out = []
    for i, a in enumerate(asks_in, start=1):
        original = a.get("asked_at") or now
        sla = a.get("sla_deadline") or utc_plus_minutes_iso(int(a.get("sla_minutes", 30)))
        esc = a.get("escalation_deadline") or utc_plus_minutes_iso(int(a.get("escalation_minutes", 60)))
        asks_out.append({
            "ask_id": a.get("ask_id") or f"ask-{i}",
            "team_member_uid": a["team_member_uid"],
            "role": a["role"],
            "question": a["question"],
            "asked_at": original,
            "original_asked_at": original,
            "ping_count": int(a.get("ping_count", 1)),
            "sla_deadline": sla,
            "escalation_deadline": esc,
            "status": a.get("status", "pending"),
            "answer": a.get("answer"),
            "answered_at": a.get("answered_at"),
        })
    fm = {
        "title": args.title or f"Q: {args.content[:60]}",
        "query_id": args.query_id,
        "guest_conversation_id": args.conv_id,
        "guest_message_id": args.msg_id,
        "guest_property_id": args.property_id or None,
        "status": "open",
        "created_at": now,
        "updated_at": now,
        "owner_mirror_session_key": args.owner_mirror_key,
        "guest_message_content": args.content,
        "asks": asks_out,
        "drafts": [],
    }
    body = (
        f"# {fm['title']}\n\nGuest conversation: `{args.conv_id}`\n\n"
        f"Guest message:\n\n> {args.content}\n\n"
        "## In-flight asks\n\n"
        "(Auto-maintained for debugging. Frontmatter is authoritative.)\n"
    )
    with FlockedPage(path):
        if path.exists() and path.stat().st_size > 0:
            existing, _ = read_page(path)
            if existing.get("query_id"):
                # Idempotency: re-creating an existing query is a no-op.
                print(f"query already exists: {args.query_id}", file=sys.stderr)
                return
        write_page_atomic(path, fm, body)
    git_commit_brain(brain_dir, f"queries/{args.query_id}.md",
                     f"coordinator: new query {args.query_id}")
    print(args.query_id)


def cmd_write_answer(args, brain_dir):
    path = query_path(brain_dir, args.query_id)
    if args.answer_file:
        answer = pathlib.Path(args.answer_file).read_text()
    elif args.answer_text is not None:
        answer = args.answer_text
    else:
        answer = sys.stdin.read()
    # Preserve verbatim: rstrip only the trailing newline (file IO artifact),
    # keep all internal whitespace + multi-line structure.
    if answer.endswith("\n"):
        answer = answer[:-1]
    with FlockedPage(path):
        fm, body = read_page(path)
        ask = find_ask(fm, args.ask_id)
        if ask.get("status") != "pending":
            print(f"ask {args.ask_id} not pending (status={ask.get('status')}); no-op",
                  file=sys.stderr)
            return
        ask["answer"] = answer
        ask["answered_at"] = utc_now_iso()
        ask["status"] = "answered"
        fm["updated_at"] = utc_now_iso()
        if fm.get("status") == "open":
            fm["status"] = "partial"
        write_page_atomic(path, fm, body)
    git_commit_brain(brain_dir, f"queries/{args.query_id}.md",
                     f"coordinator: team answer for {args.query_id}/{args.ask_id}")


def cmd_repinging(args, brain_dir):
    """Mark a re-ping AFTER the side effect succeeded.

    The courier MUST only call this after plow_chat POST returned 2xx. We do not
    advance state speculatively.
    """
    path = query_path(brain_dir, args.query_id)
    with FlockedPage(path):
        fm, body = read_page(path)
        ask = find_ask(fm, args.ask_id)
        if ask.get("status") != "pending":
            return
        ask["ping_count"] = int(args.new_ping_count)
        ask["asked_at"] = args.new_asked_at
        fm["updated_at"] = utc_now_iso()
        write_page_atomic(path, fm, body)
    git_commit_brain(brain_dir, f"queries/{args.query_id}.md",
                     f"coordinator: re-pinged {args.query_id}/{args.ask_id}")


def cmd_escalate(args, brain_dir):
    """Mark an ask escalated AFTER the wakeAgent side effect succeeded."""
    path = query_path(brain_dir, args.query_id)
    with FlockedPage(path):
        fm, body = read_page(path)
        ask = find_ask(fm, args.ask_id)
        if ask.get("status") != "pending":
            return
        ask["status"] = "escalated"
        draft_id = next_draft_id(fm)
        fm.setdefault("drafts", []).append({
            "draft_id": draft_id,
            "kind": "escalate-notice",
            "content": args.draft_content,
            "drafted_at": utc_now_iso(),
        })
        fm["updated_at"] = utc_now_iso()
        if fm.get("status") in (None, "open"):
            fm["status"] = "partial"
        write_page_atomic(path, fm, body)
    git_commit_brain(brain_dir, f"queries/{args.query_id}.md",
                     f"coordinator: escalated {args.query_id}/{args.ask_id}")


def cmd_append_draft(args, brain_dir):
    path = query_path(brain_dir, args.query_id)
    content = pathlib.Path(args.content_file).read_text()
    if content.endswith("\n"):
        content = content[:-1]
    with FlockedPage(path):
        fm, body = read_page(path)
        draft_id = args.draft_id or next_draft_id(fm)
        fm.setdefault("drafts", []).append({
            "draft_id": draft_id,
            "kind": args.kind,
            "content": content,
            "drafted_at": utc_now_iso(),
        })
        fm["updated_at"] = utc_now_iso()
        write_page_atomic(path, fm, body)
    git_commit_brain(brain_dir, f"queries/{args.query_id}.md",
                     f"coordinator: appended {args.kind} draft to {args.query_id}")
    print(draft_id)


def _mark_field(args, brain_dir, field: str, label: str, close_on_set: bool = False):
    path = query_path(brain_dir, args.query_id)
    with FlockedPage(path):
        fm, body = read_page(path)
        draft = find_draft(fm, args.draft_id)
        draft[field] = utc_now_iso()
        fm["updated_at"] = utc_now_iso()
        if close_on_set and getattr(args, "close", False) and draft.get("kind") == "final":
            fm["status"] = "closed"
            fm["closed_at"] = utc_now_iso()
        write_page_atomic(path, fm, body)
    git_commit_brain(brain_dir, f"queries/{args.query_id}.md",
                     f"coordinator: {label} {args.draft_id} for {args.query_id}")


def cmd_mark_mirrored(args, brain_dir):
    _mark_field(args, brain_dir, "mirrored_to_owner_at", "mirrored")


def cmd_mark_approved(args, brain_dir):
    _mark_field(args, brain_dir, "approved_at", "approved")


def cmd_mark_rejected(args, brain_dir):
    _mark_field(args, brain_dir, "rejected_at", "rejected")


def cmd_mark_delivered(args, brain_dir):
    _mark_field(args, brain_dir, "delivered_at", "delivered", close_on_set=True)


def cmd_mark_auto_shipped(args, brain_dir):
    """Mark a PARTIAL draft as auto-shipped to the guest (no owner approval).

    Distinct from mark-delivered because the partial path has no approve gate:
    auto_shipped_to_guest_at records that the courtesy ack went out, while
    delivered_at + approved_at stay reserved for the FINAL draft owner-approve
    path. The boss skill's owner-mirror reads this field to confirm "what
    actually shipped to the guest" in 8b.6.
    """
    _mark_field(args, brain_dir, "auto_shipped_to_guest_at", "auto-shipped")


def cmd_latest_pending_approve(args, brain_dir):
    """Find the single most-recent kind=final draft awaiting owner approval.

    Recency-matching helper for the v12.1 attendant UX: the owner-mirror
    message no longer carries query_id / draft_id, so the approve session
    needs a way to figure out WHICH draft the owner just said 'approve' to.

    Algorithm:
      For each queries/q-*.md, parse frontmatter. For each draft d in drafts[]:
        - require d.kind == args.kind (default 'final')
        - require d.mirrored_to_owner_at is set (truthy)
        - require d.approved_at NOT set
        - require d.rejected_at NOT set
        - require d.delivered_at NOT set
      Sort all qualifying drafts by mirrored_to_owner_at DESCENDING. Emit
      JSON for the first (most-recent).
      If no candidates, emit '{}' (empty object) and exit 0 — the boss
      treats empty as "nothing pending; ask the owner to clarify".

    Output JSON keys when match found:
      {"query_id": "...", "draft_id": "...", "conversation_id": "...",
       "content": "...", "kind": "...", "mirrored_to_owner_at": "..."}
    """
    kind = getattr(args, "kind", "final") or "final"
    queries_dir = brain_dir / "queries"
    if not queries_dir.is_dir():
        print("{}")
        return
    candidates = []
    for path in sorted(queries_dir.glob("q-*.md")):
        try:
            fm, _ = read_page(path)
        except SystemExit:
            continue
        for d in fm.get("drafts", []) or []:
            if d.get("kind") != kind:
                continue
            if not d.get("mirrored_to_owner_at"):
                continue
            if d.get("approved_at") or d.get("rejected_at") or d.get("delivered_at"):
                continue
            candidates.append({
                "query_id": fm.get("query_id"),
                "draft_id": d.get("draft_id"),
                "conversation_id": fm.get("guest_conversation_id"),
                "content": d.get("content"),
                "kind": d.get("kind"),
                "mirrored_to_owner_at": d.get("mirrored_to_owner_at"),
            })
    if not candidates:
        print("{}")
        return
    candidates.sort(key=lambda c: c["mirrored_to_owner_at"], reverse=True)
    print(json.dumps(candidates[0]))


def cmd_show(args, brain_dir):
    path = query_path(brain_dir, args.query_id)
    fm, _ = read_page(path)
    print(json.dumps(fm, indent=2, default=str))


def cmd_tick(args, brain_dir):
    """Per-tick processing for the courier sidecar.

    Walks queries/q-*.md, evaluates deadlines, emits a JSON action list on
    stdout. The courier bash loop reads these, performs the side effects
    (plow_chat POST, wakeAgent), and on success re-invokes query-edit with
    the corresponding state-mutation subcommand. Decoupling decisions from
    side effects means state never advances unless the side effect succeeded.

    Output: one JSON object per line, schema:
      {"action": "repinging", "query_id": "...", "ask_id": "...",
       "team_member_uid": "...", "question": "..."}
      {"action": "escalate", "query_id": "...", "ask_id": "...",
       "role": "...", "question": "..."}
      {"action": "wake_for_draft", "query_id": "...", "file": "..."}
    """
    sla_minutes = int(args.sla_minutes)
    escalation_minutes = int(args.escalation_minutes)
    partial_stale = int(args.partial_staleness_seconds)
    queries_dir = brain_dir / "queries"
    if not queries_dir.is_dir():
        return
    now_epoch = utc_epoch()
    for path in sorted(queries_dir.glob("q-*.md")):
        try:
            # Read without write lock — we only emit ACTIONS; the followup
            # commands take the write lock.
            fm, _ = read_page(path)
        except SystemExit:
            continue
        if fm.get("status") not in ("open", "partial"):
            continue
        any_state_changed_externally = False  # tracks if downstream actions
        for ask in fm.get("asks", []) or []:
            if ask.get("status") != "pending":
                continue
            sla = iso_to_epoch(ask.get("sla_deadline"))
            esc = iso_to_epoch(ask.get("escalation_deadline"))
            pc = int(ask.get("ping_count", 1))
            if now_epoch < sla:
                continue
            # Past SLA but not past escalation, OR past escalation and we
            # still haven't sent the second ping → re-ping. This covers the
            # codex P1 #7 case (first sees ask after escalation_deadline
            # with ping_count==1: still re-ping, then next tick escalates).
            if pc == 1:
                print(json.dumps({
                    "action": "repinging",
                    "query_id": fm["query_id"],
                    "ask_id": ask["ask_id"],
                    "team_member_uid": ask["team_member_uid"],
                    "question": ask["question"],
                    "new_ping_count": 2,
                }))
                any_state_changed_externally = True
                continue
            if now_epoch >= esc and pc >= 2:
                print(json.dumps({
                    "action": "escalate",
                    "query_id": fm["query_id"],
                    "ask_id": ask["ask_id"],
                    "role": ask.get("role", "unknown"),
                    "question": ask["question"],
                }))
                any_state_changed_externally = True
        # Evaluate ready_to_draft (PROJECTION — actual mutation happens via
        # the boss skill being woken, not in this helper).
        asks = fm.get("asks", []) or []
        drafts = fm.get("drafts", []) or []
        all_resolved = bool(asks) and all(
            a.get("status") in ("answered", "escalated", "timed_out")
            for a in asks
        )
        any_answered = any(a.get("status") == "answered" for a in asks)
        any_pending = any(a.get("status") == "pending" for a in asks)
        has_final = any(d.get("kind") == "final" for d in drafts)
        has_recent_partial = any(
            d.get("kind") == "partial"
            and now_epoch - iso_to_epoch(d.get("drafted_at")) < partial_stale
            for d in drafts
        )
        should_wake = (
            (all_resolved and not has_final)
            or (any_answered and any_pending and not has_recent_partial)
        )
        if should_wake:
            print(json.dumps({
                "action": "wake_for_draft",
                "query_id": fm["query_id"],
                "file": str(path),
            }))
        # Also emit mirror_now for any drafts that exist but were never
        # mirrored to the owner channel — recovers from a failed mirror call
        # (e.g., transient Plow API outage). Idempotent: handler POSTs +
        # marks mirrored; subsequent ticks see mirrored_to_owner_at set and skip.
        for d in drafts:
            if not d.get("mirrored_to_owner_at"):
                print(json.dumps({
                    "action": "mirror_now",
                    "query_id": fm["query_id"],
                    "draft_id": d.get("draft_id"),
                }))


# ---------------------------------------------------------------------------
# Argparse
# ---------------------------------------------------------------------------

def build_parser():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    p.add_argument("--brain-dir", default=os.environ.get("BRAIN_DIR", "/opt/data/home/brain"))
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("create-query")
    s.add_argument("--query-id", required=True)
    s.add_argument("--conv-id", required=True)
    s.add_argument("--msg-id", required=True)
    s.add_argument("--content", required=True)
    s.add_argument("--owner-mirror-key", required=True)
    s.add_argument("--asks-json", required=True)
    s.add_argument("--title")
    s.add_argument("--property-id")
    s.set_defaults(func=cmd_create_query)

    s = sub.add_parser("write-answer")
    s.add_argument("--query-id", required=True)
    s.add_argument("--ask-id", required=True)
    s.add_argument("--answer-file")
    s.add_argument("--answer-text")
    s.set_defaults(func=cmd_write_answer)

    s = sub.add_parser("repinging")
    s.add_argument("--query-id", required=True)
    s.add_argument("--ask-id", required=True)
    s.add_argument("--new-ping-count", type=int, required=True)
    s.add_argument("--new-asked-at", required=True)
    s.set_defaults(func=cmd_repinging)

    s = sub.add_parser("escalate")
    s.add_argument("--query-id", required=True)
    s.add_argument("--ask-id", required=True)
    s.add_argument("--draft-content", required=True)
    s.set_defaults(func=cmd_escalate)

    s = sub.add_parser("append-draft")
    s.add_argument("--query-id", required=True)
    s.add_argument("--kind", choices=["partial", "final", "escalate-notice"], required=True)
    s.add_argument("--content-file", required=True)
    s.add_argument("--draft-id")
    s.set_defaults(func=cmd_append_draft)

    for name, fn in [
        ("mark-mirrored", cmd_mark_mirrored),
        ("mark-approved", cmd_mark_approved),
        ("mark-rejected", cmd_mark_rejected),
        ("mark-auto-shipped", cmd_mark_auto_shipped),
    ]:
        s = sub.add_parser(name)
        s.add_argument("--query-id", required=True)
        s.add_argument("--draft-id", required=True)
        s.set_defaults(func=fn)

    s = sub.add_parser("mark-delivered")
    s.add_argument("--query-id", required=True)
    s.add_argument("--draft-id", required=True)
    s.add_argument("--close", action="store_true")
    s.set_defaults(func=cmd_mark_delivered)

    s = sub.add_parser("show")
    s.add_argument("--query-id", required=True)
    s.set_defaults(func=cmd_show)

    s = sub.add_parser("latest-pending-approve")
    s.add_argument("--kind", default="final", choices=["final", "partial", "escalate-notice"])
    s.set_defaults(func=cmd_latest_pending_approve)

    s = sub.add_parser("tick")
    s.add_argument("--sla-minutes", default=os.environ.get("AIRBNB_COURIER_SLA_MINUTES", "30"))
    s.add_argument("--escalation-minutes", default=os.environ.get("AIRBNB_COURIER_ESCALATION_MINUTES", "60"))
    s.add_argument("--partial-staleness-seconds", default=os.environ.get("AIRBNB_COURIER_PARTIAL_STALENESS_SECONDS", "300"))
    s.set_defaults(func=cmd_tick)

    return p


def main():
    args = build_parser().parse_args()
    brain_dir = pathlib.Path(args.brain_dir)
    args.func(args, brain_dir)


if __name__ == "__main__":
    main()
