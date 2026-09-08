---
date: 2026-09-08
status: in progress
implements: []
tags: [healthkit, server, protocol, mcp, write-path]
related_tasks: []
---

# An agent writes Health data through the service

## Goal

Let an agent that holds a connection handoff change the person's Health data — record a night of sleep, log a meal as energy, protein, carbohydrates and fat, correct a day in the past — by submitting edits to the service. The service is the single point of truth for the edit queue and for what became of each edit. The phone downloads edits it has not applied, writes them into HealthKit, reports the outcome, and the changed days flow back into the archive through the existing upload path, so the archive keeps holding what Health says now.

## Overview

### Context

Today the phone only ever sends. `HealthReader.requestAuthorization()` asks HealthKit for read access with an empty `toShare` set, and nothing in the app calls `HKHealthStore.save`. The service (`server/src/index.ts`) knows five routes — claim a bucket, put days, list days, get a day, stats — plus a keyless remote MCP with four tools. The agent's connection path is: remote MCP `setup_guide` → embedded Python reference → fetch and decrypt days locally. The handoff gives the agent the bucket id (in the MCP URL) and the reading key (`efferent-reading-v1.<private>.<public>`). Only the phone holds the Ed25519 writer key that signs uploads.

The user's request, verbatim: «Я хочу, чтобы агент мог обновлять данные в Health. Например, сон, КБЖУ и так далее. SPoT должен являться наш сервер. Агенту нужны инструменты для редактирования, а приложение должно скачивать изменения и применять их. Учти, что данные могут обновляться и в прошлом. Нужно тщательно продумать API, чтобы он был производительным и удобным.»

### Current State

- Phone: read-only. Metric catalogue in `HealthMetrics.swift` (7 totals, 7 record metrics), none of them dietary or body mass. Background launches: Health deliveries (`HealthCoordinator.collect`), a `BGProcessingTask` catch-up (`EfferentApp.handleRefresh`), and background URLSession completions. Every launch that can read Health already runs `refreshNow()` + `sendNow()`.
- Service: Cloudflare Worker over R2, no accounts, writer key registered at claim, per-caller rate limits, byte tallies. No edit routes, no per-bucket second key.
- Protocol (`protocol/`): Ed25519 upload signature over a canonical string, HPKE v2 sealed days bound to `(bucket, day)`, a day frame for batches. Swift mirrors it in `src/Core/Sources/Wire`; `deno task interop` proves agreement.
- Agent side: local TypeScript MCP (`tools/mcp.ts`, seven `phone_data_*` read tools), CLI (`tools/efferent.ts`), and the Python reference returned by `setup_guide` (read one day).
- Docs: `README.md`, `AGENTS.md` (invariants: the service must never learn contents; a day is read from Health and sent whole; reading key ≠ writing key), `documents/connection.md`.

### Constraints

- **HealthKit facts that shape the write path.**
  - An app may delete or replace only samples it wrote itself. Sleep recorded by the Watch, steps from the iPhone, meals logged by another app cannot be edited or removed by Efferent. So an "edit" is: add a sample, replace a sample Efferent wrote earlier, delete a sample Efferent wrote earlier. The tools must say so, and an item that targets somebody else's record is refused with a code, not silently ignored.
  - `HKMetadataKeySyncIdentifier` + `HKMetadataKeySyncVersion` give native upsert: saving a sample with the same identifier and a higher version replaces the earlier one atomically. This is the idempotency and correction mechanism, and it is what makes re-applying an edit after a crash harmless.
  - Past dates are allowed; HealthKit refuses samples that end in the future. A cumulative quantity (energy, protein, water) written by Efferent is merged by Health with other sources the same way steps are, and Efferent's own totals query then sees it.
  - Share authorization is per type and the status is knowable (`authorizationStatus(for:)` answers for writes, unlike reads). The person can deny a type; an edit for a denied type is refused with a code. The write types must be declared in the same `requestAuthorization` call or in a second one before the first apply.
  - Writing samples wakes Efferent's own observer, marks the day, rebuilds and re-uploads it — exactly the flow the invariants require. The phone never uploads the edit itself as a day.
- **The service must not learn contents.** Edits travel sealed with the same HPKE construction as days, sealed to the reading public key (the agent has it: the handoff carries the public half) and opened by the phone with the reading private key it keeps in its Keychain. Associated data binds the bucket so an edit cannot be moved between buckets; the name is assigned by the service after sealing, so it is not in the associated data. A replay of a signed edit within the timestamp window would re-apply an old correction over a newer one, so the signed body is never handed to anybody but the phone: fetching it needs the writer's signature. Outcomes reported back carry item indexes and codes only — never a metric name.
- **Somebody has to be allowed to edit, and the phone must check it, not the service.** A service that decided on its own which edits the phone applies is a service that can write into Health when compromised. The phone verifies an editor signature over the sealed bytes before it opens them. The service verifies the same signature to keep strangers from filling the queue and the bill.
- **No push channel exists.** The phone learns of edits when it is launched: a Health delivery, the catch-up task, a foreground open, a tap on the button. Latency is therefore "within the hour, usually", and the API must be cheap on every launch: one listing of the pending prefix, empty most of the time.
- **Every write path has a ceiling** (AGENTS.md): edit size, edits per bucket, edits per minute per caller, and edit bytes counted in the bucket tally.
- **`protocol/` changes go to both languages in the same commit** and `deno task interop` must cover the new frame and signature. The Python reference is a third implementation of whatever the agent path needs.
- Repo rules: every command is a `deno task`; no signing code; a push is not a release; the screen stays two screens with one sentence — the edit path gets a line in the log, not a counter on the dial.
- Repository roles: this repository declares no `tasks`, `SRS`, `SDS` or `index` role in `AGENTS.md`. The task lives under the factory-wide layout `documents/tasks/<YYYY>/<MM>/`; `README.md`, `AGENTS.md` and `documents/connection.md` are what an SRS/SDS would be here and are the documents to sync.

### Affected Surface

Independent scout report (`surface-scout`, dispatched with the request text only), verbatim:

````text
## Surface

