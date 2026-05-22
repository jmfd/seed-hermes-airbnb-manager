---
name: str-manager-approval
description: Boss skill for short-term rental coordination. Handles Hostex message_created callbacks, classifies guest messages, routes async asks to team members via plow_chat REST, drafts cited client replies when team answers arrive, and mirrors all client-facing drafts to the owner for approval. Replaces the legacy v9.0.0 pirate-joker skill while preserving the no-consult fast path (Trial Reel demo continuity) and the v9.0.0 Hostex POST contract.
version: 10.0.0
---

# airbnb-coordinator-boss (installed as str-manager-approval)

The skill is INSTALLED under the legacy name `str-manager-approval` because the
existing Hostex webhook subscription on the owner profile references
`--skills str-manager-approval`. Renaming would break that subscription.
Frontmatter `version: 10.0.0` signals the breaking semantic change.

State files:

- Pending pirate approvals (legacy v9.0.0 path):
  `/opt/data/home/.airbnb-manager/pirate-joker-pending.json`
- Outbox audit log (legacy v9.0.0 path):
  `/opt/data/home/.airbnb-manager/outbox.jsonl`
- Coordinator query pages (NEW, the durable state for in-flight consults):
  `/opt/data/home/brain/queries/q-<datetime>-<conv-short>.md`
- Team role pages (NEW, the routing input):
  `/opt/data/home/brain/team/<member-slug>.md`
- Property pages (NEW, the per-property team assignment input):
  `/opt/data/home/brain/properties/<property-slug>.md`

The webhook subscription's prompt template provides:
- `platform=<name>` — owner approval channel
- `chat_id=<value>` — owner approval channel chat id
- `hostex_base_url=<url>` — Hostex API base
- `hostex_access_token=<token>` — Hostex API token

The boss skill ALSO reads these env vars (set by the install script into
the owner profile `.env`):
- `PLOW_CHAT_BASE_URL` — Plow Chat REST/WSS base (default `https://chat.plow.co`)
- `TEAM_CHAT_SECRETS_FILE` — path to a per-team-member secret-key file
  written by the install script at `/opt/data/home/.airbnb-coordinator/team-secrets.json`,
  mode 600, shape `{ "<team_member_uid>": "<X-Chat-Secret-Key>" }`.
- `AIRBNB_OWNER_MIRROR_SESSION_KEY` — the Hermes session key for owner mirrors,
  e.g. `agent:main:telegram:dm:123456789`

## Hostex callback shape (UNCHANGED from v9.0.0)

```json
{
  "event": "message_created",
  "conversation_id": "<conv-id>",
  "message_id": "<msg-id>",
  "timestamp": "<iso8601>"
}
```

There is no message content and no `sender_role` in the callback. To handle it,
call `GET /v3/conversations/{conversation_id}` and find the message in
`data.messages[]` whose `id` equals `message_id`.

Every Hostex API call, GET and POST, MUST include:
- `Hostex-Access-Token: <hostex_access_token>`
- `User-Agent: curl/8.7.1`

Use `Content-Type: application/json` on POST.

## Trigger 1: Hostex message_created callback

Activates when the user message contains a JSON object with
`event == "message_created"` and top-level `conversation_id` and `message_id`.
Any other payload shape -> do not engage.

Procedure:

1. Parse the callback's top-level `conversation_id` and `message_id`.
2. Fetch full conversation detail:
   - `GET {hostex_base_url}/v3/conversations/{conversation_id}`
   - Headers: `Hostex-Access-Token: {hostex_access_token}`, `User-Agent: curl/8.7.1`
3. Parse the response JSON. Use `data.id` as `conversation_id`. Find the message
   in `data.messages[]` where `id == message_id`.
