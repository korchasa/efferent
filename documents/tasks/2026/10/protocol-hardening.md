---
date: 2026-10-01
status: done
implements: [READ-1, READ-2, READ-3, READ-4, READ-5, DELIVERY-3a]
tags: [protocol, security, performance, server, reader, phone]
related_tasks:
  - [An agent writes Health data through the service](../09/agent-writes-health.md)
  - [The reader in Python](../09/reader-in-python.md)
---

# The protocol: a bucket id opens nothing, history comes a quarter at a time, an edit lands once

## Goal

The archive protocol must be safe against the parties that actually see its addresses, and fast for
the way agents actually read it. Today knowing a bucket id is enough to download every sealed day
the owner has ever recorded, a question about a year of history costs 365 requests and, on the
public path, 365 Python processes, and a compromised service can make the phone apply an old edit a
second time. After this task the bucket id is an address and nothing more, a range of history is one
request per quarter, and the phone applies an edit at most once whoever serves it again.

## Overview

### Context

The request, verbatim: «Проанализируй и исправь протокол в efferent. Он должен быть безопасным и
быстрым. Учти всю специфику приложения, ресурсы на хранение и паттерны работы агента, включая
поиски в истории. Делай все сам, не задавай вопросов и не останавливайся.»

The protocol has three implementations that must agree byte for byte: the Cloudflare Worker and its
`protocol/` modules (the service repository, private), the phone in `src/Core` (Swift), and the
Python reader in `reader/` — the package behind the local MCP server and the command line, plus
`reader/efferent_hpke.py`, the script the remote `setup_guide` hands every agent.

Who sees a bucket id. It is the last path segment of the remote MCP URL, so it sits in every MCP
client configuration the owner ever adds it to — including cloud-hosted connector lists — and in the
Worker's request logs. It was designed as "not a secret in the sense that losing it is fatal"
(`protocol/ids.ts`), which was true when the only thing it opened was ciphertext nobody could read.
Health data stays sensitive for a lifetime, though, and ciphertext harvested today is opened the day
X25519 falls; and the listing beside it is a side channel of its own: the size of every day (activity
level), the moment every day was written (when the phone was awake), and the moment of every edit an
agent made (often a meal time).

How agents read history, measured from the code:

- The local MCP server keeps a mirror. `Reader.refresh` asks for stats and the last 14 days at most
  every five minutes and fetches what changed one day per request, eight requests at a time, each on
  a new TLS connection. A fresh mirror of the owner's archive (3 914 days) is about 3 920 requests.
- The public path (`setup_guide`) tells the agent to run `python efferent_hpke.py --day …` once per
  date: one process, one TLS handshake and one request per day. A year is 365 of each.

Storage and cost facts that bound the design (`documents/server-costs.md`): a day is one R2 object of
about 9.5 KB; the owner's decade is 37.3 MB. A Worker may make 1 000 calls to Cloudflare's own
services — R2 included — per request; at most six of them wait at once, the rest queue. R2 `get` is
Class B ($0.36 per million), `list` is Class A ($4.50 per million).

### Current State

- Read routes need only the bucket id: `GET /b/<b>/days` (listing with size and upload time),
  `GET /b/<b>/d/<day>`, `GET /b/<b>/stats`, `GET /b/<b>/edits`, `GET /b/<b>/o/<name>`, and the
  remote MCP tools `list_sealed_days`, `get_sealed_day`, `list_edits`, `archive_status`.
- There is no way to read more than one sealed day per request.
- The phone verifies the editor signature on every edit (`Applier.open`) but keeps no record of
  which signed edits it has already answered. The service can hand an answered edit back under a
  new name — or under its old one, which takes the crash-recovery path that re-applies on purpose —
  and the phone writes its items into Health again. A `put` replayed after a later correction wins,
  because the version the phone keeps only climbs.
- The reader still reads the outcome count as `refused` (`reader/efferent/archive.py`,
  `reader/efferent/cli.py`); the service has answered `failed` since the word changed, so per-item
  failure codes never reach an agent and the command line miscounts. The tests' stand-in service
  still speaks the old word, which is why nothing failed.

