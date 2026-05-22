# seed-hermes-airbnb-manager

Async multi-person coordination layer for short-term rental hosts. Installs into a
running `seed-hermes` Compose scaffold and turns a single-person Hermes airbnb-manager
bot into a "boss + team listener + courier" system: the boss owns the guest
conversation, consults the right team member over iMessage (via `seed-hermes-plow-chat`),
and assembles a cited client reply when the team has answered — all while keeping
the owner as the final-approval gate.

## Purpose

Today, a host running the legacy `airbnb-manager` seed manually pings the cleaner /
handyman / etc. out-of-band whenever a guest message needs information only a team
member has. This doesn't scale past one property and locks the host in the loop on
every guest question.

This seed installs:

- A **boss skill** (`airbnb-coordinator-boss`) that replaces the legacy
  `str-manager-approval` skill. It classifies guest messages, fans out asks to team
  members when needed, and drafts cited replies when team answers arrive. The
  legacy "no consult" fast path is preserved so the existing demo continuity holds.
- A **team listener skill** (`airbnb-team-listener`) on a second Hermes profile,
  bound to N team-member chats via the `PLOW_CHATS=<uid>:<key>,...` multi-token
  env. Info-capture only — this profile NEVER sends to clients.
- A **courier sidecar** (`airbnb-courier`) in `compose.airbnb-coordinator.yaml`.
  60-second tick. Re-pings at 30 min SLA, escalates to owner at 60 min. Wakes
  the boss only when work is ready — zero LLM cost when idle (uses Hermes'
  `wakeAgent` per the documented cron primitive).
- Brain page templates for `team/<member>.md`, `properties/<property>.md`, and
  the live state files `queries/q-<datetime>-<conv>.md`. These live in the
  `gbrain` brain repo at `/opt/data/home/brain/`, so the owner can ask
  "what's pending?" through normal `gbrain search`.

The whole system is durable across container restarts via the bind-mounted brain
repo. The query pages ARE the state — there is no parallel database.

## Install order

This seed sits on top of four existing seeds. Install them in this order:

