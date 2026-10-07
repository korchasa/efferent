---
date: 2026-10-08
status: in progress
implements: [READER-1, READER-2, READER-3, READ-2, READ-3]
tags: [reader, mcp, setup-guide, node, skill]
related_tasks:
  - [The protocol: a bucket id opens nothing](protocol-hardening.md)
---

# One Node client for the skill, the local MCP server and the setup guide

## Goal

Every agent the owner uses should be able to read and write the Health archive in every session,
not only in the one the handoff was pasted into. The carrier for that is an agent skill, and a skill
can only count on what the popular ones count on: Node, not Python (skills.sh top 100, checked
2026-10-08: 47 rely on Node, 5 bundle Python, none assume an interpreter of a given version, and the
macOS system `python3` is 3.9, below the reader's floor). So the reading side the agents run becomes
one dependency-free Node file, `efferent.mjs`, that is at once the skill's command line, the local
MCP server (`node efferent.mjs mcp`) and the program the service's `setup_guide` hands an agent.
The Python reader stays as the reference the phone's interop check is held against (owner, variant
D, 2026-10-08).

## Overview

### Context

- The research behind this choice is the owner's, kept outside this repository (2026-10-05 and
  2026-10-08). Only a local process can decrypt, the service
  never receives the key (owner), and the carriers that persist across sessions are a user-level MCP
  registration and a skill folder.
- Node built-ins cover every primitive the wire needs, verified on Node 24.18: X25519
  (`crypto.diffieHellman`), ChaCha20-Poly1305 (`createCipheriv('chacha20-poly1305')`), Ed25519
  (`crypto.sign`), HKDF (`createHmac`), AES-GCM for the legacy v1 envelope, raw deflate (`zlib`),
  `fetch`. No package is needed, which is the same stance as the Python reader's "only
  `cryptography`" (AGENTS.md, "Do not bring a third-party HPKE package back").

### Current State

- `reader/efferent_hpke.py` (652 lines) is the wire and the guide's script; `reader/efferent/*.py`
  (≈3 300 lines) is the mirror, the analysis, the command line and the stdio MCP server; 90 Python
  tests cover them. `deno task mcp` and `deno task efferent` run them from `reader/.venv`.
- The service repository carries a hand copy of `efferent_hpke.py`, renders it into
  `server/src/python-reference.ts` (`deno task reference`, `String.raw`, refuses backticks and
  `${`), and `setup-guide.ts` is written around Python: a venv, `pip install cryptography`,
  `python efferent_hpke.py …`. `index.ts` names the Python flags in `signedReadsOnly` and two tool
  descriptions; `server/reader_test.ts:365` pins that text.
- The owner's Codex registers the local server as `reader/.venv/bin/python -m efferent.mcp` with an
  explicit `EFFERENT_HOME` (`~/.codex/config.toml`, outside both repositories).

### Constraints

- Node built-ins only, ES module, one file, Node ≥ 22 (`node --test` over a list of files works from 22; the client itself also runs its self-test on 18). No `npm install` anywhere on the agent path.
- The on-disk profile stays the Python one byte for byte in meaning: `reading-key.json`
  (base64url PKCS8 + raw public), `editor-key.json`, `mirror.json`, `days/<day>.ndjson`,
  `edits.json`, `metrics.json`, directories 0700 and files 0600 written through a rename. A profile
  the Python reader made is read by the Node client without a migration.
- The MCP surface is a public contract: the same nine `phone_data_*` tools, names, schemas,
  descriptions and answer shapes, the same protocol versions and instructions.
- Every rule in AGENTS.md "Answering on behalf of a reader" holds in the port: sleep merged, nights
  noon to noon, daily and hourly totals never meet, the SpO2 note, refuse rather than truncate, a
  stale answer says so, `metrics.json` tested by its file, one stats call per question.
- The service never receives a key; nothing here may change that.
- The phone and the Worker change the wire together — this task changes no byte on the wire, so the
  Worker side is a text change (the guide) and is deployed by the owner, never by this task.
- This repository is public: no private place outside it is named here.

### Affected Surface

Scout report, verbatim except for one edit: this repository is public, so the absolute paths are cut to
repository-relative ones and two mentions of places outside both repositories are replaced by a
bracketed note.

