---
name: str-manager-approval
description: Boss skill for short-term rental coordination. Handles Hostex message_created callbacks, classifies guest messages, routes async asks to team members via plow_chat REST, drafts cited client replies when team answers arrive, and mirrors all client-facing drafts to the owner for approval. Replaces the legacy v9.0.0 pirate-joker skill while preserving the no-consult fast path (Trial Reel demo continuity) and the v9.0.0 Hostex POST contract verbatim.
version: 10.0.0
---

# airbnb-coordinator-boss (installed as str-manager-approval)

The skill is INSTALLED under the legacy name `str-manager-approval` because the
existing Hostex webhook subscription on the owner profile references
`--skills str-manager-approval`. Renaming would break the subscription.
Frontmatter `version: 10.0.0` signals the breaking semantic change.

## State files

Legacy v9.0.0 fast-path state (UNCHANGED, the pirate path uses these verbatim):
- `/opt/data/home/.airbnb-manager/pirate-joker-pending.json` — pending pirate drafts keyed by Hostex `message_id`.
- `/opt/data/home/.airbnb-manager/outbox.jsonl` — append-only audit log of every approved/rejected/delivered draft.

Coordinator durable state (NEW, the consult path):
- `/opt/data/home/brain/queries/q-<datetime>-<conv>.md` — one page per in-flight cross-team query. THE AUTHORITATIVE STATE.
- `/opt/data/home/brain/team/<member-slug>.md` — role + responsibilities per team member (read-only at runtime).
- `/opt/data/home/brain/properties/<property-slug>.md` — property info + optional per-role team assignments (read-only).

**IMPORTANT: NEVER write to query pages with raw YAML.** Always invoke the
helper at `/opt/data/home/airbnb-courier/query-edit.py`. It owns flock + atomic
write + git commit. Constructing YAML by hand is forbidden — it breaks the
"preserve answer verbatim" contract and races with the courier sidecar.

## Live occupancy & guest state (hostex-context)

Static brain facts describe *policy*; the `hostex-context` skill tells you the
*current answer*. Its read-only tools live at `/opt/data/home/hostex-context/hxctx`
and pull live from Hostex (the single source of truth — no cache/mirror). Reach for
them whenever a guest message or your draft depends on who is booked / checked in /
arriving, or on check-in / check-out timing.

Every `hxctx` call takes `--base-url "<hostex_base_url>" --token "<hostex_access_token>"`
using the SAME webhook-prompt values you use for the Hostex GET/POST calls — these are
never hardcoded and never read from a static file.

- **At classification (Trigger 1 step 7):** run
  `python3 /opt/data/home/hostex-context/hxctx --base-url "<hostex_base_url>" --token "<hostex_access_token>" guest-state --conversation <conversation_id>`.
  The returned `state` (`curious_browser | inquiry_pending | future_guest |
  arriving_today | checked_in_midstay | checking_out_today | past_guest |
  cancelled`) anchors tone and the consult decision. A question the live data
  already answers (e.g. early check-in when the night before is booked) may need
  **no** team consult — draft directly.
- **At drafting (step 8a, step 8b.5, and Trigger 3 step 4):** for any timing or
  occupancy claim, call `hxctx occupancy --property <id> --date <D>` (early-checkin /
  late-checkout feasibility), `hxctx calendar --property <id> --start <D1> --end <D2>`,
  `hxctx reservations …`, or `hxctx schedule …`. Ground the reply in the live result;
  never paste raw JSON to the guest. When live state and a static fact conflict, the
  live state wins.

These tools are READ-ONLY and never message the guest — delivery still flows through
the owner-approval + Hostex POST path below. See the skill's own SKILL.md for how to
fold results into a draft (including the same-day-booking caveat for early check-in).

## Env vars (set by the installer into the owner profile `.env`)

