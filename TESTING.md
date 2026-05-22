# TESTING

## Pre-merge gates

CI runs on every push and PR:

- `bash -n` on every `ref/scripts/*.sh` and `ref/courier/*.sh` (parser-clean).
- SEED.md presence + RFC 2119 declaration grep.
- README.md install-order section grep.
- Heredoc + secret-hygiene check: no committed `sk_*`, `tok_*`, `bearer-*`,
  no committed `.env` files (the `.env` in `.gitignore` is enforced).

## Local verification

Use `ref/verify.sh` after running the installer:

```bash
./ref/verify.sh --scaffold ../hermes-agent
```

The verify script covers 9 checks (V1-V9 in SEED.md `## Verify`). Two are
CRITICAL REGRESSION gates that exercise the live Trial Reel demo path:

- **V6:** v9.0.0 pirate fast path still drafts pirate vocabulary + mirrors
  to owner against the captured `hostex-message_created.json` wire sample.
- **V7:** v9.0.0 Branch A POST to Hostex still ships
  `{"message":"<draft>"}` to `/v3/conversations/<conv-id>` with
  `User-Agent: curl/8.7.1`.

These MUST pass before any /ship. They prove the new boss skill did not
break the demo running today.

## What `verify.sh` does NOT cover (deferred)

- LLM-quality evals on routing decisions (boss picks the right team member
  given a guest message). These need a separate eval harness and are
  flagged in `TODOS.md` for a follow-up PR.
- Concurrent-writer fuzz on the same `queries/q-*.md` page (flock contention).
  The flock + atomic-rename path is verified by a single unit test in V8
  but not stressed.
- Failure injection for `wakeAgent` (e.g. Hermes process not responding).
  The courier sidecar exits non-zero on consecutive wake failures and
  Compose restarts it; not exercised here.

## Manual acceptance

After `verify.sh` passes, do a real-world smoke:

1. From your phone, send an iMessage that says "Can the guest check in
   at 1pm?" via the cleaner's plow_chat. (You're playing the role of the
   cleaner answering a synthetic boss-asked question.)
2. Watch the listener profile's session log for a "Got it, thanks." reply
   from the listener skill.
3. Watch the owner-approval channel for the boss's drafted reply mirror.
4. Approve. Watch Hostex for the outgoing message.

If steps 1-4 all happen end-to-end with no manual routing by you, the
install is good.
