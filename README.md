# Efferent

An iPhone app that sends your Health data to a server you own, so that software which is not an
Apple device can read it.

The name comes from the efferent nerves — the ones carrying signals away from the centre. That is
the whole design in one word: the phone only ever sends.

## Why it works this way

iOS cannot be a server. The app is suspended seconds after it goes to the background, a listening
socket is closed by the system, the address changes with the network, and behind NAT the phone is
unreachable anyway. So nothing ever connects _to_ the phone. The phone pushes, and the meeting point
with whoever reads the data lives elsewhere.

One decision follows from that and explains most of the code: **the unit of everything is a day.**

The phone does not work out what changed and send a difference. It notices which _dates_ were
touched, re-reads those days out of Health in full, and puts each one up as a single object named by
its date. Writing a day again replaces it. So:

- **A second write is the ordinary case, not a conflict.** A watch that synced late, a workout
  deleted a week later, a re-read after a crash — all of them are the same operation.
- **There is nothing to keep in step.** No sequence numbers, no acknowledgement to get right, no way
  for a reinstalled phone to collide with its own past, and no state on the phone that has to have
  been correct every time since the first launch. What is in the archive is what Health says now.
- **A query is a range.** "Sleep in August" is thirty-one names, worked out without asking anybody.

## What it stores on the device

Not a copy of Health. HealthKit is already the source of truth and sits a millisecond away;
mirroring it would cost hundreds of megabytes and a migration every time a record changes shape, and
buy nothing. What survives a relaunch is bookkeeping:

- one row per day — whether it still has to go, and the fingerprint of what was sent last time;
- one row per HealthKit record, holding only which day it is in;
- one anchor per HealthKit sample type — where each reader stopped;
- when a day was last accepted, how far back the first export has reached, and when the archive was
  last checked against all this.

The fingerprint is what keeps re-reading cheap: a day rebuilt from Health that comes out byte for
byte as it was sent is not uploaded at all.

The row per record exists for one reason. When something is deleted, HealthKit hands over an
identifier and nothing else — no date, no type — and the record it names is already gone, so nothing
can be asked about it afterwards. Writing down its day while it still existed is the only way to
know which day to rebuild without it.

Days and the anchor are marked in a single transaction. If the anchor could move without them,
HealthKit would consider that data delivered and never offer it again — data loss with no error
anywhere.

## Why the phone checks the archive

A fingerprint is not a fact about Health. It is a claim about the _archive_ — "it already holds
exactly this" — and nothing on the phone could ever test it. So an archive that lost a day left the
device certain of something untrue, and certain of it for good: the day is re-read, comes out
identical, matches the fingerprint, and is never sent again. Silently, for history nobody is looking
at. That is not a hypothetical: deleting objects from the bucket does exactly this, and afterwards
every counter on the phone still reads zero pending.

So a pass now begins by reading the listing and comparing it against the days that ought to exist —
the first day Health knows about through today, not the days the phone believes it sent, because the
ledger is the thing under suspicion. Whatever the archive does not have loses its fingerprint and
goes again in that same pass. Sending was already idempotent — a day is written whole and replaced
whole — so re-sending one costs bytes and nothing else, and there is no state anywhere that a
duplicate could corrupt.

It is cheap enough to do without thinking about it, but not free, so it runs at most once a day. A
page is a thousand days, which makes a decade three round trips and about two hundred kilobytes —
under two seconds. The failure behaviour is the part that matters: a walk that cannot finish throws
rather than answering with the pages that did arrive, because a partial listing would name the rest
of the archive as lost and the phone would dutifully re-upload years. A check that fails neither
stops the send behind it nor counts as done, so one bad moment does not buy a whole day of not
looking.

## What it collects

Two streams, because one would be wrong.

**Totals**, bucketed by hour and by day: steps, walking and running distance, active and basal
energy, flights climbed, exercise and stand minutes. These come from `HKStatisticsCollectionQuery`,
never from adding samples up — iPhone, Watch and other apps all write steps for the same minutes,
and summing them double-counts against what the Health app shows.

**Records**, kept as they are: sleep, workouts, heart rate, heart rate variability, resting heart
rate, respiratory rate, blood oxygen. A total of any of these would say nothing. Sleep in particular
arrives as overlapping stretches with stages rather than one interval per night; stitching them into
"a night" is a judgement call and is left to whoever reads the data.