- `PLOW_CHAT_BASE_URL` — Plow Chat REST base, default `https://chat.plow.co`
- `TEAM_CHAT_SECRETS_FILE` — JSON map `{team_member_uid: X-Chat-Secret-Key}`, default `/opt/data/home/.airbnb-coordinator/team-secrets.json`, mode 600
- `AIRBNB_OWNER_MIRROR_SESSION_KEY` — Hermes session key for owner-channel mirrors (e.g. `agent:main:telegram:dm:<chat_id>`)
- `AIRBNB_COURIER_SLA_MINUTES` — default 30, used when creating asks
- `AIRBNB_COURIER_ESCALATION_MINUTES` — default 60, used when creating asks
- `BRAIN_DIR` — default `/opt/data/home/brain`

These are read at runtime via the shell environment. They are NEVER prompt-injected.

## Hostex callback shape (UNCHANGED v9.0.0 contract)

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

Procedure (steps 1-6 UNCHANGED from v9.0.0):

1. Parse the callback's top-level `conversation_id` and `message_id`.
2. Fetch full conversation detail:
   - `GET {hostex_base_url}/v3/conversations/{conversation_id}`
   - Headers: `Hostex-Access-Token: {hostex_access_token}`, `User-Agent: curl/8.7.1`
3. Parse response JSON. Use `data.id` as `conversation_id`. Find the message
   in `data.messages[]` where `id == message_id`.
4. If the referenced message is absent, STOP with a short webhook-log status.
5. If the fetched message's `sender_role` is not `"guest"`, STOP silently.
6. Read:
   - `content` from the fetched message
   - guest name from `data.guest.name`, defaulting to `guest`
   - property id/title from the first `data.activities[].property`, if present

7. **Decide: does this need team consult?** (NEW step.)
   - List `/opt/data/home/brain/team/*.md`. For each, read the YAML frontmatter
     (`role`, `member_uid`, `active`, `display_name`) and the body. Build a
     candidate set where `active != false`.
   - If `guest_property_id` is set AND `/opt/data/home/brain/properties/<slug>.md`
     exists AND has `team_assignments.<role>` entries, prefer those specific
     `member_uid`s over the global candidate set for matching roles.
   - LLM-classify: given the guest message + the candidate role/notes pages,
     produce a list of `(team_member_uid, role, question_text)` tuples. Empty
     list means "no consult needed". If multiple roles could answer, produce
     one tuple per team member.

### 8a — NO CONSULT NEEDED (legacy v9.0.0 pirate fast path, preserved verbatim)

This branch is unchanged from `seedlab/seeds/airbnb-manager.seed.md` v9.0.0,
steps 7-11. The Trial Reel demo depends on this path producing bit-identical
behavior to v9.0.0 when the classifier returns "no consult needed".

7. (FAQ slot — optional) Read `/opt/data/profiles/<owner>/data/faq.jsonl`
   if it exists and is non-empty. Use it as context when drafting.
8. Draft ONE short ENGLISH PIRATE JOKE riffing on the fetched message
   content. Pirate vocabulary REQUIRED: use at least one of `arrr`, `ahoy`,
   `ye`, `treasure`, `parrot`, `plank`, `scurvy`, `matey`, or `hearties`.
   No Italian.
9. Read `/opt/data/home/.airbnb-manager/pirate-joker-pending.json` (`{}` if
   missing or empty). Set key `<message_id>` to:
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
   Write back atomically (tmp + rename).
10. Deliver via the `send_message` tool. This is MANDATORY — it triggers
    `gateway.mirror.mirror_to_session`, putting the draft in the owner's
    session for later approval context.
    - platform: the `platform` value from the webhook subscription prompt template
    - chat_id: the `chat_id` value from the prompt template
    - content (multi-line):
      ```
      [B] external #<message_id> property=<property-id-or-empty> from <guest-name>: "<fetched-message-content>"
      DRAFT: "<joke>"
      message_id="<message_id>"
      Reply: approve / reject / edit <text>
      ```
11. After `send_message` returns, the webhook session's final response is a
    short status string that goes only to the webhook log. STOP.

