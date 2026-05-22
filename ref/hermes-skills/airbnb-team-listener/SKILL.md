---
name: airbnb-team-listener
description: Info-capture-only listener for the team-side Hermes profile. Receives team-member messages on plow_chat, finds the matching open ask in /opt/data/home/brain/queries/q-*.md, records the team member's verbatim reply into the page, and acknowledges briefly in chat. Never sends to guests; never mirrors to owner channels. The boss profile handles guest-facing drafts on the next courier tick.
version: 1.0.0
---

# airbnb-team-listener

This skill runs on the TEAM profile (default name `daniel-team`). The team
profile MUST NOT have any client-facing platforms enabled — no Hostex webhook,
no telegram owner channel. The only outbound channel from this skill is back
into the team member's own plow_chat for a brief "Got it, thanks." reply.

## Trigger A: outbound boss-ask delivery (informational)

When the plow_chat adapter on this profile delivers an outbound
`QUERY_ID=...` message FROM this profile to a team member, the adapter
already logs the delivery in the session log. No skill action is required.
The boss profile already wrote the query page before POSTing the ask via
REST; the team listener never has to write on outbound.

(If your install bound BOSS-side asks to come through the TEAM profile's
plow_chat adapter instead of REST POST, that's a non-standard topology and
this skill does not support it.)

## Trigger B: inbound team-member message

Activates when an inbound plow_chat message arrives on a chat whose
`chat_id` matches a `member_uid` in one of `/opt/data/home/brain/team/*.md`.

Procedure:

1. Extract `chat_id` (the plow_chat chat uid) and the message body from the
   inbound event.
2. List `/opt/data/home/brain/team/*.md`. For each, parse YAML frontmatter
   `member_uid`. If `chat_id` does not match any team page's `member_uid`,
   reply briefly in chat: `Got it, but I don't recognize this chat. Letting
   the owner know.` Then STOP.
3. List `/opt/data/home/brain/queries/q-*.md` sorted by mtime descending.
   For each page, parse YAML frontmatter, scan `asks[]` for the most recent
   entry where `team_member_uid == chat_id` AND `status == "pending"`.
4. If no open ask is found, reply briefly in chat: `Got it, but there's no
   open question for you right now.` Then STOP. Do NOT mutate any brain
   page. Do NOT POST to Hostex. Do NOT mirror to any owner channel.
5. If an open ask is found:
   - Acquire flock on the query page file (`flock /opt/data/home/brain/queries/<file>`).
   - Re-read frontmatter (the page may have been touched by the courier
     between step 3 and now; the most-recent flocked-read view wins).
   - If the targeted ask's `status` is no longer `pending` (already
     `answered` or `escalated`), release flock, reply `Got it — already
     covered, thanks.`, STOP.
   - Set the ask's `answer = <verbatim team message body>` (preserve all
     whitespace and emoji; do not trim except trailing newline).
   - Set the ask's `answered_at = <UTC now ISO 8601>`.
   - Set the ask's `status = answered`.
   - Set the page's `updated_at = <UTC now>`.
   - Write the page atomically (tmpfile + rename), release flock.
6. `cd /opt/data/home/brain && git add queries/<file> &&
   git commit -m "coordinator: team answer for <query_id>/<ask_id>"`.
7. Reply briefly in the team chat: `Got it, thanks.`

The next courier tick (within 60 seconds by default) will pick up the
state change and wake the boss profile to draft a reply.

## Hard rules

- NEVER POST to Hostex. The team profile doesn't have Hostex credentials
  in its env, but don't try anyway.
- NEVER mirror anything to the owner approval channel.
- NEVER fan out additional plow_chat messages to other team members.
- NEVER call the boss profile directly. The courier does that on tick.
- NEVER read or write `/opt/data/home/.airbnb-manager/pirate-joker-pending.json`
  or `/opt/data/home/.airbnb-manager/outbox.jsonl`. Those are owner-profile
  artifacts.
- ALWAYS acquire flock on the query page before read+write.
- ALWAYS git add + commit after writing.
- ALWAYS preserve team member message text VERBATIM in `ask.answer`. The
  boss profile cites verbatim when drafting; trimming or "cleaning up" the
  reply breaks the citation contract.
- If multiple team members might match (a single team member listed twice
  under different `member_uid`s — misconfiguration), use the FIRST match.
  Don't try to be clever.
- The acknowledgement reply (`Got it, thanks.`) is OPTIONAL but
  RECOMMENDED. If the chat is high-volume and an ack would be noisy, set
  `AIRBNB_LISTENER_ACK_DISABLED=1` in the team profile `.env` to suppress.
