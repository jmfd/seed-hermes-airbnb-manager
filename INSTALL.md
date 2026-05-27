# Installing the Airbnb Manager stack

This document is the canonical install orchestration for the `seed-hermes-airbnb-manager` stack. Follow it top to bottom on a fresh machine — operator or coding agent — and you end with a working production system: a Dockerized Hermes Agent running boss + listener skills with gbrain memory, hostex-context live lookups, Hostex webhook ingestion, plow_chat for owner approval, and a courier sidecar that handles SLA + escalation.

If any step fails, **STOP and surface to the operator** — don't paper over with a placeholder or work around the failure. Every step has a verification gate; treat a failed gate as a hard stop.

---

## The 5-seed stack

The install pulls and installs five GitHub seed repos in dependency order. Each owns one layer of the stack:

| Order | Seed | What it provides |
|---|---|---|
| 1 | `plow-pbc/seed-hermes` | The base Hermes Agent Docker scaffold + Codex OAuth bootstrap |
| 2 | `plow-pbc/seed-hermes-plow-chat` | The `plow_chat` platform plugin (iPhone iMessage / SMS as a Hermes channel) |
| 3 | `plow-pbc/seed-hermes-gbrain` | The gbrain CLI + Hermes hook for memory queries |
| 4 | `plow-pbc/seed-hostex-history-ingest` | Hostex conversation distiller + voice-synthesizer — populates gbrain with historical facts |
| 5 | `plow-pbc/seed-hermes-airbnb-manager` | This repo — boss skill, listener skill, hostex-context tools, courier sidecar, the integration glue |

Each seed has its own README and installer; this document orchestrates them.

---

## Prereqs

Verify all of these BEFORE starting. If any is missing, install it first or surface to the operator.

| Prereq | How to verify | If missing |
|---|---|---|
| OS: macOS (recent) or Linux | `uname -a` | (no fix — pick a supported machine) |
| Docker Desktop running | `docker info` exits 0 | Install Docker Desktop + start it |
| `git` | `git --version` | Install via package manager |
| `gh` CLI authenticated | `gh auth status` shows logged in | Acceptable to fall back to HTTPS clone (no `gh` needed) |
| `bun` runtime (needed by gbrain installer) | `bun --version` | `curl -fsSL https://bun.sh/install \| bash` |
| `jq` | `jq --version` | `brew install jq` / `apt-get install -y jq` |
| `HOSTEX_ACCESS_TOKEN` available | env var OR file the operator can point you at | **Required** — installer fails loud without it. Acceptable sources: env var, `~/.hostex-token` file, 1Password lookup. Hold the value in memory only — never echo, log, or commit. |
| Free disk space | ~10 GB (Docker images + gbrain Postgres) | Free up space; the install does not gracefully degrade on disk-full |
| Outbound network: `api.hostex.io`, `api.plow.co`, `api.openai.com`, `auth.openai.com`, GitHub | `for h in https://api.hostex.io https://api.plow.co https://api.openai.com https://auth.openai.com https://github.com; do code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 "$h"); [ "$code" = "000" ] && echo "BLOCKED: $h" || echo "OK ($code): $h"; done` — treat any HTTP response as reachable; only `000` (no connection) is a fail. Do NOT use `curl -fsS` — these public root endpoints return 404 / 421 / 403 by design and -fsS exits 22 on non-2xx. | If any host is `000`, STOP — no workaround |
| **OpenAI Codex OAuth access** | An OpenAI account that can complete the `auth.openai.com/codex/device` flow | The install requires Codex OAuth, **not** an `OPENAI_API_KEY` — see Phase 2.5. No API-key fallback. |

Walltime budget: **~30 minutes**, plus ~5–10 minutes for the operator to complete the OAuth browser approval and any plow_chat / iMessage binding steps.

---

## Working directory

Pick a fresh dir on the operator's host — do **not** clone into an existing checkout. Tell the operator the path before starting:

```bash
WORK_DIR="${HOME}/plow-seeds-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$WORK_DIR" && cd "$WORK_DIR"
```

---

## Phase 1 — Clone the 5 seeds (all from `main`)

```bash
for repo in \
  plow-pbc/seed-hermes \
  plow-pbc/seed-hermes-plow-chat \
  plow-pbc/seed-hermes-gbrain \
  plow-pbc/seed-hostex-history-ingest \
  plow-pbc/seed-hermes-airbnb-manager \
; do
  git clone --branch main "https://github.com/${repo}.git" "${repo##*/}"
done
```