### 8b — CONSULT NEEDED (coordinator path)

For each `(team_member_uid, role, question_text)` tuple from step 7:

8b.1. Compute `query_id = q-$(date -u +%Y%m%d-%H%M%S)-${conversation_id:0:8}`.

8b.2. Build the asks JSON array (one entry per team member):
```bash
ASKS_JSON='[{"team_member_uid":"cht_abc","role":"cleaner","question":"Can guest <name> check in at 1pm at <property>?","sla_minutes":30,"escalation_minutes":60}]'
```

8b.3. Create the query page (helper handles flock + atomic write + git commit):
```bash
python3 /opt/data/home/airbnb-courier/query-edit.py \
  create-query \
  --query-id "$query_id" \
  --conv-id "$conversation_id" \
  --msg-id "$message_id" \
  --content "$guest_message_content" \
  --property-id "$guest_property_id" \
  --owner-mirror-key "$AIRBNB_OWNER_MIRROR_SESSION_KEY" \
  --asks-json "$ASKS_JSON" \
  --title "Q: <one-line summary>"
```

8b.4. For each ask, POST to plow_chat using the team member's secret key:
```bash
SECRET=$(python3 -c "import json,os;print(json.load(open(os.environ['TEAM_CHAT_SECRETS_FILE'])).get('cht_abc',''))")
curl -fsS -X POST "${PLOW_CHAT_BASE_URL%/}/v1/chats/cht_abc/messages" \
  -H "X-Chat-Secret-Key: $SECRET" \
  -H 'Content-Type: application/json' \
  --data-binary "{\"content\":\"QUERY_ID=$query_id\n$question_text\"}"
```
If a POST fails (non-2xx), log it and continue with the other asks. The
courier will re-ping on SLA expiry.

8b.5. Compose a partial "working on it" draft. Append it to the query page:
```bash
echo "Working on it — checking with <team display name(s)> now. I'll get back to you shortly." > /tmp/draft.txt
DRAFT_ID=$(python3 /opt/data/home/airbnb-courier/query-edit.py \
  append-draft \
  --query-id "$query_id" \
  --kind partial \
  --content-file /tmp/draft.txt)
```

8b.6. Mirror via send_message (same content shape as legacy, but `#<draft_id>`
instead of `#<message_id>`, and include `query_id`):
```
[B] external #<DRAFT_ID> query=<query_id> from <guest-name>: "<guest_message_content>"
PARTIAL DRAFT: "<partial draft text>"
query_id="<query_id>"
draft_id="<DRAFT_ID>"
Reply: approve / reject / edit <text>
```

8b.7. Mark the draft mirrored:
```bash
python3 /opt/data/home/airbnb-courier/query-edit.py \
  mark-mirrored --query-id "$query_id" --draft-id "$DRAFT_ID"
```

8b.8. STOP. Webhook session response is a short status string.

## Trigger 2: owner reply about a pending draft (UNCHANGED v9.0.0 semantics)

Activates when the owner sends a message in a session whose recent history
contains a mirrored `[B] external #<ref-id>` agent turn.

The referenced id is parsed from THAT mirror turn. Do NOT choose "the most
recent pending entry". For pirate drafts, `ref-id` is the Hostex `message_id`;
for coordinator drafts, `ref-id` is a `draft-<N>` token and the mirror line
also contains `query_id=<query_id>`.

Classify the owner's reply semantically:
- **approve** — `approve`, `yes`, `looks good`, `va bene`, `send`.
- **reject** — `reject`, `no`, `don't send`, `cancel`, `non mandare`.
- **edit** — natural-language feedback in any language: `shorter`, `more polite`, etc.
- **unrelated** — off-topic; fall through to default persona.

### Branch A — approve (Hostex POST contract UNCHANGED from v9.0.0)

