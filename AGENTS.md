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
- **Ids are derived from the data, never from a counter, and never stored.** A reader rebuilds an
  identity from the kind, the metric and the instant a record began; the phone writes none. The
  HealthKit record id it used to carry was 58% of everything this app uploaded and nothing ever read
  it. If you find yourself generating a UUID for an event id, or putting one back on the wire, the
  design has gone wrong.
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
- **A day is built by `Columnar.body(_:)`, and its bytes must not depend on the order events
  arrived in.** The comparison above is over the whole body, and HealthKit does not promise to hand
  records back in the same order twice. Sorting by id used to settle that; with no id left the order
  is over the content — series by kind, metric, bucket, unit and source, rows by their instants and
  then their values. It has to be a _total_ order: two sleep stages beginning in the same second
  differ only past the third field, and a comparison that stopped earlier would let one day hash two
  ways. Tests on both sides shuffle real days to prove it.
- **An instant is not a name, so rows that land on one are numbered.** `#1`, `#2` in the order the
  series holds them. Over a decade of real days 3 620 events out of 994 336 share an identity with
  another — sleep stages that start together, one heartbeat seen by two devices. A reader that
  skipped the numbering would silently drop them into each other.
- **An instant is a whole second.** Both ends of a record are stored as seconds since 1970, and a
  finer `Date` is cut down. The line format said the same thing in ISO-8601 and truncated just as
  quietly; here it is the shape of the field, so it is written down rather than discovered.
- **The columns are a closed set, and that is enforced by the type.** A field with no column would
  travel no further and nothing would say so. Which is why the columns are the stored properties of
  `Event`: adding a field without adding a column does not compile. The TypeScript writer, which has
  no such help, refuses an unknown key instead.
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
- **Anything that lists R2 must page, a rolled-up listing included.** R2 answers a listing with at
  most one page and a `truncated` flag; code that fetches once and filters afterwards reports
  everything past that page as nothing at all, and reports it as success. Follow the cursor until it
  runs out, and cap what is unbounded loudly rather than quietly. A listing with a `delimiter` looks
  like the exception and is not: R2 gathers the prefixes from the objects it happened to scan, so the
  real archive answers twelve years as two pages. Reading only the first cost it 2 942 days out of
  3 914 and put `lastDay` two and a half years early, with nothing anywhere saying so.
- **`stats` counts the archive a year at a time, and every year at once.** There is no cheaper answer
  than the listing itself — R2 knows how many objects a prefix holds only by walking them — so the
  saving is in not waiting. Days are named by date, so the archive splits along a boundary the keys
  already have: one rolled-up listing says which years exist, and the years are then counted side by
  side. A decade fell from 1.4 seconds to about 0.7, and the answer is the same answer. Never take it
  from a number kept somewhere instead: a count nothing re-derives is a claim about the archive that
  the archive is never asked about.
- **Every write path has a ceiling, because anybody can reach this service.** The address ships
  inside the app, there is no account behind it, and a bucket is claimed by whoever signs for it
  first — so the only thing between a stranger and the bill is what the code refuses. A day may
  weigh a mebibyte, a request five, one bucket may be handed half a gigabyte and the service a
  hundred, and a caller gets a count per minute on claims and on uploads. Before those, the free
  plan's own hundred thousand requests a day allowed 1.6 TB to be added daily and kept forever. The
  two tallies (`<bucket>/taken` and `taken`) count bytes _handed over_, not bytes held: a day
  written twice counts twice, because what costs money is taking the request. They are budgets and
  never answers — `stats` still walks the archive, and nothing asks a tally what the archive holds.
  The numbers come from the live archive on 2026-09-05: eleven years is 3 914 days and 37 MB, the
  median day 8.7 KB, the heaviest 278 KB.
- **A range is inclusive at both ends.** A listing skips _past_ a key, so `from` has to be turned
  into the day before it. Passing `from` straight through drops the first day of every range — the
  one most likely to be the point of the question. A test enforces this.
- **One build pass runs at a time, and the claim is released on every path.** The guard is a flag,
  and a flag a `return` can slip past stops sending until the app is relaunched.
- **A day in the air is left out of the next round.** The ledger knows only that a day is marked, so
  a second round would pick the same days as the first, build them again and write the archive
  twice with one answer left over. `Uploader` therefore keeps the days of every request it has
  handed over and `Store.pendingDays(limit:excluding:)` skips them — fetching past the limit rather
  than filtering after it, since those days sit at the head of exactly that order and a filtered page
  would come back empty and read as "nothing else to send".
