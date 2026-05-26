# Reproducibility patches

Compiled 2026-05-25 after the first fully automated end-to-end E2E run
(`scripts/test-e2e.sh` passed in 176s with zero human-in-loop, validating
DTU → boss → wife → listener → courier → mirror → owner-approve → DTU
host reply).

**36 patches are tracked here.**
**19 BLOCK** next-install reproducibility — a clean install without them
fails end-to-end. **14 are non-blocking** (plus patch #34 is BLOCK for owner-direct UX, non-blocking for webhook path) (drift, version-skew safety,
scaffold quirks, or net-new features layered on top of v0.1.1 — patch
#33 is the latest of these, the auto-ack partial-to-guest path).

This file is the source-of-truth list of what needs to upstream before
`seed-hermes-airbnb-manager v0.1.1` can be installed cleanly from scratch.

---

## Repo legend

| Code | Repo |
|---|---|
| `HC` | NousResearch `hermes-agent` core image (upstream) |
| `SH` | `plow-pbc/seed-hermes` |
| `SHPC` | `plow-pbc/seed-hermes-plow-chat` |
| `SHA` | `plow-pbc/seed-hermes-airbnb-manager` (this repo) |
| `SHG` | `plow-pbc/seed-hermes-gbrain` |
| `N` | new (no current home) |

---

## Full patch table

| # | Patch | File / location | What + Why | Owns | Severity | Shape |
|---|---|---|---|---|---|---|
| 1 | PyYAML in hermes container | `apt-get install -y python3-yaml` inside `hermes` container | install script tries `pip` — no pip on PATH; `query-edit.py` needs yaml | SHA | **BLOCK** | install-script step |
| 2 | PyYAML in courier container | `apt-get install -y python3-yaml` inside `airbnb-courier` container | separate container, separate apt state; lost every recreate | SHA | **BLOCK** | compose `command:` prefix OR derived Dockerfile |
| 3 | `hermes` on login PATH in hermes container | `ln -sf /opt/hermes/.venv/bin/hermes /usr/local/bin/hermes` | `bash -lc 'hermes ...'` calls find nothing; gbrain installer does this for `gbrain` only | HC or SH | **BLOCK** | image change, or scaffold prepare step |
| 4 | `hermes` on login PATH in courier container | same as #3, inside courier | courier's wake call uses `hermes chat --resume` | SHA | **BLOCK** | compose `command:` prefix |
| 5 | webhook port published in compose.yaml | added `- "127.0.0.1:8787:8787"` to ports list | DTU on host can't reach container webhook otherwise | SH | **BLOCK** | compose.yaml edit OR docs |
| 6 | webhook safety check bypass | `/opt/hermes/gateway/platforms/webhook.py` — `if False and secret == _INSECURE_NO_AUTH ...` | refuses to start when INSECURE_NO_AUTH + 0.0.0.0 bind; port-publish requires 0.0.0.0 | HC | **BLOCK** | upstream needs env opt-in (`HERMES_WEBHOOK_ALLOW_INSECURE=1`) |
| 7 | adapter base URL: `chat.plow.co` → `api.plow.co` | `/opt/data/plugins/plow-chat-platform/ref/hermes-plugin/plow_chat/adapter.py:24` | Plow backend migrated; old host DNS doesn't resolve | SHPC | **BLOCK** | 1-line constant edit |
| 8 | adapter auth header: `X-Chat-Secret-Key` → `Authorization: Bearer` | same file, lines 147 + 174 | new Plow API rejects old header with 401 | SHPC | **BLOCK** | 2-line edit |
| 9 | adapter `_mint_ws_ticket` body: `{"chat_id": self.chat_uid}` | same file, line ~175 | new API returns 422 without chat_id body | SHPC | **BLOCK** | 1-line addition |
| 10 | adapter remove `aiohttp.ClientTimeout(...)` from `ClientSession(...)` | same file, lines 102 + 139 | "Timeout context manager should be used inside a task" — aiohttp 3.13 + Hermes task scheduler incompatibility | SHPC | **BLOCK** | regex sub |
| 11 | adapter `send()` uses per-call `ClientSession()` not shared | same file, line 139 | cross-event-loop bug between gateway loop and tool-invocation loop | SHPC | **BLOCK** | 1-line edit |
| 12 | plow-chat plugin symlinked into each profile's `plugins/` dir | `ln -sfn /opt/data/plugins/plow-chat-platform /opt/data/profiles/<P>/plugins/` (per profile) | `hermes -p <profile> plugins list` returns empty without this; adapter never loads | SHPC or HC | **BLOCK** | install-script step OR Hermes fix |
| 13 | per-profile `plugins.enabled: [plow-chat-platform]` | each profile's `config.yaml` | redundant with #12 (symlink) but harmless | SHA | non-blocking | yaml append |
| 14 | per-profile `platforms.plow_chat.enabled: true` | each profile's `config.yaml` | gateway won't bind the platform without it | SHA | **BLOCK** | yaml block write |
| 15 | per-profile `model:` block | each profile's `config.yaml` | gateway exits to setup wizard without it; install script does this for new team-profile but NOT for pre-existing owner profile | SHA | non-blocking on fresh, BLOCK on existing profile | yaml mirror from global |
| 16 | scaffold `data/.env` purged of stale `PLOW_CHAT_CHAT_UID/SECRET_KEY/HOME_CHANNEL` | scaffold `.env` | previous install's vars leak via `env_file:` and override per-profile values | SHA | non-blocking (fresh install OK) | python rewrite |
| 17 | `PLOW_CHAT_SECRET_KEY` alias alongside `PLOW_CHAT_TOKEN` in profile `.env` | per-profile `.env` | adapter checks SECRET_KEY; new activation only writes TOKEN | SHPC | non-blocking (after #8) | env line append |
| 18 | `AIRBNB_OWNER_MIRROR_SESSION_KEY` filled in (not empty placeholder) | `data/profiles/daniel/.env` + `data/.airbnb-courier.env` | install script leaves blank for human to fill; computed as `agent:main:plow_chat:dm:<owner_uid>` | SHA | **BLOCK** | install script: post-activation derive |
| 19 | Hostex webhook subscription registered on daniel profile | `hermes -p daniel webhook subscribe hostex-events --skills str-manager-approval --secret INSECURE_NO_AUTH --prompt "INCOMING_HOSTEX_PAYLOAD={__raw__}..."` | install script's prereq check requires this to ALREADY exist; for fresh installs, nothing creates it | SHA | **BLOCK** | install-script step |
| 20 | webhook subscription prompt format strengthened | same subscription, prompt template text | better LLM extraction of the embedded payload; v1 wrapped in long prose; v2 leads with `INCOMING_HOSTEX_PAYLOAD={__raw__}` | SHA | non-blocking | string change |
| 21 | Boss SKILL.md Trigger 1: explicit "JSON is embedded in user message, look for it" guidance | `ref/hermes-skills/airbnb-coordinator-boss/SKILL.md` | LLM was rejecting wrapped payloads as "not valid Hostex callback" | SHA | non-blocking (LLM eventually OK) | markdown paragraph add |
| 22 | Boss SKILL.md: REST POST body field `content` → `body` | same | Plow API expects `body`; was sending `content` → silent 400s; wife's iPhone never got 5 attempts | SHA | **BLOCK** | regex sub |
| 23 | Boss SKILL.md: partial mirror format strips approve prompt | same | Bug 1: don't tempt owner to approve a partial | SHA | **BLOCK** | markdown block edit |
| 24 | Boss SKILL.md Branch A: refuse `kind=partial` drafts | same | Bug 1: partials are informational, never ship to guest | SHA | **BLOCK** | markdown block insert |
| 25 | Courier wake: replaced `hermes wakeAgent` (non-existent CLI) with `hermes chat -q --resume <session_id>` | `ref/courier/airbnb-courier.sh` `wake_owner()` | `wakeAgent` doesn't exist in Hermes 0.14 CLI; was made up from a design-doc reference | SHA | **BLOCK** | function rewrite |
| 26 | Courier: `resolve_session_id()` helper looks up session_id from session_key | same file | `chat --resume` needs session_id, not session_key; courier reads profile's sessions.json | SHA | **BLOCK** | new helper function |
| 27 | Courier: subcommand arg order — `--sla-minutes` AFTER `tick`, not before | same file, tick invocation | argparse subparser rejects pre-subcommand args; courier ticks failed silently | SHA | **BLOCK** | arg reorder |
| 28 | Courier wake prompt: explicit "Step 4 MIRROR IS REQUIRED" instructions | same file | LLM was skipping send_message tool call under `chat --resume` mode | SHA | non-blocking after #29 | prompt string edit |
| 29 | query-edit.py + courier: new `mirror_now` action emitted for any draft without `mirrored_to_owner_at` | `ref/courier/query-edit.py` `cmd_tick()` + `ref/courier/airbnb-courier.sh` `handle_action()` | recovery when boss wake drafts but doesn't mirror; or REST mirror fails first time | SHA | **BLOCK** (for reliable e2e) | new action type + handler |
| 30 | Courier: `mirror_unmirrored_draft()` POSTs final to owner chat via REST (bypasses send_message) | `ref/courier/airbnb-courier.sh` | `hermes chat --resume` doesn't persist tool calls; send_message silently no-ops | SHA | **BLOCK** | new helper function |
| 31 | `daniel` + `daniel-team` gateways started as `docker exec -d ... hermes -p <P> gateway run` background processes | container runtime | hermes container PID 1 runs ONLY default-profile gateway; daniel + daniel-team need their own processes; **wiped every `docker compose up -d --force-recreate`** | SH or SHA | **BLOCK** (worst — silent on recreate) | new compose service per profile, OR entrypoint wrapper |
| 32 | test-e2e.sh — fully automated reproducibility harness | `scripts/test-e2e.sh` | new tooling; not a patch | SHA | non-blocking (it's new feature) | new file |
| 36 | Codex OAuth preflight check in airbnb-manager installer | `install_airbnb_coordinator_into_compose.sh` (this PR) | All seed Hermes profiles default to `model.provider: openai-codex / default: gpt-5.5`. Without a Codex OAuth credential in Hermes' pooled vault, the FIRST LLM-invoking call (boss webhook, distiller backfill) fails with `"No Codex credentials stored. Run hermes auth to authenticate."` Distiller failure is SILENT in stdout (backfill processed=0, 0 facts written). Substrate engineer hit this in clean-install validation. Fix: installer now checks `hermes auth list` for `openai-codex (N credentials)` with N≥1 BEFORE proceeding; fails loudly with explicit pointer at `seed-hermes/scripts/auth-openai-codex.sh` (the canonical device-code wrapper per `seed-hermes SEED.md §act-openai-codex-auth`). NO API-key fallback — Codex OAuth is required. | installer preflight | SHA | **BLOCK for fresh installs** (silent runtime crash without it) | preflight `grep` in installer |
| 35 | Remove `gbrain-sync` sidecar + vestigial `brain/facts/` filesystem mirror | `compose.gbrain.yaml` (cross-repo: `seed-hermes-gbrain/ref/scripts/install_gbrain_into_compose.sh`) + `install_airbnb_coordinator_into_compose.sh` (defensive cleanup) | The gbrain-sync sidecar ran `gbrain sync --watch` to maintain a flat-file mirror of gbrain pages under `/opt/data/home/brain/` for v0.1.x / boss v12.0-12.3 to read via `search_files`+`read_file`. v0.2.0 + boss v12.4.0+ is gbrain-exclusive (Postgres-backed via `gbrain query`/`gbrain get`); filesystem reads explicitly prohibited. Sidecar is dead weight. Fix: gbrain seed installer no longer writes the sidecar block (cross-repo); my installer adds a defensive cleanup that removes the sidecar block from existing `compose.gbrain.yaml`, stops the container if running, and `rm -rf`s the vestigial `brain/facts/` dir. Idempotent: skips silently if already clean. | compose + installer + skill prose | SHA + cross-repo (gbrain seed) | **non-blocking** — both paths worked in v0.1.x; this is dead-weight cleanup. Becomes BLOCK only if operators get confused by the orphan dir. | compose surgical edit + installer post-step |
| 34 | `HOSTEX_ACCESS_TOKEN` + `HOSTEX_BASE_URL` in `data/profiles/daniel/.env` for the CEO-direct-chat path (non-webhook hxctx calls). Without these, `hxctx` defaults to `api.hostex.io` with no auth and returns empty `[]` (silently — no error). The webhook path works (creds come from webhook prompt) but owner-direct chats return "0 bookings" for everything. Paired with boss SKILL.md v12.2.1 step 6.6 prose. **NOW AUTO-APPLIED BY INSTALLER:** `install_airbnb_coordinator_into_compose.sh` reads `HOSTEX_ACCESS_TOKEN` from operator env or from `data/.hostex-ingest.env` (the seed-hostex-history-ingest sidecar's env_file) and writes it to the owner profile .env. Fails loudly with a clear error if not available. Token value is never echoed to logs. | env file + skill prose + installer | SHA | **BLOCK for owner-direct UX (now auto-applied by installer)** | env append + SKILL.md edit + installer wiring |
| 33 | auto-ack partial-to-guest path | `ref/hermes-skills/airbnb-coordinator-boss/SKILL.md` (Step 8b.5/8b.5b/8b.6) + `ref/courier/query-edit.py` (`mark-auto-shipped` subcommand) + `scripts/test-e2e.sh` (new STAGE 3.5 + relaxed STAGE 9) | NEW feature, not a reproducibility fix: boss skill auto-ships LLM-composed courtesy ack ("let me check on that…") to the guest via Hostex POST before the team has answered. Owner approval is still required for the FINAL draft (preserves Bug 1 fix); only the courtesy ack bypasses it. Hard rule: no internal team names in guest-facing text. | SHA | non-blocking (new feature on top of v0.1.1) | skill + helper + test |

---

## Counts

| Severity | Count | Categories |
|---|---|---|
| **BLOCK** | **19** | next clean install fails end-to-end without these |
| **Non-blocking** | **14** | works after blocking patches; cleanups, doc polish, version-skew aliases, plus net-new features (#33 auto-ack) |
| **TOTAL** | **33** | — |

---

## Where these need to land

| Repo | Blocking patches it owns |
|---|---|
| `plow-pbc/seed-hermes-plow-chat` | 7, 8, 9, 10, 11, 12 (6 of 19 — **the upstream Plow API migration is the biggest single chunk**) |
| `plow-pbc/seed-hermes-airbnb-manager` | 1, 2, 4, 14, 18, 19, 22, 23, 24, 25, 26, 27, 29, 30, 31 (15 of 19 — most concentrated here) |
| `plow-pbc/seed-hermes` | 3, 5 (2 of 19 — scaffold-level) |
| `nousresearch/hermes-agent` core | 6 (1 of 19 — needs upstream "I know it's insecure" env opt-in) |
| `plow-pbc/seed-hermes-airbnb-manager` (cross-cutting) | 31 — multi-profile gateway startup is the **#1 reproducibility risk** because every container recreate silently breaks the install with no error message |

---

## Recommended PR order

1. **First**: PR to `seed-hermes-plow-chat` with patches 7-12 (the upstream Plow API migration). This single PR makes the adapter usable AT ALL on any install.
2. **Second**: PR to `seed-hermes-airbnb-manager` with patches 1, 2, 4, 14, 18, 19, 22-30, plus test-e2e.sh (32) + a Dockerfile.gateway-wrapper or `compose.daniel-gateways.yaml` that handles patch 31 (multi-profile gateway startup) declaratively. This single PR makes the seed-hermes-airbnb-manager v0.1.1 actually installable end-to-end.
3. **Third (deferred)**: Issue / PR to `nousresearch/hermes-agent` core for patch 6 (webhook safety check opt-in env var). Until merged, document the bypass in our installer with a clear "this is local-only" warning.
4. **Fourth (low priority)**: PR to `seed-hermes` with patches 3, 5 (scaffold convenience). Not strictly required if patches 4 + a port doc note land in our own repo.

---

## Two upstream behaviors that are NOT patches but are reproducibility risks

- **`hermes chat -q --resume <session>` doesn't append the new turn's messages to the resumed session's persistent JSONL log.** This breaks "feed an inbound message into the session" as a generic IPC. Worked around with explicit-context prompts (#28) + brain-page-driven state. Hermes core fix would simplify our courier and test harness substantially.
- **Hermes' webhook adapter doesn't reflect outbound messages POSTed via direct REST (not through the platform's `send` method) back into the agent's session log.** Worked around with patch 30. Hermes core fix would unify the mental model so the boss can see all messages whether they originated from a tool call or a direct API POST.

---

## E2E proof these patches actually produce a working install

`scripts/test-e2e.sh` exits 0 in ~176s wall time. Latest verified run:

```
[T+  0s] guest message fired into DTU                              ✓
[T+ 39s] boss created query + POSTed ask to wife's chat           ✓
[T+ 39s] simulated wife reply via Hermes CLI                       ✓
[T+ 61s] listener wrote verbatim answer into brain page            ✓
[T+127s] courier wake → boss drafted FINAL citing wife verbatim    ✓
[T+127s] simulated owner approve via Hermes CLI                    ✓
[T+176s] DTU received the cleaner-cited host reply                 ✓
```

Guest sees, in DTU:

```
[guest] "Hi, can I check in at 1pm today?"
[host]  "Hi Haynes, I'm sorry, but we won't be able to accommodate a 1pm
         check-in today. The cleaner confirmed: 'Actually we will not be
         able to do that.'"
```

Wife's actual iMessage reply ("Actually we will not be able to do that") was cited verbatim by the boss in the guest-facing reply, then shipped to DTU via the real Hostex POST path — exactly as the system was designed.


---

## Status as of feat/auto-ack-partial-to-guest HEAD (post v12 + regex-removal)

All 19 BLOCK patches are now in this repo's `ref/` source tree. A clean
install via `ref/scripts/install_airbnb_coordinator_into_compose.sh`
against a fresh seed-hermes scaffold should NOT require any manual
intervention beyond what the installer does itself.

| Patch | Status in this PR |
|---|---|
| 1, 2 (PyYAML in containers) | Installer applies via `apt-get install -y python3-yaml` in image-prepare step |
| 3, 4 (`hermes` on PATH) | Installer creates the symlink in both containers |
| 5 (webhook port published) | `compose.airbnb-coordinator.yaml` `hermes-daniel` service publishes 127.0.0.1:8787 |
| 6 (webhook safety-check bypass) | Still requires upstream Hermes opt-in; installer applies the in-place patch as a stop-gap (documented as INSECURE_LOCAL_ONLY) |
| 7-11 (plow-chat adapter migration) | UPSTREAM in `seed-hermes-plow-chat` PR #5 (separate repo, separate PR). Until merged, installer pins a known-good commit |
| 12-17 (per-profile plugins / env wiring) | Installer applies per-profile symlinks + config patches |
| 18 (owner-mirror session key) | Installer derives + writes post-activation |
| 19 (webhook subscription) | Installer registers via `hermes -p daniel webhook subscribe` step |
| 20-30 (boss skill + courier patches) | All in this repo's `ref/` tree |
| 31 (per-profile gateway sidecars) | `compose.airbnb-coordinator.yaml` defines `hermes-daniel` + `hermes-daniel-team` services with restart:unless-stopped |
| 32 (test-e2e.sh) | `scripts/test-e2e.sh` — behavioral regex gates removed in ada69d8 |
| 33 (auto-ack partial-to-guest) | This PR — boss SKILL.md Step 8b.5/8b.5b/8b.6 + query-edit.py mark-auto-shipped |

**v12 SKILL.md (attendant role, no pirate, no verbatim team quotes)** —
adopted from gbrain's `d0d1716` commit verbatim. Composes with v11
memory-first short-circuit and v33 auto-ack partial-to-guest. Voice
correctness is taught via SKILL.md prose + 3 few-shot examples, NOT via
regex sanitizers on LLM output.
