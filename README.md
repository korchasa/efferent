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

Two consequences follow, and they explain most of the code:

- **Every fact carries a stable id** derived from the data itself. A re-send cannot create a
  duplicate, so the device is free to be careless — send a batch twice, send it after a crash, send
  it out of order.
- **A sequence number gives the reader a cursor.** "Give me everything after 41207" is the only
  query the other side needs.

## What it stores on the device

Not a copy of Health. HealthKit is already the source of truth and sits a millisecond away;
mirroring it would cost hundreds of megabytes and a migration every time a record changes shape, and
buy nothing. Three small things do have to survive a relaunch:

- the outbox — facts waiting to reach the server;
- one anchor per HealthKit sample type — where each reader stopped;
- counters — next sequence number, last one the server confirmed, and how far the first full export
  has walked.

Events and the anchor are written in a single transaction. If the anchor could move without them,
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

The last seven days of daily totals are recomputed on every refresh, because the Watch syncs late
and yesterday can still grow tomorrow. Re-reading them is almost free: a bucket whose value did not
change never leaves the device.

The first export walks history backwards a month at a time, on screen, saving its place as it goes.
It covers daily totals only — hourly buckets for five years would be several hundred thousand events
for a resolution nobody asks of last decade, so hourly history starts when the app was installed.

## The wire format

NDJSON. One self-contained JSON object per line:

```
{"id":"agg:steps:2026-08-07T09:00Z:h","seq":41207,"v":1,"type":"health.agg","metric":"steps","bucket":"hour","value":842,"unit":"count"}
```

`v` is the schema version, so an old reader can refuse a format it does not understand instead of
quietly parsing nonsense. `type` is one of `health.agg` (a de-duplicated bucket total),
`health.sample` (an interval or reading kept as-is) or `health.delete` (the person removed it from
Health).

The server answers `{"ack": <seq>}` with the highest sequence number it has durably stored. The
device moves its mark to that, not to what it happened to send — a half-accepted batch simply goes
again.

## Who can read it

Nobody but you, and the service holding the data least of all.

The reading key pair is made on the machine that will read — the one with a keyboard and a terminal.
Its private half stays there and never travels. The phone is given only the public half, which it
uses to seal every batch, so a lost or seized phone gives up nothing about the history it already
sent. The bucket is named by the hash of that public key, which is why there are no accounts here:
knowing where to write follows from knowing who to write to.

Encryption says nothing about authorship, so the phone also makes a signing key on first launch and
signs every upload. The first upload into an empty bucket registers that key and afterwards only it
is accepted — otherwise a stranger who learned a bucket name could fill it with rubbish. It cannot
decrypt, and the reading key cannot write: handing an agent the ability to read must not hand it the
ability to forge.

A batch on the wire is raw-deflate-compressed NDJSON inside a sealed envelope —
`[version][ephemeral public key][nonce][ciphertext]` — with the bucket name and the sequence range
bound into the tag, so a blob cannot be moved to another bucket or relabelled with a different range
without the decryption failing. The building blocks are X25519, HKDF-SHA256 and AES-256-GCM, all of
which CryptoKit and WebCrypto already ship. No crypto library is vendored anywhere.

Pairing is therefore a scan, not a careful transfer. The reader prints a code holding its address
and its public key — `deno task efferent pair --url …` — and the phone's camera reads it. Nothing
worth protecting travels that way.

`protocol/` describes these bytes in TypeScript and `src/Core` describes them again in Swift, so
`deno task interop` exists to prove the two still agree: a Swift test seals and signs a real batch,
and the reader opens it and checks the signature. With `--post <url>` it also puts that batch
through a running service and reads it back out.

What the service still learns: which bucket, when, and how much. From the rhythm of uploads a
determined observer could infer when you sleep. Encryption hides contents, not the fact of them, and
the privacy copy should say so.

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
- `efferent` — the reading side: `keygen`, `pair` (prints the code to scan), `send`, `read`.

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

Signing, packaging and upload all happen outside this repository. Nothing here touches a
certificate, and the archive path above is the whole of the agreement with whatever does.

## Layout

- `src/Core/Sources/Health` — the metric catalogue, the readers, the coordinator.
- `src/Core/Sources/Wire` — the event type and NDJSON assembly.
- `src/Core/Sources/Store` — schema, outbox, anchors, counters.
- `src/Core/Sources/Upload` — Keychain, background upload.
- `src/App/Sources` — the SwiftUI screen and the composition root.
- `src/Tests/Sources` — unit tests.
- `protocol/` — bucket names, signing, sealed envelopes, framing.
- `server/` — the bucket service, a Cloudflare Worker over R2.
- `tools/` — the reading side as a command line tool.