- **A round that only cleans days runs the next round itself.** The chain that walks a backlog
  restarts from a finished upload, so a round in which every day came back unchanged sends nothing,
  finishes nothing and starts nothing. The queue then moves one round per wake-up: a phone with 2 794
  days waiting on 2026-08-30 was clearing 31 of them per Health delivery, all of them already in the
  archive, while the screen said thousands were waiting. So a round that scheduled nothing and
  cleaned something goes straight into the next one, until the queue is empty or the launch has run
  long enough (`passBudget`).
- **A round takes days that are next to each other, and stops at the first gap.**
  Building a round reads Health once, for the span between its first day and its last, because
  Health answers a range almost as fast as a single day. That is only true while the days *are* a
  range. Thirty-one days plucked from all over the ledger make the span months wide and Health hands
  back everything in it: a phone on 2026-08-30 fetched 87 718 readings over 4.4 seconds to build 31
  days, 28 of which turned out unchanged. It happens whenever a backlog is walking backwards and the
  observers keep re-marking this week. Stopping at the gap costs nothing — the order is the same,
  nothing is skipped, and the next round starts at the gap — so `Store.pendingDays` returns a run.
- **The recent past is re-read at most once every 20 minutes, and only for deliveries.** Totals have
  no anchor, so the only way to notice one moving is to mark the last week and build those days
  again — which reads a week out of Health in full, thousands of readings, usually for the digest to
  say every day is unchanged. Two deliveries twelve seconds apart did exactly that work twice. Totals
  are not delivered faster than hourly, so a second look inside the window cannot find anything the
  first one missed: `HealthCoordinator.markRecentDaysIfDue` keeps the stamp in `meta` (it has to
  survive the process — background launches are separate ones) and returns 0 inside the window. The
  refresh button calls `markRecentDays` directly and is never throttled, and sample metrics are never
  throttled at all: their anchors say exactly what moved.
- **Only a delivery asks to send; every other path is asked for by a caller that sends anyway.**
  `refresh()` and `markHistory()` used to call `onNewData` themselves, and both of their callers send
  on the very next line — so each of them started a second pass that either landed on the pass lock or
  ran over an empty queue. `reconcile()` was worse: its only caller is the uploader's own check at the
  start of a pass, so its ask was refused by the pass that made it, every time, by construction. A new
  marking path must either ask to send or be called by something that does — never both.
- **A pass fills the pipe rather than stopping at one request.** Rounds carry on until as many
  requests are in the air as the session runs at once (`concurrentUploads`), because the days in
  them are excluded from the next round and nothing is built twice. A pass that stopped after one
  request left the network idle between round trips, and a decade then took a day of wake-ups.
- **Every answer starts the next pass, a failure included.** The chain that walks a backlog is made
  of exactly this. Before, a failed request simply ended the chain and the queue stood still until
  something outside woke the app. A failure now waits first — doubling from five seconds, capped at
  five minutes — so a phone with no network does not spend a day of battery rediscovering that.
- **A day the service keeps refusing is set aside, not retried forever.** Refusals are counted per
  day (`Store.recordRefused`) and a day refused `attemptsBeforeParking` times stops being offered:
  it does not become acceptable by being sent a sixth time, and while it is being tried it stands at
  the head of the queue in front of days that would go. Nothing is forgotten — `markMissing` and
  `markDirty` both reset the count, so the daily check against the archive owes a parked day back
  once a day. `Stats.stuckDays` counts them apart from the ones still moving.
- **A phone cannot tell that its own clock is wrong, so the service tells it.** A signature refused
  for being out of time is refused forever, with nothing the phone can measure to say why. The
  service puts its own seconds in that 400 (`now`), the phone learns the difference once
  (`clock.offset`) and signs against the service's clock from then on. The `Date` header is the
  fallback; a difference under a minute is latency, not a clock, and is not written down.
- **Day boundaries are pinned to one time zone, and it is never moved.** `day.timezone` is set to
  the phone's zone the first time anything asks and left alone. A boundary that followed the phone
  abroad would re-cut every day of history into different days — every one of them changed, every
  one of them owed again — for a fortnight's holiday.
- **The archive check compares sizes as well as names.** A write that landed cut short leaves an
  object with the right name and the wrong length, and a listing of names alone can never show it.
  The size the service accepted is written down per day (`day.bytes`) and compared against the
  listing; days sent before that was recorded have nothing to compare and are left alone rather than
  suspected.

