# seed-hermes-airbnb-manager — SEED

The canonical normative spec + install procedure for the Airbnb Manager
stack. Follow this document top to bottom on a fresh machine — operator
or coding agent — and the result is a working production system: a
Dockerized Hermes Agent running boss + listener skills with gbrain
memory, hostex-context live lookups, Hostex webhook ingestion, plow_chat
for owner approval, and a courier sidecar that handles SLA + escalation.

If any verification gate fails, **STOP and surface to the operator** —
do not paper over with placeholders or work around the failure.

## Normative Language

The key words MUST, MUST NOT, REQUIRED, SHALL, SHALL NOT, SHOULD, SHOULD
NOT, RECOMMENDED, MAY, and OPTIONAL in this document are to be
interpreted as described in RFC 2119.

`Implementation-defined` means the behavior is part of the
implementation contract; this specification does not prescribe a single
policy. Where this document gives an `Implementation-defined` example
command, the operator MAY substitute an equivalent that produces the
same observable outcome.

`^anchors` mark normative requirements + verification gates that
downstream tooling (validators, test harnesses, follow-up PRs) cite
verbatim. Anchors MUST be stable across PR revisions of this document.

---

## §1 — The 5-seed dependency stack

This SEED targets a host that has the following five plow-pbc seeds
installed in dependency order. The order MUST be respected because each
seed verifies + extends the previous one. ^dep-seed-order

| Order | Seed | Layer | Anchor |
|---|---|---|---|
| 1 | `plow-pbc/seed-hermes` | The base Hermes Agent Docker scaffold + Codex OAuth bootstrap | ^dep-seed-hermes |
| 2 | `plow-pbc/seed-hermes-plow-chat` | The `plow_chat` platform plugin (iPhone iMessage / SMS as a Hermes channel) | ^dep-seed-plow-chat |
| 3 | `plow-pbc/seed-hermes-gbrain` | The gbrain CLI + Hermes hook for memory queries (`gbrain query`/`get`/`put`) | ^dep-seed-gbrain |
| 4 | `plow-pbc/seed-hostex-history-ingest` | Hostex conversation distiller + voice-synthesizer — populates gbrain with historical facts | ^dep-seed-hostex-ingest |
| 5 | `plow-pbc/seed-hermes-airbnb-manager` | This repo — boss + listener + hostex-context + courier sidecar + install glue | ^dep-seed-airbnb-manager |

Each seed has its own README + installer. This document orchestrates the
five into a single working system; per-seed details are
Implementation-defined by the respective seed README. ^dep-per-seed-readmes

---

## §2 — Host prerequisites

The host MUST satisfy every row in the table below BEFORE Phase 1 begins.
Phase 1 SHOULD NOT start if any row is unmet — fix at the host level
first. ^prereq-table

| Prereq | Verification command | Required outcome | Anchor |
|---|---|---|---|
| OS: macOS (recent) or Linux | `uname -a` | Darwin or Linux kernel string | ^prereq-os |
| Docker Desktop running | `docker info` | exits 0; reports `Server Version:` | ^prereq-docker |
| `git` | `git --version` | exits 0 | ^prereq-git |
| `gh` CLI authenticated (RECOMMENDED) | `gh auth status` | "Logged in to github.com" (HTTPS clone is an acceptable substitute) | ^prereq-gh |
| `bun` runtime | `bun --version` | exits 0 (install via `curl -fsSL https://bun.sh/install \| bash`) | ^prereq-bun |
| `jq` | `jq --version` | exits 0 (`brew install jq` / `apt-get install -y jq`) | ^prereq-jq |
| `HOSTEX_ACCESS_TOKEN` available | env var, or path the operator can paste | non-empty string; held in memory only — MUST NOT be echoed, logged, or committed | ^prereq-hostex-token |
| Free disk space | `df -h .` | ~10 GB free in `$WORK_DIR` (Docker images + gbrain Postgres) | ^prereq-disk |
| Outbound network reachable | the curl loop in ^prereq-network-cmd | every host returns a non-`000` HTTP code | ^prereq-network |
| OpenAI Codex OAuth | an OpenAI account that can complete `auth.openai.com/codex/device` | browser approval on §5 succeeds | ^prereq-codex-oauth |

The operator MUST run the following exact curl loop. Treat any HTTP
response (even 404 / 421 / 403) as reachable; only `000` (no connection)
is a fail. The operator MUST NOT use `curl -fsS` — these public root
endpoints return non-2xx codes by design and `-fsS` exits 22 on non-2xx.
^prereq-network-cmd

```bash
for h in https://api.hostex.io https://api.plow.co https://api.openai.com https://auth.openai.com https://github.com; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 "$h")
  [ "$code" = "000" ] && echo "BLOCKED: $h" || echo "OK ($code): $h"
done
```

Walltime budget: ~30 minutes, plus ~5–10 minutes for operator browser
interactions (Codex OAuth + plow_chat / iMessage binding). ^prereq-walltime

---