4. If the referenced message is absent, STOP with a short webhook-log status.
5. If the fetched message's `sender_role` is anything other than `"guest"`,
   STOP silently. (Prevents feedback loops from agent's own host messages.)
6. Read:
   - `content` from the fetched message
   - guest name from `data.guest.name`, defaulting to `guest`
   - property id from the first `data.activities[].property.id`, if present;
     call this `guest_property_id`

7. **Decide: does this need team consult?**
   - List `/opt/data/home/brain/team/*.md`. For each, read the YAML frontmatter
     (`role`, `member_uid`, `active`, `display_name`) and the body (free-text).
     Build a candidate set of all team members where `active != false`.
   - If `guest_property_id` is set AND `/opt/data/home/brain/properties/<slug>.md`
     exists for that property AND has `team_assignments.<role>` entries, prefer
     those specific `member_uid`s over the global candidate set for matching roles.
   - LLM-classify: given the guest's message + the candidate role/notes pages,
     produce a list of `(team_member_uid, role, question_text)` tuples. Empty
     list means "no team consult needed". If multiple team members could
     answer (e.g. both a cleaner AND a handyman are relevant for a 2-part
     question), produce one tuple per team member.

8a. **NO CONSULT NEEDED — legacy v9.0.0 fast path (Trial Reel demo).**
   (FAQ slot — optional) Read `/opt/data/profiles/<owner>/data/faq.jsonl`
   if it exists and is non-empty. Use it as context.

   Draft ONE short ENGLISH PIRATE JOKE riffing on the fetched message content.
   Pirate vocabulary required: use at least one of `arrr`, `ahoy`, `ye`,
   `treasure`, `parrot`, `plank`, `scurvy`, `matey`, or `hearties`. No Italian.

   Read `/opt/data/home/.airbnb-manager/pirate-joker-pending.json` (`{}` if missing).
   Set key `<message_id>` to:
   ```json
   {
     "id": "<message_id>",
     "conversation_id": "<conversation_id>",
     "property_id": "<guest_property_id-or-empty>",
     "property_title": "<property-title-or-empty>",
     "from": "<guest-name>",
     "content": "<fetched-message-content>",
     "draft": "<joke>"
   }
   ```
   Write back atomically.

   Deliver via the `send_message` tool with content:
   ```
   [B] external #<message_id> property=<property-id-or-empty> from <guest-name>: "<fetched-message-content>"
   DRAFT: "<joke>"
   message_id="<message_id>"
   Reply: approve / reject / edit <text>
   ```

   STOP. The webhook session's final response is a short status string.

8b. **CONSULT NEEDED — new coordinator path.**
   - Compute a query_id: `q-$(date -u +%Y%m%d-%H%M%S)-${conversation_id:0:8}`.
   - Compute path: `/opt/data/home/brain/queries/<query_id>.md`.
   - For each tuple `(team_member_uid, role, question_text)`:
     - Append an entry to `asks[]` with `ask_id: ask-<N>`, `team_member_uid`,
       `role`, `question`, `asked_at`, `original_asked_at` (== `asked_at`),
       `ping_count: 1`, `sla_deadline: asked_at + AIRBNB_COURIER_SLA_MINUTES`,
       `escalation_deadline: asked_at + AIRBNB_COURIER_ESCALATION_MINUTES`,
       `status: pending`.
   - Write the page atomically (via temp + rename) with full frontmatter +
     a short body summary (for cat/grep debugging).
   - For each ask, POST to plow_chat:
     ```
     POST {PLOW_CHAT_BASE_URL}/v1/chats/{team_member_uid}/messages
     Headers:
       X-Chat-Secret-Key: <team_member_uid's key from TEAM_CHAT_SECRETS_FILE>
       Content-Type: application/json
     Body:
       { "content": "QUERY_ID=<query_id>\n<question_text>" }
     ```
     Expect 200/201. On error, append a note to the query page's
     `asks[<n>].notes` field and continue with the other asks.
   - `cd /opt/data/home/brain && git add queries/<query_id>.md &&
     git commit -m "coordinator: new query <query_id>"`
   - Append a partial draft entry to `drafts[]` with kind `partial`, content
     `"Working on it — checking with <one or more team member display names>
     now. I'll get back to you shortly."`, `drafted_at` set.
   - Deliver the partial draft via `send_message` with content:
     ```
     [B] external #draft-1 query=<query_id> from <guest-name>: "<fetched-message-content>"
     PARTIAL DRAFT: "<partial draft text>"
     query_id="<query_id>"
     draft_id="draft-1"
     Reply: approve / reject / edit <text>
     ```
     Set the draft entry's `mirrored_to_owner_at`.
   - Commit again with message `coordinator: partial draft for <query_id>`.
   - STOP. Webhook session's final response is a short status string.

## Trigger 2: owner reply about a pending draft (UNCHANGED v9.0.0 semantics + draft kind awareness)

Activates when the owner sends a message in a session whose recent history
contains a mirrored `[B] external #<ref-id>` agent turn.

The referenced id is parsed from THAT mirror turn. Do not choose "the most
recent pending entry". For pirate drafts, `ref-id` is the Hostex
`message_id`; for coordinator drafts, `ref-id` is `draft-<N>` and the
mirror line additionally contains `query_id=<query_id>`.

Classify the owner's reply:
- **approve** — `approve`, `yes`, `looks good`, `va bene`, `send`.
- **reject** — `reject`, `no`, `don't send`, `cancel`, `non mandare`.
- **edit** — wants the draft changed; includes natural-language feedback
  in any language: `shorter`, `more polite`, `try in Portuguese`, etc.
- **unrelated** — off-topic; fall through to default persona.

### Branch A — approve (UNCHANGED Hostex POST contract)

This branch is identical to v9.0.0 EXCEPT for the additional bookkeeping
when the referenced draft is a coordinator draft.

1. Look up the pending entry by the referenced id:
   - PIRATE: read `/opt/data/home/.airbnb-manager/pirate-joker-pending.json`
     keyed by Hostex `message_id`. Pull `conversation_id` and `draft`.
   - COORDINATOR: read `/opt/data/home/brain/queries/<query_id>.md`, find
     the draft in `drafts[]` matching the referenced `draft_id`. Pull
     `guest_conversation_id` and the draft `content`.
2. Get a UTC timestamp: `date -u +%Y-%m-%dT%H:%M:%SZ`.
3. Ship to guest via Hostex API (UNCHANGED CONTRACT):
   - `POST {hostex_base_url}/v3/conversations/{conversation_id}`
   - Headers: `Hostex-Access-Token: {hostex_access_token}`,
     `User-Agent: curl/8.7.1`, `Content-Type: application/json`
   - Body: `{"message":"<draft>"}`
   - Expect 200 or 202. On error, write outbox with `delivered:false` and
     error note; reply to owner `Errore consegnando a hostex: <reason>` and
     STOP. Do not remove the pending entry / mutate the query page so the
     owner can retry.
4. Append a JSONL line to `/opt/data/home/.airbnb-manager/outbox.jsonl`:
   ```json
   {"ts":"<timestamp>","id":"<ref-id>","conversation_id":"<conv>","approved":true,"delivered":true,"sent_content":"<draft>"}
   ```
5. POST-SHIP BOOKKEEPING:
   - PIRATE: remove the processed id from `pirate-joker-pending.json`; write back.
   - COORDINATOR: acquire flock on the query page, set the draft's
     `approved_at` and `delivered_at`. If the draft `kind == "final"`, set
     the query page's `status: closed` and `closed_at`. If `kind == "partial"`,
     leave the page open (status stays `partial` if it was `partial`, or moves
     `open` -> `partial` on first partial approval). Release flock.
     `cd /opt/data/home/brain && git add queries/<query_id>.md &&
     git commit -m "coordinator: approved <draft_id> for <query_id>"`.
6. Reply briefly to the owner with one short confirmation, e.g.
   `Aye, draft be sailin' out!` (for pirate) or `Sent.` (for coordinator).

### Branch B — reject

1. Append to outbox.jsonl:
   ```json
   {"ts":"<ts>","id":"<ref-id>","conversation_id":"<conv>","approved":false,"delivered":false,"sent_content":"<draft>"}
   ```
2. Do NOT call the Hostex API.
3. POST-REJECT BOOKKEEPING:
   - PIRATE: remove the referenced id from pending; write back.
   - COORDINATOR: acquire flock, set draft's `rejected_at`. Leave page open
     (a future ask result + courier wake may produce a different draft).
     git add + commit.
4. Reply: `Arrr, that one be walkin' the plank.` (pirate) or `Rejected.` (coord).

### Branch C — edit

1. Generate a NEW draft incorporating the owner's feedback. For pirate path,
   pirate vocabulary still required. For coordinator path, the new draft MUST
   still cite team answers from the query page verbatim and MUST NOT invent
   facts.
2. POST-EDIT BOOKKEEPING:
   - PIRATE: update only the referenced pending entry's `draft` field.
     Write pending back.
   - COORDINATOR: append a new draft entry to `drafts[]` with incremented
     `draft_id` (e.g. `draft-2`), same `kind` as the previous draft, new
     `content`, new `drafted_at`. git add + commit.
3. Reply with the same approval-template format as the original mirror,
   preserving the same `#<ref-id>` (pirate) or new `#draft-<N>` (coord).
   Do NOT write outbox, do NOT call Hostex API.

### Branch D — plan-request (REPLACED — now handled by Trigger 1 step 8b)

The v9.0.0 stub is GONE. If the owner explicitly requests a multi-step
action (e.g. "approve and tell the cleaner X"), reply:
`That's a multi-step ask. The team-consult flow auto-fans-out on guest
messages; for ad-hoc team pings, edit the relevant team brain page or
ping them yourself for now.`
STOP. Do not mutate state.

## Trigger 3: courier wakeAgent (NEW)

Activates when a wakeAgent prompt includes the literal token `query_id=`.
The prompt's format is `draft reply for query_id=<id>; read /opt/data/home/brain/queries/<file>`.

Procedure:

1. Parse `query_id` from the prompt.
2. Acquire flock on `/opt/data/home/brain/queries/<query_id>.md`.
3. Read the page's frontmatter.
4. Determine draft kind:
   - If ALL asks have `status` in `{answered, escalated, timed_out}` AND no
     existing `drafts[]` entry has `kind: final`: draft `kind: final`.
   - Else if AT LEAST ONE ask has `status: answered` AND no existing partial
     draft has `drafted_at` within the last 5 minutes AND at least one ask
     is still `pending`: draft `kind: partial`.
   - Else: nothing to do (idempotent — already drafted this state). Release
     flock and STOP.
5. Compose the draft:
   - Read the guest's original message from `guest_message_content`.
   - For each ask with `status: answered`, read `ask.answer` (team's verbatim
     reply). For each ask with `status: escalated`, note "We're still checking
     with <role>" or similar.
   - Produce a single client-facing reply that addresses the guest's question
     using ONLY the information in the asks' answers + the property page (if
     `guest_property_id` is set). Do not invent facts. Cite team answers
     verbatim where natural ("The cleaner confirmed it'll be ready by 12:30").