## The parts that must agree across languages

`protocol/` is the single description of what goes on the wire, and the Swift side has to match it
byte for byte. When you change anything there, change both sides in the same commit and run
`deno task interop` — Swift agreeing with Swift proves only that Swift is consistent, and that check
is the only thing that catches drift before a phone does. The MCP setup guide's Python reference is
a third implementation: after changing HPKE or the guide, also run `deno task interop:python` with
PyHPKE 0.6.3 in the selected local interpreter.

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
- **A refusal for being out of time carries the service's clock.** The 400 answers with `now`, its
  own seconds. It is the only way a phone can discover that its own clock is wrong, and without it
  such a phone stops sending for good. Any rewrite of the service keeps that field; the phone falls
  back to the `Date` header, which every HTTP answer has.
- **Compress before sealing, never after.** Ciphertext does not compress, and a round trip that only
  works one way tends to be discovered on a phone.
- **New days are written in layout 2; old days remain readable as layout 1.** Layout 2 is the
  columnar day above; layout 1 was one JSON object per line carrying the HealthKit record id. Every
  reader — Swift, TypeScript, the `setup_guide` Python — accepts both and unpacks either into the
  same NDJSON, because an archive is replaced a day at a time and nothing above that layer should
  notice. Changing the layout again means a new `dayFormatVersion`, all three readers, and a ledger
  reset through `Store.activateDayFormat`: a digest is over the plaintext, so a day repacked in a new
  shape hashes differently while the archive still holds the old bytes, and without the reset the
  uploader would call every day unchanged and leave the old archive up there for good.
- **New days are RFC 9180 HPKE version 2; old days remain readable as version 1.** The current suite
  is DHKEM(X25519, HKDF-SHA256), HKDF-SHA256 and ChaCha20-Poly1305. Changing it requires a new
  envelope byte, an updated MCP setup guide, Swift/TypeScript/Python interoperability proof and a
  one-time ledger reset that makes the phone replace every known day.
- The service must never gain a way to read a day. If a feature seems to need one, it belongs in
  local reading code instead.
- **Anything that answers a question runs on the agent's machine.** The remote MCP server is only a
  catalogue and transport for ciphertext. The remote MCP's `setup_guide` Python reference is the
  complete default connection path; the repository's TypeScript reader is optional. If an agent
  cannot execute local code, it cannot read this archive; do not work around that by sending the
  reading key to the service.

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
- **A summary kept beside the mirror is a claim about a file, and the file is what tests it.**
  `metrics.json` holds what each day holds, so the overview answers with 3 KB without opening 3 914
  files to do it. Every entry carries the size and modification time of the day it was read from,
  and an entry whose fingerprint no longer matches is thrown away and worked out again — a record
  gone stale, gone missing or gone wrong costs a read, never a wrong answer. Deleting the file is
  always safe, and so is having none.
- **One question asks the archive once.** The freshness check already asks what the archive holds —
  that is how the mirror knows whether it is behind — so an answer that also wants those numbers
  takes them from the check instead of calling again. The service walks the whole listing to answer
  that, a second and a half on a decade of days, and the overview was paying for the walk twice.
- **The MCP bootstrap is self-contained.** The phone instruction tells an unprepared agent to call
  the argument-free `setup_guide` tool first. That tool contains the exact Python source that
  decrypts selected days. It must never require a separate prompt URL, repository checkout, Deno, a
  second MCP server or a gateway restart.
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
- **One observer over every type, never one per type.** `HKObserverQuery(sampleType:)` is called once
  per type, so a Watch catching up woke the app fourteen times in the same second — fourteen reads of
  the ledger and fourteen asks to send, thirteen of which the pass lock turned away.
  `HKObserverQuery(queryDescriptors:)` hands the changed types to one handler instead, and
  `HealthCoordinator.plan` turns that set into the work: the metrics that moved get read, and a week
  gets marked once however many totals moved. Background delivery stays per type — that is where the
  frequency lives, and samples want `.immediate` where totals want `.hourly`. A handler that is told
  nothing (`changed` is nil) reads everything: an unknown change is not the same as no change.
