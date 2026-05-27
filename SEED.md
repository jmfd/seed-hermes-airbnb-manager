# Purpose

> See [[README#Purpose]].

## Normative Language

The key words MUST, MUST NOT, REQUIRED, SHALL, SHALL NOT, SHOULD, SHOULD NOT, RECOMMENDED, MAY, and OPTIONAL in this document are to be interpreted as described in RFC 2119.

`Implementation-defined` means the behavior is part of the implementation contract; this specification does not prescribe a single policy.

Sub-folder SEEDs in this tree inherit the RFC 2119 declaration. They MUST NOT re-declare it.

## Dependencies

### Adjacent seeds (REQUIRED)

- `https://github.com/plow-pbc/seed-hermes` MUST be installed and a `<scaffold>/data/` bind-mount MUST be present. This seed targets the same scaffold. ^dep-seed-hermes
- `https://github.com/plow-pbc/seed-plow-chat` defines the Plow Chat API (REST + WSS). A consumer MUST read that SEED first for chat / line / member / message / WebSocket frame semantics; this SEED depends on its `## Objects` and `## Actions` and does not restate them. ^dep-seed-plow-chat
- `https://github.com/plow-pbc/seed-hermes-plow-chat` MUST be installed in the same scaffold and its `plow_chat` gateway platform MUST be enabled. v0.1.0 of this seed REQUIRES the `PLOW_CHATS=<uid>:<key>,...` multi-token patch (Slack-style precedent at `slack.md:453`); without it, the team listener profile can bind exactly one team member. The installer MAY be run with `--skip-team-listener` for early-tester installs that lack the patch. ^dep-seed-hermes-plow-chat
- `https://github.com/plow-pbc/seed-hermes-gbrain` MUST be installed in the same scaffold; this seed writes its brain pages into the brain repo at `/opt/data/home/brain/` and relies on the `gbrain-sync` sidecar to index them. ^dep-seed-hermes-gbrain

### Runtime

- Hermes Agent MUST run in the Docker-backed `seed-hermes` shape: a host `compose.yaml`, a whole `./data:/opt/data` bind mount, and `HERMES_HOME=/opt/data` inside the container. ^dep-hermes-docker
- The Hermes runtime MUST inject a subprocess HOME at `${HERMES_HOME}/home/` (i.e. `/opt/data/home/`) for every command spawned by the agent's terminal tool. This is the load-bearing fact inherited from `seed-hermes-gbrain` `^dep-subprocess-home`. The boss skill, the listener skill, AND the courier sidecar all rely on `gbrain` and the brain repo being reachable under that HOME. ^dep-subprocess-home-inherit
- The container's login-shell PATH MUST include `/usr/local/bin` so the courier sidecar's `bash -lc 'gbrain'` invocation works. ^dep-path-login
- The Hostex webhook subscription MUST already be configured on the owner profile (handled by the legacy `seedlab/seeds/airbnb-manager.seed.md` or by `seed-plow-str-manager`). This seed REPLACES the owner profile's `str-manager-approval` skill but does NOT change the webhook subscription itself. ^dep-hostex-subscription
- The owner profile MUST have a configured owner-approval channel (telegram is the v0.1.0 default; an owner-side `plow_chat` instance is a forward-compatible alternative). The install script writes the owner channel's session key into a parameter that the boss skill reads. ^dep-owner-channel

### Host

- The host MUST have Docker with Compose support and a `seed-hermes` scaffold prepared with `./scripts/prepare.sh`. ^dep-host-docker
- The host MUST be able to bring up at least three Compose services on the same project: `hermes`, `gbrain-sync` (from `seed-hermes-gbrain`), and `airbnb-courier` (from this seed). ^dep-host-multi-service
- The host setup path MUST NOT require host `hermes`, host `bun`, host `gbrain`, host Python beyond `python3`, host writes outside the scaffold directory, or container-side network access after install completes. ^dep-host-minimal
- The host setup path MAY use `curl`, `flock`, and standard shell tools. ^dep-curl-flock

## Objects

The named entities that exist on the Hermes / Plow / brain side. Plow Chat entities (chats, lines, members, messages, WebSocket frames) are defined in `seed-plow-chat`; Hostex entities are defined in `seedlab/seeds/airbnb-manager.seed.md`; gbrain brain pages are defined in `seed-hermes-gbrain`. This seed does not redefine them.

### Owner-facing Hermes profile (BOSS)

- A Hermes profile (operator-chosen handle, exposed as `$OWNER_PROFILE`) MUST exist on the scaffold and MUST have its `model.provider` + `model.default` mirrored from the scaffold-level config (per `seed-hermes-gbrain` `^act-profile-model-mirror`). The seed is operator-neutral — there is no canonical profile name baked in; the installer prompts for `OWNER_PROFILE` at install time if unset and persists it to `<scaffold>/.env`. ^obj-owner-profile
- The profile MUST have an existing Hostex webhook subscription bound to a skill the boss skill replaces. The webhook subscription name and prompt template MUST be preserved unchanged across the skill swap. ^obj-owner-webhook-preserve
- The profile MUST have an owner-approval channel (telegram or owner-side `plow_chat`) connected; the install script reads the channel's session key into `AIRBNB_OWNER_MIRROR_SESSION_KEY`. ^obj-owner-channel
- The profile's `data/skills/str-manager-approval/SKILL.md` MUST be the contents of `ref/hermes-skills/airbnb-coordinator-boss/SKILL.md` after install (the skill is INSTALLED UNDER THE LEGACY NAME `str-manager-approval` to preserve the runtime identifier referenced by the existing Hostex webhook subscription). ^obj-boss-skill-named-legacy
- The profile's `data/SOUL.md` MUST contain the boss persona contents from `ref/hermes-soul/owner-SOUL.md`. The install script SHOULD back up any prior SOUL.md to `SOUL.md.bak.<ts>` before overwrite. ^obj-owner-soul
- `/opt/data/home/hostex-context/` MUST contain the `hostex-context` skill (the `hxctx` tool + `_client.py` + `_classify.py` + `SKILL.md`) from `ref/hermes-skills/hostex-context/`, deployed alongside the courier so the boss can call it by absolute path; `hxctx` MUST be executable. The boss skill (`^obj-boss-skill-named-legacy`) references it for live calendar / reservation / guest-state / occupancy-adjacency reads at classification + drafting time. Hostex is the single source of truth: the tools pull live on every call and keep no cache, mirror, or store. The tools are READ-ONLY — they never message a guest; delivery still flows through the boss's owner-approval + Hostex POST path. ^obj-hostex-context-installed

### Team-listener Hermes profile (LISTENER)

- A SECOND Hermes profile (operator-chosen handle, exposed as `$TEAM_PROFILE`; convention `<owner-handle>-team`) MUST exist on the scaffold and MUST have its `model.provider` + `model.default` mirrored from the scaffold-level config. ^obj-team-profile
- The profile MUST have a `plow_chat` gateway platform enabled and MUST be configured with the multi-token env `PLOW_CHATS=<uid1>:<key1>,<uid2>:<key2>,…` in `<scaffold>/data/profiles/<team>/.env`, listing every team member's chat. v0.1.0 REQUIRES the patched `seed-hermes-plow-chat` adapter that consumes this env (Slack-style multi-token precedent). The same per-chat secret keys ALSO live in `/opt/data/home/.airbnb-coordinator/team-secrets.json` (mode 600) so the boss skill and courier sidecar can POST to plow_chat without needing the team profile to broker the request — `PLOW_CHATS` is where the plow_chat ADAPTER binds; `team-secrets.json` is where the BOSS / COURIER look up the key to send. The installer writes both; the wizard fills `team-secrets.json`. ^obj-team-plow-chats-env
- The profile MUST NOT have any client-facing platforms enabled (no Hostex webhook, no owner-approval channel). The persona enforces "info-capture only" but the platform list is the harder boundary. ^obj-team-no-client-platforms
- The profile's `data/skills/airbnb-team-listener/SKILL.md` MUST be the contents of `ref/hermes-skills/airbnb-team-listener/SKILL.md` after install. ^obj-listener-skill
- The profile's `data/SOUL.md` MUST contain the listener persona contents from `ref/hermes-soul/team-SOUL.md`. ^obj-team-soul

### Brain pages (durable cross-process state)

All brain pages live under `/opt/data/home/brain/` (the bind-mounted `gbrain` content repo). The `seed-hermes-gbrain` `gbrain-sync` sidecar indexes them on its 5-minute tick. Writes MUST be flock-protected and git-committed.

- `/opt/data/home/brain/team/<member-slug>.md` describes a single team member. Frontmatter is normative: `title`, `member_uid` (plow_chat chat uid), `role`, `display_name`, `active` (default `true`), OPTIONAL `sla_minutes`, OPTIONAL `escalation_minutes`, OPTIONAL `languages`. Body is free-text describing what they know and what they're responsible for. ^obj-brain-team
- `/opt/data/home/brain/properties/<property-slug>.md` describes a single property. Frontmatter: `title`, `property_id` (Hostex), `address`, OPTIONAL `team_assignments.<role>: <member_uid>` map. Body is free-text. ^obj-brain-property
- `/opt/data/home/brain/queries/q-<datetime>-<conv-short>.md` is the LIVE STATE for one in-flight guest conversation that required team consultation. Frontmatter is normative and defined in `## Actions` below. Filename pattern: `q-YYYYMMDD-HHMMSS-<first-8-of-conversation_id>.md`. ^obj-brain-query
- The brain repo MUST contain `/opt/data/home/brain/queries/.gitkeep` so the directory exists at zero queries. ^obj-brain-queries-gitkeep

### Courier sidecar

- `<scaffold>/compose.airbnb-coordinator.yaml` MUST declare an `airbnb-courier` Compose service using the same `nousresearch/hermes-agent` image as the main `hermes` service, running as `${HERMES_UID}:${HERMES_GID}` with `HOME=/opt/data/home`, mounting `./data:/opt/data`, loading `<scaffold>/data/.airbnb-courier.env` via `env_file:`, `depends_on: hermes`, `restart: unless-stopped`. ^obj-courier-service
- The sidecar's command MUST be `bash -lc '/opt/data/home/airbnb-courier/tick-loop.sh'` and the file at that path MUST be the contents of `ref/courier/airbnb-courier.sh`. ^obj-courier-script
- `<scaffold>/.env` MUST be updated to set `COMPOSE_FILE=compose.yaml:compose.gbrain.yaml:compose.airbnb-coordinator.yaml` (or whatever order matches the operator's prior installs) so `docker compose up -d` picks up the new sidecar without `-f` flags. The installer MUST preserve any preexisting `:`-separated entries. ^obj-courier-compose-file

### Host orchestration scripts

- `ref/scripts/install_airbnb_coordinator_into_compose.sh` is the canonical installer. It MUST be idempotent. It MUST run every install step that touches the brain repo as the hermes user (uid 501, gid 20 by default; overridable via `--uid` / `--gid`) with `HOME=/opt/data/home` pinned. It MUST refuse to proceed if `seed-hermes-gbrain` is not installed (`docker compose exec hermes bash -lc 'which gbrain'` MUST succeed). It MUST refuse to proceed if `seed-hermes-plow-chat` is not installed (the scaffold's `data/config.yaml` MUST list `plow-chat-platform` in `plugins.enabled`). ^obj-install-script
- `ref/scripts/seed_team_brain_pages.sh` is an interactive wizard the installer invokes after the runtime install. It walks the operator through authoring `team/*.md` and `properties/*.md` pages for their actual team + properties, then `git add` + `git commit`s them into the brain repo. Per-install config; not committed to this repo. ^obj-seed-wizard
- `ref/scripts/uninstall.sh` MUST stop and remove the `airbnb-courier` sidecar, delete `<scaffold>/compose.airbnb-coordinator.yaml`, delete `<scaffold>/data/.airbnb-courier.env`, strip the seed-managed `:compose.airbnb-coordinator.yaml` segment from `<scaffold>/.env`'s `COMPOSE_FILE`. With `--purge`, it MAY also delete the `$TEAM_PROFILE` profile (DESTRUCTIVE — clears its skills, sessions, plow_chat pairing) and remove `/opt/data/home/airbnb-courier/`. With `--purge-queries`, it MAY also delete `/opt/data/home/brain/queries/q-*.md` (DESTRUCTIVE — loses in-flight state). It MUST NOT delete `team/*.md` or `properties/*.md` pages even with `--purge` — those are the operator's authored config. ^obj-uninstall-script
- `ref/verify.sh` MUST be runnable against a fresh install and a re-install. It MUST include a CRITICAL REGRESSION GATE that exercises the legacy "no consult" pirate fast path against the captured Hostex wire sample, to prove the live Trial Reel demo did not break. ^obj-verify-script

## Actions

### Boss skill replaces the legacy str-manager-approval skill

- A host agent MUST run `ref/scripts/install_airbnb_coordinator_into_compose.sh` against a scaffold where `seed-hermes`, `seed-hermes-plow-chat`, and `seed-hermes-gbrain` are already running. ^act-install-prereq
- The installer MUST replace `<scaffold>/data/profiles/<owner-profile>/skills/str-manager-approval/SKILL.md` with the contents of `ref/hermes-skills/airbnb-coordinator-boss/SKILL.md`. It MUST preserve the file path and name (`str-manager-approval`) to avoid breaking the existing Hostex webhook subscription's `--skills str-manager-approval` reference. ^act-boss-install
- The installer MUST clear the owner profile's skill snapshot at `<scaffold>/data/profiles/<owner-profile>/.skills_prompt_snapshot.json` so Hermes reloads the new skill on the next session. ^act-boss-snapshot-clear
- The installer MUST deploy `ref/hermes-skills/hostex-context/` to `<scaffold>/data/home/hostex-context/` (the `hxctx` tool, `_client.py`, `_classify.py`, `SKILL.md`, `reference/`, `tests/`), make `hxctx` executable, and chown the runtime files to the hermes uid. The step MUST be idempotent (re-copy on re-run). ^act-hostex-context-install
- The replaced skill MUST preserve the legacy `version: 9.0.0` Hostex contract markers (callback parser, `User-Agent: curl/8.7.1`, `POST /v3/conversations/{conversation_id}` body field `message`) and MUST advertise `version: 10.0.0` in its frontmatter. ^act-boss-version

### Boss skill handles guest message arrival (Trigger 1)

- On a Hostex `message_created` callback (existing contract), the boss skill MUST fetch the conversation via `GET /v3/conversations/{conversation_id}` with `User-Agent: curl/8.7.1` and `Hostex-Access-Token: <token>` (UNCHANGED from v9.0.0). ^act-boss-fetch
- If the fetched message's `sender_role` is not `"guest"`, the boss skill MUST stop silently (UNCHANGED from v9.0.0). ^act-boss-host-ignore
- The boss skill MUST decide whether the message requires team consultation. The decision is LLM reasoning over the candidate set of `/opt/data/home/brain/team/*.md` pages (obtained via `gbrain search` or direct directory listing — Implementation-defined). The decision SHOULD return a list of `(team_member_uid, role, question_text)` tuples; an empty list means "no consult needed". ^act-boss-classify
- At classification AND at drafting, for any timing / occupancy / guest-state question, the boss skill SHOULD consult `hostex-context` via `/opt/data/home/hostex-context/hxctx` (Hostex base URL + token passed as `--base-url`/`--token` from the webhook prompt values, never hardcoded) and MUST prefer live Hostex state over static brain facts on conflict. A question the live data already answers may need no consult. These tools are READ-ONLY. ^act-boss-hostex-context
- If no consult is needed (CLASSIFY returns empty list), the boss skill MUST execute the legacy v9.0.0 pirate-joker draft + mirror flow (Trigger 1 Procedure steps 6-11 of `seedlab/seeds/airbnb-manager.seed.md` SKILL.md). This is the REGRESSION GATE for the live Trial Reel demo. ^act-boss-no-consult-fastpath
- If consult is needed, the boss skill MUST create `/opt/data/home/brain/queries/q-<datetime>-<conv-short>.md` with the frontmatter shape defined in `^act-query-schema` below, then for each ask MUST POST to the plow_chat REST API at `{PLOW_CHAT_BASE_URL}/v1/chats/{team_member_uid}/messages` with body `{"content":"QUERY_ID=<query_id>\n<question_text>"}` and the team member's `X-Chat-Secret-Key: <key>` header (the key MUST be read from the team profile's `.env` via the install-time write, NOT from the boss profile). ^act-boss-fanout
- After fanning out, the boss skill MUST mirror a "working on it" partial draft to the owner via the existing send_message tool (UNCHANGED mirror mechanism). The partial draft content MUST include the query_id so the owner can correlate later mirrors. The partial draft MUST be recorded in the query page's `drafts[]` array with `kind: partial`. ^act-boss-partial-mirror
- The boss skill MUST git add + commit the new query page with message `coordinator: new query <query_id>`. ^act-boss-commit

### Boss skill handles owner approval (Trigger 2)

- This trigger is UNCHANGED from v9.0.0 except for one addition: when the owner replies `approve` to a mirrored draft, the boss skill MUST look up the referenced `draft_id` (parsed from the `[B] external #<draft_id>` mirror line, preserving v9.0.0 semantics). ^act-boss-approve-lookup
- For drafts of `kind: partial`, the legacy Branch A semantics apply (POST to Hostex) BUT the boss skill MUST also update the query page's `drafts[].delivered_at` and MUST NOT close the query (status stays `partial` until all asks are answered AND a final draft has been delivered). ^act-boss-approve-partial
- For drafts of `kind: final`, the legacy Branch A semantics apply AND the boss skill MUST set the query page's `status: closed` and record `closed_at`. ^act-boss-approve-final
- Branch B (reject) MUST behave as v9.0.0 but ALSO MUST set the relevant draft's `rejected_at` in the query page so the courier knows not to re-emit the same draft. ^act-boss-reject
- Branch C (edit) MUST behave as v9.0.0 but operate on the most recent unfinalized draft for the referenced query. ^act-boss-edit

### Boss skill responds to courier wake (Trigger 3)

- The courier MAY invoke the boss skill via `hermes -p <owner-profile> wakeAgent --session <session_key> --prompt 'draft reply for query_id=<id>; read /opt/data/home/brain/queries/<file>'`. The boss skill MUST recognize this trigger by the presence of `query_id=` in the wake prompt. ^act-boss-wake-trigger
- On wake, the boss skill MUST acquire a flock on the referenced query page, re-read its frontmatter, and produce a draft. If all asks have `status: answered`, draft `kind: final`. If at least one ask is answered and at least one is still `pending`, draft `kind: partial`. ^act-boss-draft-kind
- The draft MUST cite team answers VERBATIM where possible. The boss skill MUST NOT invent facts not in the answers (eval covers this). The draft MUST be recorded in `drafts[]` with `drafted_at`, mirrored to the owner via send_message with the v9.0.0 mirror format, and `mirrored_to_owner_at` set. ^act-boss-draft-cite
- After mirroring, the boss skill MUST release the flock and git commit the page with message `coordinator: draft <kind> for <query_id>`. ^act-boss-draft-commit

### Query page schema

- Each `queries/q-*.md` page MUST contain the following frontmatter fields. Optional fields MAY be omitted. Unknown fields MAY exist; readers MUST NOT fail on them. ^act-query-schema

  - `title` (string, REQUIRED, human-readable summary)
  - `query_id` (string, REQUIRED, MUST match the file basename without `.md`)
  - `guest_conversation_id` (string, REQUIRED, Hostex conversation_id)
  - `guest_message_id` (string, REQUIRED, Hostex message_id of the triggering guest msg)
  - `guest_property_id` (string, OPTIONAL, Hostex property id if extractable)
  - `status` (string, REQUIRED, one of `open` | `partial` | `escalated` | `closed`)
  - `created_at` (ISO 8601 UTC string, REQUIRED, immutable after creation)
  - `updated_at` (ISO 8601 UTC string, REQUIRED, write-time)
  - `owner_mirror_session_key` (string, REQUIRED, Hermes session key for owner approval channel mirrors — typically `agent:main:telegram:dm:<chat_id>` for v0.1.0)
  - `guest_message_content` (string, REQUIRED, the triggering guest message text)
  - `asks[]` (array, REQUIRED, may be empty only if the page is closed without consult)
    - `ask_id` (string, REQUIRED, unique within the page, e.g. `ask-1`)
    - `team_member_uid` (string, REQUIRED, the team member's plow_chat chat uid)
    - `role` (string, REQUIRED, free-form, matches a `team/*.md` role)
    - `question` (string, REQUIRED, the actual question text posted to plow_chat)
    - `asked_at` (ISO 8601 UTC string, REQUIRED, write-time of the most recent ask or re-ping)
    - `original_asked_at` (ISO 8601 UTC string, REQUIRED, immutable, set at first ask)
    - `ping_count` (integer, REQUIRED, starts at 1, +1 per re-ping)
    - `sla_deadline` (ISO 8601 UTC string, REQUIRED, `original_asked_at + sla_minutes`)
    - `escalation_deadline` (ISO 8601 UTC string, REQUIRED, `original_asked_at + escalation_minutes`)
    - `status` (string, REQUIRED, one of `pending` | `answered` | `timed_out` | `escalated`)
    - `answer` (string, OPTIONAL, populated when `status: answered`)
    - `answered_at` (ISO 8601 UTC string, OPTIONAL, populated when `status: answered`)
  - `drafts[]` (array, OPTIONAL, append-only)
    - `draft_id` (string, REQUIRED, unique within the page, e.g. `draft-1`)
    - `kind` (string, REQUIRED, one of `partial` | `final` | `escalate-notice`)
    - `content` (string, REQUIRED, the draft text)
    - `drafted_at` (ISO 8601 UTC string, REQUIRED)
    - `mirrored_to_owner_at` (ISO 8601 UTC string, OPTIONAL)
    - `approved_at` (ISO 8601 UTC string, OPTIONAL)
    - `rejected_at` (ISO 8601 UTC string, OPTIONAL)
    - `delivered_at` (ISO 8601 UTC string, OPTIONAL, set on successful Hostex POST)
  - `closed_at` (ISO 8601 UTC string, OPTIONAL, set when `status: closed`)

- The page body MAY contain a human-readable summary for `cat`/`grep` debugging. The authoritative state is the frontmatter; readers MUST NOT parse the body. ^act-query-body-advisory

### Listener skill handles boss ask delivery confirmation (Trigger A)

- This trigger is informational. When the listener profile's plow_chat adapter delivers an outbound `QUERY_ID=...` message from the boss, the adapter MAY log the delivery to the chat session log. No state mutation is required. ^act-listener-trigger-a

### Listener skill handles team member reply (Trigger B)

- When the listener profile's plow_chat adapter receives an inbound message from a team member (`chat_id` matches a `team/*.md` page's `member_uid`), the listener skill MUST search `/opt/data/home/brain/queries/q-*.md` for an open ask whose `team_member_uid` equals the chat_id and whose `status` is `pending`. ^act-listener-find-open-ask
- The most recent open ask (by `asked_at` descending) MUST be selected. If no open ask exists for that team member, the listener skill MUST reply briefly in the chat ("Got it, but no open question") and MUST NOT mutate any brain page. ^act-listener-no-open-ask
- If an open ask exists, the listener skill MUST acquire a flock on the query page, set `ask.answer` to the team member's reply text VERBATIM, set `ask.answered_at` to now (ISO 8601 UTC), set `ask.status: answered`, set the query page's `updated_at`, release the flock. ^act-listener-write-answer
- The listener skill MUST git add + commit the page with message `coordinator: team answer for <query_id>/<ask_id>`. ^act-listener-commit
- The listener skill MUST reply briefly to the team member ("Got it, thanks.") in the same chat. The listener skill MUST NOT send any message intended for the guest, and MUST NOT POST to Hostex. ^act-listener-no-client-send

### Courier sidecar tick loop

- The courier sidecar MUST run a loop that wakes every `AIRBNB_COURIER_TICK_SECONDS` seconds (default 60). Each tick MUST list `/opt/data/home/brain/queries/q-*.md` and for each page whose frontmatter `status` is in `{open, partial}`, process its open asks. ^act-courier-tick
- For each ask where `status: pending`: ^act-courier-per-ask
  - If `now() < sla_deadline`, skip (still within SLA).
  - If `sla_deadline <= now() < escalation_deadline` AND `ping_count == 1`, re-ping the team member by POSTing to `{PLOW_CHAT_BASE_URL}/v1/chats/{team_member_uid}/messages` with body `{"content":"Reminder — still need an answer to: <question>"}` and the team member's chat secret. Then set `ask.ping_count = 2` and `ask.asked_at = now()`. `original_asked_at`, `sla_deadline`, and `escalation_deadline` MUST NOT change.
  - If `now() >= escalation_deadline` AND `ping_count >= 2`, set `ask.status: escalated`, append a `drafts[]` entry with `kind: escalate-notice` and content describing the escalation, mirror it to the owner channel via `hermes -p <owner-profile> wakeAgent --session <owner_mirror_session_key> --prompt 'ESCALATE: <one line>'`. The owner-side wake is responsible for the actual mirror.
- After processing all asks on a page, the courier MUST evaluate `ready_to_draft(page)`. It MUST return true when: ^act-courier-ready
  - ALL asks have `status` in `{answered, escalated, timed_out}` AND the page does NOT already have a `drafts[]` entry with `kind: final`, OR
  - AT LEAST ONE ask has `status: answered` AND the page does NOT already have a `drafts[]` entry with `kind: partial` whose `drafted_at` is within the last 5 minutes AND at least one ask still has `status: pending`.
- If `ready_to_draft` returns true, the courier MUST invoke `hermes -p <owner-profile> wakeAgent --session <owner_mirror_session_key> --prompt 'draft reply for query_id=<id>; read /opt/data/home/brain/queries/<file>'`. The boss skill's Trigger 3 picks it up from there. ^act-courier-wake
- The courier MUST acquire a flock on each page during read+write and MUST git add + commit any page it modified with message `coordinator: courier <action> for <query_id>`. ^act-courier-flock-commit
- The courier MUST NOT call any LLM directly. Its only mutations are mechanical (ping count, status, deadlines). All semantic work happens in the boss skill via wakeAgent. ^act-courier-no-llm

## Verify

1. **Install prerequisites check.** Run `ref/verify.sh --scaffold <scaffold> --check-prereqs-only`. Does it find `seed-hermes-gbrain` (gbrain on container PATH) and `seed-hermes-plow-chat` (plow-chat-platform in `data/config.yaml`)? Expected: yes. ^v-prereqs

2. **Brain page directory check.** Run `docker compose exec -T -u 501:20 hermes bash -lc 'ls /opt/data/home/brain/{team,properties,queries}'`. Do all three directories exist? Expected: yes. ^v-brain-dirs

3. **Boss skill installed at legacy path check.** Run `docker compose exec -T -u 501:20 hermes bash -lc 'grep -E "^version:" /opt/data/profiles/<owner-profile>/skills/str-manager-approval/SKILL.md'`. Does the output include `10.0.0`? Expected: yes. ^v-boss-version

4. **Listener skill installed check.** Run `docker compose exec -T -u 501:20 hermes bash -lc 'test -f /opt/data/profiles/<team-profile>/skills/airbnb-team-listener/SKILL.md'`. Does it exit zero? Expected: yes. ^v-listener-installed

4b. **hostex-context installed + callable check.** Run `docker compose exec -T -u 501:20 hermes bash -lc 'test -x /opt/data/home/hostex-context/hxctx && python3 /opt/data/home/hostex-context/tests/test_classify.py >/dev/null && python3 /opt/data/home/hostex-context/hxctx --help >/dev/null'`. Does it exit zero (tool present + executable, pure-logic tests pass, CLI loads)? Expected: yes. Additionally `grep -q hostex-context /opt/data/profiles/<owner-profile>/skills/str-manager-approval/SKILL.md` MUST exit zero (the boss skill is wired to use it). ^v-hostex-context

5. **Courier sidecar running check.** Run `docker compose --project-directory <scaffold> ps --services --status running`. Does the output include `airbnb-courier`? Expected: yes. ^v-courier-running

6. **CRITICAL REGRESSION: v9.0.0 pirate fast path.** Post the captured `hostex-message_created.json` wire sample to the tunnel; assert the boss skill writes a draft to `pirate-joker-pending.json` containing pirate vocabulary AND mirrors to the owner channel. This MUST pass for the live Trial Reel demo to not break. ^v-regression-fast-path

7. **CRITICAL REGRESSION: v9.0.0 Branch A Hostex POST.** Simulate owner `approve` for a pirate draft; intercept the Hostex POST; assert URL is `POST /v3/conversations/<conv-id>`, body is `{"message":"<draft>"}`, headers include `User-Agent: curl/8.7.1` and `Hostex-Access-Token`. Outbox.jsonl MUST record `delivered:true`. ^v-regression-hostex-post

8. **End-to-end consult flow.** Author a synthetic `team/cleaner-test.md` page. Inject a synthetic Hostex `message_created` callback whose content is a clear cleaner question. Assert the boss skill creates `queries/q-*.md` with at least one ask targeting the test cleaner. Inject a synthetic plow_chat inbound message from the test cleaner's chat_id with the answer. Wait one courier tick. Assert the boss is woken (look for the wake prompt in the owner profile's session log) and mirrors a final draft citing the cleaner's verbatim answer. ^v-e2e-consult

9. **Re-run idempotency.** Run the installer twice. Assert the second run exits zero, makes no destructive changes, and the verify still passes. ^v-idempotent

## Open

- The boss skill's classify-decision (does this guest message need team consult?) is LLM-only in v0.1.0; no fast-path heuristics. A future PR MAY add cheap pre-filters (e.g. message length < 20 chars + greeting pattern → no consult). ^o-classify-heuristics
- v0.1.0 does not auto-translate team member replies. If the cleaner answers in Spanish and the guest asked in English, the boss skill produces the draft in English citing the Spanish answer verbatim, and the owner sees both. A future PR MAY add a translation step at draft time. ^o-translate
- v0.1.0 has no archive job for closed `queries/q-*.md` pages. At expected volume (< 100 / day) this is fine for ~12 months; beyond that, an archive sidecar SHOULD move closed pages older than 30 days to `queries/archive/<yyyy>/<mm>/`. ^o-archive
- v0.1.0 does not implement the per-role `sla_minutes` override on `team/<member>.md` pages — the schema reserves the field but the courier reads `AIRBNB_COURIER_SLA_MINUTES` globally. A future PR MAY honor per-team-page overrides. ^o-per-role-sla
- v0.1.0 does not implement hierarchical team resolution beyond 2 levels (property-specific → global). For larger orgs with regional cleaners + property-specific cleaners + backup cleaners, a future PR MAY extend the resolution. ^o-deep-team-hierarchy
- The Plow Chat API is pre-1.0 and may change without backwards compatibility guarantees; see `seed-plow-chat#Open`. ^o-api-stability
- The `seed-hermes-plow-chat` multi-token `PLOW_CHATS=<uid>:<key>,…` patch is REQUIRED for the team listener to bind > 1 team member from a single profile. Until that patch lands upstream, this seed's installer MUST be invoked with `--skip-team-listener` and operators MUST use the boss-only path. ^o-plow-chats-patch
- The 3 outstanding `seed-plow-str-manager` blockers (manual session key construction, INSECURE_NO_AUTH + public tunnel, secret-in-prompt) are deploy blockers for production use. Tracked separately; this seed installs but production deployment SHOULD wait for those fixes. ^o-str-manager-blockers

## Non-Goals

- This SEED does not document the Hostex API; see `seedlab/seeds/airbnb-manager.seed.md` and its captured wire samples. ^ng-hostex-api
- This SEED does not document the Plow Chat API; see `seed-plow-chat`. ^ng-plow-chat-api
- This SEED does not document the Hermes Agent runtime; see `seed-hermes`. ^ng-hermes-runtime
- This SEED does not document gbrain; see `seed-hermes-gbrain` and the upstream gbrain repo. ^ng-gbrain
- This SEED does not implement group-chat consultation (one chat with multiple team members at once). Per CEO premise, "no groups." ^ng-groups
- This SEED does not implement guest-side broadcast (one boss message to multiple guests). Out of scope. ^ng-guest-broadcast
- This SEED does not commit, log, or print Plow Chat secrets, Hostex tokens, or owner channel tokens. ^ng-secrets
- This SEED does not modify the Hermes container image. All install artifacts live under the bind-mounted `/opt/data/home/` and persist via the host volume. ^ng-image-rebuild