6. Append a draft entry to `drafts[]` with the next `draft_id`, the chosen
   `kind`, the composed `content`, `drafted_at` set.
7. Mirror the draft to the owner via send_message:
   ```
   [B] external #draft-<N> query=<query_id> from <guest-name>: "<guest_message_content>"
   <FINAL or PARTIAL> DRAFT: "<draft text>"
   query_id="<query_id>"
   draft_id="draft-<N>"
   Reply: approve / reject / edit <text>
   ```
   Set the draft's `mirrored_to_owner_at`.
8. Release flock.
9. `cd /opt/data/home/brain && git add queries/<query_id>.md &&
   git commit -m "coordinator: draft <kind> for <query_id>"`.

## Hard rules

- ONE inbound Hostex contract: real `message_created` callback (UNCHANGED).
- The callback is top-level `conversation_id` + `message_id`; never expect
  message content or `sender_role` in the callback.
- Trigger 1 MUST fetch `GET /v3/conversations/{conversation_id}` before
  reading content or `sender_role`.
- `sender_role == "host"` events from the fetched conversation are ignored.
- Every Hostex GET and POST includes `User-Agent: curl/8.7.1`.
- Approve uses `POST /v3/conversations/{conversation_id}` with body field
  `message` (UNCHANGED v9.0.0 contract).
- Pirate voice = English only. Coordinator drafts are language-matched to
  the guest's message (English in / English out).
- Edit classification is semantic. Never substring matching.
- Trigger 1 MUST call `send_message` so Hermes mirrors the approval request.
- Branch A MUST call Hostex API. The outbox is an audit trail, not delivery.
- Platform/chat_id/Hostex URL/Hostex token come from the webhook subscription
  prompt; PLOW_CHAT_BASE_URL and TEAM_CHAT_SECRETS_FILE come from env;
  AIRBNB_OWNER_MIRROR_SESSION_KEY comes from env. None hardcoded.
- All query page reads/writes hold a flock on the page file.
- All query page writes are followed by `git add` + `git commit` in
  `/opt/data/home/brain/`.
- Drafts cite team answers VERBATIM. Never invent facts the team didn't say.
- The boss skill NEVER POSTs to plow_chat with guest-facing content — only
  with team-facing question text. Guest-facing content ships via Hostex on
  owner approval.