- **The delivered set names what moved, and a cold launch is why it looks like everything.** Measured
  on the simulator on 2026-08-30: adding one Steps sample by hand woke the app about `steps` alone,
  out of the fourteen types it subscribes to; on an empty store the registration delivery named
  nothing at all. On the phone every delivery names all fourteen, and that is not HealthKit handing
  over the whole subscription — it is the delivery a freshly registered observer always gets, and this
  app registers from a cold launch every time, because nothing keeps its process alive between
  deliveries. So `plan` really does narrow; on the phone the honest answer just happens to be
  everything. An empty set is an ordinary answer, not a fault, and `woke` says so in words.
- **A locked phone hands over nothing, and that is not a fault.** Health data is encrypted with the
  passcode, so every read fails with `HKError` 6 — "Protected health data is inaccessible" — while
  the screen is locked. That is most of when the catch-up task runs, so the task asks
  `UIApplication.isProtectedDataAvailable` first and waits rather than reading the ledger and
  starting a build it cannot finish. `HealthReader.isLocked` catches the case that slips through — a
  phone that locks mid-pass — and keeps it off the screen: reported as a failure it becomes a red
  sentence under the dial saying the health data is inaccessible, which is true of every locked phone
  and names nothing anybody can act on. Nothing is lost either way; the days stay marked.
  Health delivers to a locked phone — measured on 2026-08-30 — so this is an ordinary state rather
  than a rare one, and `Services.sendNow` asks the same question before starting a pass at all.
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

There are two screens and no more: a first-run walkthrough, and one everyday screen with a single
button in the middle of it. The button is the face of a dial: it carries the number it is about — the
days still waiting, with its unit — and the scale of sixty marks around it turns that number into
progress. Underneath is one sentence, and that sentence is the answer to the only question that
matters: is it still working. Keep it that way when adding anything. A number that needs interpreting
is not a status, and a second row of counters is how the sentence stops being read.

The line under the button says how long the rest will take, measured from the days already going
rather than assumed — a decade of workouts and an empty week are not the same work, and no constant
could stand for both. Until enough days have gone to have an answer it says "sending" and no number,
because a rate computed from three days changes every second.

"Nothing waiting" is not the same fact as "nothing has ever been sent", and neither is the same as
"stopped a week ago". The screen still distinguishes all three, and that is why the device stamps
when a day was last accepted — but the stamp is not on display: nobody acts on "last sent 4 minutes
ago", and a count nobody acts on crowds out the sentence that matters. What is on display is the
silence, once the silence is itself the news, from three days on. Collapsing the three into one
cheerful row is how a silent failure gets to look healthy.

The scale measures the run in front of it, not the archive. Ten unsent days fill it exactly as three
thousand do — a scale measured against a decade of history would sit at ninety-nine per cent every
ordinary day and say nothing about whether anything is moving.

Everything sent is the good state and is drawn as one: the scale closes, and the face carries a mark
and the words "Up to date" instead of a nought. A nought is what an empty archive shows too, and the
two mean opposite things. For the same reason the scale is lit only when it has something to report
— with nothing ever sent it stays unlit, because arithmetic says that run is complete and a full
orange scale over "nothing sent yet" would announce a finished job to somebody whose archive is
empty.

Starting always begins by re-reading Health, which is why there is no separate "send now": one
button does both. Stopping holds the days back and never drops them, so a pause costs time and never
data.

**A stop stops the chain, not only the button.** Every finished batch starts the next pass from the
upload session's own delegate, so a pause honoured only where the person pressed looks like a pause
and keeps sending — which is what it did until 2026-08-29. The flag lives on the uploader, is checked
on the way into every pass and before the chain restarts itself, and setting it cancels what is
already in the air: a request the system has taken finishes on its own otherwise. A cancelled batch
fails like any other, so its days stay marked and nothing is lost. A test enforces it.

The appearance is pinned to light, because the palette is committed rather than adaptive. Half
supporting dark mode is worse than not supporting it: the system turns its own text white and leaves
it on a light background, which is a screen of invisible words. Every colour lives in `Design.swift`
as a literal, and nothing may read a system colour that changes underneath it.

The walkthrough is three steps and ends at the archive: what this is, what it reads, how far back to
go. Handing the archive to an agent is not one of them. It needs a decision about somebody else's
software, it can be done any day, and a walkthrough that ends on it leaves the phone waiting on a
step nobody has to take today. A step whose archive was never created does not walk on either — an
everyday screen with nowhere to send is a screen nobody can act on.

