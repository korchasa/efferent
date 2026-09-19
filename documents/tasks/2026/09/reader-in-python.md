---
date: 2026-09-19
status: in-progress
tags: [reader, python, hpke, mcp, tooling]
related_tasks: [agent-writes-health, approving-agent-changes]
---

# The reading side is one Python implementation

## Goal

One reader, in Python, with one dependency. The script an agent receives from `setup_guide` and the
tool the owner runs on their own machine are the same code, so nothing can drift between them, and
nothing on the reading side trusts a cryptography package nobody has audited.

## Overview

### Context

On 2026-09-19 the owner ruled that a guide may not name a dependency it cannot vouch for, and the
Python reference in `setup_guide` dropped `pyhpke` for an RFC 9180 implementation of its own on top
of PyCA `cryptography` (commit `44f9504`). The TypeScript reader under `tools/` still sits on
`hpke-js`, a package of the same single author, and it is a second implementation of everything the
Python script does: handoff parsing, HPKE, the day layout, edit packing and signing. The owner chose
to replace it outright rather than swap its HPKE (option B, 2026-09-19).

What the TypeScript reader is, measured:

- `tools/` — 5 modules, 2 863 lines of code and 2 130 of tests: `archive.ts` (keys, mirror, fetch,
  edits), `analysis.ts` (pure functions over events), `connection.ts` (handoff import),
  `efferent.ts` (the command line: connect, keygen, send, read, sync, status, query, ask, write,
  edits) and `mcp.ts` (JSON-RPC over stdio, spoken directly, nine `phone_data_*` tools).
- `protocol/` — shared with the server. The Worker imports `attestation`, `batch`, `edits`, `ids`
  and `signing`; it never imports `sealedbox`, `sealedbox-v1`, `framing` or `day`. Those four exist
  for the reader and for the Swift interop, and they are where `hpke-js` lives.
- `scripts/interop.ts` runs the Swift `InteropTests` through `xcodebuild`, then opens and verifies
  the fixtures the tests print with the TypeScript protocol. `scripts/python-interop.ts` checks the
  guide script against the TypeScript reader in both directions.
- The owner's agents reach the local MCP by `deno run -A tools/mcp.ts` (`~/.codex/config.toml:143`;
  `~/.claude.json` names the project). Those registrations are the owner's files.

### What the surface already gives us, verified

- The guide script (`server/src/python-reference.ts`, 461 lines) already parses a handoff, checks
  both key pairs against the bucket, opens a day, unpacks layout 2 into NDJSON, validates, packs,
  seals and signs an edit, and lists edits. It is the wire layer of the new reader as it stands.
- Every stored file the reader keeps is JSON or NDJSON with a documented shape — `reading-key.json`
  and `editor-key.json` (bare base64url PKCS8), `mirror.json`, `days/<day>.ndjson`, `edits.json`,
  `metrics.json` — and `cryptography` loads PKCS8 DER directly. The owner's existing `EFFERENT_HOME`
  is read as it is; nothing is migrated.
- `tools/mcp.ts` speaks JSON-RPC itself, in about a hundred lines, so the Python server needs no
  MCP SDK either. `server/server_test.ts` shows the client handshake the tests expect.
- Python 3.13 is at `/opt/homebrew/bin/python3.13`; `ruff` is installed system-wide. The system
  `python3` is 3.9 and cannot run `str | None` annotations.

### Constraints

- `deno task <verb>` stays the command interface of the repository (factory rule). Deno remains the
  task runner and the server's toolchain; Python is reached through tasks that name the interpreter.
- One dependency at run time: `cryptography`. Tests use the standard library's `unittest`;
  formatting and linting use `ruff`, a development tool that never ships.
- The guide script and the reader's wire module are one file. `server/src/python-reference.ts` is
  generated from it, and a test fails when the two differ.
- Stored formats do not change. A reader connected before this change keeps working from the same
  directory without a migration.
- The server keeps its TypeScript protocol modules and their tests untouched.
- The Swift interop keeps covering both directions — the phone's frame opened here, this side's edit
  opened by the phone — with Python as the second party.

## Decided

- **Layout.** `reader/efferent_hpke.py` is the guide script, verbatim. `reader/efferent/` is the
  package that imports it: `archive.py`, `analysis.py`, `connection.py`, `cli.py`, `mcp.py`,
  `interop.py` (the Swift fixture side), `phone.py` (the `keygen`/`send` stand-in for a phone).
  `reader/tests/` holds the `unittest` suites. `reader/pyproject.toml` declares the package and
  `cryptography`.
- **Interpreter.** `deno task reader:setup` creates `reader/.venv` from `python3.13` and installs
  `cryptography` and `ruff`. Every reader task runs `reader/.venv/bin/python`; `EFFERENT_PYTHON`
  overrides it. `.venv` is ignored.
- **Tasks.** `efferent` → `python -m efferent.cli`, `mcp` → `python -m efferent.mcp`,
  `test:reader` → `python -m unittest discover`, `reference` → regenerate the embedded script.
  `check` gains `ruff format --check`, `ruff check` and the reader tests; `fmt` gains `ruff format`.
  `interop:python` goes: its two directions are now the unit tests and the Swift interop.
- **Deletions, once Python is green.** `tools/`, `protocol/sealedbox.ts`, `protocol/sealedbox-v1.ts`,
  `protocol/framing.ts`, `protocol/day.ts`, the protocol tests that only they served, the three
  `@hpke/*` entries in `deno.json`, and `scripts/python-interop.ts`.