- `README.md` (whole document, esp. lines 1-30, 149-237, 306-371) — the document is built entirely around "the phone only ever sends" as the one-word design; a write-back capability contradicts the title concept itself ("efferent" = signals only leaving the phone), the "What the service keeps"/"What the service learns" sections (`PUT /b/<bucket>/days` is upload-only, `/mcp/b/<bucket>` "never accepts the reading key" and offers ciphertext-only tools), and the "Layout" section listing every module by its current (read/upload) role — evidence: README.md:6-7 "the phone only ever sends", README.md:155-170 endpoint list, README.md:357-371 module map.
- `AGENTS.md` (whole rulebook, ~40 numbered invariants) — dozens of hard invariants assume one-directional flow: "A day is read from Health and sent whole. Never send a difference" (line 19-22), "The service must never gain a way to read a day" (line 286), "The signing key and the reading key are separate on purpose. One writes, one reads" (line 255-256), "A reading key goes from phone to agent and nowhere else" (line 251-254) — a write-back design needs a fourth actor/direction and a new key type these rules explicitly forbid mixing.
- `protocol/ids.ts`, `protocol/day.ts`, `protocol/batch.ts`, `protocol/framing.ts`, `protocol/signing.ts`, `protocol/sealedbox.ts`, `protocol/sealedbox-v1.ts`, `protocol/attestation.ts` — the whole wire-protocol description is one-directional (phone→server, and server→agent as read-only ciphertext); a "server is SPoT, agent edits, phone downloads and applies" flow needs a new message/object type for pending changes, sealed the other way (server/agent→phone), which none of these files model.
- `protocol/protocol_test.ts`, `protocol/attestation_test.ts` — cross-language interop tests that would need new cases for the write-direction protocol.
- `server/src/index.ts` (819 lines) — only exposes `PUT /b/<bucket>`, `PUT /b/<bucket>/days`, `GET /b/<bucket>/days`, `GET /b/<bucket>/d/<day>`, `GET /b/<bucket>/stats`, and the read-only remote MCP tools `setup_guide`, `archive_status`, `list_sealed_days`, `get_sealed_day` (lines 185-262) — no endpoint exists for an agent to submit a write/edit, nor for the phone to poll/ack pending writes. Per-bucket/per-service byte ceilings (`MAX_BODY_BYTES` etc., lines 78-100) assume upload-only traffic and would need a parallel budget for write requests.
- `server/src/setup-guide.ts`, `server/src/python-reference.ts` — the embedded Python reference the remote MCP hands the agent is decrypt-only; if the agent is to construct/seal a write request itself (rather than send plaintext to the server), this reference needs a sealing counterpart too.
- `tools/mcp.ts` (950 lines, local MCP server) — all seven registered tools (`phone_data_overview`, `phone_data_daily`, `phone_data_statistics`, `phone_data_sleep`, `phone_data_workouts`, `phone_data_samples`, `phone_data_sync`, lines 385-699) are read-only; a "let the agent update sleep/nutrition" tool would sit here as new siblings, and the file's closing "server.serve() must stay the last line" invariant (AGENTS.md:327-329) applies to whatever is added.
- `tools/mcp_test.ts` — would need new test coverage for the write tools.
- `tools/archive.ts` — "where days come from: the reading key, the service, the mirror" (README.md:368); a write path needs a parallel "where edits go" component.
- `tools/efferent.ts` (CLI) — exposes `connect`, `ask`, `sync`, `status`, `query`, plus dev-only `keygen`/`send`/`read`; a new `write`/`edit` command for protocol development is the direct sibling of the existing `send`.
- `tools/connection.ts`, `tools/connection_test.ts` — the phone→agent handoff (bucket id, reading key, instruction) is three fields (README.md:213-260); a write-capable agent needs the handoff to also carry (or the connection flow to also establish) whatever key authorizes/seals writes.
- `tools/archive_permissions_test.ts` — permission-related test file, worth checking once new write permissions exist.
- `src/Core/Sources/Health/HealthReader.swift:87-89` — `requestAuthorization(toShare: [], read: Self.readTypes)` is the literal read-only line; needs a `toShare` set and corresponding `HKHealthStore.save`/`.delete` calls, none of which exist anywhere in `src/` (verified via repo-wide grep — zero hits for `.save(` or `.delete(` against HealthKit, zero hits for `toShare` with contents).
- `src/Core/Sources/Health/HealthCoordinator.swift:57-58` — thin wrapper around `reader.requestAuthorization()`; would need an analogous write-plan/apply coordinator, mirroring how `HealthCoordinator.plan` currently turns observed changes into reads (AGENTS.md:342-357).
- `src/Core/Sources/Health/HealthMetrics.swift` — `AggregateMetric`/`SampleMetric` catalogues (lines 1-80) are read/encode only (`encode: @Sendable (HKSample) throws -> Event`); a write catalogue needs the inverse mapping (Event → HKSample/HKQuantitySample/HKCategorySample/HKCorrelation for KБЖУ/sleep), and AGENTS.md:70-73 ("A metric belongs to exactly one catalogue") is a rule that would need extending to a third catalogue.
- `src/Core/Sources/Upload/Uploader.swift`, `Archive.swift`, `SealedBox.swift`, `DeviceIdentity.swift`, `Attestation.swift`, `Deflate.swift` — the entire outbound pipeline (build day → compress → seal → sign → attest → PUT); a download-and-apply pipeline is the structural mirror of this whole directory, including its own pass-lock, retry/backoff and idempotency invariants (AGENTS.md:157-208).
- `src/Core/Sources/Store/Store.swift`, `Database.swift`, `Log.swift` — the day ledger (`markDirty`, `markMissing`, `pendingDays`, `recordRefused`, fingerprints) is the pattern a "pending writes to apply" ledger would need to copy; `Log.swift`'s "nothing goes in it that would matter if it were read" rule (AGENTS.md:502-504) applies to whatever gets logged about applied edits.
- `src/Core/Sources/Wire/Connection.swift`, `Columnar.swift`, `Event.swift`, `Day.swift`, `Batch.swift`, `Destination.swift`, `Base32.swift` — the Swift half of the wire protocol that must byte-for-byte match `protocol/` (AGENTS.md:240-245, `deno task interop`); any new write-direction message needs a Swift counterpart here and a run of `deno task interop`.
- `src/App/Sources/Services.swift:338` — the composition root that currently only calls `health.requestAuthorization()` for read; would need to request write authorization and wire a new download/apply service.
- `src/App/Sources/SetupView.swift` — the three-step walkthrough ("what this is, what it reads, how far back to go", AGENTS.md:431-435) explicitly does not mention writing; consent/explanation copy for write access is a new surface here.
- `src/App/Sources/HomeView.swift`, `RootView.swift` — the "two screens and no more" design (AGENTS.md:383-466) with one dial for "days still waiting to send"; a symmetrical "changes waiting to apply" state is a UI surface the rulebook's own screen-design invariants constrain tightly.
- `src/App/Sources/LogView.swift`, `Design.swift` — log/appearance conventions that any new write-related log lines or screens must follow.
- `Project.swift:56-66` — `NSHealthShareUsageDescription` and, notably, `NSHealthUpdateUsageDescription` are both already declared, but the update string literally says *"Efferent never writes to your health data. It only reads what is already there"* with a comment *"Required even though the app never writes… Nobody ever reads this one: write access is never requested"* — both the string and the comment become false and must be rewritten.
- `Resources/Efferent.entitlements` — HealthKit write capability/entitlement surface to verify (not yet read in detail).
- `documents/connection.md` — defines "the complete decision and the boundary between phone, Cloudflare and agent" for the *read* connection; a write-back flow adds a fourth relationship (agent→server→phone) this document does not cover.
- `documents/server-costs.md` — cost model measured against upload-only traffic (README.md:301-304, AGENTS.md:130-146); storing/queuing agent-submitted write requests changes the cost and quota model.
- `scripts/interop.ts`, `scripts/python-interop.ts` (via `deno task interop`, `interop:python`) — cross-language proof harness that would need extending to cover the new write protocol and any new HPKE direction/key.
- `.gitleaks.toml` — currently has exceptions tuned to the specific reading-key/signing-key prefixes (AGENTS.md:257-261); a new write/apply key type must not accidentally widen an exception to a whole file, per the existing warning.
- `deno.json` — task list (`check`, `test`, `interop`, etc.) may need a new task if a write-side CLI/dev command is added, per the "every command is a `deno task`" rule (AGENTS.md:14-15).