The everyday screen asks for the handoff instead, and keeps asking. It opens the sheet by itself once,
straight out of the walkthrough, and while the text has never gone anywhere the ask is a lit key
across the whole shell: an archive nobody can read is the state this app is least useful in. Once the
text has gone somewhere that invitation is not news, so it steps down into the row of keys along the
bottom — doing it again is a thing you may do, not a thing left undone. What counts as gone is a
share that reported completion or a copy to the clipboard, which is why the sheet shares through
`UIActivityViewController` and not `ShareLink`: `ShareLink` never reports the outcome, so a cancelled
share would count as an archive handed over.

"Start syncing" starts it, and the walkthrough then waits. Sending runs whether or not anybody is
looking, so the last screen could simply move on — but the one thing a person wants after pressing
"start" is to see that it started, so the screen shows the archive being made and then the count, and
goes no further until they say Continue. An archive that could not be made stops there too, with the
error and a way back: an everyday screen with nowhere to send is a screen nobody can act on. The
walkthrough also clears any pause before it queues the history, because a pause left over from an
earlier life of this install swallows the whole first export in silence — the days are marked,
nothing goes, and the only clue is a play symbol on a dial nobody has learnt to read yet.

On screen the setup text is called the prompt, because that is what a person does with it: they send
it to an agent — ChatGPT, Claude, Gemini — and it goes whole, as one block of text in the shape the
app composes it. Presented as three fields it invites pasting one of them, and a
part of it opens nothing: the instruction says what to do first, the address says where the archive
is, and only the key opens it.

Anything that is needed but rarely — reaching further back, Health access, disconnecting — is a
labelled key in the row along the bottom. Three keys, printed with their names: a menu hides how many
there are, and a key can be read without being pressed. Nothing may claim that Health access was
granted: Health does not say, so that screen offers where to look instead of an answer it cannot
have.

## The log

The app keeps its own account of what it did, in `Application Support/efferent/efferent.log`, and
`Log` writes every line to it as well as to the system log. Not because the system log is worse — it
is better, when a Mac is at hand. Sending happens in launches that last two seconds, hours apart,
days after anybody last opened the app; by the time the phone is plugged into anything the
interesting launch is over, and `OSLogStore` hands back only the running process. So the phone
writes it down and keeps it.

**It is written low, not in milestones.** `debug` is the step underneath every milestone — each day
built with its event count and its sealed size, each request with its method, address and size, each
answer with its bytes, each page of a listing, how long Health took to answer — because that is what
a strange sending problem is actually read from. `info` is the account a person can follow, `error`
is what went wrong. A milestone log ("send outcome: nothingToSend") names the symptom and hides
every step that produced it.

The conditions the app does not control go down at launch: version, iOS, whether background refresh
is allowed, whether low power mode is on. Each of them stops a phone from sending, and from the
inside each looks exactly like an app that had nothing to do.

**A repeated fact is counted, not repeated.** A burst of identical lines was two thirds of a launch's
log and said one thing. The single observer above removes the burst at its source; what is left is
counted rather than written out. The uploader counts the asks it turns away *and* the passes that
found nothing waiting, and reports the lot in one line at the end of the next pass that actually did
something; the pause counts its asks and reports them when sending is let go again. A step that found
nothing writes nothing at all — a week re-read with nothing new, a metric Health offered no changes
for, a round that came back empty, an archive check still inside its daily window. At rest that is
every line a launch used to write, which is why the counting matters more than the silence: without
it a quiet phone would have nothing in the log to say it had been awake. What survives is every step
that did something. Measured on real launches: 73 lines became 28, then a single observer took the
same wake-up to 14.

It is capped at half a megabyte and drops its oldest half when it fills, and it never throws: a log
that can stop the sending it exists to explain is worse than no log.

**Nothing goes in it that would matter if it were read.** Day dates, counts, sizes, HTTP codes and
error text — never a reading, never a key. The whole point of it is to be handed to somebody, so
anything that could not be is not written down.

Five taps on the name at the top of the everyday screen open it, counted within one sitting: putting
the app down starts the count again. It has no key of its own on purpose — sending is meant to be a
thing nobody has to think about, and a permanent way in would say the opposite. The screen hands the
whole log to the share sheet, which is where every way of passing it on already lives — including the
clipboard.

**The screen draws the end of it, the share sheet hands over all of it.** `LogStore.tail` returns the
last 64 KiB at a line boundary with a count of the lines it left behind. The view draws that count so
nobody reads a short excerpt as a short log. Drawing the whole file was what the cap made impossible:
half a megabyte of monospaced text in one `Text` takes long enough to lay out that the screen reads as
broken, which is exactly what happened once the columnar format let a launch clear hundreds of days.

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
