# Efferent — rules for working in this repository

Read `README.md` first; it explains what the app does and why the design is shaped the way it is.
This file is the rulebook.

## Boundaries

- **No signing code lives here.** Signing, packaging and upload all happen outside this repository.
  `deno task dist` produces an _unsigned_ `build/Efferent.xcarchive` and stops. Never add a
  certificate, a provisioning profile, or a workflow that uploads anywhere.
- **A push is not a release.** Anything that reaches real users starts from a version tag or a
  manual dispatch, never from a branch push. The only workflow here is the secret scan, and it is
  the only kind that belongs: it reads and reports, and reaches nothing.
- Every command is a `deno task`. When you need a new one, add a task and a typed script under
  `scripts/` — never a shell script or a Makefile target.

## Invariants you must not break

- **A day is read from Health and sent whole. Never send a difference.** The archive holds what
  Health says now, not the sum of every update that was ever correct. If you find yourself computing
  what changed and uploading only that, the design has gone wrong — mark the day and let it be
  rebuilt.
- **Marked days and their anchor go in one transaction.** `Store.markDirty` takes both for exactly
  this reason. An anchor saved on its own tells HealthKit that data was delivered when it was not,
  and HealthKit will never offer it again.
- **Ids are derived from the data, never from a counter.** If you find yourself generating a UUID
  for an event id, the design has gone wrong.
- **A day that came back unchanged must not be uploaded.** The fingerprint is of the _plaintext_,
  never of what goes on the wire: sealing uses a fresh throwaway key every time, so identical days
  never produce identical bytes and a comparison of those would re-upload a week every hour.
- **A fingerprint is a claim about the archive, so the archive is what tests it.** It says "the
  archive already holds exactly this", and when that is false the ordinary path cannot recover: the
  day rebuilds identically, matches, and is never sent again. A pass therefore reads the listing
  first — at most once a day — and compares it against the days that _ought_ to exist, from the
  first day Health knows about through today. Never against the days the ledger says were sent: the
  ledger is the thing under suspicion. `Store.markMissing` is the one place a fingerprint is thrown
  away, and `markDirty` deliberately keeps it; do not merge the two.
- **Archive claims belong to one bucket.** The ledger records which bucket its digests describe.
  Activating another phone-owned archive clears every digest and archive timestamp and requeues
  every known day, while preserving HealthKit anchors, sample-to-day rows and the install day.
  Merely adopting a legacy reader-first destination records its bucket without resetting it.
- **The check runs before the pass decides there is nothing to do.** "Nothing waiting" is precisely
  the answer it exists to distrust — a day whose fingerprint matches an archive that has since lost
  it looks exactly like a day that is safely stored.
- **A listing walk answers in full or throws.** Returning the pages that did arrive names the rest
  of the archive as lost, and the caller believes it — a phone re-uploading a decade, or worse if
  the comparison ever runs the other way. A check that fails must neither stop the send behind it
  nor be stamped as done, or one bad moment buys a whole day of not looking.
- **Payload bytes must be canonical, and the body is sorted by id.** Build payloads with
  `Event.payload(_:)`. The comparison above is over the whole body, and HealthKit does not promise
  to hand samples back in the same order twice.
- **A metric belongs to exactly one catalogue.** Cumulative quantities are totals via
  `AggregateMetric`; everything else travels record by record via `SampleMetric`. Putting one in
  both sends the total _and_ the samples behind it, which is the double count wearing a different
  hat. A test enforces this.
- **A record belongs to the day it started on.** Not to every day it overlaps: a day written whole
  cannot hold half a record twice. A query compensates by fetching one day earlier than it was asked
  for.
- **A record's day is written down while the record still exists.** A deletion arrives as a bare
  identifier whose record is already gone from Health, so nothing can be asked about it afterwards.
  Dropping the `sample` table would make old deletions unnoticeable — silently, and only for the
  history nobody is looking at.
- **A day that Health has nothing for still gets an entry.** Without one it stays marked forever and
  is rebuilt on every pass.
- **A batch is a way of travelling and ends at the door.** Days share a request because the request
  is what costs, but each one is sealed to its own date and stored as its own object. Nothing below
  the unpacking may learn that a batch happened — a stored frame, a summary of one, or a day whose
  contents depend on what it travelled with would all put a second shape into an archive that reads
  only one.