A record belongs to the day it _started_ on. A night that begins before midnight is in the evening's
day, which is what a person means by "that night" — and it keeps a record in exactly one day, which
a day written whole requires.

The last seven days are re-read on every refresh, because the Watch syncs late and yesterday can
still grow tomorrow. Almost all of it costs nothing: a day that did not change never leaves the
device.

The first export finds how far back Health goes and marks every day since. That part takes a second,
because marking a day is a row and nothing more; the sending that follows needs nobody watching, and
resumes on its own, because a day is either in the archive or still marked. Hourly totals begin the
day the app was installed — buckets by the hour for a decade would be several hundred thousand
readings at a resolution nobody asks of last decade.

Days are the person's own days. The time zone comes from the device; the numbering is always
Gregorian, because `Calendar.current` follows the phone's region and can be Japanese or Buddhist,
where the year is not 2026 and nobody else could name the day.

## The wire format

NDJSON. One self-contained JSON object per line:

```
{"id":"agg:steps:2026-08-07T09:00Z:h","v":1,"metric":"steps","bucket":"hour","value":842,"unit":"count"}
```

`v` is the schema version, so an old reader can refuse a format it does not understand instead of
quietly parsing nonsense. `id` is derived from the data itself, so the same fact always carries the
same id. A total names its `bucket`; a record does not, and that is the only difference between the
two — there is no kind on an event, because the third one a kind used to be for was a deletion, and
a day sent whole says a record is gone by not containing it.

Lines are sorted by id. The body is what decides whether a day has changed since it was last sent,
and HealthKit does not promise to hand samples back in the same order twice.

## What the service keeps

Everything, for good. The service is not a letterbox that empties when the reader collects — it is
where the history lives, so an agent can ask a question months later without the phone being awake,
reachable, or still owned by the same person.

- **`PUT /b/<bucket>`** creates the logical archive with an empty signed request. It records only
  the phone's public signing key, before there is a Health day to upload.
- **`PUT /b/<bucket>/days`** stores the days the request carries, each replacing what was there.
  Every date is in what was signed, so a stored day cannot be passed off as another date by anyone
  in between. The answer names the days that landed, and that is what lets the phone stop marking
  them; a day it does not name simply goes again.
- **`GET /b/<bucket>/days?from=…&to=…`** names the days in a range, with the size of each and when
  it was last written. Both ends are inclusive; both are optional. It pages, and `next` has to be
  followed until it comes back null — a listing that stopped at its first page would report the rest
  of a decade as nothing at all, and would do it without an error.
- **`GET /b/<bucket>/d/<day>`** hands that day back, exactly as it went in.
- **`GET /b/<bucket>/stats`** says how much is there — days, bytes, first and last — without handing
  any of it over. It is encrypted anyway; this is for deciding whether to fetch.
- **`/mcp/b/<bucket>`** exposes the keyless remote MCP tools for archive metadata and ciphertext
  links plus `setup_guide`, which returns the complete local Python reference without accepting any
  arguments. It never accepts the reading key.

The upload time in a listing is what keeps a mirror in step. A day can be rewritten at any moment,
so "everything after where I stopped" is not a question that can be asked any more. "Everything that
changed since I looked" is, and it is the same one listing.

## What the service learns

Which days exist, how big each is, and when each was written. Not what happened in them, not at what
time, not of what kind. A day is one sealed blob and the service has no way inside it.

That is as coarse as it can be while still answering a question: the date is the address, and
without it there would be nothing to ask for. Everything finer — which readings, at what hour, of
what metric — happens after decryption, on the machine holding the reading key.

Batching adds one thing to that list and it is worth naming rather than glossing over: the service
sees which days arrived together. It already knew as much from their write times landing in the same
second, so nothing new is given away, but the frame says it outright.

Encryption hides contents, not the fact of them, and the privacy copy should say so plainly.

## Asking the archive

Two ways, and they differ in what they cost rather than in what they answer. `ask` goes to the
service every time and downloads only the days a question covers. `sync` keeps a local copy — one
file per day — and `query` then answers from it with the network switched off:

```bash
deno task efferent ask --metric sleep --since 2026-08-01 --until 2026-08-31
deno task efferent sync      # copy every day that changed since last time
deno task efferent status    # what the archive holds, what the mirror has
deno task efferent query --metric sleep --since 2026-08-01
```