### Constraints

- **The service must never be able to read a day**, and the reading key never goes into a URL,
  header, log or remote tool. A proof of holding it is fine; the key is not.
- **No new key in the handoff.** Every handoff already carries the reading key, so anything the
  reader needs is derived from it; a reconnect is not required of the owner.
- **The phone and the service change the word together; the Worker is never deployed alone**
  (service `CLAUDE.md`). The current phone build (25) keeps working against the new Worker, because
  nothing closes until a phone registers a read key. The new reader and the new phone need the new
  Worker — the range route and the word `replayed` are unknown to the old one — so the order is the
  Worker first, then the reader and the phone. Deploying and installing remain the owner's to type.
- **Every R2 listing pages; every write path has a ceiling; a range is inclusive at both ends.**
- **Budget per request**: 1 000 calls to R2, six waiting at once.
- `reader/efferent_hpke.py` is copied into the service and rendered by `deno task reference`;
  `deno task interop` proves Swift and Python agree; Swift and Python change in the same commit.
- Post-quantum sealing (an X-Wing HPKE suite) is out of scope: it needs a new reading key, a new
  bucket and a reconnect, which is the owner's decision. This task removes the cheap harvesting
  route instead — the bucket id — and leaves the stronger seal as a recorded option.

## Definition of Done

- [x] READ-1: once the phone has registered a read key, every per-day and per-edit read needs a
  signature by it; the coarse figures and the setup guide stay open.
  - Test: `server/reader_test.ts::a registered read key closes every per-day and per-edit read`
  - Test: `server/reader_test.ts::the remote tools that list per day point at the script once a read key exists`
  - Evidence: `deno task test` in the service repository — 129 passed
- [x] READ-2: the read key is derived from the reading key the same way in Swift and Python, only
  its public half reaches the service, registered with the writer key, and a read signature covers
  the bucket, the exact path and query, and the moment.
  - Test: `src/Tests/Sources/ReadKeyTests.swift::testTheReadKeyMatchesThePublishedVector`
  - Test: `src/Tests/Sources/ReadKeyTests.swift::testTheReadersSignatureVerifiesAgainstTheKeyThePhoneMakes`
  - Test: `src/Tests/Sources/ReadKeyTests.swift::testRegisteringTheReadKeyIsAWriterSignedPutOfItsPublicHalf`
  - Test: `src/Tests/Sources/ReadKeyTests.swift::testASignedReadIsStampedWithTheServicesClock`
  - Test: `src/Tests/Sources/StoreTests.swift::testTheReadKeyIsRegisteredPerArchive`
  - Test: `reader/tests/test_wire.py::ReadKey::test_the_read_key_matches_the_published_vector`
  - Test: `reader/tests/test_reader.py::SignedReads::test_every_read_is_signed_with_the_key_made_from_the_reading_key`
  - Test: `server/reader_test.ts::the phone registers its read key, and only the owner may`
  - Test: `server/reader_test.ts::a read signed for another path is refused`
  - Evidence: `deno task interop` (Swift signs a read, Python verifies it under its own derivation)
- [x] READ-3: a range of days comes back as one frame per request — at most 92 days and 8 MiB —
  with a pointer to where the next one starts; the reader, the command line and the local MCP
  server fetch history that way, and the guide's script reads a range in one process.
  - Test: `server/reader_test.ts::a range comes back as one frame, both ends included`
  - Test: `server/reader_test.ts::a long range is cut at its day and byte ceilings and says where to go on`
  - Test: `reader/tests/test_wire.py::Frames::test_days_come_back_in_order_with_their_bytes`
  - Test: `reader/tests/test_reader.py::WindowedFetch::test_a_run_of_days_is_asked_for_as_a_range_not_a_day_at_a_time`
  - Test: `reader/tests/test_reader.py::ReferenceScript::test_a_range_comes_back_as_lines_that_each_name_their_day`
  - Evidence: `deno task test` in the service repository, `deno task test:reader`