1. Look up the referenced entry:
   - PIRATE: read `pirate-joker-pending.json` keyed by Hostex `message_id`.
     Pull `conversation_id` and the stored `draft`.
   - COORDINATOR: `python3 /opt/data/home/airbnb-courier/query-edit.py show
     --query-id <query_id>` and find the draft in `drafts[]` matching the
     referenced `draft_id`. Pull `guest_conversation_id` and the draft `content`.
2. UTC timestamp: `date -u +%Y-%m-%dT%H:%M:%SZ`.
3. Ship to guest via Hostex API (CONTRACT UNCHANGED):
   - `POST {hostex_base_url}/v3/conversations/{conversation_id}`
   - Headers: `Hostex-Access-Token: {hostex_access_token}`,
     `User-Agent: curl/8.7.1`, `Content-Type: application/json`
   - Body: `{"message":"<draft>"}`
   - Expect 200 or 202. On error, write outbox with `delivered:false` and
     error note; reply to owner `Errore consegnando a hostex: <reason>` and
     STOP. Do not remove the pending entry / advance the query page.
4. Append a JSONL line to `/opt/data/home/.airbnb-manager/outbox.jsonl`:
   ```json
   {"ts":"<timestamp>","id":"<ref-id>","conversation_id":"<conv>","approved":true,"delivered":true,"sent_content":"<draft>"}
   ```
5. POST-SHIP BOOKKEEPING:
   - PIRATE: remove the processed id from `pirate-joker-pending.json`. Write back.
   - COORDINATOR: mark the draft delivered + close the query if it was a final draft:
     ```bash
     python3 /opt/data/home/airbnb-courier/query-edit.py \
       mark-delivered --query-id <query_id> --draft-id <draft_id> --close
     ```
     Use `--close` only for `kind: final` drafts. For partial drafts, omit
     `--close` — leave the page open for the next courier wake.
6. Reply briefly: `Aye, draft be sailin' out!` (pirate) or `Sent.` (coordinator).

### Branch B — reject

1. Append to outbox.jsonl:
   ```json
   {"ts":"<ts>","id":"<ref-id>","conversation_id":"<conv>","approved":false,"delivered":false,"sent_content":"<draft>"}
   ```
2. Do NOT call the Hostex API.
3. POST-REJECT BOOKKEEPING:
   - PIRATE: remove the referenced id from pending; write back.
   - COORDINATOR:
     ```bash
     python3 /opt/data/home/airbnb-courier/query-edit.py \
       mark-rejected --query-id <query_id> --draft-id <draft_id>
     ```
4. Reply: `Arrr, that one be walkin' the plank.` (pirate) or `Rejected.` (coord).

### Branch C — edit

1. Generate a NEW draft incorporating the owner's feedback. For pirate, pirate
   vocabulary REQUIRED. For coordinator, the new draft MUST still cite team
   answers from the query page VERBATIM and MUST NOT invent facts.
2. POST-EDIT BOOKKEEPING:
   - PIRATE: update only the referenced pending entry's `draft` field; write
     back.
   - COORDINATOR: append a new draft with the same `kind` as the previous:
     ```bash
     echo "<new draft text>" > /tmp/draft.txt
     NEW_DRAFT_ID=$(python3 /opt/data/home/airbnb-courier/query-edit.py \
       append-draft --query-id <query_id> --kind <partial|final> \
       --content-file /tmp/draft.txt)
     ```
3. Reply with the same approval-template format, preserving `#<ref-id>` for
   pirate or new `#<NEW_DRAFT_ID>` for coordinator. Do NOT write outbox,
   do NOT call Hostex API.

### Branch D — REPLACED

The v9.0.0 "plan-request STUB" branch is gone. Its purpose (multi-step team
consult) is now Trigger 1 step 8b. If the owner explicitly requests an ad-hoc
multi-step action ("approve and also tell the cleaner X"), reply:
`That's a multi-step ask. The team-consult flow auto-fans-out on guest
messages; for ad-hoc team pings, edit the team brain page or ping them yourself.`
STOP. Do not mutate state.

