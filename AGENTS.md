# Efferent — rules for working in this repository

Read `README.md` first; it explains what the app does and why the design is shaped the way it is.
This file is the rulebook.

## Boundaries

- **No signing code lives here.** Signing, packaging and upload all happen outside this repository.
  `deno task dist` produces an _unsigned_ `build/Efferent.xcarchive` and stops. Never add a
  certificate, a provisioning profile, or a workflow that uploads anywhere.
- **A push is not a release.** Anything that reaches real users starts from a version tag or a
  manual dispatch, never from a branch push.
- Every command is a `deno task`. When you need a new one, add a task and a typed script under
  `scripts/` — never a shell script or a Makefile target.

## Invariants you must not break

- **Events and their anchor go in one transaction.** `Store.commit` takes both for exactly this
  reason. An anchor saved on its own tells HealthKit that data was delivered when it was not, and
  HealthKit will never offer it again.
- **Ids are derived from the data, never from a counter.** That is what makes a re-send free. If you
  find yourself generating a UUID for an event id, the design has gone wrong.
- **The confirmation mark only moves forward, and only to what the server reports.** Never advance
  it because a request returned 200 with the batch you sent — a server that accepted half a batch
  says so in its `ack`.
- **Payload bytes must be canonical.** Build them with `Event.payload(_:)`. The outbox decides
  whether anything changed by comparing those bytes, so an unstable encoder would make every re-scan
  look like fresh data and turn the daily aggregate refresh into constant traffic.
- **Confirmed rows are pruned late, not immediately.** They are what the comparison above compares
  against. Retention must comfortably exceed the re-scan window — a month against a week.
- **A metric belongs to exactly one catalogue.** Cumulative quantities are totals via
  `AggregateMetric`; everything else travels record by record via `SampleMetric`. Putting one in
  both sends the total _and_ the samples behind it, which is the double count wearing a different
  hat. A test enforces this.
- **A deletion reuses the id of the sample it removes.** Same id, different kind, so the receiver
  drops the record without keeping a lookup table.
- **The service is an archive, not a letterbox.** It never overwrites a stored batch and never
  deletes one. A repeated range is acknowledged and ignored, so a device that missed an answer stops
  retrying without history changing underneath it.
- **Anything that lists R2 must page.** R2 answers a listing with at most one page and a `truncated`
  flag; code that fetches once and filters afterwards reports everything past that page as nothing at
  all, and reports it as success. Follow the cursor until it runs out, and cap what is unbounded
  loudly rather than quietly.
- **One upload is in flight at a time, and the claim is released on every path.** The guard that
  enforces it is a flag, and a flag that a `return` can slip past locks the outbox until the app is
  relaunched. Release it before every early exit, and let an acknowledged batch start the next one —
  otherwise sending stops at one batch and looks like a server that went quiet.

## The parts that must agree across languages

`protocol/` is the single description of what goes on the wire, and the Swift side has to match it
byte for byte. When you change anything there, change both sides in the same commit and run
`deno task interop` — Swift agreeing with Swift proves only that Swift is consistent, and that check
is the only thing that catches drift before a phone does.

- **Never log or persist the reading private key anywhere but the reader's own machine.** The phone
  gets the public half only. If you find yourself adding a way to send the private half to the
  device, the design has gone wrong.
- **The signing key and the reading key are separate on purpose.** One writes, one reads. Merging
  them would mean an agent's config file grants the right to forge uploads.
- **Bucket, sequence range and body hash are all bound into what gets signed and into the encryption
  tag.** Dropping any of them from either place lets a blob be replayed, relabelled or moved,
  silently.
- **Compress before sealing, never after.** Ciphertext does not compress, and a round trip that only
  works one way tends to be discovered on a phone.
- The service must never gain a way to read a batch. If a feature seems to need one, it belongs in
  the reading tool instead.

## HealthKit facts that shape the code

- Read permission is unknowable. `authorizationStatus(for:)` always answers `.notDetermined` for
  reads, on purpose, so an app cannot work out what is being hidden from it. Do not build a "no
  access" screen — it cannot be correct. Show counters instead.
- Raw samples must not be summed. iPhone, Watch and third-party apps all write steps, and adding
  them up double-counts. Totals come from `HKStatisticsCollectionQuery` with `.cumulativeSum`, which
  picks a source per interval the way the Health app does.
- Observers must be registered synchronously in `application(_:didFinishLaunchingWithOptions:)`. The
  system launches the app in the background with no UI; registration deferred to a `Task` or to a
  view appearing simply never happens.
- The observer's `completion()` must be called, and quickly. Skip it and HealthKit treats the
  delivery as failed, retries, and after a few failures stops waking the app at all — with no error,
  and a symptom that shows up days later.
- Never make a network call inside the observer. Read, write to the outbox, call `completion()`,
  then hand the send to the background session.
- `.immediate` frequency is not honoured for most types; the system rounds it to hourly. Hourly is
  the real ceiling on freshness.
- `HKAnchoredObjectQuery` returns deletions as well as additions. They must be sent as
  `health.delete`, or the server keeps records the person has erased.
- Background delivery does not work in the simulator. Anything touching it has to be tested on a
  device.
- Health data must not be put in iCloud — App Store rule 5.1.3. Sending it to a server the person
  configured is fine, and needs a privacy policy.

## The screen

One question matters more than everything else — is it still working — so it is answered first, in a
sentence, and the counters sit underneath for when the answer is not the expected one. Keep it that
way when adding anything: a number that needs interpreting is not a status.

"Nothing waiting" is not the same fact as "nothing has ever been sent", and neither is the same as
"stopped a week ago". That is why the outbox stamps when the confirmation mark last moved, and why
the screen distinguishes all three. Collapsing them into one cheerful row is how a silent failure
gets to look healthy.

## Other traps

- Keychain accessibility is `afterFirstUnlock`. Under `whenUnlocked` every background upload fails
  silently, because the phone is locked when they run.
- Background uploads must be file-based. The in-memory `uploadTask(with:from:)` is rejected by
  background sessions — the daemon has to read the body after this process is gone.
- The app icon needs the classic `AppIcon.appiconset` with an explicit `ios-marketing` 1024 slot. A
  single-size "universal" icon compiles without one and the App Store listing icon comes out blank.
- `xcodebuild` needs `/usr/bin` first on PATH. A Homebrew rsync earlier in the path breaks copy
  phases, and the error blames the copy rather than the tool.
- **Never test-write into a bucket a real phone will use.** The first writer owns a bucket for
  good, so a smoke test claims it and the phone is refused with 403 afterwards — a failure that
  surfaces on the device, long after the test looked like it passed. This bites twice: `deno task
  interop --post` signs with a throwaway key, and `efferent send` signs with the machine's own.
  Post to `server:dev`, whose storage dies with the process. A real bucket that is already claimed
  is released by deleting `<bucket>/key` from R2.