- **A day is written down as sent only if the answer names it.** The service replies with the days
  it stored; a batch is not a promise that all of them landed. Marking a day clean that never
  arrived loses it for good, and loses it invisibly — nothing later goes looking for a day that is
  no longer marked.
- **The frame ascends and never repeats, and a bad one is refused whole.** Ordering is what makes
  the same days pack to the same bytes, which the signature over the body depends on, and it removes
  the question of which of two copies of a day wins. A frame that unpacked to whatever parsed before
  it went wrong would store part of a batch and answer as though it stored all of it. Tests on both
  sides enforce this.
- **A day too large for a batch travels alone.** There is no size at which a day stops being owed. A
  limit that held one back would leave it marked for good, with the counters saying forever that
  something is waiting.
- **The service must not learn more than which days exist.** It sees a date, a size and a write
  time. Anything that would tell it what happened inside a day — a summary, a count, a metric name
  in the path — hands over what the encryption exists to keep, and nothing would fail to make that
  visible.
- **Anything that lists R2 must page.** R2 answers a listing with at most one page and a `truncated`
  flag; code that fetches once and filters afterwards reports everything past that page as nothing
  at all, and reports it as success. Follow the cursor until it runs out, and cap what is unbounded
  loudly rather than quietly.
- **A range is inclusive at both ends.** A listing skips _past_ a key, so `from` has to be turned
  into the day before it. Passing `from` straight through drops the first day of every range — the
  one most likely to be the point of the question. A test enforces this.
- **One build pass runs at a time, and the claim is released on every path.** The guard is a flag,
  and a flag a `return` can slip past stops sending until the app is relaunched. Days themselves are
  independent and several may be in the air at once; the next pass starts only when none are left,
  or it would rebuild work already under way.

## The parts that must agree across languages

`protocol/` is the single description of what goes on the wire, and the Swift side has to match it
byte for byte. When you change anything there, change both sides in the same commit and run
`deno task interop` — Swift agreeing with Swift proves only that Swift is consistent, and that check
is the only thing that catches drift before a phone does.

- **The phone creates the archive and the reading key; the agent only connects.** The phone derives
  the bucket id from the reading public key, seals days with that public half, and keeps the private
  half in its Keychain for a user-directed handoff. The old reader-first scan is a migration source,
  not a design to extend. The complete boundary is in `documents/connection.md`.
- **A reading key goes from phone to agent and nowhere else.** The handoff carries it as a field
  separate from the remote MCP URL. The agent stores it locally. Never put it in a URL, HTTP header,
  remote tool argument, log or Cloudflare storage. The remote MCP server takes a bucket id and
  returns ciphertext only.
- **The signing key and the reading key are separate on purpose.** One writes, one reads. Merging
  them would mean an agent's config file grants the right to forge uploads.
- **The stored reader key is bare base64 PKCS8; the phone handoff key is raw base64url.** A stock
  secret scanner looks for PEM armour and can read either as ordinary text. `.gitleaks.toml` matches
  the stored PKCS8 prefix and excuses the interop fixture by file *and* value, so replacing that
  fixture with a real key still fails. The phone handoff prefix must also remain covered; never
  widen an exception to a whole file.
- **Bucket, days and body hash are all bound into what gets signed, and bucket and day into the
  encryption tag.** Dropping any of them from either place lets a day be replayed, moved to another
  bucket, or handed back as a different date, silently. The days are named in the signed string as
  well as hashed inside the body on purpose: the service verifies against the days it unpacked, so a
  frame read differently from how it was packed fails there rather than storing a day under a date
  nobody meant.
- **Compress before sealing, never after.** Ciphertext does not compress, and a round trip that only
  works one way tends to be discovered on a phone.
- The service must never gain a way to read a day. If a feature seems to need one, it belongs in the
  reading tool instead.
- **Anything that answers a question runs on the agent's machine.** The remote MCP server is only a
  catalogue and transport for ciphertext. The local reader decrypts and runs `tools/analysis.ts`.
  If an agent cannot execute local code, it cannot read this archive; do not work around that by
  sending the reading key to the service.

## Answering on behalf of a reader

`tools/analysis.ts` is where a day stops being events and becomes an answer, and every correction in
it exists because the wrong version fails quietly.