## Trigger 3: courier wakeAgent (NEW)

Activates when a wakeAgent prompt includes the literal token `query_id=`.
Prompt format: `draft reply for query_id=<id>; read /opt/data/home/brain/queries/<file>`.

Procedure:

1. Parse `query_id` from the prompt.
2. Read the query page state:
   ```bash
   STATE=$(python3 /opt/data/home/airbnb-courier/query-edit.py show --query-id <query_id>)
   ```
   The output is JSON. Parse `asks[]` and `drafts[]`.
3. Determine draft kind:
   - If ALL asks have `status` in `{answered, escalated, timed_out}` AND no
     existing `drafts[]` has `kind: final`: produce `kind: final`.
   - Else if AT LEAST ONE ask has `status: answered` AND no existing partial
     draft has `drafted_at` within the last 5 minutes AND at least one ask is
     `pending`: produce `kind: partial`.
   - Else: nothing to do (idempotent — already drafted this state). STOP.
4. Compose the draft using ONLY information in the asks' answers + the
   property page (if `guest_property_id` is set). Do NOT invent facts. Cite
   team answers VERBATIM where natural ("The cleaner confirmed it'll be ready
   by 12:30"). For escalated asks, note "still checking with <role>".
5. Write the draft to a temp file and append it to the query page (helper
   handles flock + atomic write + git commit):
   ```bash
   echo "<draft text>" > /tmp/draft.txt
   NEW_DRAFT_ID=$(python3 /opt/data/home/airbnb-courier/query-edit.py \
     append-draft --query-id <query_id> --kind <partial|final> \
     --content-file /tmp/draft.txt)
   ```
6. Mirror to owner via send_message with the standard approval format
   (see 8b.6 above), substituting `<NEW_DRAFT_ID>` for `<DRAFT_ID>`.
7. Mark the draft mirrored:
   ```bash
   python3 /opt/data/home/airbnb-courier/query-edit.py \
     mark-mirrored --query-id <query_id> --draft-id <NEW_DRAFT_ID>
   ```

## Hard rules

- ONE inbound Hostex contract: real `message_created` callback (UNCHANGED v9.0.0).
- The callback is top-level `conversation_id` + `message_id`; never expect
  message content or `sender_role` in the callback.
- Trigger 1 MUST fetch `GET /v3/conversations/{conversation_id}` before
  reading content or `sender_role`.
- `sender_role == "host"` events from the fetched conversation are ignored.
- Every Hostex GET and POST includes `User-Agent: curl/8.7.1`.
- Approve uses `POST /v3/conversations/{conversation_id}` with body field
  `message` (CONTRACT UNCHANGED).
- Pirate voice = English only. Coordinator drafts are language-matched to the
  guest's message (English in / English out).
- Edit classification is semantic. Never substring matching.
- Trigger 1 MUST call `send_message` so Hermes mirrors the approval request.
- Branch A MUST call Hostex API. The outbox is an audit trail, not delivery.
- All query page mutations MUST go through `/opt/data/home/airbnb-courier/query-edit.py`.
  NEVER write raw YAML; the helper owns flock + atomic write + git commit.
- Drafts cite team answers VERBATIM. Never invent facts the team didn't say.
- The boss skill NEVER POSTs to plow_chat with guest-facing content — only
  with team-facing question text. Guest-facing content ships via Hostex on
  owner approval.
- Webhook subscription prompt provides `platform`, `chat_id`,
  `hostex_base_url`, `hostex_access_token`. Env provides `PLOW_CHAT_BASE_URL`,
  `TEAM_CHAT_SECRETS_FILE`, `AIRBNB_OWNER_MIRROR_SESSION_KEY`. None hardcoded.
- For timing / occupancy / guest-state questions, consult `hostex-context` live —
  never guess a date is free. Live Hostex state overrides static brain facts on
  conflict. The tools are read-only; they never message the guest.