- **MCP tool surface stays the same nine tools with the same names and descriptions**, so the
  owner's agents notice nothing but the command that starts the server.

## Definition of Done

1. **Wire.** `reader/efferent_hpke.py` is the guide script; `server/src/python-reference.ts` is
   generated from it and a test fails on drift. Unit tests cover the RFC 9180 A.2.1 vectors, handoff
   parsing (both key pairs, the bucket check, three and four fields), layout 2 expansion and its
   refusals, edit validation and packing. Evidence: `deno task test:reader`.
2. **Archive and command line.** `connect`, `sync`, `status`, `query`, `ask`, `read`, `write`,
   `edits` behave as the TypeScript ones did against the same `EFFERENT_HOME`, with the same files,
   modes and messages; `keygen` and `send` still stand in for a phone. Evidence: the ported
   `reader_test`, `connection_test` and `archive_permissions_test` cases, green.
3. **Analysis.** Every correction in `tools/analysis.ts` — merged sleep, noon-to-noon nights, totals
   never summed, hourly and daily never mixed, the unit note — is ported with its test. Evidence:
   the ported `analysis_test` cases.
4. **MCP.** `python -m efferent.mcp` serves the nine tools over stdio, and the ported `mcp_test`
   cases spawn it as a process and pass. Evidence: `deno task test:reader`.
5. **Interop.** `deno task interop` runs the Swift tests and verifies their fixtures with Python,
   both directions. Evidence: the task, green, on a simulator.
6. **Removal.** The TypeScript reader, the four orphaned protocol modules, their tests, the
   `@hpke/*` dependencies and `scripts/python-interop.ts` are gone; `deno task check` is green;
   `grep -r hpke-js` finds nothing outside history. Evidence: `deno task check`.
7. **Docs and registrations.** `README.md`, `AGENTS.md`, `documents/connection.md` describe one
   Python reader and how to set it up; the owner's MCP registrations are switched with their OK;
   `APPS.md` in the factory records the change.

## Solution

Phases, each a commit with `deno task check` green:

- **P1 — wire and skeleton.** Move the guide script to `reader/efferent_hpke.py`; add
  `scripts/reference.ts` and the drift test; `pyproject.toml`, `reader:setup`, `test:reader`,
  `ruff` in `check` and `fmt`; the DoD-1 tests.
- **P2 — archive, connection, analysis, cli.** Port `archive.ts`, `connection.ts`, `analysis.ts`,
  `efferent.ts` and their tests. The `send` stand-in needs day packing, batch framing and upload
  signing in Python (`phone.py`), ported from `protocol/day.ts`, `batch.ts`, `signing.ts`.
- **P3 — mcp.** Port `mcp.ts` and `mcp_test.ts`.
- **P4 — interop and removal.** `interop.py` for the fixture side; `scripts/interop.ts` calls it;
  delete the TypeScript reader and the orphaned protocol modules; drop the dependencies; fix the
  gitleaks allowlist path if the fixture key moves.
- **P5 — docs and hand-over.** README, AGENTS.md, connection.md; ask the owner before touching
  `~/.codex/config.toml` and `~/.claude.json`; APPS.md row.

## Progress

- 2026-09-19: scoped; P1 started.
- 2026-09-19: P1 done (`3c42bac`). The guide script is `reader/efferent_hpke.py`, `deno task
  reference` regenerates the copy the Worker serves and a test fails on drift between them.
  `reader:setup`, `test:reader` and `ruff` are in place.
- 2026-09-19: P2 done (`0dda9d6`). `archive.py`, `connection.py`, `analysis.py`, `cli.py` and
  `phone.py`, with the ported tests. `phone.py` packs a day, frames a batch and signs an upload, so
  `send` still stands in for a phone.
- 2026-09-19: P3 done (`dee0f6e`). `mcp.py` serves the nine tools over stdio. The two servers were
  run side by side and their `initialize` and `tools/list` answers diffed field by field until
  identical — one tool description had lost a line break, which is what that comparison caught.
  A red probe found two holes first: the edit-tag assertions called the function under test, so
  they agreed with themselves, and nothing covered `note()` at all. Both are closed; breaking
  either deliberately now fails exactly two tests.
- 2026-09-19: P4 done (`fdb9124`). `interop.py` is the reading half and the fixture source;
  `scripts/interop.ts` only runs the Swift test and carries the markers. The TypeScript reader,
  `protocol/{sealedbox,sealedbox-v1,day}.ts`, the `@hpke/*` dependencies and
  `scripts/python-interop.ts` are gone. `protocol/framing.ts` stays — `edits.ts` compresses with it
  and the service imports that. `scripts/reader-run.ts` keeps `mcp` and `efferent` as `deno task`s.
  Reversing series order in `pack_day` made the interop check fail with "Swift and Python packed
  2026-08-07 differently", so the byte-equality claim bites. The secret scan needed the fixture
  allowlist to name both the new path and the old one, because it reads history too, and needed the
  reader's `__pycache__`, `.venv` and `.interop.json` exempted the way `build/` already is.
- 2026-09-19: P5, docs done. `README.md`, `AGENTS.md` and `documents/connection.md` describe one
  Python reader. Still open: the owner's own MCP registrations (`~/.codex/config.toml:143` and
  `~/.claude.json` still run `deno run -A tools/mcp.ts`, which no longer exists) and the `APPS.md`
  row in the factory.