## Queries used
- `find` across `protocol/`, `server/`, `tools/`, `src/`, `documents/`, `scripts/`, top-level directory listing.
- `wc -l` over the same files to gauge scope before reading.
- Full reads of `README.md` and `AGENTS.md`.
- `grep -rn "requestAuthorization|toShare|HKHealthStore|\.save(|\.delete(|NSHealthUpdateUsageDescription|NSHealthShareUsageDescription" src/ Configs/`
- `sed -n` reads of `HealthMetrics.swift`, `HealthReader.swift` heads.
- `grep -n "Health|Usage|Entitlement|entitlement" Project.swift`, `find -iname "*.entitlements"`.
- `sed -n '40,80p' Project.swift` for the Info.plist keys.
- `grep -n "^app\.|\.get(|\.put(|\.post(|\.delete(|registerTool|tool("` on `server/src/index.ts`.
- `grep -n "registerTool|server.tool|name:.*\""` on `tools/mcp.ts`.
- `Read server/src/index.ts` lines 1-100 and 170-270 for endpoint/tool inventory.

## Not examined (budget)
- `server/src/index.ts` lines 270-819 (the PUT/GET day-storage handlers, signing/attestation verification, rate-limiting code in full detail) — read only the header and the remote-MCP tool block.
- `tools/analysis.ts` and `tools/reader_test.ts`/`tools/analysis_test.ts` in full — only confirmed they exist and their line counts; did not verify whether analysis-answer code would need write-adjacent additions (e.g., "what's pending to apply" reporting).
- `src/Core/Sources/Wire/*.swift` and `src/Core/Sources/Upload/*.swift` file bodies — enumerated by name and README/AGENTS description only, not opened.
- `src/App/Sources/*.swift` file bodies beyond `Services.swift:338` — not opened.
- `Resources/Efferent.entitlements` contents — not read.
- `documents/connection.md` full body (187 lines) — not read past what README references.
- Anything in the `factory` hub outside this repository (`sites/efferent`, `metadata/efferent`, `APPS.md` entry) — out of the given repo's scope per the dispatch, but per this hub's own rule ("Keep the public face current with the app") a shipped write-back feature would eventually need site/store-copy updates there too.

## Could not rule out
- Whether a *new* keypair (a "write key", distinct from both the signing key and the reading key) is required, or whether the design intends to route agent-authored edits through the existing signing key infrastructure somehow — this is a design choice, not something visible in the current code, but every file in `protocol/` and `src/Core/Sources/Upload/` that handles keys is a candidate site for it.
- Whether `server/src/index.ts`'s per-bucket/per-service byte ceilings and rate limits (`MAX_BODY_BYTES`, `MAX_BUCKET_BYTES`, `MAX_SERVICE_BYTES`, per-minute claim/upload counters) need a parallel budget class for write requests, given the file was only skimmed past line 270.
- Whether `tools/mcp.ts`'s local-CLI-facing tools or `server/src/index.ts`'s remote MCP tools are the intended home for new "edit" tools — both are plausible per the existing local/remote split described in README.md:213-237.
````

Dispositions (union of the scout's list and the planner's own; `covered-by` points at a Definition of Done item until the Solution is written, then at its step):