```
## Surface

Orientation: no skill exists yet for Efferent. `grep -il skill` across both repos (excluding node_modules, build, Derived) found nothing. The only Efferent-named hit among the local skill folders [paths outside both repositories removed] was none. The skill's home directory and packaging are therefore not decided anywhere in the tree. Also, `node` is not mentioned as a runtime in either repo's rulebook; the toolchain is Deno for tasks and Python 3.13 for the reader.

**A. The things the Node client would reimplement (producers of the behaviour)**

- `efferent/reader/efferent_hpke.py` (about 28 KB) — the wire reference: handwritten RFC 9180 HPKE, day unpacking (raw deflate via `zlib.decompress(..., -MAX_WBITS)` at lines ~297-298, with the columnar day layout and old NDJSON days), read-key and editor-key derivation, request signing, `--self-test` against RFC vectors, `--list/--day/--from/--to/--write/--edits`, edit sealing and packing (~lines 531-542). This is the file D names as "the reference for compatibility". A Node client needs a port of every function here (HPKE, Ed25519 signing, deflate, packing). Node 22 has no built-in ChaCha20-Poly1305 HPKE, so the port is a decision about its own crypto, and the `cryptography`-only dependency stance would become a "node:crypto only" stance.
- `efferent/reader/efferent/*.py` — the rest of the reading side, about 3,300 lines:
  - `mcp.py` (1,138 lines) — the stdio MCP server that `node efferent.mjs mcp` must replace: JSON-RPC 2.0 newline-delimited, a `TOOLS` list (overview, daily, statistics, sleep, workouts, samples, `phone_data_write`, `phone_data_edits`, sync), the `handle()`/`serve()` dispatcher, the mirror-freshness class (lines ~97-250), and `serve()` required to stay the last line (AGENTS.md ~387).
  - `analysis.py` (356) — turns days into answers, with all the corrections.
  - `archive.py` (494) — keys, service calls, mirror, state, `EFFERENT_HOME` (default `.efferent`, line 56-59).
  - `cli.py` (444) — the `efferent` command: ask, sync, query, connect (`connect --handoff -`), send, mcp.
  - `phone.py` (242) — write items and the refusal of unknown keys.
  - `sealed.py`, `days.py`, `edits.py`, `connection.py`, `interop.py` (414, the check fixtures).
  - On disk, the mirror and handoff layout (one file per day under `EFFERENT_HOME`) is a format the Node client must share or keep separate.
- `efferent/reader/pyproject.toml` — `efferent` console script entry point, `cryptography>=42`. A Node client duplicates this packaging role.

**B. Parallel copies of the reference (where "the program the service hands to agents" lives)**

- `efferent-service/reader/efferent_hpke.py` — byte copy of the file above, made by hand ("copy the file here", `efferent-service/AGENTS.md` lines 102-112). Nothing detects drift between this copy and the original.
- `efferent-service/server/src/python-reference.ts` (655 lines) — generated string constant of the same file.
- `efferent-service/scripts/reference.ts` — the generator (`deno task reference`). It refuses backticks and `${` in the source, a constraint that would apply to any embedded Node script too.
- `efferent-service/server/src/setup-guide.ts` (98 lines) — the `setup_guide` text. It is written entirely around Python: venv, `pip install cryptography`, `python efferent_hpke.py --self-test`, `--handoff/--from/--to/--day/--list/--write/--edits`, and "No Efferent repository, Deno, local MCP server or gateway restart is required". It embeds the Python in a fenced block and ends with a closing paragraph about "the Python reference". D says the client "replaces the program the service hands to agents", which touches this text and the embedded script.
- `efferent-service/server/src/index.ts` — tool descriptions that point at the "reference code/reader from setup_guide": lines ~282-296 (setup_guide description "reference Python"), ~306, ~347, ~386, ~452-455 (hint text about a saved copy lacking `--list` or `--from`), ~685-686 (error text naming the reference reader). These strings name the Python script's flags.
- Service tests that pin the Python: `efferent-service/server/reference_test.ts` (embedded string equals the file), `server_test.ts`, `reader_test.ts`, `device_test.ts`, `edits_test.ts`. Not opened line by line, but grep matched setup_guide/efferent_hpke/python in `server_test.ts`, `reference_test.ts`, `reader_test.ts`.
- `efferent-service/README.md` (line 28, section "The reader's Python" ~106) and its `AGENTS.md` (~102) — docs of the copy mechanism.
- `efferent-service/protocol/*.ts` (attestation, batch, edits, framing, ids, signing) — the third description of the wire, in TypeScript on the service side. A Node client is a fourth place, or could reuse these (Deno-targeted, not examined for Node portability).
- `efferent-service/server/maintenance/` and `.github/workflows/secrets.yml`, `.gitleaks.toml`, `scripts/secrets.ts`, `scripts/check.ts` — secret scanning and check tasks that would apply to any new file added.

**C. The phone side and the handoff text (producers of what the client consumes)**

- `efferent/src/Core/Sources/Wire/Connection.swift` lines ~76-116 — `Connection.instruction` (the one-line "Instruction:" the phone shares: "Connect the supplied Efferent MCP and call setup_guide first… POST a JSON-RPC tools/call…") and the share-sheet layout. If the skill becomes the path, this line (and its rule: one line, no registration command, every sentence answers an observed stop) is the text that mentions how agents connect.
- `efferent/src/Tests/Sources/ShareSheetTests.swift` (line 14 pins the prompt), `ReadKeyTests.swift`, `WireTests.swift` — pin the handoff and instruction.
- `efferent/src/App/Sources/SetupView.swift` — the screen showing the handoff and instruction (matched grep for setup_guide/python terms only via the Connection text; its exact copy not read).
- Swift wire code `efferent/src/Core/Sources/Wire/Batch.swift`, `Upload/SealedBox.swift`, and `Connection.swift` — the Swift side of the bytes the Node client must match.
- `efferent/scripts/interop.ts` plus `reader/efferent/interop.py` — the compatibility proof (Swift packs/seals/signs, Python opens and verifies; Python seals an edit, Swift opens). D says Python "stays the reference for compatibility", so a Node client needs either an extra leg in this check (Node vs Swift, or Node vs Python on the same fixtures) or a stated non-goal. Also `interop --post` against a service.
- `efferent/scripts/reader.ts`, `reader-run.ts`, `test-reader.ts`, `check.ts`, `deno.json` (`reader:setup`, `test:reader`, `mcp`, `efferent` tasks) — Python-specific task plumbing; a Node client has no task, test or format/lint entry here yet, and the repo rule is "every command is a `deno task`".
- Python tests that would need Node equivalents: `efferent/reader/tests/` — `test_wire.py`, `test_mcp.py`, `test_server.py`, `test_reader.py`, `test_analysis.py`, `test_phone.py`, `test_permissions.py`, `test_connection.py`, `fake_archive.py` (a fake service the tests run against, reusable as a fixture).

**D. Documentation that states the current contract**

- `efferent/AGENTS.md` — lines ~268-291 ("There are two implementations of reading, not three"; a Node client would make three, the exact situation the rule documents being removed on 2026-09-19 after TypeScript reader drift; also the owner rule "do not bring a third-party HPKE package back"), ~336-348 (envelope change requires updating setup guide and proving Swift/Python agree; "`reader/` is the same code as an installed package"), ~372-392 (MCP bootstrap must be self-contained: no repo checkout, Deno, second MCP server), ~79-80, ~313, ~330.
- `efferent/README.md` — ~180, ~266-290 (the setup narrative and "That script is not the only copy of itself"), ~375, ~422-445, ~478-496 (task list), ~535-542 (file map).
- `efferent/documents/connection.md` (lines 4, 94-139, 189-204, 229-236), `design.md`, `requirements.md` (FR for reading/MCP; grep for skill returned nothing), `documents/tasks/2026/09/reader-in-python.md` (the decision that made Python the reader, and why TypeScript was removed), `documents/tasks/2026/10/protocol-hardening.md`, `documents/tasks/2026/09/agent-writes-health.md`, `one-word-per-operation.md` (tool vocabulary), `approving-agent-changes.md`.
- [A rule outside this repository on what a public app repository may name; removed here.] Where a skill lives matters for that rule. No skill directory exists in either repo.

**E. Consumers of the MCP server the Node client would replace**

- Claude Desktop, Codex and other local MCP hosts register the server as a command (today `deno task mcp` or `python -m efferent.mcp`). Their config entries are outside both repos and not examined. The `phone_data_*` tool names and schemas in `mcp.py` `TOOLS` are the public contract the Node `mcp` command must keep identical.
- Anyone already holding a mirror at `EFFERENT_HOME` / `.efferent` (produced by the Python CLI) is a consumer of the on-disk format.

**F. Not affected (opened)**

- `efferent-service/server/maintenance/` — maintenance worker, not tied to reading.
- `efferent-service/server/src/apns.ts`, `limits.ts` — push and limits, no client dependency.

## Could not rule out
- A Node client may also need the `phone_data_*` write path and edit sealing (the editor key), which is a large part of `efferent_hpke.py` (lines ~531+) and `phone.py`; D says "replaces the local MCP server", which includes writes.
- Hand-copied `efferent-service/reader/efferent_hpke.py` may already differ from the original; I did not diff them (sizes differ in mtime only, both 28088 bytes, so probably identical now).
- Whether the skill would still point agents at the remote `setup_guide`, or replace it. That decides whether `setup-guide.ts`, `python-reference.ts`, `reference.ts`, `reference_test.ts` and the `Connection.instruction` line change or stay, and I cannot tell from the request.
- Which repo the skill and `efferent.mjs` live in (efferent, efferent-service, or a private one), and how the skill is distributed; nothing in the tree decides it.
```

Dispositions (union of the scout's list and mine):

- `reader/efferent_hpke.py` (wire) — covered-by Solution step 1 (ported into `efferent.mjs`); the Python file stays as the interop reference and is not deleted. ChaCha20-Poly1305 is a Node built-in cipher and HPKE is written out by hand, as in Python.
- `reader/efferent/mcp.py`, `analysis.py` — covered-by Solution steps 3–4 (ported), then step 8 (Python copies removed, `efferent/mcp.py` becomes a shim that runs the Node server).
- `reader/efferent/archive.py`, `cli.py`, `connection.py`, `edits.py` — covered-by Solution steps 2, 5 and 8: the reading commands move to Node; Python keeps only what the phone stand-in (`send`, `keygen`) and the interop check need.
- `reader/efferent/phone.py`, `sealed.py`, `days.py`, `interop.py` — not affected as code: they are the phone stand-in and the interop reference, which variant D keeps in Python (`interop.py` gains no new role; the Node leg is a separate file, step 6).
- `reader/pyproject.toml` — covered-by step 8 (description and console script narrowed to the stand-in).
- On-disk profile format — covered-by Constraints and DoD READER-2 (Node reads a Python-made profile).
- Service `reader/efferent_hpke.py`, `python-reference.ts`, `scripts/reference.ts`, `reference_test.ts` — covered-by step 7 (the copy becomes `reader/efferent.mjs`, embedded with `JSON.stringify` so backticks and `${` are no longer a constraint).
- Service `setup-guide.ts` — covered-by step 7 (rewritten for Node).
- Service `index.ts` strings naming Python flags (`signedReadsOnly`, `setup_guide` and `get_sealed_day` descriptions) and `server/reader_test.ts:365` — covered-by step 7.
- Service `server_test.ts`, `device_test.ts`, `edits_test.ts` — not affected unless they pin the guide text; step 7 runs the whole service suite to prove it.
- Service `README.md`, `AGENTS.md` — covered-by step 9.
- Service `protocol/*.ts` — not affected: Deno/Worker code, not a reader; the Node client does not import it, because the client must be one file an agent can save.
- Service secret scanning (`.gitleaks.toml`, `scripts/secrets.ts`) — not affected: the new embedded file carries no key; `deno task check` proves it.
- Service `server/maintenance/`, `apns.ts`, `limits.ts` — not affected (scout opened them).
- `Connection.swift` instruction line, `ShareSheetTests.swift`, `SetupView.swift` — not affected: the instruction says "call setup_guide first", and setup_guide stays the bootstrap; only what the guide hands out changes. Swift wire code is untouched: no byte on the wire changes.
- `scripts/interop.ts` — covered-by step 6 (a Node leg: Node makes the edit fixture the phone opens, and Node checks the frame, the days and the read key Swift produced).
- `scripts/reader.ts`, `reader-run.ts`, `test-reader.ts`, `check.ts`, `deno.json` — covered-by step 5 (`deno task mcp`/`efferent` run Node; `test:reader` runs the Node suite and `deno fmt`/`deno lint` over the `.mjs`).
- Python tests — covered-by step 8: the tests of removed modules are ported to `reader/tests/node/` (steps 1–5) and then deleted; `test_wire.py`, `test_phone.py` stay with the reference.
- `AGENTS.md`, `README.md`, `documents/connection.md`, `design.md`, `requirements.md` — covered-by step 9.
- Earlier task files (`reader-in-python.md` and others) — not affected: historical records keep their wording (hub rule on managed repos).
- Where the skill lives — covered-by step 10: `skill/efferent/SKILL.md` in this (public) repository; the client is copied in by `deno task skill`. Distribution (installer, Claude account upload) — deferred — human choice, see Follow-ups.
- Claude Desktop / Codex registrations outside the repos — deferred — human choice: the shim in step 8 keeps the owner's Codex working unchanged; switching the config to `node … mcp` is the owner's call (Follow-ups).
- A skills folder outside this repository — not affected: the skill lives with the app.

## Definition of Done

- [x] READER-1: one file `reader/efferent.mjs`, Node built-ins only, passes the RFC 9180 A.2.1 vectors and the read-key vectors the Python and Swift sides are held to.
  - Test: `reader/tests/node/wire.test.mjs`
  - Evidence: `node --test reader/tests/node/` and `node reader/efferent.mjs self-test`
- [x] READER-1: `node reader/efferent.mjs mcp` answers the same nine tools with the same schemas and the same answers as the Python server did, every trap rule included.
  - Test: `reader/tests/node/mcp.test.mjs`, `reader/tests/node/server.test.mjs`, `reader/tests/node/analysis.test.mjs`
  - Evidence: `node --test reader/tests/node/`; a differential run over a copy of the owner's real mirror, Node against Python, every tool equal (recorded in this file)
- [x] READER-2: a profile the Python reader made is read without migration, and what Node writes keeps the 0700/0600 modes.
  - Test: `reader/tests/node/store.test.mjs`
  - Evidence: `node --test reader/tests/node/`
- [x] READ-2, READ-3: the Node client signs every read with the derived key and fetches ranges a quarter at a time, four in the air, in order.
  - Test: `reader/tests/node/reader.test.mjs`
  - Evidence: `node --test reader/tests/node/`
- [x] READER-1: the phone and the Node client agree on the wire: Node opens the days Swift packed and verifies the read Swift signed; the phone opens the edit Node sealed.
  - Test: `reader/tests/node/interop.mjs` via `scripts/interop.ts`
  - Evidence: `deno task interop`
- [ ] READER-3: the service's `setup_guide` hands out `efferent.mjs`, byte for byte, with instructions for Node; no Python is named on the agent path.
  - Test: efferent-service `server/reference_test.ts`, `server/reader_test.ts`
  - Evidence: `deno task check` in efferent-service
- [x] READER-1: `deno task check` in this repository runs the Node suite and formats and lints the `.mjs`.
  - Test: `scripts/test-reader.ts`
  - Evidence: `deno task test:reader` and `deno task check`
- [ ] READER-1: the Python reader is left as the reference only (Solution step 8).
  - Test: `scripts/test-reader.ts`
  - Evidence: `deno task test:reader`
- [x] Add a "The reading client" section to `documents/requirements.md` with READER-1 and READER-2 and their acceptance; update AGENTS.md, README.md, `documents/design.md` and `documents/connection.md` for the local half.
  - Test: manual — korchasa — this task file
  - Evidence: `grep -n "READER-1" documents/requirements.md`
- [ ] Add READER-3 to `documents/requirements.md` and update the service's README/AGENTS.md once the guide is rewritten (step 7).
  - Test: manual — korchasa — this task file
  - Evidence: `grep -n "READER-3" documents/requirements.md`
- [x] READER-1: `skill/efferent/SKILL.md` is committed, and `deno task skill` assembles it with the client in `build/skill/efferent/`, so the client lives in one place.
  - Test: `scripts/skill.ts`
  - Evidence: `deno task skill && node build/skill/efferent/efferent.mjs self-test`

## Solution

Variant D, chosen by the owner on 2026-10-08 from four directions (A quick: keep Python and bundle
it; B safe: Python with a Node launcher; C correct: a Node client in the skill only; D strategic:
one Node client for the skill, the local MCP and the guide).

1. **Wire** (`reader/efferent.mjs`, section 1). HKDF extract/expand with `createHmac`, labelled
   extract/expand, `keyAndNonce`, `hpkeSeal`/`hpkeOpen` (X25519 through JWK key objects, ChaCha20-
   Poly1305 with a 16-byte tag), the A.2.1 self-test, base64url, `bucketOf` (base32 of SHA-256),
   handoff `field`/`connection` with every Python check and message, `isDay`, `readKey` (Ed25519
   from a PKCS8-wrapped seed), `canonicalRead`, `readHeaders`, `openSealed` (v2, and v1 AES-GCM for
   the archive's old days), `unpackFrame`, `expand` (layout 2, numbering of shared instants, layout
   1 passing through), `validateItems`/`packEdit`, `canonicalEdit`. Errors are thrown `Error`s with
   the Python's sentences.
2. **Profile** (section 2). `home()` from `EFFERENT_HOME` (default `.efferent`), PKCS8 ↔ raw for
   both key kinds, `write` through `<name>.partial` + rename, 0700/0600, `loadState`/`saveState`,
   editor key, `edits.json`, day files, `mirrorVersions` (`size:mtimeMs`), `mirroredDays`.
3. **Service** (section 3). `transport` over `fetch` with a 30-second timeout and a 16 MiB ceiling;
   `Archive` with `read` (signed), `readJson`, `span` (follows `x-efferent-next`, refuses days out
   of range), `fetch`, `list` (follows `next`), `several` (spans of ≤ 92 days, gap 7, four ranges in
   the air, days yielded in the order asked), `stats`, `submitEdits`, `edits` (local record laid over,
   outcomes read for failed counts, `refused` still read).
4. **Answers and the MCP server** (sections 4–5). `analysis.py` ported function by function;
   `Reader` with the five-minute freshness window, the fortnight listing, `behind` with the floor
   rule, `takeWhole`, `reload`; `whatEachDayHolds` with `metrics.json`; the nine tools with the
   exact descriptions and schemas; JSON-RPC over stdio (newline-delimited, notifications unanswered,
   protocol versions, compact JSON answers); the `serve()` call stays the last statement run.
   Python's `round()` rounds the exact binary value and sends a tie to the even digit, while
   `toFixed` sends a tie away from zero: the port uses `toFixed` and detects a tie through
   `toFixed(20)` (a 5 followed by zeros), and sums floats with Neumaier compensation as Python 3.12+
   `sum()` does. The differential run in the DoD is what proves it on real data.
5. **Command line** (section 6) and tasks. `node efferent.mjs <command>`: `self-test`, `connect
   --handoff <file|->`, `sync`, `status`, `query`, `ask`, `read`, `edits`, `write <items.json>`,
   `mcp`, and `call <tool> [json]` plus one alias per tool (`overview`, `daily`, `statistics`,
   `sleep`, `workouts`, `samples`) so the skill's CLI answers in the MCP tools' shapes. `deno task
   mcp` and `deno task efferent` run Node through `scripts/reader-run.ts`; `scripts/test-reader.ts`
   adds `node --test reader/tests/node/` and `deno fmt --check`/`deno lint` over the `.mjs` files;
   `deno.json` fmt/lint include them. Tests run a Node port of `fake_archive.py`
   (`reader/tests/node/fake-archive.mjs`, with its own phone-side packer).
6. **Interop leg.** `reader/tests/node/interop.mjs fixture|check <state>`: Node seals and signs the
   edit fixture (so the phone opens what Node sealed), and checks the frame, both days, the ids, the
   date binding and the read key exactly as `interop.py` does. `scripts/interop.ts` runs Node's
   fixture, then both checks (Python and Node) on what Swift printed.
7. **Service** (efferent-service repository). `reader/efferent.mjs` replaces `reader/efferent_hpke.py`;
   `scripts/reference.ts` renders `server/src/node-reference.ts` with `JSON.stringify`;
   `reference_test.ts` holds it byte for byte; `setup-guide.ts` is rewritten for Node (save
   `efferent.mjs`, `node efferent.mjs self-test`, `EFFERENT_HOME=<private dir> node efferent.mjs
   connect --handoff <file>`, then `overview`/`sleep`/… or `ask`, `write`, `edits`, and how to keep it
   as an MCP server); `signedReadsOnly` and two descriptions name the Node commands;
   `reader_test.ts:365` and the four strings `server_test.ts:812-818` pins follow. Measure the guide's size before and after. No deploy.
8. **Python narrowed to the reference.** Delete `efferent/mcp.py`'s body, `analysis.py`, and the
   reading commands of `cli.py` (`connect`, `read`, `sync`, `status`, `query`, `ask`, `edits`) with
   `archive.py`'s mirror and `Archive`, and their tests (`test_mcp`, `test_server`, `test_reader`,
   `test_analysis`, `test_permissions`, `fake_archive`, the install half of `test_connection`).
   Keep `efferent_hpke.py`, `phone.py`, `sealed.py`, `days.py`, `interop.py`, `parse_connection_handoff`,
   and `send`/`keygen`. `efferent/mcp.py` becomes a shim that execs `node reader/efferent.mjs mcp`, so
   the owner's Codex, registered as `python -m efferent.mcp`, keeps working until its config is
   switched. Ruff and the remaining Python tests stay green.
9. **Documents.** requirements.md gains READER-1..3; design.md, connection.md, README.md and
   AGENTS.md ("two implementations", "the reader's Python", task list, file map) say what is now
   true; the service's README and AGENTS.md describe the Node copy.
10. **Skill.** `skill/efferent/SKILL.md` (how to connect once, where the profile lives, which command
    answers which question, the traps, never to print keys) and `deno task skill` assembling
    `build/skill/efferent/` with the client beside it.

Verification: `node --test reader/tests/node/`, `deno task test:reader`, `deno task check`,
`deno task interop` (efferent); `deno task check` (efferent-service); the differential run.

## Results

- Differential run, 2026-10-08: a copy of the owner's real profile (3 950 days) with its endpoint
  pointed at a closed port, so both readers answered from the mirror. 63 tool calls covering all
  nine tools; Node and Python answered identically as parsed JSON, key order included. Copies made
  with `cp -Rp`, so the kept metric record was read rather than rebuilt; deleted afterwards. No key
  was printed.
- `deno task check`: the secret scan clean, the reading side green, the simulator build done.
- `deno task test:reader`: 132 Node tests on Node 24.18 and 22.14, then the 127 Python tests.
- `deno task interop`: the phone opened the edit the Node client sealed; Node and Python both agreed
  with what Swift packed, sealed and signed.

## Review notes

The plan critic's findings, and what became of each:

1. The guide grows from about 28 KB of Python to about 103 KB of Node (about 83 KB without
   comments), and the MCP tool-result ceiling of each client is unverified — waits for the owner,
   blocks step 7.
2. The service's `server_test.ts:812-818` pins `"three fields"`, `"--self-test"`,
   `'USER_AGENT = "efferent-local-reader/1.0"'` and `"--write"` — added to step 7.
3. `node --test <directory>` fails before Node 26 — fixed: the files are listed, minimum Node 22.
4. The default profile is `.efferent` in the working directory — `SKILL.md` always names
   `EFFERENT_HOME="$HOME/.efferent/reader"`.
5. The interop fixture key would trip the secret scanner as a file of its own — fixed: the key
   travels in `EFFERENT_INTEROP_READING_PRIVATE`.
6. Python's own edit sealing was no longer held to anything — covered by
   `reader/tests/node/reference.test.mjs`.
7. A Codex shim needs `node` on the `PATH` a desktop client gives it — waits for the owner, decides
   step 8.
8. The differential run — done, see Results.

Found while writing the documents: an option a command does not read was ignored, so `daily
--metirc steps` answered for every metric. Every command now refuses an option it does not read
(`reader/tests/node/reader.test.mjs`, "a misspelt option is refused rather than ignored").

## Follow-ups

- Switch the owner's Codex registration from `python -m efferent.mcp` to `node reader/efferent.mjs mcp`
  and drop the shim — the owner's local configuration, asked in chat.
- Distribution of the skill: an installer that registers the client in every local agent's config
  and skill folder, and the Claude account Skill upload.
- Deploy the Worker with the new guide — the owner's command; no wire byte changes, so the phone
  needs no build for it.