Verify each `*/ref/scripts/` (or `*/hermes-agent/scripts/`) exists.

---

## Phase 2 — Bootstrap the seed-hermes scaffold

```bash
cd "$WORK_DIR/seed-hermes/hermes-agent"
./scripts/prepare.sh
docker compose up -d hermes
./scripts/check-ready.sh   # blocks until the gateway is up
```

**Verify:**
- `docker compose ps hermes` shows status `Up`
- `docker compose exec hermes hermes profile list` exits 0
- Browse `http://localhost:9119` — Hermes dashboard loads

Note the scaffold path AND resolve the container's actual UID/GID for subsequent phases (the upstream `nousresearch/hermes-agent` image runs as UID `10000`; older builds use `1001`; macOS-only docs sometimes assume `501:20`). Compute it once from the live container — do NOT hardcode `-u 501:20`:

```bash
SCAFFOLD="$WORK_DIR/seed-hermes/hermes-agent"
HERMES_USER=$(cd "$SCAFFOLD" && docker compose exec -T hermes id -u | tr -d '\r'):$(cd "$SCAFFOLD" && docker compose exec -T hermes id -g | tr -d '\r')
echo "Container hermes runs as: $HERMES_USER"
```

Every later `docker compose exec ... hermes ...` in this document uses `-u "$HERMES_USER"`. Don't substitute `501:20`.

### Pick the Hermes profile handles (OWNER_PROFILE / TEAM_PROFILE)

This seed is **operator-neutral** — there is no canonical "Daniel" baked in. Pick any handle you want for the operator-facing profile, plus a matching team-listener handle. The convention is `<owner-handle>` + `<owner-handle>-team`, but any lowercase alphanumeric+dash name works.

```bash
# Pick whatever names suit your install. Examples: owner / owner-team,
# marie / marie-team, primary / cleaning-crew, etc.
export OWNER_PROFILE="owner"
export TEAM_PROFILE="owner-team"
```

These exports are read by every later phase + by the airbnb-manager installer (which also persists them to `$SCAFFOLD/.env` so docker compose can substitute `${OWNER_PROFILE}` into the per-profile gateway sidecars). If you skip the exports, the installer will prompt for them interactively when it runs in Phase 7.

---

## Phase 2.5 — Authenticate Hermes against OpenAI Codex (REQUIRED, no fallback)

All Hermes profiles in this stack default to `provider: openai-codex / default: gpt-5.5`. Without a Codex OAuth credential stored in Hermes' pooled-credential vault, the first LLM-invoking call (boss webhook, distiller backfill) crashes with `"No Codex credentials stored. Run hermes auth to authenticate."` — and the distiller failure is **silent in stdout** (backfill exits 0 with `processed=0` and no fact pages written). Catch this here, not at runtime.

**There is ONE supported auth path. No API-key fallback. If device-code OAuth cannot complete on this machine (headless / CI / no browser), STOP — do not switch providers, do not substitute any other model + key combination.**

### Run the canonical wrapper

```bash
cd "$SCAFFOLD"
./scripts/auth-openai-codex.sh
```

The wrapper runs `docker compose run --rm -T hermes auth add openai-codex`, parses the device-code output, and surfaces:

```
Open this URL: https://auth.openai.com/codex/device
Enter this code: ABCD-EFGH
```

**Operator action**: open the URL in any browser signed into the operator's ChatGPT account, enter the code, approve. The wrapper exits 0 only when Hermes prints `Added openai-codex OAuth credential #<N>` and writes `data/auth.json`.

### Verify

```bash
docker compose run --rm -T hermes auth list
# Expect: openai-codex (1 credentials):
#   #1  openai-codex-oauth-1   oauth   device_code ←

docker compose run --rm -T hermes status
# Expect: Provider: OpenAI Codex / Model: gpt-5.5
```

One-turn smoke test:

```bash
docker compose run --rm -T hermes chat -q 'reply with just OK' -Q --yolo
# Expect: OK
```

If any check fails, STOP. Do not proceed.

---

## Phase 3 — Install the plow-chat plugin

```bash
cd "$WORK_DIR/seed-hermes-plow-chat"
HERMES_SCAFFOLD_DIR="$SCAFFOLD" bash ref/scripts/install_direct_mount.sh
```

**Verify:**

```bash
docker compose --project-directory "$SCAFFOLD" exec -T hermes hermes plugins list | grep plow-chat-platform
```

---

## Phase 4 — Create + activate the owner + team profiles