- `README.md` — covered-by S9.
- `AGENTS.md` — covered-by S9 (new invariants; the "one writes, one reads" rule is kept and a third, separate editor key is added rather than mixed).
- `protocol/ids.ts`, `protocol/signing.ts`, `protocol/sealedbox.ts` — covered-by S1.
- `protocol/day.ts`, `protocol/batch.ts`, `protocol/framing.ts`, `protocol/sealedbox-v1.ts`, `protocol/attestation.ts` — not affected — the day layout, the day batch frame, the legacy envelope and the claim attestation are untouched by an edit that never becomes a day on the wire (edits are applied to Health, and the day is then rebuilt by the existing path).
- `protocol/protocol_test.ts` — covered-by S1 tests (`attestation_test.ts` not affected, no attestation on the edit path).
- `server/src/index.ts` — covered-by S3.
- `server/src/setup-guide.ts`, `server/src/python-reference.ts` — covered-by S8.
- `tools/mcp.ts`, `tools/mcp_test.ts`, `tools/efferent.ts` — covered-by S8.
- `tools/archive.ts` — covered-by S8 (`submitEdits`, `listEdits`, `loadEditor`).
- `tools/connection.ts`, `tools/connection_test.ts` — covered-by S8 (fourth handoff field, `editor-key.json`).
- `tools/archive_permissions_test.ts` — covered-by S8 (owner-only `editor-key.json`).
- `src/Core/Sources/Health/HealthReader.swift`, `HealthCoordinator.swift`, `HealthMetrics.swift` — covered-by S5.
- `src/Core/Sources/Upload/Uploader.swift`, `Archive.swift` — covered-by S6 (`Applier` beside `Archive`; `Uploader` itself unchanged, the rebuilt days go through it as before).
- `src/Core/Sources/Upload/SealedBox.swift`, `DeviceIdentity.swift` — covered-by S2 (`SealedBox.open`, `EditorIdentity`).
- `src/Core/Sources/Upload/Attestation.swift` — not affected — the claim attestation stays claim-only. `src/Core/Sources/Upload/Deflate.swift` — covered-by S2: it holds only `compress(_:)`, so `decompress(_:limit:)` is added (plan-critic finding 2).
- `src/Core/Sources/Store/Store.swift`, `Database.swift` — covered-by S4.
- `src/Core/Sources/Store/Log.swift` — not affected — the log format is unchanged; the new lines follow the existing "counts, codes, never a reading" rule (`Log.swift` not edited).
- `src/Core/Sources/Wire/Connection.swift` — covered-by S7 (`ConnectionHandoff.editorKey`).
- `src/Core/Sources/Wire/Columnar.swift`, `Event.swift`, `Day.swift`, `Batch.swift`, `Destination.swift`, `Base32.swift` — Columnar/Event/Day/Batch/Base32 not affected (a day's shape does not change); `Destination.swift` covered-by S2 (edit URLs, canonical strings).
- `src/App/Sources/Services.swift`, `EfferentApp.swift` — covered-by S7 (editor registration, `applyEdits()` at the head of `sendNow()`).
- `src/App/Sources/SetupView.swift` — covered-by S7 (owner chose a sentence in step 2, 2026-09-08).
- `src/App/Sources/HomeView.swift`, `RootView.swift`, `LogView.swift`, `Design.swift` — not affected — no new screen, no counter; the apply step reports in the log only (AGENTS.md "The screen"). `RootView.swift` inspected: it only chooses between the walkthrough and the everyday screen.
- `Project.swift` — covered-by S7.
- `Resources/Efferent.entitlements` — not affected — inspected: it carries `com.apple.developer.healthkit` and the background-delivery entitlement; HealthKit write needs no further entitlement.
- `documents/connection.md` — covered-by S9.
- `documents/server-costs.md` — deferred — human choice (owner: after the implementation and the tests, 2026-09-08). Recorded under Follow-ups.
- `scripts/interop.ts`, `scripts/python-interop.ts` — covered-by S8 (interop scripts).
- `.gitleaks.toml` — covered-by S7 (`.gitleaks.toml` prefix, by prefix and by fixture value, never by file).
- `deno.json` — not affected — the write command is a subcommand of the existing `efferent` task, no new task.
- `tools/analysis.ts` (scout: not examined) — covered-by S8: `TOTALS` and `RECORDS` there are the metric catalogue the MCP tool schemas are built from (`tools/mcp.ts` enums), so the writable metrics are added to them (plan-critic finding 1).
- Factory hub (`sites/efferent`, `metadata/efferent`, `APPS.md`) — deferred — human choice: the app is not in the store, its site describes a read-only app; updated when the feature ships to a build somebody else can install. Recorded under Follow-ups.

## Definition of Done

Acceptance tuple per item: (FR, test or benchmark, evidence command). This repository declares no SRS and no FR ids, so the FR slot names the DoD item itself (`DoD-n`).

- [x] **DoD-1** An agent holding a handoff can submit a batch of edits (add / replace / delete) for sleep, dietary energy, protein, carbohydrates, fat, water and body mass, with a start and end in the past, through the local MCP, the CLI and the Python reference of the public connection path. — (`DoD-1`, `tools/mcp_test.ts::phone_data_write`, `tools/connection_test.ts::editor key`, `deno test -A tools/`; Python path: `deno task interop:python`)
- [x] **DoD-2** The service registers an editor key, stores edits sealed, lists them with their status, hands one back byte for byte with its signature headers, records the outcome the phone reports and drops the applied body; it never learns a metric name or a value, and every path has a ceiling. — (`DoD-2`, `server/server_test.ts::edits *`, `deno test -A server/`)
- [x] **DoD-3** The phone, on any launch that can reach Health and is not paused, and only once write access has been asked for, fetches every pending edit, verifies the editor signature, opens them, applies each item to HealthKit with sync identifier + version, refuses items it cannot apply with a code, and reports the outcome; an edit whose outcome was not accepted stays pending and is applied again. — (`DoD-3`, `src/Tests/Sources/ApplierTests.swift`, `src/Tests/Sources/HealthWriterTests.swift`, `deno task test`)
- [ ] **DoD-4** The days of applied items are marked and re-uploaded by the existing path, and the read catalogue includes every writable metric, and the agent's read tools accept them, so the archive shows the edit afterwards. — (`DoD-4`, `ApplierTests::testAppliedItemsMarkTheirDays`, `HealthTests::testEveryWritableMetricIsReadable`, `tools/mcp_test.ts::phone_data_daily answers dietaryEnergy`, `deno task test && deno test -A tools/`; end to end on the phone: `manual — korchasa`, `fastlane install app:efferent` then one real edit and `deno task efferent query`)
- [x] **DoD-5** Re-applying the same batch (a crash before the ack) leaves Health with one copy of each sample. — (`DoD-5`, `ApplierTests::testReapplyingKeepsOneCopy`, `deno task test`)
- [x] **DoD-6** `deno task interop` covers the editor signature and the sealed edit TypeScript → Swift; `deno task interop:python` covers the Python write path Python → TypeScript. — (`DoD-6`, `scripts/interop.ts`, `scripts/python-interop.ts`, `deno task interop && deno task interop:python`)
- [ ] **DoD-7** `README.md`, `AGENTS.md`, `documents/connection.md` describe the write path, the fourth handoff field, the boundary and the new invariants; the walkthrough's second step says the app writes what an agent asks; `NSHealthUpdateUsageDescription` tells the truth. — (`DoD-7`, `manual — korchasa`, `grep -n "Editor key" README.md documents/connection.md src/Core/Sources/Wire/Connection.swift && grep -n "NSHealthUpdateUsageDescription" Project.swift`)

## Solution

### Design in one paragraph

An edit is a sealed, signed object in the bucket's queue. The agent packs a list of items, deflates, seals to the reading public key (HPKE v2, associated data `efferent/v1 edit\n<bucket>`), signs the sealed bytes with a third key — the editor key — and POSTs. The service checks the editor signature against the key the phone registered, names the object `<unix-ms>-<8 base32>` so the queue is ordered by arrival, and stores the sealed bytes with the signature, timestamp and editor key as object metadata. The phone lists the whole of `e/` on every launch that can reach Health — there is no cursor: what waits is exactly what is still under `e/`, and the service moves an edit from `e/` to `o/` when the phone reports its outcome (the body is dropped, the status stays). The phone verifies each signature itself, opens the sealed bytes with its reading private key, writes every item into HealthKit with `HKMetadataKeySyncIdentifier = "efferent:" + id` and a version it keeps per id, and PUTs an outcome signed with the writer key. An outcome that never reached the service leaves the edit under `e/`, and it is applied again next launch — safe by construction, because a repeated `put` replaces the same sample. Names are `<unix-ms>-<8 base32>` from the Worker's clock: they order the listing, and two edits submitted seconds apart may land in either order across colocations, which is why nothing depends on that order but the agent's own habit of submitting a correction after the previous outcome. The pending queue is one listing and the archive of outcomes is tiny. Applied items mark their days; the existing uploader rebuilds those days from Health and replaces them. Nothing new touches a day on the wire.

### S1. Protocol, TypeScript side (`protocol/`)

- `protocol/ids.ts`: `editorKeyObject(bucket) = "<bucket>/editor"`, `EDIT_PREFIX = "e/"`, `OUTCOME_PREFIX = "o/"`, `editKey(bucket, name)`, `editPrefix(bucket)`, `outcomeKey(bucket, name)`, `outcomePrefix(bucket)`, `isEditName(name)` (`/^\d{13}-[a-z2-7]{8}$/`), `newEditName(now: number, random: Uint8Array)`.
- `protocol/edits.ts` (new): `EDIT_FORMAT_VERSION = 1`; `EditItem = PutItem | DeleteItem`; `PutItem = {op:"put", id, metric, start, end, value?, unit?, stage?}`; `DeleteItem = {op:"delete", id}`; `WRITABLE` catalogue: `sleep` (category, `stage` ∈ inBed|awake|asleepUnspecified|asleepCore|asleepDeep|asleepREM), `dietaryEnergy` (kcal), `dietaryProtein`, `dietaryCarbohydrates`, `dietaryFat` (g), `dietaryWater` (mL), `bodyMass` (kg). `validateItems(items)` refuses unknown keys, unknown metric, unit not in the catalogue, `end < start`, ids not matching `/^[A-Za-z0-9._:-]{1,120}$/`, more than `MAX_ITEMS_PER_EDIT = 500`. `packEdits(items): Uint8Array` = raw-deflate of `{"v":1,"items":[…]}` with keys in a fixed order; `unpackEdits(bytes)` = inflate, parse, validate, refuse `v ≠ 1`. `editAssociatedData(bucket)`. `OUTCOME_CODES` closed set: `unknownMetric`, `badUnit`, `badRange`, `unauthorized`, `notFound`, `healthRefused`, `badSignature`, `cannotOpen`, `malformed`; `Outcome = {applied: number, refused: {item: number, code}[]}`; `validateOutcome`.
- `protocol/signing.ts`: `canonicalEditorRegistration(bucket, timestamp, body)`, `canonicalEdit(bucket, timestamp, sealed)`, `canonicalOutcome(bucket, name, timestamp, body)`, `canonicalFetch(bucket, name, timestamp)` — each a first line naming its purpose (`efferent/v1 editor`, `efferent/v1 edit`, `efferent/v1 outcome`, `efferent/v1 fetch`) then the fields then the base64url SHA-256 of the body; `signMessage(privateKey, message)` / `verifyMessage(publicKey, signature, message)` shared with `signUpload`/`verifyUpload`; `hasSmallOrder` reused for the editor key.
- Tests in `protocol/protocol_test.ts`: pack/unpack round trip, validation refusals, edit name ordering, canonical strings byte for byte against fixed fixtures (the fixtures are what Swift is checked against).

### S2. Protocol, Swift side (`src/Core/Sources/Wire`, `Upload`)

- `Upload/Deflate.swift`: `decompress(_ data: Data, limit: Int) throws -> Data` — raw deflate through `compression_stream` (`COMPRESSION_ZLIB`, the same raw stream `compress` writes), refusing output past `limit`; a round-trip test in `WireTests`.
- `Wire/Edits.swift` (new): `EditItem` (Decodable with `unknownKeys` refused via a manual `init(from:)`), `EditBatch.unpack(_ data: Data) throws -> [EditItem]` (through `Deflate.decompress`), `Outcome` Encodable, `OutcomeCode` enum with the same raw values as TypeScript, `EditName.isValid`.
- `Wire/Destination.swift`: `editorURL`, `editsURL(after: String?, limit: Int)`, `editURL(name)`, `outcomeURL(name)`; `CanonicalRequest` gains `editorRegistration(bucket:timestamp:body:)`, `edit(bucket:timestamp:sealed:)`, `outcome(bucket:name:timestamp:body:)`, `fetch(bucket:name:timestamp:)`, and `associatedData(editBucket:)`.
- `Upload/SealedBox.swift`: `open(readingPrivateKey: Curve25519.KeyAgreement.PrivateKey, blob: Data, associatedData: Data) throws -> Data` via `HPKE.Recipient` (refuses a version byte other than 2).
- `Upload/DeviceIdentity.swift`: `EditorIdentity` (Keychain `account: "editor"`, `Curve25519.Signing.PrivateKey`, `forget()`); the reading identity already exposes the private key.
- `Tests/WireTests.swift`: canonical strings against the same fixtures as S1; `EditsTests.swift`: unpack refuses unknown keys, wrong version, oversize item list; `SealedBox.open` round trip with `seal`.

### S3. Service (`server/src/index.ts`, `server/wrangler.jsonc`, `server/server_test.ts`)

- New ceilings: `MAX_EDIT_BYTES = 256 KiB`, `MAX_PENDING_EDITS = 500` (deliberately below R2's page of 1000, so one listing with `limit: MAX_PENDING_EDITS + 1` is the whole answer and a truncated page can never hide the count — plan-critic finding 3), `MAX_OUTCOME_BYTES = 64 KiB`, `MAX_EDITS_PER_PAGE = 200`; a new rate limit `EDITS` (60 per minute per caller) in `wrangler.jsonc`, `deno task server:types` regenerated.
- `PUT /b/<bucket>/editor` — writer-signed (`authorizeWriter` with `canonicalEditorRegistration`), body exactly 32 bytes, small-order refused, bucket must already be claimed (an unregistered writer is refused with "claim the bucket first"); stores `<bucket>/editor`. Idempotent. Rate limit `CLAIMS`.
- `POST /b/<bucket>/edits` — `authorizeEditor`: headers `x-efferent-editor`, `x-efferent-signature`, `x-efferent-timestamp`; the same clock refusal with `now`; key must equal `<bucket>/editor`; signature over `canonicalEdit`; body ≤ `MAX_EDIT_BYTES`, first byte 2; pending count (one listing of `e/` with `limit: MAX_PENDING_EDITS + 1`; the cap is below a page, so `truncated` is impossible and the count is exact) below the cap, else 429; bytes added to the bucket and service tallies exactly as uploads are. Name from `newEditName(Date.now(), crypto.getRandomValues(5 bytes))`; stored with `customMetadata: {editor, signature, timestamp}`. Answer `201 {name, at}`. Rate limit `EDITS`.
- `GET /b/<bucket>/edits?after=<name>&limit=&status=pending|all` — `after` is a paging key only, never a watermark. `pending` (default): one listing of `e/`: `{edits: [{name, bytes, at, status: "pending"}], next}`. `all`: the merge of `e/` and `o/` listings in the same window, an `o/` entry described from the custom metadata the outcome left beside it (`applied`, `refused` counts, the edit's `bytes` and `at`) — no read per entry, so a page of 200 stays inside the Worker's subrequest budget — and reported as `applied` (nothing refused), `partial` (some) or `failed` (every item refused). The whole outcome, refusal indexes and codes included, is readable at `GET /b/<bucket>/o/<name>` (public by name, like a day, and as revealing as one). Both page and `next` is followed until null; a merged page is cut at the earliest point either prefix's listing stopped, so paging over both never skips an entry.
- `GET /b/<bucket>/e/<name>` — writer-signed (`canonicalFetch(bucket, name, timestamp)` over an empty body): only the phone may read a signed edit body, so nobody else can replay it (plan-critic finding 6). Answers the sealed bytes with `x-efferent-editor`, `x-efferent-signature`, `x-efferent-timestamp` headers from metadata; `410` once the outcome exists, `404` never seen, `400` unsigned (an unsigned request is malformed, the same answer an unsigned upload gets) and `403` signed by another key.
- `PUT /b/<bucket>/e/<name>/outcome` — writer-signed over `canonicalOutcome`; JSON body validated by `validateOutcome`; writes `<bucket>/o/<name>` = the outcome JSON plus `bytes` and `at` copied from the edit, then deletes `<bucket>/e/<name>`. Idempotent (a second PUT rewrites the outcome, the delete of a missing object is fine). Rate limit `WRITES`.
- Remote MCP: `list_edits` tool (arguments `after`, `limit`, `status`; metadata only), description saying edits are submitted with the local reference and are never plaintext here. `setup_guide` text: see S8.
- Tests: editor registration (refused before claim, idempotent, small-order refused), POST (unknown editor 403, wrong key 403, bad signature 403, stale timestamp 400 with `now`, oversize 413, version byte, queue full 429 at 500, tally moved), listing order and paging, body fetch needs the writer signature (403 unsigned) and carries the headers, outcome then `410` and `all` listing, malformed outcome 400.

### S4. Ledger (`src/Core/Sources/Store`)

- Migration `v3.edits`: table `written(id TEXT PRIMARY KEY, version INTEGER NOT NULL, updatedAt DOUBLE NOT NULL)`; `MetaKey.editorRegisteredFor = "editor.bucket"`. No cursor (plan-critic finding 4): the service's `e/` prefix is the queue.
- `Store.nextVersion(for id: String) throws -> Int` (read-increment-write in one transaction, starting at 1), `Store.forgetWritten(id)`, `Store.editorRegistered(for bucket) -> Bool`, `Store.recordEditorRegistered(for bucket)`. `activateArchive` clears `editor.bucket` (a new archive registers its editor again) and keeps `written` (the samples in Health are the phone's whatever the archive).
- `StoreTests`: versions increase per id and are independent across ids; `activateArchive` resets `editor.bucket` and keeps `written`.

### S5. Writing into HealthKit (`src/Core/Sources/Health/HealthWriter.swift`, `HealthMetrics.swift`, `HealthReader.swift`)

- `WritableMetric` catalogue (third catalogue, and every entry must also be readable — a test): `sleep` → `HKCategoryType(.sleepAnalysis)` with the stage mapping inverted from `sleepStageName`; `dietaryEnergy` → `.dietaryEnergyConsumed` kcal; `dietaryProtein` → `.dietaryProtein` g; `dietaryCarbohydrates` → `.dietaryCarbohydrates` g; `dietaryFat` → `.dietaryFatTotal` g; `dietaryWater` → `.dietaryWater` mL; `bodyMass` → `.bodyMass` kg.
- Read catalogue: `AggregateMetric.all` gains the five dietary metrics; `SampleMetric.all` gains `bodyMass`. `HealthCoordinator.plan` needs nothing new (a total marks the week, a sample marks its day) — verified by reading `plan`.
- `HealthReader.requestAuthorization()` becomes `requestAuthorization(toShare: HealthWriter.shareTypes, read: readTypes)`.
- `bodyMass` gets its anchor seeded like every other sample metric; the dietary totals are picked up by the weekly re-read. Meals and weights the person logged before this build are not exported on their own: the existing "Export everything Health has" key re-marks every day and brings them in (Follow-ups, README).
- `HealthWriter` protocol (`apply(_ item: EditItem, version: Int) async throws -> String` returning the day; `remove(id:) async throws -> Set<String>`) with `HealthKitWriter` (real) and a `FakeWriter` in tests. `HealthKitWriter.apply`: refuses `unknownMetric`, `badUnit`, `badRange` (end before start, end in the future, more than 24 h for a sleep stretch), `unauthorized` (`authorizationStatus(for:) == .sharingDenied`); builds `HKQuantitySample`/`HKCategorySample` with metadata `[HKMetadataKeySyncIdentifier: "efferent:<id>", HKMetadataKeySyncVersion: version]`, `healthStore.save`; a HealthKit error is `healthRefused`. `remove(id:)`: `HKSampleQuery` over every writable type with `HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier, allowedValues: ["efferent:<id>"])`, deletes what it finds, returns their days, `notFound` when nothing. Days are computed with the pinned day time zone (`Store.dayTimeZone`) by the same `DayBoundary` the reader uses.
- Tests (`HealthWriterTests`): the catalogue is readable, stage mapping round-trips, refusal codes for each bad item, sync metadata is set (via a `HealthStoring` seam the writer takes, faked in tests — HealthKit itself is not exercised on the simulator here).

### S6. The applier (`src/Core/Sources/Upload/Applier.swift`)

- `Applier(destination:, identity: DeviceIdentity, reading: ReadingIdentity, editorPublicKey: Data, store: Store, writer: HealthWriter, fetch:)`; the default `fetch` is an ephemeral session with a 20 s timeout like `Archive`. `maxEditsPerRun = 50`.
- `run() async throws -> Applied {edits, items, refused, days: Set<String>}`: takes the pass lock (a flag released on every path, like `Uploader.claimPass`; a second caller gets `.busy` and does nothing — plan-critic finding 7); checks write authorization first: any writable type still `.notDetermined` ends the run as `.notAsked` without touching an edit (the sheet has not been shown yet; the edits wait — plan-critic finding 5); lists the whole of `e/` (paging until `next` is null); for each edit in order: fetch bytes + headers with a writer-signed GET; verify `x-efferent-editor == editorPublicKey` and the Ed25519 signature over `canonicalEdit` — a failure is reported as outcome `badSignature` for item 0 and the cursor still moves (the service accepted something it should not have; blocking the queue forever on it is worse); open (`cannotOpen`) and unpack (`malformed`) likewise; then items in order, each `put` with `store.nextVersion(for: id)` and each `delete` with `store.forgetWritten`; collect days; PUT the outcome signed with the writer key and the clock offset; on anything but 2xx stop the run (throw): the edit stays under `e/` and is applied again next launch, which is safe by construction (DoD-5).
- A transport failure anywhere throws; the days collected so far are still returned by the caller via a `partial` field so they get marked.
- Log: one `info` line per run that did something (`applied N edits, M items, R refused, D days marked`), `debug` per edit with name, bytes and codes; nothing else. Never an id, a value or a metric name.
- `ApplierTests` with a scripted `fetch` and `FakeWriter`: applies in listing order; a 5xx outcome ends the run and the second run re-applies with a higher version and the fake still holds one sample per id (DoD-5); bad signature → outcome `badSignature`; days returned equal the items' days (DoD-4); stops at `maxEditsPerRun`; a second `run()` while one is in flight returns `.busy` and fetches nothing; `.notDetermined` returns `.notAsked` and fetches nothing; `.sharingDenied` yields `unauthorized` per item.

### S7. Wiring in the app (`src/App/Sources/Services.swift`, `EfferentApp.swift`, `SetupView.swift`, `Project.swift`, `Wire/Connection.swift`)

- `Services`: `editor = EditorIdentity()`; `createArchive()` also registers the editor key (`ArchiveCreator.registerEditor`, a writer-signed PUT) and records it; `ensureEditorRegistered()` runs on every launch with an archive and does the PUT once per bucket (`editor.bucket` meta). `applierIfPaired()` mirrors `uploaderIfPaired()`.
- `askForWriteAccessIfNeeded()`: on the first foreground launch (scene active) with an archive, if any writable type's `authorizationStatus(for:)` is `.notDetermined`, call `health.requestAuthorization()` — the system sheet shows only the types not yet decided, so an installed app asks once for the new ones (plan-critic finding 5). Background launches never ask; the applier waits with `.notAsked` until then.
- `sendNow()`: after the pause and the locked-phone guards and before `uploader.send()`, `await applyEdits()`: runs the applier, marks `applied.days` dirty with `store.markDirty`, logs; a failure is logged and does not stop the send. The pause holds edits back as it holds days back (documented).
- `ConnectionHandoff` gains `editorKey` (`efferent-editor-v1.<private>.<public>`) and a fourth block `Editor key:`; the instruction says to keep both keys local. `refreshConnectionHandoff()` passes the editor private key.
- `Project.swift`: `NSHealthUpdateUsageDescription` = "Efferent writes the entries an agent you connected asks for — meals, sleep, weight — and only those." and the stale comment goes. `SetupView` step 2 gains one sentence in the same voice (answer 2 = B).
- `.gitleaks.toml`: the editor handoff prefix `efferent-editor-v1.` added beside the reading prefix, by prefix and by the interop fixture value.

### S8. Agent tools (`tools/`, `server/src/setup-guide.ts`, `server/src/python-reference.ts`)

- `tools/archive.ts`: `EditorKey {editorPrivate, editorPublic}`, `loadEditor()` (from `editor-key.json`, owner-only), `submitEdits(items): Promise<{name, at}>` (validate, pack, seal with the reading public key, sign, POST, then append `{name, at, items: [{op, id, metric, day}]}` to `edits.json` in the profile so a later session can find the ids it needs to replace or delete — plan-critic finding 8), `listEdits({after, status})` merging the service's status with that local record.
- `tools/connection.ts`: parses the optional `Editor key` field (an old three-field handoff still imports, read-only, with a note), verifies the public half matches the private half, writes `editor-key.json` with mode 0600; `connection_test.ts` and `archive_permissions_test.ts` cover it.
- `tools/efferent.ts`: `write --file <items.json>` (`-` for stdin) prints the name; `edits [--after <name>] [--all]` prints status lines.
- `tools/analysis.ts`: `TOTALS` gains `dietaryEnergy`, `dietaryProtein`, `dietaryCarbohydrates`, `dietaryFat`, `dietaryWater`; `RECORDS` gains `bodyMass` — the MCP input schemas derive their enums from these lists, so the agent can read back what it wrote.
- `tools/mcp.ts`: `phone_data_write` (input schema mirrors `EditItem`, with the HealthKit facts in its description: only Efferent's own entries can be replaced or deleted, an id is the agent's handle for that, end must be in the past); `phone_data_edits` (status); `phone_data_overview` gains `writable` (the catalogue with units). `mcp_test.ts` covers both tools against a fake fetch.
- Python reference: `--write <items.json>` seals with `SUITE.create_sender_context`, signs with `Ed25519PrivateKey` (already in `cryptography`), POSTs and prints the name; `--edits` lists status. `connection()` returns the editor key when the field is present. `setup-guide.ts`: a step "To write into Health" with the item shape, the codes and the facts above.
- `scripts/python-interop.ts`: Python seals and signs an edit → TypeScript opens and verifies. `scripts/interop.ts`: TypeScript seals and signs an edit to the fixture reading key, writes it to a temp file, and runs `EditInteropTests` on the simulator with `TEST_RUNNER_EFFERENT_EDIT_FIXTURE` pointing at it; the Swift test verifies the signature, opens and unpacks it and prints a marker the script checks. The fixture editor key is generated on the spot, never committed.

Deviations recorded while implementing S8 (2026-09-08):

- The edit fixture for `EditInteropTests` travels inline in `TEST_RUNNER_EFFERENT_EDIT_FIXTURE` as base64url JSON rather than as a temp-file path: the value is under 2 KB, and an environment value needs no file the simulator process has to be able to read. Without the variable the Swift test skips, so `deno task test` is not tied to the script.
- `installConnectionHandoff` adds the editor key to an existing reader when a fresh four-field handoff names the same reading key and no `editor-key.json` exists yet; everything else about an existing reader is still refused. Without this a phone that learnt to write would cost the agent a new profile and a full re-sync. Covered by `connection_test.ts`.
- `phone_data_edits` and `efferent edits` fetch `GET /o/<name>` for every listed edit with a refusal, and turn the phone's item index back into the id from the local record: the listing carries counts only, and "item 1 was badRange" is not an answer an agent can act on. `phone_data_edits` defaults to `status=all`.
- The Python reference's `--edits` walks every page and prints one JSON object per line; `connection()` returns a four-tuple with the raw editor private key or `None`. The reader's user agent moved into a `USER_AGENT` constant, and the server test asserts that line instead of the header literal.
- `efferent`'s option parser now treats a bare `--flag` (followed by nothing or another option) as `"true"`, which is what makes `edits --all` work; a valued option missing its value used to become an empty string and read as absent.

### S9. Documents

- `README.md`: "Letting an agent write" section after "Letting an agent ask"; endpoints in "What the service keeps"; commands; layout lines for `Applier`, `HealthWriter`, `protocol/edits.ts`; the opening "the phone only ever sends" becomes "the phone sends days and applies edits; nothing connects to it".
- `AGENTS.md`: new invariants — an edit never becomes a day on the wire; the phone verifies the editor signature itself; an edit is replaced by its outcome; ids map to sync identifiers and versions live on the phone; an outcome carries indexes and codes only; the pause holds edits; a third catalogue must be a subset of the readable ones.
- `documents/connection.md`: fourth field, editor responsibilities per party, the boundary diagram gains `agent -> sealed edits -> R2 -> phone -> HealthKit`.

### Order of work and checks

S1 → S2 (with `deno test -A protocol/` and `deno task test` green after each) → S3 (`deno test -A server/`) → S4 → S5 → S6 (`deno task test`) → S7 (`deno task check`, a simulator walk of the walkthrough's second step in both appearances) → S8 (`deno test -A tools/`, `deno task interop`, `deno task interop:python`) → S9. Final: `deno task check`, `deno task test`, `deno task interop`, `deno task interop:python`.

### Error handling strategy

Every refusal has a code from one closed set shared by three languages; a code the phone does not know is `malformed`. The service refuses before it stores (size, version byte, signature, queue cap) and never stores a partial edit. The phone never lets the service drop an edit whose outcome it has not accepted, and never blocks its queue on an edit it cannot open — it reports it and moves on. A transport failure ends the run and is retried next launch. No fallbacks: an unknown metric is refused, not guessed; a missing editor key on the agent side makes `write` fail with a sentence saying the handoff predates writing.

## Follow-ups

- Walkthrough copy: answered — step 2 gains a sentence (S7).
- `documents/server-costs.md`: measure the marginal cost of an edit after the implementation is on the phone and the tests have run; not estimated now (owner's answer, 2026-09-08).
- Factory hub (`sites/efferent`, `metadata/efferent`, `APPS.md`): update when a build with writing reaches somebody else; the app is not in the store.
- Workouts and meal correlations (`HKCorrelation`), several editor keys with individual revocation, a push channel: variant C, not started.
- History of the new read metrics (meals, water, weight logged before this build): not exported automatically; the "Export everything Health has" key does it on request (plan-critic finding 8, deferred by the planner: a one-phone product, and the key exists).
- Editor key rotation from the phone (a signed `PUT /editor` with a new key plus a fresh handoff): the endpoint is idempotent and allows it; no screen for it yet.