1. `seed-hermes` — base Compose scaffold. Run `hermes-agent/scripts/prepare.sh`.
2. `seed-plow-chat` — Plow Chat API spec (no install required; documentation only).
3. `seed-hermes-plow-chat` — `plow_chat` gateway platform. Run its
   `ref/scripts/install_direct_mount.sh --scaffold ./hermes-agent`. **Requires the
   `PLOW_CHATS=<uid>:<key>,...` multi-token patch** (Stream #1) for this seed to
   run end-to-end. Without the patch, the team listener can only bind one team
   member at a time; use `--skip-team-listener` here for early-tester installs.
4. `seed-hermes-gbrain` — brain markdown repo at `/opt/data/home/brain/`. Run its
   `ref/scripts/install_gbrain_into_compose.sh --scaffold ./hermes-agent`.

Then this seed:

```bash
git clone https://github.com/plow-pbc/seed-hermes-airbnb-manager
cd seed-hermes-airbnb-manager
./ref/scripts/install_airbnb_coordinator_into_compose.sh \
  --scaffold ../hermes-agent \
  --owner-profile daniel \
  --team-profile daniel-team
```

That:
- Drops both Hermes skills into `<scaffold>/data/profiles/<profile>/skills/`.
- Writes both SOUL files.
- Creates the `daniel-team` Hermes profile (mirrors the global model block per
  the `seed-hermes-gbrain` pattern).
- Writes `compose.airbnb-coordinator.yaml` (courier sidecar) into the scaffold.
- Appends `:compose.airbnb-coordinator.yaml` to the scaffold's `COMPOSE_FILE`
  in `.env` so `docker compose up -d` starts the sidecar without `-f` flags.
- Drops brain page templates (`team/`, `properties/`, `queries/.gitkeep`) into
  `/opt/data/home/brain/` and git-commits the templates.
- Interactively walks the operator through `ref/scripts/seed_team_brain_pages.sh`
  to author the initial `team/*.md` and `properties/*.md` pages for their
  actual team + properties (NOT committed to this repo — these are per-install
  config).

## Quick smoke test

After install, with the scaffold running and the existing Hostex webhook live:

```bash
./ref/verify.sh --scaffold ../hermes-agent
```

That walks through:
- Brain page schema present at `/opt/data/home/brain/{team,properties,queries}/`.
- Both skills loaded into their respective profiles.
- Courier sidecar running (`docker compose ps gbrain-sync airbnb-courier`).
- Owner-side legacy "no consult" fast path still draft+ships an approved reply
  to the captured Hostex wire sample (REGRESSION GATE for the live Trial Reel demo).
- End-to-end consult flow: synthetic guest message → boss writes `q-*.md` →
  fan-out plow_chat POST → synthetic team reply via plow_chat → courier
  detects + wakes boss → boss drafts cited reply → owner sees mirror.

## How the brain pages work

Three subdirs under `/opt/data/home/brain/` (the gbrain content repo):

```
brain/
├── team/
│   ├── cleaner-maria.md           # role + responsibilities + plow_chat uid
│   └── handyman-juan.md
├── properties/
│   ├── prop-123-main-st.md        # Hostex property id + per-role team assignments
│   └── prop-456-oak-ave.md
└── queries/
    ├── q-20260523-1230-conv42.md  # LIVE STATE — frontmatter is the source of truth
    ├── q-20260523-1415-conv88.md
    └── ...
```

The `queries/q-*.md` files ARE the durable state for in-flight conversations. The
boss skill creates them on guest message arrival, the listener writes team answers
into them, the courier reads them on tick to drive re-pings + escalations + wakes.
All writes are flock-protected; all changes are git-committed (matches the
`seed-hermes-gbrain` ingest contract).

See `SEED.md` for the full RFC 2119 normative spec including frontmatter schemas.

## Configuration

| Env var | Required | Default | Used by |
|---|---|---|---|
| `OWNER_PROFILE` | yes | `daniel` | install script |
| `TEAM_PROFILE` | yes | `daniel-team` | install script |
| `HOSTEX_BASE_URL` | yes | (inherited from owner profile `.env`) | boss skill |
| `HOSTEX_ACCESS_TOKEN` | yes | (inherited) | boss skill |
| `PLOW_CHAT_BASE_URL` | yes | (inherited from team profile `.env`) | boss skill (REST), listener skill (WSS) |
| `PLOW_CHATS` | yes (for team) | none | team profile `plow_chat` adapter |
| `AIRBNB_COURIER_TICK_SECONDS` | no | `60` | courier sidecar |
| `AIRBNB_COURIER_SLA_MINUTES` | no | `30` | courier sidecar |
| `AIRBNB_COURIER_ESCALATION_MINUTES` | no | `60` | courier sidecar |
| `AIRBNB_OWNER_MIRROR_SESSION_KEY` | yes | (set by install script from owner channel) | courier sidecar, boss skill |

## When a team member leaves

Edit `/opt/data/home/brain/team/<member>.md` to mark them inactive (set
`active: false` in frontmatter); the boss skill stops routing to them. To
remove their plow_chat binding, remove their `<uid>:<key>` pair from the
`PLOW_CHATS` env in the team profile's `.env` and restart the scaffold.

## Known limitations (v0.1.0)

- Per-role SLAs (cleaner = 30 min, handyman = 60 min) — schema reserves
  `sla_minutes` per team page but v0.1.0 uses the global default for all roles.
- No group chats — explicitly out of scope (CEO premise).
- Single owner — schema reserves `approved_by` for future multi-owner; v0.1.0
  is Daniel-only.
- No web UI for `queries/` — debug via `cat`/`grep` and the brain repo's git log.
- Brain repo bloat — no archive job in v0.1.0. At expected volume (< 100
  queries/day) this is fine for the first 12 months.

## Open

- `seed-hermes-plow-chat` `PLOW_CHATS=<uid>:<key>,...` multi-token patch (Stream
  #1) is required for the team listener to bind > 1 team member from a single
  profile. The install script accepts `--skip-team-listener` until that lands.
- The 3 `seed-plow-str-manager` blockers (manual session key construction,
  INSECURE_NO_AUTH + public tunnel, secret-in-prompt) are deploy blockers for
  the owner-facing webhook side. Tracked separately; not in this repo's scope.

## License

MIT. See LICENSE.
