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
- when a day was last accepted, and how far back the first export has reached.

The fingerprint is what keeps re-reading cheap: a day rebuilt from Health that comes out byte for
byte as it was sent is not uploaded at all.

The row per record exists for one reason. When something is deleted, HealthKit hands over an
identifier and nothing else — no date, no type — and the record it names is already gone, so nothing
can be asked about it afterwards. Writing down its day while it still existed is the only way to
know which day to rebuild without it.

Days and the anchor are marked in a single transaction. If the anchor could move without them,
HealthKit would consider that data delivered and never offer it again — data loss with no error
anywhere.

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

- **`PUT /b/<bucket>/d/<YYYY-MM-DD>`** stores that day, replacing what was there. The day is in the
  signed request, so a stored day cannot be passed off as another date by anyone in between.
- **`GET /b/<bucket>/days?from=…&to=…`** names the days in a range, with the size of each and when
  it was last written. Both ends are inclusive; both are optional. It pages, and `next` has to be
  followed until it comes back null — a listing that stopped at its first page would report the rest
  of a decade as nothing at all, and would do it without an error.
- **`GET /b/<bucket>/d/<day>`** hands that day back, exactly as it went in.
- **`GET /b/<bucket>/stats`** says how much is there — days, bytes, first and last — without handing
  any of it over. It is encrypted anyway; this is for deciding whether to fetch.

The upload time in a listing is what keeps a mirror in step. A day can be rewritten at any moment,
so "everything after where I stopped" is not a question that can be asked any more. "Everything that
changed since I looked" is, and it is the same one listing.

## What the service learns

Which days exist, how big each is, and when each was written. Not what happened in them, not at what
time, not of what kind. A day is one sealed blob and the service has no way inside it.

That is as coarse as it can be while still answering a question: the date is the address, and
without it there would be nothing to ask for. Everything finer — which readings, at what hour, of
what metric — happens after decryption, on the machine holding the reading key.

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
day, so a question about the 11th that fetched only the 11th would miss the night it is asking
about — silently, which is the worst way for a query to be wrong. The exact filtering happens after
decryption, and compares day against day: an event's times are instants and a bound is a date, so
comparing the two as strings would put every reading of the 6th after the 6th.

`sync` is safe to interrupt. Each day is its own file and what was taken is written down as it goes,
so a run that stops costs the days it had not reached and nothing else.

## Who can read it

Nobody but you, and the service holding the data least of all.

The reading key pair is made on the machine that will read — the one with a keyboard and a terminal.
Its private half stays there and never travels. The phone is given only the public half, which it
uses to seal every day, so a lost or seized phone gives up nothing about the history it already
sent. The bucket is named by the hash of that public key, which is why there are no accounts here:
knowing where to write follows from knowing who to write to.

Encryption says nothing about authorship, so the phone also makes a signing key on first launch and
signs every upload. The first upload into an empty bucket registers that key and afterwards only it
is accepted — otherwise a stranger who learned a bucket name could fill it with rubbish. That check
carries more weight now than it did: writing over a day is the ordinary operation, so without it a
stranger could overwrite history rather than merely add to it. The signing key cannot decrypt, and
the reading key cannot write: handing an agent the ability to read must not hand it the ability to
forge.

A day on the wire is raw-deflate-compressed NDJSON inside a sealed envelope —
`[version][ephemeral public key][nonce][ciphertext]` — with the bucket name and the date bound into
the tag, so a blob cannot be moved to another bucket, or offered back as a different day, without
the decryption failing. The building blocks are X25519, HKDF-SHA256 and AES-256-GCM, all of which
CryptoKit and WebCrypto already ship. No crypto library is vendored anywhere.

Pairing is therefore a scan, not a careful transfer. The reader prints a code holding its address
and its public key — `deno task efferent pair --url …` — and the phone's camera reads it. Nothing
worth protecting travels that way.

`protocol/` describes these bytes in TypeScript and `src/Core` describes them again in Swift, so
`deno task interop` exists to prove the two still agree: a Swift test seals and signs a real day,
and the reader opens it and checks the signature. With `--post <url>` it also puts that day through
a running service and reads it back out.

The service itself is a Cloudflare Worker over an R2 bucket, deployed with `deno task server:deploy`
and answering on a `workers.dev` address. It is open to the internet by design — there are no
accounts, so anyone who knows the address can claim an unused bucket and write to it. Your bucket is
safe, because the first writer keeps it, but the storage bill is not: a cap on buckets or a
turnstile in front of the first write is the obvious next thing if the address ever gets around.

## Commands

```bash
deno task check
```

- `check` — lint and types on the scripts, protocol tests, then a simulator build.
- `test` — protocol tests, then unit tests on any available iPhone simulator.
- `dist` — unsigned App Store archive at `build/Efferent.xcarchive`.
- `fmt` — format task scripts, and Swift if swiftformat is installed.
- `generate` — regenerate the Xcode project from `Project.swift`.
- `icons` — re-render the app icons from `documents/icon.svg`.
- `server:dev` / `server:deploy` — the bucket service, locally or to Cloudflare.
- `interop` — check that the Swift and TypeScript sides still make the same bytes.
- `efferent` — the reading side: `keygen`, `pair` (prints the code to scan), `ask`, `sync`, `status`,
  `query`, plus `send` and `read` for poking at a single day by hand.

Trying the whole path without a phone:

```bash
deno task server:dev
```

Then, in another shell: `deno task efferent keygen`,
`deno task efferent pair
--url http://127.0.0.1:8787` to get a code the phone can scan, and
`deno task
efferent read --url http://127.0.0.1:8787` to see what arrived. `send` stands in for a
phone when you have no device to hand.

In the simulator there is no camera, so scanning cannot be reached and neither can any screen behind
it. Debug builds therefore also take the code as text — put it on the device's pasteboard with
`xcrun simctl pbcopy <udid>` and paste it in. It goes through the same pairing path as a scan, and
is compiled out of what ships.

One thing to watch when writing into a service that keeps its data: the first writer owns a bucket
for good, so a test upload claims it and the phone is refused afterwards. Release the claim by
deleting `<bucket>/key` from R2.

Signing, packaging and upload all happen outside this repository. Nothing here touches a
certificate, and the archive path above is the whole of the agreement with whatever does.

## Layout

- `src/Core/Sources/Health` — the metric catalogue, the readers, the day builder.
- `src/Core/Sources/Wire` — the event type, the day, NDJSON assembly.
- `src/Core/Sources/Store` — schema, day ledger, anchors.
- `src/Core/Sources/Upload` — Keychain, background upload.
- `src/App/Sources` — the SwiftUI screen and the composition root.
- `src/Tests/Sources` — unit tests.
- `protocol/` — bucket and day names, signing, sealed envelopes.
- `server/` — the bucket service, a Cloudflare Worker over R2.
- `tools/` — the reading side as a command line tool.