- **Sleep is merged, never summed.** Stretches overlap — two sources, or a stage boundary that laps
  its neighbour — so adding their lengths invents hours of sleep. A test breaks if anybody adds them.
- **A night is noon to noon, named by the evening it began in.** A night is stored across two day
  files, because a record belongs to the day it started on. Grouping by that day reports two short
  nights instead of one whole one.
- **Daily and hourly totals never meet.** Both live in the same day and mean the same thing at
  different resolutions, so a reader that takes whichever it finds first doubles the day.
- **A unit that lies is corrected in the label, not in the value.** Blood oxygen leaves the phone as
  0.97 with "%" written on it. Rewriting the value would put two meanings of one field into a single
  history, so the note travels with the answer instead.
- **A tool refuses rather than truncates.** An answer cut down to what fitted is a question quietly
  replaced by a smaller one, and nothing in it says so.
- **An answer from a stale local copy says it is stale.** The archive being unreachable is not a
  reason to fail, and it is not a reason to keep quiet either.
- **Bootstrap and interpretation have separate homes.** The public, immutable, versioned connection
  prompt teaches an unprepared agent how to connect the keyless remote MCP endpoint and start the
  local reader. Tool descriptions still carry everything needed to interpret the health data they
  return; do not make a tool's correctness depend on remembering the bootstrap prompt.
- **The server's `serve()` call stays the last line of `tools/mcp.ts`.** It never returns, so
  anything below it never initialises; importing the module hides this entirely, and only the test
  that spawns the server as a process catches it.

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
- Never make a network call inside the observer. Work out which days changed, mark them, call
  `completion()`, then hand the send to the background session.
- `.immediate` frequency is not honoured for most types; the system rounds it to hourly. Hourly is
  the real ceiling on freshness.
- `HKAnchoredObjectQuery` returns deletions as well as additions, and a deleted object carries its
  identifier and nothing else — no date, no type. `HKQuery.predicateForObject(with:)` cannot help:
  it searches the records that still exist. The day has to come from what was written down earlier.
- Background delivery does not work in the simulator. Anything touching it has to be tested on a
  device.
- Health data must not be put in iCloud — App Store rule 5.1.3. Sending it to a server the person
  configured is fine, and needs a privacy policy.

## The screen

One question matters more than everything else — is it still working — so it is answered first, in a
sentence, and the counters sit underneath for when the answer is not the expected one. Keep it that
way when adding anything: a number that needs interpreting is not a status.

"Nothing waiting" is not the same fact as "nothing has ever been sent", and neither is the same as
"stopped a week ago". That is why the device stamps when a day was last accepted, and why the screen
distinguishes all three. Collapsing them into one cheerful row is how a silent failure gets to look
healthy.

## Other traps

- Keychain accessibility is `afterFirstUnlock`. Under `whenUnlocked` every background upload fails
  silently, because the phone is locked when they run.
- Background uploads must be file-based. The in-memory `uploadTask(with:from:)` is rejected by
  background sessions — the daemon has to read the body after this process is gone.
- The app icon needs the classic `AppIcon.appiconset` with an explicit `ios-marketing` 1024 slot. A
  single-size "universal" icon compiles without one and the App Store listing icon comes out blank.
- `xcodebuild` needs `/usr/bin` first on PATH. A Homebrew rsync earlier in the path breaks copy
  phases, and the error blames the copy rather than the tool.
- **Never test-write into a bucket a real phone will use.** The first writer owns a bucket for good,
  so a smoke test claims it and the phone is refused with 403 afterwards — a failure that surfaces
  on the device, long after the test looked like it passed. This bites twice:
  `deno task
  interop --post` signs with a throwaway key, and `efferent send` signs with the
  machine's own. Post to `server:dev`; its storage lives in `server/.wrangler/state` and can be
  deleted outright. A real bucket that is already claimed is released by deleting `<bucket>/key`
  from R2.
- **Deleting objects from a live bucket takes days out of Health's reach, not just the archive's.**
  Health keeps the readings, but the phone's ledger says those days are already stored, so nothing
  would ever send them again — and no button in the app rebuilds a day it believes is safe. That is
  what the listing check now repairs, and it repairs it a day later at the earliest. Before clearing
  a prefix, list it and see what is in it: a cleanup of keys left over from an older protocol has
  already taken most of a year of real days with it, because they shared the prefix.