- [x] READ-4: an archive whose phone has not registered a read key answers exactly as before.
  - Test: `server/reader_test.ts::an archive without a read key answers as it always did`
  - Evidence: `deno task test` in the service repository — the existing listing, day and MCP tests
    pass unchanged
- [x] READ-5: an agent learns which items of an edit failed, in the phone's words.
  - Test: `reader/tests/test_mcp.py::Writing::test_edits_are_listed_with_the_status_and_the_local_record`
  - Evidence: `deno task test:reader`
- [x] DELIVERY-3a: the phone applies a signed edit at most once, under any name, and answers a
  replay with `replayed` without touching Health.
  - Test: `src/Tests/Sources/ApplierTests.swift::testAnEditServedAgainUnderANewNameIsNotAppliedTwice`
  - Test: `src/Tests/Sources/ApplierTests.swift::testAnAnsweredEditServedAgainUnderItsOwnNameIsNotApplied`
  - Test: `src/Tests/Sources/ApplierTests.swift::testAnEditSignedLongBeforeTheNewestAnsweredOneIsNotApplied`
  - Test: `src/Tests/Sources/ApplierTests.swift::testAnEditWhoseAnswerDidNotLandIsNotTakenForAReplay`
  - Test: `src/Tests/Sources/StoreTests.swift::testAnsweredEditsAreKeptInsideTheWindowAndForgottenWithTheArchive`
  - Test: `protocol/edits_test.ts::an outcome carries counts and codes and nothing else` (service)
  - Evidence: `deno task test`
- [x] Docs: `README.md`, `documents/connection.md`, `documents/design.md`,
  `documents/requirements.md`, `documents/server-costs.md`, the setup guide and the service's
  `README.md` describe the protocol as built.
  - Evidence: `grep -n "read key" README.md documents/connection.md documents/design.md documents/requirements.md`

## Solution

### 1. A bucket id opens nothing on its own (READ-1, READ-2, READ-4)

- **The read key.** `seed = HKDF-SHA256(ikm = the 32 raw bytes of the reading private key, salt =
  empty, info = "efferent/v1 read", 32 bytes)`, used as an Ed25519 seed. Every holder of the
  reading key — the phone, the package, the guide's script — derives the same key; nothing new
  travels in the handoff, and the key itself never leaves.
- **Registration.** `PUT /b/<b>/reader`, body the 32-byte public half, signed by the writer key over
  `efferent/v1 reader\n<bucket>\n<ts>\n<b64url sha256(body)>`, counted with the claims. Stored at
  `<bucket>/reader`. Same shape as the editor registration; the phone sends it once per archive,
  as `ensureReaderRegistered`, beside `ensureEditorRegistered`, and remembers it under the meta key
  `reader.bucket`.
- **A signed read.** Headers `x-efferent-reader`, `x-efferent-signature`, `x-efferent-timestamp`
  over `efferent/v1 read\n<bucket>\n<path and query exactly as requested>\n<ts>`. The ±300 s window
  and the small-order refusal are the ones every other signature has.
- **What a read key closes.** `GET /days`, `GET /d/<day>`, the new `GET /d` range, `GET /edits`,
  `GET /o/<name>`; and the remote tools `list_sealed_days`, `get_sealed_day`, `list_edits`, which
  then answer with the script command to use instead. `GET /stats`, `archive_status` and
  `setup_guide` stay open: whether the archive exists, how many days and bytes, and its first and
  last day.
- **Compatibility.** No read key registered → every route answers as today. Readers sign every read
  whether or not it is needed, so a phone registering its key asks nothing of them.
- **The phone** signs its two reads — the archive check (`Archive.days`) and the queue listing
  (`Applier.pending`) — with the same derived key, on the service's clock (`clockOffset`). Its
  registrations use the corrected clock as well.

### 2. History a quarter at a time (READ-3)