This phase creates two Hermes profiles using the handles you chose in Phase 2 (`$OWNER_PROFILE` and `$TEAM_PROFILE`). If you skipped the exports, set them now before continuing — they're referenced literally in the commands below.

⚠ **Operator action usually required**: each profile binds to a real iMessage / SMS line via `plow_chat` device-code (similar to Phase 2.5's Codex flow).

```bash
(cd "$SCAFFOLD" && docker compose exec -T hermes hermes profile create "$OWNER_PROFILE")
(cd "$SCAFFOLD" && docker compose exec -T hermes hermes profile create "$TEAM_PROFILE")
```

For each profile, run the plow-chat activation helper (look for `create_plow_chat_curl.sh` or equivalent in `$WORK_DIR/seed-hermes-plow-chat/ref/scripts/`). The helper prints a URL/code; operator completes the bind from the target iPhone (`$OWNER_PROFILE` = operator's phone; `$TEAM_PROFILE` = cleaner's phone).

**Verify:**

```bash
grep -c 'PLOW_CHAT_CHAT_UID=..*' "$SCAFFOLD/data/profiles/$OWNER_PROFILE/.env"   # expect 1
grep -c 'PLOW_CHAT_TOKEN=..*'    "$SCAFFOLD/data/profiles/$OWNER_PROFILE/.env"   # expect 1
grep -c 'PLOW_CHAT_CHAT_UID=..*' "$SCAFFOLD/data/profiles/$TEAM_PROFILE/.env"    # expect 1
grep -c 'PLOW_CHAT_TOKEN=..*'    "$SCAFFOLD/data/profiles/$TEAM_PROFILE/.env"    # expect 1
```

---

## Phase 5 — Install seed-hermes-gbrain (CLI + entrypoint hook)

gbrain needs an OpenAI API key for embeddings (semantic search). It is fine to use the same `OPENAI_API_KEY` the operator supplied for other steps — gbrain's embedding lookups are independent from Hermes' chat provider (which is `openai-codex` OAuth — see Phase 2.5; do NOT swap Hermes off Codex).

```bash
cd "$WORK_DIR/seed-hermes-gbrain"
# GBRAIN_EMBEDDING_API_KEY is REQUIRED — installer fails loud if absent.
# OpenAI API key for embeddings ONLY (Hermes chat stays on Codex OAuth).
export GBRAIN_EMBEDDING_API_KEY="${OPENAI_API_KEY:?OPENAI_API_KEY must be set for gbrain embeddings}"
HERMES_SCAFFOLD_DIR="$SCAFFOLD" bash ref/scripts/install_gbrain_into_compose.sh
```

**Note on PGLite:** the gbrain installer defaults to PGLite. On Apple Silicon macOS the PGLite WASM is known to crash on heavy write workloads (issue `garrytan/gbrain#223`). Phase 9 below ships a `compose.gbrain-postgres.yaml` (from `ref/compose/` in this repo, deployed by the airbnb-manager installer) that switches gbrain to a Postgres backend — portable and avoids the WASM bug.

**Verify:**

```bash
(cd "$SCAFFOLD" && docker compose exec -T hermes bash -lc 'command -v gbrain')   # expect /usr/local/bin/gbrain
```

---

## Phase 6 — Register the Hostex webhook subscription on the owner profile

The webhook subscription tells Hermes "route Hostex `message_created` callbacks to the `str-manager-approval` skill". It must exist before Phase 8 installs the boss skill (the airbnb-manager installer's prereq checks for it).

### Phase 6a — Enable the webhook platform on the owner profile (REQUIRED before subscribe)

`hermes webhook subscribe` will print `Webhook platform is not enabled` and refuse to write the subscription if `platforms.webhook.enabled` is absent from the profile's `config.yaml`. The plow-chat installer (Phase 3) does not write this block for the airbnb-manager's webhook needs. Add it explicitly:

```bash
OWNER_CFG="$SCAFFOLD/data/profiles/$OWNER_PROFILE/config.yaml"
python3 - "$OWNER_CFG" <<'PY'
import sys, yaml, pathlib
p = pathlib.Path(sys.argv[1])
d = yaml.safe_load(p.read_text()) if p.exists() else {}
d = d or {}
platforms = d.setdefault('platforms', {})
wh = platforms.setdefault('webhook', {})
wh['enabled'] = True
extra = wh.setdefault('extra', {})
extra.setdefault('host', '0.0.0.0')
extra.setdefault('port', 8787)
extra.setdefault('secret', 'INSECURE_NO_AUTH')
platforms.setdefault('plow_chat', {})['enabled'] = True
p.write_text(yaml.safe_dump(d, default_flow_style=False, sort_keys=False))
print(f"  ✓ {p}: platforms.webhook.enabled=true, platforms.plow_chat.enabled=true")
PY
```

### Phase 6b — Subscribe

```bash
(cd "$SCAFFOLD" && docker compose exec -T hermes bash -lc "
  hermes -p $OWNER_PROFILE webhook subscribe hostex-events \
    --skills str-manager-approval \
    --secret INSECURE_NO_AUTH \
    --prompt 'INCOMING_HOSTEX_PAYLOAD={__raw__}\\n\\nExtract event, conversation_id, message_id and follow Trigger 1. Owner channel: platform=plow_chat chat_id=\$(grep PLOW_CHAT_CHAT_UID /opt/data/profiles/$OWNER_PROFILE/.env | cut -d= -f2). Hostex API: hostex_base_url=https://api.hostex.io hostex_access_token=\$HOSTEX_ACCESS_TOKEN.'
")
```

**Verify** — use `jq` for structural validation (`grep -c hostex-events` returns 2 because the subscription name appears in both the route key and the prompt body):

```bash
jq -e '.["hostex-events"] // .subscriptions[]? | select(.name=="hostex-events")' \
  "$SCAFFOLD/data/profiles/$OWNER_PROFILE/webhook_subscriptions.json" >/dev/null \
  && echo "  ✓ hostex-events subscription present" \
  || { echo "  ✗ hostex-events subscription missing"; exit 1; }
```

### Caveats

- **Port mismatch.** Running `hermes webhook subscribe` without a prior `platforms.webhook` block defaults to `port: 8644`. Phase 6a's explicit YAML write pins port `8787` to match `compose.airbnb-coordinator.yaml`'s host mapping (`127.0.0.1:8787 → 8787`). If you see `port: 8644` in `$OWNER_PROFILE/config.yaml` after Phase 6b, re-run Phase 6a (idempotent) — it overwrites to 8787.
- **Hostex base URL + access token are baked into the subscription prompt literal.** The boss skill reads `hostex_base_url` and `hostex_access_token` from the webhook prompt template stored in `data/profiles/$OWNER_PROFILE/webhook_subscriptions.json`, NOT from runtime env. If you later change `HOSTEX_BASE_URL` (e.g. to swap DTU for real Hostex), you MUST re-run Phase 6b — re-registering with the same name updates the prompt. Editing `$HOSTEX_BASE_URL` in `.env` alone has no effect on the webhook path.

---

## Phase 7 — Install seed-hostex-history-ingest (distiller + voice-synthesizer)

```bash
cd "$WORK_DIR/seed-hostex-history-ingest"
# Per the v0.2.0 README: surgical install. Copy the 4 container scripts,
# the hostex-distiller profile, and the voice-synthesizer profile into
# the bind-mounted scaffold. Follow the README for exact paths.
HERMES_SCAFFOLD_DIR="$SCAFFOLD" bash ref/scripts/install_hostex_ingest_into_compose.sh
```

⚠ **Manual step — voice-synthesizer profile.** The current upstream
`install_hostex_ingest_into_compose.sh` creates the `hostex-distiller`
profile but **not** `voice-synthesizer`. Phase 7's verify below tests
for both. Create voice-synthesizer manually until the upstream installer
covers it:

```bash
(cd "$SCAFFOLD" && docker compose exec -T -u "$HERMES_USER" hermes hermes profile create voice-synthesizer)
docker cp \
  "$WORK_DIR/seed-hostex-history-ingest/ref/hermes-soul/voice-synthesizer-SOUL.md" \
  "$(cd "$SCAFFOLD" && docker compose ps -q hermes):/opt/data/profiles/voice-synthesizer/SOUL.md"
mkdir -p "$SCAFFOLD/data/profiles/voice-synthesizer/skills"
cp -r "$WORK_DIR/seed-hostex-history-ingest/ref/hermes-skills/synthesize-voice" \
   "$SCAFFOLD/data/profiles/voice-synthesizer/skills/"
# Mirror the scaffold's model: block so it inherits provider: openai-codex
python3 - "$SCAFFOLD/data/profiles/voice-synthesizer/config.yaml" "$SCAFFOLD/data/config.yaml" <<'PY'
import sys, yaml, pathlib
prof_p, scaf_p = map(pathlib.Path, sys.argv[1:])
scaf = yaml.safe_load(scaf_p.read_text()) or {}
prof = yaml.safe_load(prof_p.read_text()) if prof_p.exists() else {}
prof = prof or {}
if 'model' in scaf and 'model' not in prof:
    prof = {'model': scaf['model'], **prof}
    prof_p.write_text(yaml.safe_dump(prof, default_flow_style=False, sort_keys=False))
PY
```

**Verify:**

```bash
(cd "$SCAFFOLD" && docker compose exec -T hermes bash -lc 'test -x /opt/data/home/hostex-ingest/initial-ingest.sh')
(cd "$SCAFFOLD" && docker compose exec -T hermes bash -lc 'test -f /opt/data/profiles/hostex-distiller/SOUL.md')
(cd "$SCAFFOLD" && docker compose exec -T hermes bash -lc 'test -f /opt/data/profiles/voice-synthesizer/SOUL.md')
```

---

## Phase 8 — Install seed-hermes-airbnb-manager

```bash
cd "$WORK_DIR/seed-hermes-airbnb-manager"
HERMES_SCAFFOLD_DIR="$SCAFFOLD" \
  HOSTEX_ACCESS_TOKEN="${HOSTEX_ACCESS_TOKEN}" \
  bash ref/scripts/install_airbnb_coordinator_into_compose.sh
```

This installer:

- Reads `OWNER_PROFILE` + `TEAM_PROFILE` from the env you exported in Phase 2 (or prompts interactively if unset + stdin is a TTY) and persists them to `$SCAFFOLD/.env` so docker compose can substitute them into the per-profile gateway sidecars at compose-eval time.
- Verifies all prereqs from Phases 2–7 (Codex OAuth, plow-chat plugin, gbrain CLI, brain git-init, owner profile + webhook subscription, `HOSTEX_ACCESS_TOKEN` resolvable). Fails loud if any is missing.
- Auto-wires `HOSTEX_ACCESS_TOKEN` + `HOSTEX_BASE_URL=https://api.hostex.io` into the owner profile `.env`.
- Auto-derives `AIRBNB_OWNER_MIRROR_SESSION_KEY` and writes it to **both** the owner profile `.env` and the courier sidecar `.env`.
- Auto-patches `/opt/hermes/gateway/platforms/webhook.py` to lift the `INSECURE_NO_AUTH + 0.0.0.0` safety rail (required for the local DTU testing path) and verifies the patch landed.
- Installs the boss skill at `str-manager-approval` v12.4.1 (memory-first + attendant role + hostex-context Branch L + 3-tier early-checkin + gbrain-exclusive + auto-ack partial-to-guest).
- Installs the listener skill at `airbnb-team-listener`.
- Installs the `airbnb-courier` sidecar service via `compose.airbnb-coordinator.yaml`.
- Writes `compose.gbrain-postgres.yaml` (the Postgres backend override for Phase 10).
- Removes the legacy `gbrain-sync` sidecar from `compose.gbrain.yaml` (was dead weight after v12.4 went gbrain-exclusive).

---

## Phase 9 — Switch gbrain backend to Postgres + bring the full stack up

The gbrain installer defaults to PGLite. The Postgres backend avoids the WASM bug on macOS and is portable.

```bash
# Add the Postgres override to COMPOSE_FILE chain (idempotent)
ENV_FILE="$SCAFFOLD/.env"
if ! grep -q "compose.gbrain-postgres.yaml" "$ENV_FILE"; then
  python3 - "$ENV_FILE" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
lines = p.read_text().splitlines(keepends=True)
out = []
for line in lines:
    if line.startswith("COMPOSE_FILE="):
        val = line.strip().split("=", 1)[1]
        files = val.split(":")
        if "compose.gbrain-postgres.yaml" not in files:
            files.append("compose.gbrain-postgres.yaml")
        out.append("COMPOSE_FILE=" + ":".join(files) + "\n")
    else:
        out.append(line)
p.write_text("".join(out))
PY
fi

# ⚠ LINUX OPERATORS — per-profile image caveat:
# compose.airbnb-coordinator.yaml hardcodes `image: nousresearch/hermes-agent:latest`
# for hermes-owner + hermes-owner-team + airbnb-courier. The
# airbnb-coordinator installer applies runtime patches (SDK fixes,
# webhook.py INSECURE_NO_AUTH bypass, /usr/local/bin/gbrain symlinks)
# IMPERATIVELY into the running base hermes container's filesystem —
# these patches DO NOT propagate to per-profile services that boot from
# the pristine upstream image. On macOS this rarely bites because the
# base hermes container also boots the per-profile compose hooks. On
# Linux + DinD setups, per-profile services may come up without gbrain,
# without the webhook bypass, etc.
# If you hit this: either build a local image with patches baked in
# (`image: seed-hermes/hermes-agent:local` + a Dockerfile in your
# scaffold) OR re-run the airbnb installer after `docker compose up -d`
# completes (the section-5b defensive cleanup re-applies the patches to
# the running container — but only the base hermes container, NOT the
# per-profile services).
# Tracked as upstream defect #17; not yet fixed in this version.

# Bring up the full stack (hermes-owner + hermes-owner-team + airbnb-courier + gbrain-postgres)
(cd "$SCAFFOLD" && docker compose up -d)

# Wait for postgres healthy
until [[ $(docker inspect -f '{{.State.Health.Status}}' \
    "$(cd "$SCAFFOLD" && docker compose ps -q gbrain-postgres)" 2>/dev/null) == "healthy" ]]; do
  sleep 2
done

# Point gbrain at Postgres (one-time init, replaces PGLite path).
# NOTE: hostname is the bare Compose service name `gbrain-postgres` — the
# compose network resolves this regardless of the scaffold directory name
# or COMPOSE_PROJECT_NAME. Do NOT prefix with $PROJECT_NAME or basename
# (those produce a non-resolving FQDN like hermes-agent-gbrain-postgres).
# Embedding-model syntax is `openai:<model>` (gbrain provider:model form);
# `openai-codex/<model>` is Hermes-Codex auth syntax and NOT recognized
# by gbrain — gbrain reports `(?d)` dimensions and the install proceeds
# with broken embedding lookups.
HERMES_USER=$(cd "$SCAFFOLD" && docker compose exec -T hermes id -u | tr -d '\r'):$(cd "$SCAFFOLD" && docker compose exec -T hermes id -g | tr -d '\r')
(cd "$SCAFFOLD" && docker compose exec -T -u "$HERMES_USER" -e HOME=/opt/data/home hermes bash -lc "
  gbrain init \
    --url 'postgres://gbrain:gbrain_local_dev_only@gbrain-postgres:5432/gbrain' \
    --embedding-model openai:text-embedding-3-small
")
```

**Verify:**

```bash
# Round-trip probe
(cd "$SCAFFOLD" && docker compose exec -T -u "$HERMES_USER" -e HOME=/opt/data/home hermes bash -lc '
  echo "probe" | gbrain put test-init --content "install probe" && \
  gbrain get test-init | grep -q "install probe"
')
# expect exit 0
```

---

## Phase 10 — Run the initial historical backfill (`--limit 10` to validate)

```bash
(cd "$SCAFFOLD" && docker compose exec -T -u "$HERMES_USER" -e HOME=/opt/data/home hermes \
  bash -lc '/opt/data/home/hostex-ingest/initial-ingest.sh --limit 10')
```

Expect a per-conversation `processed=N` line every 30–60 seconds. Total runtime: ~5–8 minutes for 10 conversations.

**Verify:**

```bash
# Facts landed in gbrain
(cd "$SCAFFOLD" && docker compose exec -T -u "$HERMES_USER" -e HOME=/opt/data/home hermes bash -lc '
  gbrain list -n 1000 | grep "^facts/" | wc -l
')
# expect: at least 10 (more typical: 15–25; depends on how rich the 10 sample conversations were)

# Quick semantic query
(cd "$SCAFFOLD" && docker compose exec -T -u "$HERMES_USER" -e HOME=/opt/data/home hermes bash -lc '
  gbrain query "wifi password"
')
# expect: a [score] facts/<property>/wifi line in the output
```

If `processed=0` or `facts/` count is 0 → STOP. Check the distiller log; most likely Codex OAuth isn't actually wired (re-run Phase 2.5 verify).

After validation, optionally run an unbounded backfill (omit `--limit`) for full historical coverage — that takes ~3–6 hours for 343 conversations.

---

## Phase 11 — End-to-end acceptance via DTU (or real Hostex if a tunnel is wired)

The seed ships a Digital Twin Universe (DTU) — a local Hostex stand-in for testing without involving real guests. If your `seed-hermes` scaffold doesn't include a DTU CLI, install Flask + the DTU server per the seed's `dev-harness/` README.

```bash
# Register a webhook subscription pointing at the boss's port
dtu webhook set http://127.0.0.1:8787/webhooks/hostex-events --events message_created

# Fire a test guest message
dtu guest send --property mtn-home --from "AcceptanceTest" --content "Hi, what is the wifi password?"
```

**Verify** (within ~90 seconds):

```bash
# DTU should have logged a webhook_delivered event with status 202
dtu events | grep webhook_delivered | tail -1

# Boss session should show `gbrain query` + `gbrain get` invocations
(cd "$SCAFFOLD" && docker compose exec -T hermes bash -lc "
  ls -t /opt/data/profiles/$OWNER_PROFILE/sessions/2026*.jsonl | head -1 | xargs grep -c gbrain
")   # expect: >= 2

# Pending entry written with memory_cite.gbrain_slug
(cd "$SCAFFOLD" && docker compose exec -T hermes cat /opt/data/home/.airbnb-manager/pirate-joker-pending.json | jq '.[] | .memory_cite.gbrain_slug' | tail -1)
# expect: "facts/mtn-home/wifi"
```

And the operator's iPhone should receive a `plow_chat` mirror like:

```
AcceptanceTest (Mtn Home): "Hi, what is the wifi password?"

I'd reply (from saved answer): "<the wifi network + password>"

OK to send?
```

If all four checks pass, the install is GREEN.

---

## Acceptance criteria — the 4 production gates

These are the gates the deployed system must satisfy to count as working in production. Run all four after Phase 11; treat any failure as install-not-complete.

| Gate | What it proves | One-line verify |
|---|---|---|
| **G1: Hostex webhook → boss → mirror to iPhone** | The basic ingest path: Hostex callback → boss skill → `plow_chat` mirror to owner | Fire a generic guest message via DTU. Operator's iPhone receives a mirror within ~60s. |
| **G2: gbrain memory-hit** | The boss looks up facts via `gbrain query / gbrain get` (NOT filesystem); the answer comes from a distilled fact page, NOT a hallucination | Phase 11 — pick a topic the `--limit 10` backfill is likely to have distilled (check `gbrain list -n 1000 \| grep ^facts/` first; wifi may NOT be in a small sample of recent winter-themed conversations). Universal-ish topics: "check-in time", "wifi password", "parking", "heating". Fire a guest message via DTU asking about one of those; verify `memory_cite.gbrain_slug == "facts/<property>/<topic>"` in the pending entry. For full coverage on G2, run an unbounded backfill (omit `--limit`) before this gate. |
| **G3: early-checkin 3-tier policy** | Boss correctly classifies an early-checkin request by request-vs-checkin-day delta. TIER 1 (future) → defer with no team consult; TIER 2 (night-before) → calendar check via hxctx; TIER 3 (morning-of) → cleaner consult via 8b consult flow | Fire `dtu guest send --from "Tier1Test" --content "Can I check in early on Saturday?"` (when Saturday is multiple days out). The boss should draft a deferral and NOT create a `q-*.md` brain query page. |
| **G4: multi-employee consult flow** | When the boss decides a real guest question needs the cleaner, it auto-acks the guest, asks the cleaner via `plow_chat`, waits for the answer, drafts a final, mirrors to owner for approve, owner approves, Hostex POST ships | Fire `dtu guest send --from "ConsultTest" --content "Will the unit be ready for early check-in today?"`. Within ~90s: brain query page created at `data/home/brain/queries/q-*.md`; cleaner's iPhone receives an ask; owner's iPhone receives an auto-ack mirror with no approve prompt. After cleaner replies + courier wake, owner's iPhone receives a final draft mirror with `OK to send?`. |

---

## Troubleshooting — defects we've seen + how they're fixed

Two clean-install validation runs (a macOS DinD substrate + a Linux Pi operator) surfaced 30+ defects across the 5 seeds. The top ten that bite airbnb-manager operators specifically, and their resolutions:

| Symptom | Root cause | Fixed in |
|---|---|---|
| Boss draft is generic (no `(from saved answer)`), `pirate-joker-pending.json` `memory_cite` is empty, `gbrain query` not present in session log | Per-profile gateway services (`hermes-${OWNER_PROFILE}`, `hermes-${TEAM_PROFILE}`, `airbnb-courier`) didn't have `gbrain` on PATH after container recreate. `compose.gbrain.yaml`'s entrypoint hook only applied to the base `hermes` service. | PR #8 — `compose.airbnb-coordinator.yaml` now symlinks `gbrain` + `bun` to `/usr/local/bin/` at each per-profile service startup, with `HOME=/opt/data/home` pinned. SKILL.md adds a `command -v gbrain` preflight that fails loud instead of swallowing the error. |
| Distiller backfill exits 0 with `processed=0`; no fact pages written | `hostex-distiller` profile defaulted to `openai-codex` but no Codex OAuth credential was stored. Hermes returned setup/auth text instead of JSON; distiller parsed "no JSON → no facts → done". Silent. | PR #6 — installer now has a Codex OAuth preflight check (`hermes auth list \| grep openai-codex`) that fails loud before any LLM-invoking step. Phase 2.5 of this install doc makes the same check explicit. |
| `airbnb-courier` sidecar exits at startup with `AIRBNB_OWNER_MIRROR_SESSION_KEY required` | The installer derived the session key into the owner profile's `.env` but left `data/.airbnb-courier.env` with the empty placeholder. | PR #8 — installer now syncs the derived value into both `.env` files in the same transaction. |
| `hermes-${OWNER_PROFILE}` gateway exits with `webhook error: INSECURE_NO_AUTH ... non-loopback 0.0.0.0 ... refusing to start` | The local-DTU testing path uses the `INSECURE_NO_AUTH` secret with a `0.0.0.0` bind; Hermes has a safety rail that refuses this combo. The installer was supposed to patch `webhook.py` to lift the rail (per `REPRODUCIBILITY-PATCHES.md` #6) but never actually did. | PR #8 — installer now patches `/opt/hermes/gateway/platforms/webhook.py`, clears the bytecode cache, and verifies the patch marker post-write. |
| Boss skill rejects valid `enabled: [plow-chat-platform]` inline YAML form, demands multiline form | Prereq check used `grep -qE '- plow-chat-platform'`. | PR #8 — switched to `python3 -c 'yaml.safe_load(...)'` structural parse. Accepts both list forms. |
| Installer fails `FAIL: hermes user HOME is '/', expected '/opt/data'` even on a freshly-prepared scaffold | Installer trusted `HERMES_UID/HERMES_GID` from scaffold `.env` (host UID, often `1001` / `501`); the container actually runs as UID `10000`. `docker exec -u 1001` then hit container files owned by `10000` with no permission. | This PR — installer now live-probes the running hermes container (`docker compose exec hermes id -u/id -g`) and uses the actual container UID; `.env` is a legacy fallback only. INSTALL.md likewise computes `HERMES_USER` once from the live container. |
| `gbrain init --url ...` fails with `getaddrinfo ENOTFOUND` or `(?d)` for embedding dimensions | INSTALL.md's example URL used `${PROJECT_NAME}-gbrain-postgres` (non-resolving FQDN) and embedding model `openai-codex/text-embedding-3-small` (Hermes-Codex syntax, not gbrain's `openai:<model>` form). | This PR — URL now bare `gbrain-postgres` (Compose service DNS name); embedding model now `openai:text-embedding-3-small`. |
| Phase 6 `hermes webhook subscribe` fails with `Webhook platform is not enabled` | `hermes profile create` produces an empty profile config — no `platforms.webhook.enabled: true` block. Subscribe refuses to write the subscription. | This PR — INSTALL.md has a new Phase 6a that explicitly writes the `platforms.webhook` + `platforms.plow_chat` blocks via YAML structural edit BEFORE running subscribe. |
| Boss session crashes with `No inference provider configured. Run 'hermes model'` on every webhook | `hermes profile create` makes an empty profile config — no `model:` block. The base hermes container reads `data/config.yaml` and has one, but per-profile services read `data/profiles/<name>/config.yaml` first. | PR #10 — installer now mirrors the scaffold's model block into the owner-profile `config.yaml` if missing (same code path as the team-profile mirror). |

If you hit a defect not on this list, capture: (a) which phase you were in, (b) the verbatim error, (c) what step exited non-zero. Open an issue against `plow-pbc/seed-hermes-airbnb-manager` with that triad.

---

## Final notes

- **Never use an API-key fallback in place of Codex OAuth.** The boss skill, distiller, and listener all assume `openai-codex` and expect device-code OAuth. API-key paths (`provider: custom + OPENAI_API_KEY`) work in isolation but diverge from validated production behavior — drafts use a different model, voice synthesizer outputs differ, and the install is not a faithful reproduction of the production stack.
- **The `gbrain-sync` sidecar was removed in v0.2.x.** Older installs may have it lingering in `compose.gbrain.yaml`. The airbnb-manager installer's defensive cleanup removes it — don't put it back.
- **DTU is a test stand-in.** Production uses a real Hostex tunnel registered against `auth.openai.com`-side credentials. Setting up the real tunnel is out of this document's scope.
- **For per-seed details**, consult each seed's README + `SEED.md`. This document orchestrates; it does not duplicate the per-seed specs.