## §3 — Working directory + 5-seed checkout (Phase 1)

The host MUST use a fresh working directory. Cloning into an existing
checkout is forbidden — substrate drift caused defects on every prior
clean-install run. ^phase1-fresh-dir

```bash
WORK_DIR="${HOME}/plow-seeds-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$WORK_DIR" && cd "$WORK_DIR"
```

The host MUST clone all 5 seed repos from `main`. ^phase1-clone

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

**Verify** — every `*/ref/scripts/` (or `*/hermes-agent/scripts/`) MUST
exist as a directory. ^v-phase1

```bash
for d in seed-hermes/hermes-agent/scripts \
         seed-hermes-plow-chat/ref/scripts \
         seed-hermes-gbrain/ref/scripts \
         seed-hostex-history-ingest/ref/scripts \
         seed-hermes-airbnb-manager/ref/scripts; do
  test -d "$WORK_DIR/$d" || { echo "MISSING: $d"; exit 1; }
done
echo "  ✓ all 5 seed scripts dirs present"
```

---

## §4 — Bootstrap the seed-hermes scaffold (Phase 2)

The host MUST run `prepare.sh` from the `seed-hermes/hermes-agent/`
directory + bring up the base `hermes` service via Docker Compose.
^phase2-bootstrap

```bash
cd "$WORK_DIR/seed-hermes/hermes-agent"
./scripts/prepare.sh
docker compose up -d hermes
./scripts/check-ready.sh   # blocks until the gateway is up
```

**Verify** — all 3 gates MUST pass. ^v-phase2

| Gate | Command | Expected | Anchor |
|---|---|---|---|
| Container up | `docker compose ps hermes` | status `Up` | ^v-phase2-ps |
| CLI alive | `docker compose exec hermes hermes profile list` | exits 0 | ^v-phase2-cli |
| Dashboard reachable | open `http://localhost:9119` | dashboard loads | ^v-phase2-dashboard |

### §4.1 — Resolve the container UID/GID (REQUIRED, used by later phases)

The upstream `nousresearch/hermes-agent:latest` image's s6-overlay
stage2-hook (seed-hermes PR #6 deleted the local `seed-entrypoint.sh`
overlay; the image now does init+UID-remap natively) reads `HERMES_UID`
+ `HERMES_GID` from env and `usermod -u` / `groupmod -g` the
in-container `hermes` user to match. The host MUST compute the
post-remap UID/GID once from the live container and use it for every
later `docker compose exec` invocation. The host MUST NOT hardcode
`-u 501:20`. ^phase2-hermes-user

```bash
SCAFFOLD="$WORK_DIR/seed-hermes/hermes-agent"
HERMES_USER=$(cd "$SCAFFOLD" && docker compose exec -T hermes id -u | tr -d '\r'):$(cd "$SCAFFOLD" && docker compose exec -T hermes id -g | tr -d '\r')
echo "Container hermes runs as: $HERMES_USER"
```

### §4.2 — Pick the Hermes profile handles (REQUIRED, no default)

This seed is **operator-neutral**. There is no canonical "Daniel" or
other handle baked in. The operator MUST pick a lowercase handle for the
owner profile + a matching team-listener handle (the convention is
`<owner>` + `<owner>-team`, but any `[a-z][a-z0-9-]*` value is
acceptable). ^phase2-owner-profile

```bash
export OWNER_PROFILE="owner"           # operator picks any handle
export TEAM_PROFILE="owner-team"       # convention: <owner>-team
```

These exports MUST be readable by every later phase. The §11 installer
(airbnb-manager) reads them, validates them, and persists them to
`<scaffold>/.env` so `docker compose` can substitute `${OWNER_PROFILE}`
/ `${TEAM_PROFILE}` into per-profile gateway sidecars at compose-eval
time. If the operator skips the exports, the §11 installer prompts
interactively when stdin is a TTY and fails loud otherwise.
^phase2-owner-profile-persistence

---

## §5 — Hermes Codex OAuth (Phase 2.5, REQUIRED, NO FALLBACK)

All Hermes profiles in this stack default to `provider: openai-codex /
default: gpt-5.5`. Without a Codex OAuth credential in Hermes' pooled
vault, the first LLM-invoking call (boss webhook, distiller backfill)
crashes with `"No Codex credentials stored. Run hermes auth to
authenticate."` — and the distiller failure is **silent in stdout**
(backfill exits 0 with `processed=0` and no fact pages written).
^phase25-codex-required

The operator MUST run the canonical wrapper. No API-key fallback is
supported by this seed. If device-code OAuth cannot complete on this
machine (headless / CI / no browser), the operator MUST STOP — do not
switch providers, do not substitute any other model + key combination.
^phase25-no-api-key-fallback

```bash
cd "$SCAFFOLD"
./scripts/auth-openai-codex.sh
```

