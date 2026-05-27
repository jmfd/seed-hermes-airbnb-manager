---
name: airbnb-team-listener
description: Info-capture-only listener for the team-side Hermes profile. Receives team-member messages on plow_chat, finds the matching open ask in /opt/data/home/brain/queries/q-*.md, records the team member's verbatim reply via the query-edit.py helper (which owns flock + atomic write + git commit), and acknowledges briefly in chat. Never sends to guests; never mirrors to owner channels.
version: 1.0.0
---

# airbnb-team-listener

This skill runs on the TEAM profile (operator-chosen handle, e.g. `owner-team`). The team
profile MUST NOT have any client-facing platforms enabled — no Hostex webhook,
no telegram owner channel. The installer rejects the install if those platforms
are present in the team profile's `config.yaml`.

The ONLY outbound message this skill produces is a brief "Got it, thanks."
back to the team member in their own plow_chat.

## Mutation contract

The skill NEVER writes raw YAML to query pages. Every mutation goes through:

```bash
python3 /opt/data/home/airbnb-courier/query-edit.py write-answer \
  --query-id <id> --ask-id <id> --answer-file /tmp/answer.txt
```

The helper owns flock + atomic write + git commit. Preserving the team
member's reply VERBATIM (whitespace, emoji, multi-line) is the helper's
guarantee — do not "clean up" the reply in the skill.

## Trigger A: outbound boss-ask delivery (informational, no-op)

When the team profile's plow_chat adapter delivers an outbound message FROM
this profile to a team member (only happens if your install routes boss-asks
through this profile's adapter instead of REST POST — non-standard topology),
no skill action is required. Logs only.

## Trigger B: inbound team-member message

Activates when an inbound plow_chat message arrives on a chat whose
`chat_id` matches a `member_uid` in one of `/opt/data/home/brain/team/*.md`.

Procedure:

1. Extract the inbound `chat_id` (plow_chat chat uid) and the message body.

2. List `/opt/data/home/brain/team/*.md`. Parse YAML frontmatter `member_uid`
   from each. If `chat_id` does NOT match any team page's `member_uid`,
   reply briefly in chat:
   `Got it, but I don't recognize this chat. Letting the owner know.`
   Then STOP. (Unrecognized-team-member is a misconfiguration, not a flow.)

3. Find the open ask. List `/opt/data/home/brain/queries/q-*.md` sorted by
   mtime descending. For each, run:
   ```bash
   python3 /opt/data/home/airbnb-courier/query-edit.py show --query-id <id>
   ```
   Parse the JSON. Find the most recent ask where `team_member_uid == chat_id`
   AND `status == "pending"`.

4. If no open ask is found:
   - Reply briefly: `Got it, but there's no open question for you right now.`
   - STOP. Do NOT mutate any brain page. Do NOT POST to Hostex (the team
     profile has no Hostex platform anyway). Do NOT mirror to any owner channel.

5. If an open ask is found:
   ```bash
   # Write the team reply verbatim to a temp file so multi-line content survives.
   printf '%s' "<verbatim team reply text>" > /tmp/answer.txt
   python3 /opt/data/home/airbnb-courier/query-edit.py write-answer \
     --query-id <id> --ask-id <ask_id> --answer-file /tmp/answer.txt
   ```
   The helper:
   - flocks the page,
   - re-reads under the lock (if the targeted ask is no longer `pending`,
     it logs and exits 0 with a no-op),
   - sets `ask.answer`, `ask.answered_at`, `ask.status = answered`,
   - sets the page `updated_at`,
   - bumps page `status` from `open` to `partial` if needed,
   - atomically writes the page,
   - `git add` + `git commit -m "coordinator: team answer for <id>/<ask_id>"`.

6. Reply briefly in the team chat: `Got it, thanks.`

The next courier tick (within 60 seconds by default) will pick up the state
change and wake the boss profile to draft a reply. The listener does nothing
else.

## Hard rules

- NEVER POST to Hostex. The team profile doesn't have Hostex credentials
  configured anyway, but don't try.
- NEVER mirror anything to the owner approval channel.
- NEVER fan out additional plow_chat messages to other team members.
- NEVER call the boss profile directly. The courier wakes the boss on tick.
- NEVER read or write `/opt/data/home/.airbnb-manager/pirate-joker-pending.json`
  or `/opt/data/home/.airbnb-manager/outbox.jsonl`. Those are owner-profile artifacts.
- ALWAYS go through `/opt/data/home/airbnb-courier/query-edit.py` for mutations.
- ALWAYS preserve team-member message text VERBATIM — write to a tmp file
  via `printf '%s'` (no `echo` — `echo` interprets backslashes). The helper
  strips only one trailing newline (the IO artifact).
- If multiple team pages match the inbound `chat_id` (misconfiguration), use
  the FIRST match. Don't try to disambiguate.
- The acknowledgement reply is OPTIONAL but RECOMMENDED. Set
  `AIRBNB_LISTENER_ACK_DISABLED=1` in the team profile `.env` to suppress.