Both fetch one day earlier than asked for. A night that began before midnight is in the evening's
day, so a question about the 11th that fetched only the 11th would miss the night it is asking about
— silently, which is the worst way for a query to be wrong. The exact filtering happens after
decryption, and compares day against day: an event's times are instants and a bound is a date, so
comparing the two as strings would put every reading of the 6th after the 6th.

`sync` is safe to interrupt. Each day is its own file and what was taken is written down as it goes,
so a run that stops costs the days it had not reached and nothing else.

## Letting an agent ask

Decryption and analysis run on the agent's machine. The connection starts on the phone:
the phone creates the archive and reading key, then hands an otherwise unprepared agent a keyless
remote MCP URL containing the bucket id and the reading key as a separate local secret. The short
instruction tells the agent to call `setup_guide` first. The remote MCP server returns setup text,
archive metadata and ciphertext only. The complete decision and the boundary between phone,
Cloudflare and agent are in [`documents/connection.md`](documents/connection.md).

The Worker exposes the keyless remote MCP at `/mcp/b/<bucket-id>`. It offers archive metadata,
sealed-day listings and ciphertext links. Its argument-free `setup_guide` tool returns the exact
Python source needed to decrypt one selected day locally. The agent saves that source and the
handoff in private local files, uses the remaining remote tools to select dates, and runs the
reference once per date. No repository checkout, Deno installation, second MCP server, separate
prompt URL or gateway restart is part of the connection.

**The part that answers runs next to the reading key, and it has to.** The remote MCP endpoint is
discovery and ciphertext transport. The embedded script validates that the key belongs to the
bucket, fetches only ciphertext using the bucket id and date, and emits local NDJSON. The agent then
analyses those records with local code and never sends plaintext or the reading key to a remote
tool.

The TypeScript reader and shaped local health tools remain in this repository for development and
for people who deliberately choose that interface. They are not a dependency of the public
connection procedure.

## Who can read it

Nobody but you, and the service holding the data least of all.

The phone creates the reading key pair and the archive before an agent is involved. It keeps the
public half for sealing days and keeps the private half in its Keychain so the owner can hand it to
an agent. The bucket is named by the hash of the public key, which is why there are no accounts here:
knowing where to write follows from knowing which key seals the archive.

The handoff gives the agent a remote MCP URL with the bucket id in its path and the reading private
key as a separate field. Its instruction says to call `setup_guide` first. The key is stored on the
agent's machine and never sent to the remote MCP endpoint, Cloudflare, an HTTP header or a tool
argument. Cloudflare can return setup text, list and return sealed days, but cannot open one. The
agent fetches ciphertext and decrypts and analyses it locally.

Encryption says nothing about authorship, so the phone also makes a signing key on first launch. It
claims the empty archive with that key and signs every later upload; afterwards only that writer is
accepted — otherwise a stranger who learned a bucket name could fill it with rubbish. That check
carries more weight now than it did: writing over a day is the ordinary operation, so without it a
stranger could overwrite history rather than merely add to it. The signing key cannot decrypt, and
the reading key cannot write: handing an agent the ability to read must not hand it the ability to
forge.

A day on the wire is raw-deflate-compressed NDJSON inside an RFC 9180 base-mode HPKE envelope —
`[version 2][32-byte encapsulated key][ciphertext and tag]` — with the bucket name and the date bound
into the authenticated data. The suite is DHKEM(X25519, HKDF-SHA256), HKDF-SHA256 and
ChaCha20-Poly1305. CryptoKit seals on the phone and `hpke-js` opens in the local TypeScript reader.
The reader retains the custom X25519/HKDF/AES-GCM version 1 decoder while stored days are replaced;
new writes never use it.

Days travel a month at a time, because the request is what costs rather than what is in it: a day is
a few kilobytes and the first export is thousands of them, so a request each would be a phone
spending its whole waking life on round trips. What goes up is a plain frame — a date, a length, a
sealed blob, repeated — and the signature covers the whole of it along with the dates it names, so
the service has to prove its own reading of the frame before it can store anything. Each day inside
is still sealed to its own date, so a batch binds nothing and ends at the door: the archive never
learns that days arrived together.