The wrapper runs `docker compose run --rm -T hermes auth add
openai-codex`, parses the device-code output, and surfaces an
`https://auth.openai.com/codex/device` URL + a code. The operator MUST
open the URL in any browser signed into the operator's ChatGPT account,
enter the code, and approve. The wrapper exits 0 only when Hermes prints
`Added openai-codex OAuth credential #<N>` and writes `data/auth.json`.
^phase25-wrapper

**Verify** — both gates MUST pass; the smoke test MAY be skipped if the
operator wants to defer model spend until §13. ^v-phase25

```bash
docker compose run --rm -T hermes auth list
# expected: "openai-codex (1 credentials):"
#           "  #1  openai-codex-oauth-1   oauth   device_code"

docker compose run --rm -T hermes status
# expected: "Provider: OpenAI Codex / Model: gpt-5.5"

# Smoke test (OPTIONAL — costs ~1¢):
docker compose run --rm -T hermes chat -q 'reply with just OK' -Q --yolo
# expected: "OK"
```

Recent upstream images bake the openai-python `output is None` patch
into the runtime (seed-hermes PR #5 + PR #6), so the smoke test SHOULD
succeed first try. If the operator hits a stale image cached locally
and the smoke test crashes with a `TypeError`, `docker pull
nousresearch/hermes-agent:latest` + `docker compose up -d
--force-recreate hermes` MAY resolve it. ^phase25-stale-image-note

If any required gate fails, the operator MUST STOP. ^v-phase25-stop

---

## §6 — Install plow-chat plugin (Phase 3)

```bash
cd "$WORK_DIR/seed-hermes-plow-chat"
HERMES_SCAFFOLD_DIR="$SCAFFOLD" bash ref/scripts/install_direct_mount.sh
```

**Verify** — plow-chat-platform MUST be listed by the in-container
plugin index. ^v-phase3

```bash
docker compose --project-directory "$SCAFFOLD" exec -T hermes hermes plugins list | grep plow-chat-platform
```

---

## §7 — Create + activate owner + team profiles (Phase 4)

The operator MUST create both Hermes profiles using the handles chosen
in §4.2. If §4.2 was skipped, the operator MUST set `OWNER_PROFILE` and
`TEAM_PROFILE` now before continuing — they are referenced literally
below. ^phase4-profile-create

```bash
(cd "$SCAFFOLD" && docker compose exec -T hermes hermes profile create "$OWNER_PROFILE")
(cd "$SCAFFOLD" && docker compose exec -T hermes hermes profile create "$TEAM_PROFILE")
```

⚠ The operator MUST then bind each profile to a real iMessage / SMS line
via `plow_chat` device-code. The activation helper lives at
`$WORK_DIR/seed-hermes-plow-chat/ref/scripts/create_plow_chat_curl.sh`
(or equivalent). The helper prints a URL + code; the operator completes
the bind from the target iPhone (`$OWNER_PROFILE` = operator's phone;
`$TEAM_PROFILE` = cleaner's phone). ^phase4-plow-chat-bind

**Verify** — both profiles MUST have `PLOW_CHAT_CHAT_UID` and
`PLOW_CHAT_TOKEN` set in their per-profile `.env`. ^v-phase4

```bash
grep -c 'PLOW_CHAT_CHAT_UID=..*' "$SCAFFOLD/data/profiles/$OWNER_PROFILE/.env"   # expect 1
grep -c 'PLOW_CHAT_TOKEN=..*'    "$SCAFFOLD/data/profiles/$OWNER_PROFILE/.env"   # expect 1
grep -c 'PLOW_CHAT_CHAT_UID=..*' "$SCAFFOLD/data/profiles/$TEAM_PROFILE/.env"    # expect 1
grep -c 'PLOW_CHAT_TOKEN=..*'    "$SCAFFOLD/data/profiles/$TEAM_PROFILE/.env"    # expect 1
```

---

## §8 — Install seed-hermes-gbrain (Phase 5)

gbrain REQUIRES an OpenAI API key for embeddings (semantic search). The
operator MAY use the same `OPENAI_API_KEY` supplied for other steps —
gbrain's embedding lookups are independent from Hermes' chat provider
(which is `openai-codex` OAuth — see §5; the operator MUST NOT swap
Hermes off Codex). ^phase5-embedding-key

```bash
cd "$WORK_DIR/seed-hermes-gbrain"
# GBRAIN_EMBEDDING_API_KEY is REQUIRED — installer fails loud if absent.
# OpenAI API key for embeddings ONLY (Hermes chat stays on Codex OAuth).
export GBRAIN_EMBEDDING_API_KEY="${OPENAI_API_KEY:?OPENAI_API_KEY must be set for gbrain embeddings}"
HERMES_SCAFFOLD_DIR="$SCAFFOLD" bash ref/scripts/install_gbrain_into_compose.sh
```

The gbrain installer defaults to PGLite. On Apple Silicon macOS the
PGLite WASM is known to crash on heavy write workloads
(`garrytan/gbrain#223`). §12 below installs a
`compose.gbrain-postgres.yaml` (from `ref/compose/` in this repo,
deployed by the airbnb-manager installer) that switches gbrain to a
Postgres backend — portable + avoids the WASM bug. ^phase5-pglite-note

**Verify** — `gbrain` MUST be on the in-container login-shell PATH.
^v-phase5

```bash
(cd "$SCAFFOLD" && docker compose exec -T hermes bash -lc 'command -v gbrain')   # expect /usr/local/bin/gbrain
```

---

## §9 — Register the Hostex webhook subscription on the owner profile (Phase 6)

The subscription tells Hermes "route Hostex `message_created` callbacks
to the `str-manager-approval` skill". It MUST exist BEFORE §11 installs
the boss skill — the airbnb-manager installer's prereq checks require
it. ^phase6-precondition

### §9.1 — Enable the webhook platform on the owner profile (Phase 6a, REQUIRED before subscribe)

`hermes webhook subscribe` MUST refuse to write the subscription if
`platforms.webhook.enabled` is absent from the profile's `config.yaml`.
The plow-chat installer (§6) does NOT write this block for the
airbnb-manager's webhook needs. The operator MUST add it explicitly.
(§11's installer ALSO performs this append idempotently as
defense-in-depth — but the webhook subscribe in §9.2 runs BEFORE §11,
so it MUST land here.) ^phase6a

```bash
OWNER_CFG="$SCAFFOLD/data/profiles/$OWNER_PROFILE/config.yaml"
touch "$OWNER_CFG"
if ! grep -q '^platforms:' "$OWNER_CFG"; then
  cat >> "$OWNER_CFG" <<'EOF'
platforms:
  webhook:
    enabled: true
    extra:
      host: "0.0.0.0"
      port: 8787
      secret: "INSECURE_NO_AUTH"
  plow_chat:
    enabled: true
EOF
  echo "  ✓ wrote platforms.{webhook,plow_chat} block to $OWNER_CFG"
else
  echo "  ✓ $OWNER_CFG already has a platforms: block; skipping"
fi
```

### §9.2 — Subscribe (Phase 6b)

```bash
(cd "$SCAFFOLD" && docker compose exec -T hermes bash -lc "
  hermes -p $OWNER_PROFILE webhook subscribe hostex-events \
    --skills str-manager-approval \
    --secret INSECURE_NO_AUTH \
    --prompt 'INCOMING_HOSTEX_PAYLOAD={__raw__}\\n\\nExtract event, conversation_id, message_id and follow Trigger 1. Owner channel: platform=plow_chat chat_id=\$(grep PLOW_CHAT_CHAT_UID /opt/data/profiles/$OWNER_PROFILE/.env | cut -d= -f2). Hostex API: hostex_base_url=https://api.hostex.io hostex_access_token=\$HOSTEX_ACCESS_TOKEN.'
")
```

**Verify** — the subscription MUST be present in the structural JSON
output. The operator MUST use `jq` for validation (`grep -c
hostex-events` returns 2 because the subscription name appears in both
the route key and the prompt body). ^v-phase6

```bash
jq -e '.["hostex-events"] // .subscriptions[]? | select(.name=="hostex-events")' \
  "$SCAFFOLD/data/profiles/$OWNER_PROFILE/webhook_subscriptions.json" >/dev/null \
  && echo "  ✓ hostex-events subscription present" \
  || { echo "  ✗ hostex-events subscription missing"; exit 1; }
```

### §9.3 — Webhook subscription caveats

- **Port pin.** `hermes webhook subscribe` without a prior
  `platforms.webhook` block defaults to `port: 8644`. §9.1's explicit
  YAML write pins port `8787` to match `compose.airbnb-coordinator.yaml`'s
  host mapping (`127.0.0.1:8787 → 8787`). If `port: 8644` appears in
  `$OWNER_PROFILE/config.yaml` after §9.2, the operator MUST re-run §9.1
  (idempotent) — it overwrites to 8787. ^phase6-port-pin
- **Hostex base URL + access token are baked into the subscription
  prompt literal.** The boss skill reads `hostex_base_url` and
  `hostex_access_token` from the prompt template stored in
  `webhook_subscriptions.json`, NOT from runtime env. If the operator
  later changes `HOSTEX_BASE_URL` (e.g. to swap DTU for real Hostex),
  the operator MUST re-run §9.2 — re-registering with the same name
  overwrites the prompt. Editing `$HOSTEX_BASE_URL` in `.env` alone has
  no effect on the webhook path. ^phase6-base-url-baked

---

## §10 — Install seed-hostex-history-ingest (Phase 7)

```bash
cd "$WORK_DIR/seed-hostex-history-ingest"
HERMES_SCAFFOLD_DIR="$SCAFFOLD" bash ref/scripts/install_hostex_ingest_into_compose.sh
```

The upstream installer creates the `hostex-distiller` profile but does
NOT create `voice-synthesizer`. §10.1 below covers `voice-synthesizer`
manually. (Tracked as upstream `seed-hostex-history-ingest` defect; this
seed's installer covers it until upstream does.) ^phase7-voice-synth-manual

### §10.1 — Voice-synthesizer profile (REQUIRED until upstream covers it)

```bash
(cd "$SCAFFOLD" && docker compose exec -T -u "$HERMES_USER" hermes hermes profile create voice-synthesizer)
docker cp \
  "$WORK_DIR/seed-hostex-history-ingest/ref/hermes-soul/voice-synthesizer-SOUL.md" \
  "$(cd "$SCAFFOLD" && docker compose ps -q hermes):/opt/data/profiles/voice-synthesizer/SOUL.md"
mkdir -p "$SCAFFOLD/data/profiles/voice-synthesizer/skills"
cp -r "$WORK_DIR/seed-hostex-history-ingest/ref/hermes-skills/synthesize-voice" \
   "$SCAFFOLD/data/profiles/voice-synthesizer/skills/"
# Mirror the scaffold's model: block so voice-synthesizer inherits
# provider: openai-codex. Pure-awk so no host-side pyyaml is required.
PROF_CFG="$SCAFFOLD/data/profiles/voice-synthesizer/config.yaml"
SCAF_CFG="$SCAFFOLD/data/config.yaml"
touch "$PROF_CFG"
if ! grep -qE '^model:' "$PROF_CFG" && grep -qE '^model:' "$SCAF_CFG"; then
  awk '/^model:[[:space:]]*$/{flag=1;print;next} /^[^[:space:]]/{flag=0} flag' "$SCAF_CFG" > "${PROF_CFG}.model.tmp"
  cat "${PROF_CFG}.model.tmp" "$PROF_CFG" > "${PROF_CFG}.merged"
  mv -f "${PROF_CFG}.merged" "$PROF_CFG"
  rm -f "${PROF_CFG}.model.tmp"
  echo "  ✓ mirrored model: block from scaffold into voice-synthesizer/config.yaml"
fi
```

**Verify** — all three artifacts MUST exist. ^v-phase7

```bash
(cd "$SCAFFOLD" && docker compose exec -T hermes bash -lc 'test -x /opt/data/home/hostex-ingest/initial-ingest.sh')
(cd "$SCAFFOLD" && docker compose exec -T hermes bash -lc 'test -f /opt/data/profiles/hostex-distiller/SOUL.md')
(cd "$SCAFFOLD" && docker compose exec -T hermes bash -lc 'test -f /opt/data/profiles/voice-synthesizer/SOUL.md')
```

---

## §11 — Install seed-hermes-airbnb-manager (Phase 8)

```bash
cd "$WORK_DIR/seed-hermes-airbnb-manager"
HERMES_SCAFFOLD_DIR="$SCAFFOLD" \
  HOSTEX_ACCESS_TOKEN="${HOSTEX_ACCESS_TOKEN}" \
  bash ref/scripts/install_airbnb_coordinator_into_compose.sh
```

The installer MUST: ^phase8-installer-contract

- Read `OWNER_PROFILE` + `TEAM_PROFILE` from the env exported in §4.2 (or
  prompt interactively if unset + stdin is a TTY) and persist them to
  `$SCAFFOLD/.env` so docker compose can substitute them into the
  per-profile gateway sidecars at compose-eval time.
- Verify all prereqs from §4–§10 (Codex OAuth, plow-chat plugin, gbrain
  CLI, brain git-init, owner profile + webhook subscription,
  `HOSTEX_ACCESS_TOKEN` resolvable). Fail loud if any is missing.
- Auto-wire `HOSTEX_ACCESS_TOKEN` + `HOSTEX_BASE_URL=https://api.hostex.io`
  into the owner profile `.env`.
- Auto-derive `AIRBNB_OWNER_MIRROR_SESSION_KEY` and write it to **both**
  the owner profile `.env` and the courier sidecar `.env`.
- Auto-patch `/opt/hermes/gateway/platforms/webhook.py` in the BASE
  `hermes` container to lift the `INSECURE_NO_AUTH + 0.0.0.0` safety
  rail (REQUIRED for the local DTU testing path) + verify the patch
  landed.
- Install the boss skill at `str-manager-approval` v12.4.1 (memory-first
  + attendant role + hostex-context Branch L + 3-tier early-checkin +
  gbrain-exclusive + auto-ack partial-to-guest).
- Install the listener skill at `airbnb-team-listener`.
- Install the `airbnb-courier` sidecar service via
  `compose.airbnb-coordinator.yaml`.
- Write `compose.gbrain-postgres.yaml` (the Postgres backend override
  for §12).
- Remove the legacy `gbrain-sync` sidecar from `compose.gbrain.yaml`
  (dead weight after v12.4 went gbrain-exclusive).

---

## §12 — Switch gbrain backend to Postgres + bring stack up (Phase 9)

The gbrain installer defaults to PGLite. The operator MUST switch to the
Postgres backend on macOS (avoids the WASM bug) and SHOULD use Postgres
on every platform for portability. ^phase9-postgres-required

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
# by gbrain — gbrain would report `(?d)` dimensions and the install would
# proceed with broken embedding lookups.
HERMES_USER=$(cd "$SCAFFOLD" && docker compose exec -T hermes id -u | tr -d '\r'):$(cd "$SCAFFOLD" && docker compose exec -T hermes id -g | tr -d '\r')
(cd "$SCAFFOLD" && docker compose exec -T -u "$HERMES_USER" -e HOME=/opt/data/home hermes bash -lc "
  gbrain init \
    --url 'postgres://gbrain:gbrain_local_dev_only@gbrain-postgres:5432/gbrain' \
    --embedding-model openai:text-embedding-3-small
")
```

### §12.1 — Per-profile sidecar webhook.py patch (known limitation)

`compose.airbnb-coordinator.yaml` declares per-profile sidecars
(`hermes-owner`, `hermes-owner-team`, `airbnb-courier`) that boot from
pristine `nousresearch/hermes-agent:latest`. The §11 installer patches
`/opt/hermes/gateway/platforms/webhook.py` in the BASE `hermes`
container's filesystem; that patch does NOT propagate to per-profile
sidecars (separate container instances, no shared image layer for that
file). The `hermes-owner` sidecar IS the one that binds the webhook
adapter on `0.0.0.0:8787` with the `INSECURE_NO_AUTH` secret — so it
trips the safety rail. ^phase9-sidecar-patch-gap

If the operator observes `hermes-owner` crashing at startup with
`webhook error: INSECURE_NO_AUTH ... non-loopback 0.0.0.0 ... refusing
to start`, the operator MUST apply the patch inside the live sidecar:
^phase9-sidecar-patch-workaround

```bash
(cd "$SCAFFOLD" && docker compose exec -T -u 0:0 hermes-owner \
  sed -i \
    's/if secret == _INSECURE_NO_AUTH and not _is_loopback_host/if False and secret == _INSECURE_NO_AUTH and not _is_loopback_host/' \
    /opt/hermes/gateway/platforms/webhook.py)
(cd "$SCAFFOLD" && docker compose restart hermes-owner)
```

A code-level fix (inline the patch into the sidecar's startup `command:`
in `compose.airbnb-coordinator.yaml`) is the right structural answer
and is pending a follow-up PR. seed-hermes PR #6 deleted the local
Dockerfile + `seed-entrypoint.sh` overlays (upstream image now does
init+UID-remap natively via s6-overlay), so "build a local image with
patches baked in" is NOT the workaround anymore — the per-sidecar
`docker exec` is. ^phase9-sidecar-fix-pending

**Verify** — gbrain MUST be reachable via Postgres + round-trippable.
^v-phase9

```bash
(cd "$SCAFFOLD" && docker compose exec -T -u "$HERMES_USER" -e HOME=/opt/data/home hermes bash -lc '
  echo "probe" | gbrain put test-init --content "install probe" && \
  gbrain get test-init | grep -q "install probe"
')
# expect exit 0
```

---

## §13 — Run the initial historical backfill (Phase 10)

```bash
(cd "$SCAFFOLD" && docker compose exec -T -u "$HERMES_USER" -e HOME=/opt/data/home hermes \
  bash -lc '/opt/data/home/hostex-ingest/initial-ingest.sh --limit 10')
```

Expected: a per-conversation `processed=N` line every 30–60 seconds.
Total runtime: ~5–8 minutes for 10 conversations.

**Verify** — both gates MUST pass. ^v-phase10

```bash
# Facts landed in gbrain
(cd "$SCAFFOLD" && docker compose exec -T -u "$HERMES_USER" -e HOME=/opt/data/home hermes bash -lc '
  gbrain list -n 1000 | grep "^facts/" | wc -l
')
# expect: at least 10 (typical: 15–25, depends on conversation richness)

# Quick semantic query
(cd "$SCAFFOLD" && docker compose exec -T -u "$HERMES_USER" -e HOME=/opt/data/home hermes bash -lc '
  gbrain query "wifi password"
')
# expect: a [score] facts/<property>/wifi line in output
```

If `processed=0` or `facts/` count is 0, the operator MUST STOP — most
likely Codex OAuth is not actually wired (re-run §5 verify). ^v-phase10-stop

The operator MAY then run an unbounded backfill (omit `--limit`) for
full historical coverage — ~3–6 hours for 343 conversations.
^phase10-full-backfill

---

## §14 — End-to-end acceptance via DTU (Phase 11)

The seed ships a Digital Twin Universe (DTU) — a local Hostex stand-in
for testing without involving real guests. If the `seed-hermes`
scaffold does not include a DTU CLI, the operator MUST install Flask +
the DTU server per the seed's `dev-harness/` README. ^phase11-dtu-required

```bash
# Register a webhook subscription pointing at the boss's port
dtu webhook set http://127.0.0.1:8787/webhooks/hostex-events --events message_created

# Fire a test guest message
dtu guest send --property mtn-home --from "AcceptanceTest" --content "Hi, what is the wifi password?"
```

**Verify** — all 3 gates MUST pass within ~90 seconds. ^v-phase11

```bash
# DTU MUST log a webhook_delivered event with status 202
dtu events | grep webhook_delivered | tail -1

# Boss session MUST contain `gbrain query` + `gbrain get` invocations
(cd "$SCAFFOLD" && docker compose exec -T hermes bash -lc "
  ls -t /opt/data/profiles/$OWNER_PROFILE/sessions/2026*.jsonl | head -1 | xargs grep -c gbrain
")   # expect >= 2

# Pending entry MUST contain memory_cite.gbrain_slug
(cd "$SCAFFOLD" && docker compose exec -T hermes cat /opt/data/home/.airbnb-manager/pirate-joker-pending.json | jq '.[] | .memory_cite.gbrain_slug' | tail -1)
# expect: "facts/mtn-home/wifi"
```

The operator's iPhone MUST receive a `plow_chat` mirror of the form:
^v-phase11-iphone

```
AcceptanceTest (Mtn Home): "Hi, what is the wifi password?"

I'd reply (from saved answer): "<the wifi network + password>"

OK to send?
```

---

## §15 — Production acceptance gates (run after §14)

These four gates MUST all pass for the install to count as
production-ready. Any failure is install-not-complete. ^acceptance-gates

| Gate | What it proves | Verification | Anchor |
|---|---|---|---|
| **G1** Webhook → boss → mirror | The basic ingest path: Hostex callback → boss skill → `plow_chat` mirror to owner | Fire a generic guest message via DTU. Operator's iPhone MUST receive a mirror within ~60s. | ^g1-webhook-mirror |
| **G2** gbrain memory-hit | The boss MUST look up facts via `gbrain query / gbrain get` (NOT filesystem); the answer MUST come from a distilled fact page, NOT hallucination | Pick a topic the `--limit 10` backfill is likely to have distilled (check `gbrain list -n 1000 \| grep ^facts/` first; wifi may NOT be in a small sample of recent winter-themed conversations). Universal-ish topics: "check-in time", "wifi password", "parking", "heating". Fire a guest message via DTU; verify `memory_cite.gbrain_slug == "facts/<property>/<topic>"` in the pending entry. For full coverage on G2, run an unbounded backfill (omit `--limit`) before this gate. | ^g2-memory-hit |
| **G3** Early-checkin 3-tier policy | Boss correctly classifies early-checkin by request-vs-checkin-day delta. TIER 1 (future) → defer with no team consult; TIER 2 (night-before) → calendar check via hxctx; TIER 3 (morning-of) → cleaner consult via 8b consult flow | Fire `dtu guest send --from "Tier1Test" --content "Can I check in early on Saturday?"` (when Saturday is multiple days out). The boss MUST draft a deferral and MUST NOT create a `q-*.md` brain query page. | ^g3-early-checkin |
| **G4** Multi-employee consult flow | When the boss decides a real guest question needs the cleaner, it MUST auto-ack the guest, ask the cleaner via `plow_chat`, wait for the answer, draft a final, mirror to owner for approve, owner approves, Hostex POST ships | Fire `dtu guest send --from "ConsultTest" --content "Will the unit be ready for early check-in today?"`. Within ~90s: brain query page MUST be created at `data/home/brain/queries/q-*.md`; cleaner's iPhone MUST receive an ask; owner's iPhone MUST receive an auto-ack mirror with no approve prompt. After cleaner replies + courier wake, owner's iPhone MUST receive a final draft mirror with `OK to send?`. | ^g4-consult-flow |

---

## §16 — Known limitations still present today

Multiple clean-install validation runs (macOS DinD substrate, Linux Pi
operator) shook out ~30 defects across the 5 seeds. Most have been
fixed upstream: seed-hermes PR #6 (upstream image now does init+UID
remap natively, no derived image needed), seed-hermes-gbrain PRs #3–#4
(UID detection + Codex OAuth recognition), and
seed-hermes-airbnb-manager PRs #8/#10/#11 (installer hardening +
OWNER_PROFILE operator-neutrality). This section enumerates **only
still-present limitations** an operator MAY hit on a fresh install
today. ^limitations-scope

| Symptom | Root cause | Workaround | Anchor |
|---|---|---|---|
| `hermes-owner` sidecar exits at startup with `webhook error: INSECURE_NO_AUTH ... non-loopback 0.0.0.0 ... refusing to start` | §11's installer patches `webhook.py` in the BASE `hermes` container; per-profile sidecar `hermes-owner` boots from pristine `:latest` in §12 so its `webhook.py` is unpatched. It IS the sidecar that binds the webhook adapter. | §12.1's manual patch + `docker compose restart hermes-owner`. Code-level fix pending. | ^lim-sidecar-webhook |
| Swapping `HOSTEX_BASE_URL` in the owner profile `.env` does NOT change where the boss POSTs. | `hostex_base_url` + `hostex_access_token` are baked into the webhook subscription prompt template (see §9.3). The boss reads them from the prompt, NOT from runtime env. | Re-run §9.2 with new values. `hermes webhook subscribe` with the same name overwrites the existing subscription's prompt — idempotent. (The owner-direct-chat `hxctx` path DOES read from runtime env and DOES pick up `.env` edits.) | ^lim-base-url-baked |
| `HOSTEX_ACCESS_TOKEN` visible in `webhook_subscriptions.json` (mode 644 by default). | Same root cause as ^lim-base-url-baked. The Hermes webhook adapter has no per-prompt secret-substitution mechanism today. | The operator SHOULD tighten mode: `chmod 600 "$SCAFFOLD/data/profiles/$OWNER_PROFILE/webhook_subscriptions.json"`. (The §11 installer already chmods the owner profile `.env` to 600.) | ^lim-token-in-prompt |
| Distiller backfill exits 0 with `processed=0` | Most commonly: Codex OAuth credential revoked or `data/auth.json` stale. §5 catches this for the BASE container at install time, but credentials can expire later. | Re-run `./scripts/auth-openai-codex.sh` from `$SCAFFOLD`. Re-verify with `docker compose run --rm -T hermes auth list \| grep openai-codex`. | ^lim-codex-expiry |
| `voice-synthesizer` profile missing after §10 | Upstream `install_hostex_ingest_into_compose.sh` creates `hostex-distiller` but not `voice-synthesizer`. | §10.1 covers the manual addition. (Tracked as upstream `seed-hostex-history-ingest` defect; this row will be removed when the upstream installer covers it.) | ^lim-voice-synth-manual |

If the operator hits a defect not listed above, the operator MUST
capture: (a) which phase the failure occurred in, (b) the verbatim
error, (c) which step exited non-zero. The operator SHOULD open an
issue against `plow-pbc/seed-hermes-airbnb-manager` with that triad.
^lim-issue-triad

---

## §17 — Open items + non-goals

### Open

- A code-level fix for the per-profile sidecar `webhook.py` patch
  (^lim-sidecar-webhook) — inlining the patch into the sidecar's
  startup `command:` in `compose.airbnb-coordinator.yaml` — is the
  right structural answer and is pending a follow-up PR. ^o-sidecar-fix
- A code-level fix for the upstream voice-synthesizer absence
  (^lim-voice-synth-manual) — pushing the §10.1 logic into
  `install_hostex_ingest_into_compose.sh` — is pending in
  `plow-pbc/seed-hostex-history-ingest`. ^o-voice-synth-upstream
- The 3 outstanding `seed-plow-str-manager` blockers (manual session
  key construction, INSECURE_NO_AUTH + public tunnel, secret-in-prompt)
  are deploy blockers for production use. Tracked separately; this seed
  installs but production deployment SHOULD wait for those fixes.
  ^o-str-manager-blockers

### Non-Goals

- This SEED does not document the Hostex API; see
  `seedlab/seeds/airbnb-manager.seed.md` and its captured wire samples.
  ^ng-hostex-api
- This SEED does not document the Plow Chat API; see `seed-plow-chat`.
  ^ng-plow-chat-api
- This SEED does not document the Hermes Agent runtime; see
  `seed-hermes`. ^ng-hermes-runtime
- This SEED does not document gbrain; see `seed-hermes-gbrain` and the
  upstream gbrain repo. ^ng-gbrain
- This SEED does not implement group-chat consultation (one chat with
  multiple team members at once). Per CEO premise, "no groups."
  ^ng-groups
- This SEED does not implement guest-side broadcast (one boss message
  to multiple guests). Out of scope. ^ng-guest-broadcast
- This SEED does not commit, log, or print Plow Chat secrets, Hostex
  tokens, or owner channel tokens. Anywhere a token would appear in
  this document's example commands, the example references the env var
  name only (`$HOSTEX_ACCESS_TOKEN`), never a literal value. ^ng-secrets
- This SEED MUST NOT use an API-key fallback in place of Codex OAuth.
  The boss skill, distiller, and listener all assume `openai-codex` and
  expect device-code OAuth. API-key paths (`provider: custom +
  OPENAI_API_KEY`) work in isolation but diverge from validated
  production behavior — drafts use a different model, voice synthesizer
  outputs differ, and the install is not a faithful reproduction of
  the production stack. ^ng-api-key-fallback
- This SEED MUST NOT install the `gbrain-sync` sidecar (removed in
  v0.2.x). Older installs may have it lingering in
  `compose.gbrain.yaml`; the §11 installer's defensive cleanup removes
  it. ^ng-gbrain-sync
- This SEED does not document the production Hostex tunnel setup. DTU
  is the test stand-in; production uses a real Hostex tunnel registered
  against `auth.openai.com`-side credentials, configured out of band.
  ^ng-production-tunnel
- For per-seed implementation details, the operator SHOULD consult each
  seed's README. This document orchestrates; it does not duplicate the
  per-seed specs. ^ng-per-seed-duplication
