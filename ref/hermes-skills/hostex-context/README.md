# hostex-context

Read-only live Hostex state for the STR coordination boss. Documents the Hostex
API surface and ships five tools (`hxctx`) the boss calls at classification and
drafting time: `guest-state`, `occupancy`, `calendar`, `reservations`,
`schedule`. See `SKILL.md` for behavior and `reference/` for the API + state
model.

## Layout

```
SKILL.md                 behavioral guidance (loaded by the boss agent)
hxctx                    CLI entrypoint (5 subcommands)
_client.py               live Hostex read client (no cache/mirror)
_classify.py             pure guest-state + occupancy logic (no I/O)
reference/hostex-api.md  documented API surface
reference/guest-state.md state model + tie-break
tests/test_classify.py   Tier-1 pure-function unit tests (no network)
tests/validate.sh        Tier-2 end-to-end shape/state assertions (vs a DTU)
```

## Install (boss container)

Deploy the directory to `/opt/data/home/hostex-context/` (alongside
`airbnb-courier/`). The boss skill references `hxctx` by that absolute path,
matching the existing `query-edit.py` convention. Set in the owner profile env:

```
HOSTEX_BASE_URL=https://api.hostex.io      # or the DTU for staging/tests
HOSTEX_ACCESS_TOKEN=<token>
```

## Tests

```sh
# Tier 1 — pure logic, no network
python3 tests/test_classify.py

# Tier 2 — end-to-end against a running DTU (single source of truth stand-in)
DTU_BASE=http://127.0.0.1:8082 \
DTU_PY=/path/to/dtu.py PYTHON=/path/to/python \
tests/validate.sh
```

Both tiers assert mechanical state only. Draft phrasing is validated by eyeball
or LLM-as-judge — never by regex on model output (architectural rule).

## Single source of truth

Hostex is authoritative for reservations / calendar / availability. The tools
pull live on every call; the only optimization is request-scope memoization
within one process. No persistent cache, mirror, or store.