- **Service.** `GET /b/<b>/d?from=&to=&after=`: one listing, then the days fetched side by side, and
  the answer is the frame uploads already use (`10 bytes day, 4 bytes length, blob`, ascending). At
  most 92 days — "the last three months" is the commonest question and takes one request — and
  8 MiB, decided from the sizes the listing already gives, so nothing is fetched to be thrown away.
  `x-efferent-next` names where to continue; it is absent at the end. An empty range is an empty
  body; a range that runs backwards is refused with 400. 94 R2 calls at most, far inside the 1 000.
- **Package.** `Archive.several` groups the wanted days into spans (`spans`: the next wanted day
  within 7 days joins, at most 92 days long) and fetches each span as frames, four spans at a time.
  A fresh mirror of a decade becomes about 50 requests instead of about 3 920; the everyday refresh
  fetches the changed recent days in one.
- **Script.** `--from YYYY-MM-DD --to YYYY-MM-DD` reads a range in one process and prints one NDJSON
  line per reading with its `day`; `--day` stays, and `--list` takes `--from` and `--to`. The guide
  tells the agent to use the range.

### 3. An edit lands once (DELIVERY-3a)

- After the service has taken an edit's outcome, the phone writes down the SHA-256 of its sealed
  bytes, its name and the moment its editor signed it (`answeredEdit`, migration v11; cleared with
  the journal when the archive changes, pruned to the 900 s window on every write).
- Before applying a fetched edit whose signature verified, the phone refuses it as `replayed` when
  its digest is already written down, or when it was signed more than 15 minutes before the newest
  edit already answered. The second rule covers edits answered before this build existed, whose
  digests were never kept: the service takes an edit only within five minutes of its signature, and
  the phone answers in the service's order and stops at the first edit it cannot answer, so a
  genuine edit is never signed that long before one answered ahead of it.
- A replay touches nothing in Health, is answered as one failed item with the new word `replayed`,
  and is written into the journal when it came under a new name (never over the original's lines).
- `replayed` joins the closed set in all three implementations.

### 4. `failed`, not `refused` (READ-5)

The reader reads the count and the outcome's list as `failed`, the command line counts with it, and
the stand-in service in the tests speaks the service's real word. An outcome stored under the older
word still reads.

### Verification

Run on 2026-10-01, on branch `fix/protocol` (app) and service `main`:

- Service: `deno task check` — no leaks in the working directory or in 46 commits, types up to date,
  129 tests passed (121 before this task).
- App: `deno task check` and `deno task test` — exit 0; `deno task test:reader` — 127 tests; `deno
  task interop` — exit 0, including "Making the read key on both sides".
- End to end against the Worker run locally (`deno task dev:simulator`): a fresh bucket of 200 days
  read openly, as ranges across quarter boundaries and page by page; then the read key registered,
  after which unsigned reads got 401, a foreign key and a foreign target 403, a stale moment 400,
  `stats` stayed open, the package mirrored all 200 days, the reference script read a range, listed
  and read one day, and the remote listing tools pointed at the script. The phone's own code did the
  same against it in a temporary test: registered the key (201), had an unsigned listing refused
  (401) and its own signed listings answered (200).

### Not done here, on purpose

- Deploying the Worker and installing the phone build: the owner types both, the Worker first.
- A post-quantum suite: recorded in `documents/design.md` under open decisions.
- Binding the HTTP method and path into the writer's signatures: every writer-signed message already
  names its purpose, bucket and body; what replaying one inside five minutes can do is store the
  same bytes again.
- `deno task interop --post <url>` still cannot reach a service: the fixed interop bucket is never
  claimed, and an upload no longer creates a bucket. The range read-back added to it is therefore
  not exercised; the same reads are covered by the end-to-end run above.

### Known limits

- Between installing the build and the first edit it answers, an edit answered before the upgrade
  can still be applied once more: the ledger starts empty. A phone restored from a backup starts
  empty in the same way, because the database is excluded from backups. Both need the service
  itself to misbehave.
- A legacy reader-owned connection has no reading private key on the phone, so it never registers a
  read key and stays readable by its bucket id.