There is no server-side invitation or pairing session. The phone creates the bucket and gives the
connection handoff directly to the agent. [`documents/connection.md`](documents/connection.md)
defines its fields and responsibilities. Existing build-7 destinations remain readable and keep
uploading, but fresh setup is phone-first and the scanner has been removed. The on-device ledger is
bound to the bucket whose writes its fingerprints describe: activating another phone-owned archive
invalidates those claims and queues every known day again, while a legacy destination is adopted
without a reset.

`protocol/` describes these bytes in TypeScript and `src/Core` describes them again in Swift, so
`deno task interop` exists to prove the two still agree: a Swift test packs, seals and signs a real
request of two days, and the reader unpacks it, opens each day and checks the signature. Two days
rather than one, because a batch of one would never cross the boundary where a framing disagreement
would live. With `--post <url>` it also puts that request through a running service and reads both
days back out separately.

The service itself is a Cloudflare Worker over an R2 bucket, deployed with `deno task server:deploy`
and answering on a `workers.dev` address. It is open to the internet by design — there are no
accounts, so anyone who knows the address can claim an unused bucket and write to it. Your bucket is
safe, because the first writer keeps it, but the storage bill is not: a cap on buckets or a
turnstile in front of the first write is the obvious next thing if the address ever gets around.

## Commands

```bash
deno task check
```

- `check` — the secret scan, generated Cloudflare types, lint and types on the scripts, protocol and
  reading-tool tests, then a simulator build.
- `test` — protocol and reading-tool tests, then unit tests on any available iPhone simulator.
- `dist` — unsigned App Store archive at `build/Efferent.xcarchive`.
- `fmt` — format task scripts, and Swift if swiftformat is installed.
- `secrets` — scan the working tree and the whole history for committed keys (`brew install
  gitleaks`). Part of `check`, and the only thing GitHub runs on a push.
- `generate` — regenerate the Xcode project from `Project.swift`.
- `icons` — re-render the app icons from `documents/icon.svg`.
- `server:types` — regenerate the Worker bindings and runtime types from `server/wrangler.jsonc`.
- `server:dev` / `server:deploy` — the bucket service and remote MCP, locally or on
  Cloudflare.
- `interop` — check that Swift and TypeScript agree on request bytes, HPKE and the phone handoff key.
- `interop:python` — with PyHPKE installed in the selected Python, prove that the exact source
  returned by `setup_guide` opens a TypeScript-sealed day. Set `EFFERENT_PYTHON` to that interpreter.
- `efferent` — the local reading side: `connect --handoff <file>`, `ask`, `sync`, `status`, `query`,
  plus `keygen`, `send` and `read` for protocol development. `connect --handoff -` reads the handoff
  from standard input without putting the key in a process argument.
- `mcp` — the same archive as an MCP server on stdio, for an agent to read.

Trying the phone-first path without a phone:

```bash
deno task server:dev
```

Create an archive in the app, share its three-field handoff into a private file, then set a fresh
`EFFERENT_HOME` and run `deno task efferent connect --handoff <file>`. Delete the temporary file
after import. `send` still stands in for a phone during protocol development and writes as many days
in one request as are named.

One thing to watch when writing into a service that keeps its data: the first writer owns a bucket
for good, so a test upload claims it and the phone is refused afterwards. Release the claim by
deleting `<bucket>/key` from R2.

Signing, packaging and upload all happen outside this repository. Nothing here touches a
certificate, and the archive path above is the whole of the agreement with whatever does.

## Layout

- `src/Core/Sources/Health` — the metric catalogue, the readers, the day builder.
- `src/Core/Sources/Wire` — the event type, the day, NDJSON assembly, the request frame.
- `src/Core/Sources/Store` — schema, day ledger, anchors.
- `src/Core/Sources/Upload` — Keychain, background upload, reading the archive's listing.
- `src/App/Sources` — the SwiftUI screen and the composition root.
- `src/Tests/Sources` — unit tests.
- `protocol/` — bucket and day names, the request frame, signing, sealed envelopes.
- `server/` — the bucket service, a Cloudflare Worker over R2.
- `documents/server-costs.md` — the measured marginal storage and operation cost per user.
- `tools/archive.ts` — where days come from: the reading key, the service, the mirror.
- `tools/analysis.ts` — days turned into answers, and every correction that turning needs.
- `tools/efferent.ts` — the reading side as a command line tool.
- `tools/mcp.ts` — the reading side as an MCP server.
