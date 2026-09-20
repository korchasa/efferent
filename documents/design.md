# Design

Status, 2026-09-19 (evening): the wake was watched end to end and it works, and watching it found
the same defect twice, each time in a different place. An agent's edit reached the service at
20:57:20 and the locked phone asked for the queue at 20:57:23, after a hundred seconds of silence;
it read the queue, wrote nothing, and said in its own log that Health was sealed. What it could not
do was finish: the app was suspended a moment later, the fetch froze for 224 901 ms, the thirty
seconds a wake is allowed went by unanswered, and the system stopped delivering wakes to this app
altogether — the next push was accepted by Apple and never ran. A second wake at 22:18 was frozen
the same way for 97 794 ms although the first fix was in, because the run that was frozen had been
started by an unlock rather than by the wake. Once the promise was moved onto the run itself, both
shapes were watched again and both finished: an unlock-started pass read seven days out of Health in
282 ms where the frozen one had taken 97 794, and a wake on a live phone applied an edit 3 seconds
after the agent wrote it. See "What a wake is allowed" below.

## Scope

How the app is arranged to meet [`requirements.md`](requirements.md). Written one subsystem at a
time; today it covers the delivery of an agent's edits and the notices about them. Everything above
this — what the app collects, the wire format, who can read the archive — is `README.md`, and the
boundary with the service is [`connection.md`](connection.md).

## The archive has two directions, and they are started by different things

Outbound is the app's original job: Health gets new data, the phone owes a day, the day goes up. Its
trigger belongs to Health, and that is right — Health is what changed.

Inbound is an agent asking the phone to write something. Its trigger belongs to the agent, because
the agent is what changed. Today it has no trigger of its own: `applyEdits()` sits at the head of
`sendNow()`, so the inbound direction rides the outbound one and fires when Health has something to
say. An edit produces nothing in Health, so the inbound direction fires by coincidence — most
visibly, an app left open on a still phone never fetches, while switching away and back appears to
work, because the resume is what makes Health hand over what accumulated.

The whole design follows from putting that back the right way round: **the agent's write wakes the
phone, and everything else is a floor under that wake.**

## Three layers, and each has a different job

- **The wake is the trigger.** The service takes an edit and rings the phone. This is what makes
  delivery work in the ordinary case, including with the app closed.
- **The floor is the guarantee.** A set of enumerated pull triggers that fetch without a wake.
  Apple does not promise to deliver a background wake, and several ordinary states swallow one, so
  the floor is what turns a lost wake into lost time instead of a lost edit.
- **The queue is the recovery.** An edit stays in `e/` until the phone answers it. Nothing a missed
  wake or an interrupted run can do loses an edit; the worst case is that it is applied later, and
  applying it twice is safe because a sample carries the agent's sync identifier and a version that
  only climbs.

Reading them as alternatives is the mistake this document exists to prevent. Push without the floor
is a channel whose delivery nobody promises; the floor without push is what the app has today.

## The states the app can be in

**Process states, and what reaches each.**

- *Never launched since installation.* No observer, no catch-up task, no registration with the
  service — all of them happen on first launch. Nothing reaches it, and nothing can.
- *Swiped away by the person.* iOS delivers no background wake and runs no background task until the
  next launch by hand. Neither layer reaches it. STATE-3 is how the person finds out.
- *Unloaded by the system.* A wake starts the process in the background; so do a Health delivery and
  the catch-up task.
- *Suspended in the background.* A wake resumes it. Health deliveries queued meanwhile arrive too.
- *Running in the background with no screen.* Four ways in: a wake, a Health delivery, the catch-up
  task, and a relaunch to finish transfers started earlier. All four end in a delivery.
- *In front but not active* — app switcher, notification shade, an incoming call, a system sheet. A
  wake still arrives; the screen's own ticker does not run.
- *In front and active.* The wake arrives, and the ticker fetches every 15 seconds regardless.

**Conditions that stop a run whatever the process is doing.**

- *The phone is locked.* Health is sealed. The queue is still listed and counted — keys are
  `AfterFirstUnlock`, the day database is `completeUntilFirstUserAuthentication` — and the items go
  in at the next unlock, which is itself a trigger.
- *Sending is paused.* One guard at the head of the pass holds days and edits alike.
- *No archive, or no reading key.* There is nothing to fetch from and nothing to open with.
- *Writing to Health has never been answered.* The run returns `.notAsked` without reading the
  queue; only a launch with a screen can put that question.
- *Background refresh off, low power mode, or no network.* The wake and the catch-up task both stop.
  The ticker and the foreground triggers still work, which is why the floor is not optional.

## How the wake is arranged

**The phone registers where it can be reached.** One more signed registration beside the editor key:
`PUT /<bucket>/device`, signed by the **writer** key over `efferent/v1 device` — the same canonical
shape every other write uses — carrying `{token, topic}` as JSON. The writer key and not the editor
key, because this is the owner's decision: an agent may put edits in the queue and may not choose
what gets woken. The service keeps it at `<bucket>/device`, checks the topic against its own
`APP_ID` list, and refuses a token that is not hex, because that string goes straight into a URL.

The phone asks Apple on **every** launch with an archive (`registerForWake`), since a restore, a
reinstall or a new phone each produce a different token and asking is the only way to find out. It
sends the registration only when the pair is news — `wake.registeredAs` in `meta` holds
`<bucket>:<token>` — so an ordinary launch costs nothing. Disconnecting sends
`DELETE /<bucket>/device` **before** the keys that could sign it are forgotten, then unregisters
with Apple. A token Apple has retired answers 410, and the service deletes it rather than pushing at
it forever.

**The service rings the phone when it takes an edit.** `postEdit` in `server/src/index.ts` stores
the sealed edit, then calls `wakeThePhone`, which hands the work to `ctx.waitUntil` — outside the
response path, so an agent's write never waits on Apple and never fails because Apple did.
`server/src/apns.ts` signs an ES256 provider token with the `.p8` and keeps it for the life of the
isolate: Apple refuses a token over an hour old and one made seconds ago just as readily, so a token
per push is both slower and worse. A service without the four secrets (`APNS_KEY`, `APNS_KEY_ID`,
`APNS_TEAM_ID`, `APNS_HOST`) wakes nothing and says nothing — that is the state before deployment,
and it is not an error.

`APNS_HOST` is named rather than derived. A key belongs to one environment, and a push sent to the
other answers `BadDeviceToken`, which reads like a phone that has moved on. The key this factory
holds is a sandbox one, so the app's `aps-environment` is `development`; a store build needs both
changed together.

**What a wake is allowed.** Thirty seconds of wall-clock time to do the work and say what came of
it, and an app that has not answered by then is terminated. Two separate promises follow from that,
and the app was keeping neither.

The second one is the easy one: the system is answered inside the thirty seconds whatever the work
is doing, so the woken work carries its own budget of twenty and `WakeAnswer` in
`src/App/Sources/EfferentApp.swift` makes sure exactly one of the three endings — finished, out of
budget, system reclaiming the time — reports a result.

The first is that the system must not suspend the app while the work is in flight, and the mistake
worth writing down is *where* that is asked for. Asking around the wake handler's own call looks
right and is not: four different things start the same work, and when one of them is already running
the applier turns the next one away in a moment. That is what happened on 2026-09-19 — an unlock had
started a pass, the wake's request to fetch was refused, the handler reported and handed the promise
straight back, and the pass the unlock had started ran on unprotected and was frozen for 97 794 ms.
So the request belongs to the run: `withTimeToFinish` in `src/App/Sources/BorrowedTime.swift` wraps
`deliverEdits()` and `sendNow()`, asks before the work starts (the request is itself asynchronous,
and one made late loses the race it was meant to win), and gives it back exactly once — including
when the system takes it back early, which also cancels the run. The work runs in a task of its own,
so the wake handler giving up on waiting does not cut the run short: it answers the system and
leaves the run to finish under its own protection.

Underneath both sits a limit that was missing everywhere, not only on a wake: a network request was
bounded only by how long it could go without receiving data, and a suspended app receives nothing
while also waiting for nothing, so that limit never fires. `timeoutIntervalForResource` counts from
the start of the request and stops for nothing; both sessions now set it. The same twenty-second
limit is what eventually ended the frozen fetch above — after 224 901 ms.

**How often a wake may be sent.** Apple asks for no more than two or three an hour and throttles an
app that sends more, which costs the wakes that matter rather than the ones over the line. So the
service keeps a count per bucket in `<bucket>/wakes` and spends three on the first three edits of an
hour. That is the right way round for this shape of traffic: one wake drains the whole queue, so the
second edit of a burst is usually fetched by the wake the first one bought. The count is
deliberately approximate — two edits arriving together can both read it and both ring — because a
conditional write and a retry on every edit costs more than being one over.

**The wake is silent and empty.** A background push — `content-available`, no alert, no body, no
count. The phone wakes, runs the same delivery every other trigger runs, and puts up its own notice
from what it actually wrote. An alert push would be more reliable, because Apple throttles silent
ones; it would also mean the service composing a sentence about the person's health that it cannot
read, which NOTICE-2 forbids. Reliability is bought from the floor instead.

**What this adds to what the service learns.** One line, and it goes in `README.md` and in the
store listing's privacy copy: the service can ring this phone, and it knows when it did. Nothing
about the edit, the day, the metric or the outcome travels with it. That is the price of the
inbound direction working while the app is closed, and it is named rather than glossed over.

## How the floor is arranged

**One entry point for delivery, separate from sending.** `deliverEdits()` does what `applyEdits()`
does and is callable on its own, without reading Health and without sending days. `sendNow()` keeps
calling it first, so a full pass is unchanged. Every trigger below calls the entry point, and
serialisation stays in `Applier.claimPass()` — that is DELIVERY-11 for all of them at once.

**A ticker while the screen is in front.** The everyday screen's `.task` loop gains a second
cadence: local statistics every 2 seconds as now, a delivery every 15 seconds. Cancelled with the
view, so a backgrounded app costs nothing. 15 against the ceiling of 20 leaves room for the listing.

**The scene's own trigger.** The `scenePhase` handler that already asks about Health writing and
notices also delivers.

**Every awake launch asks.** The relaunch that finishes background transfers, and
`protectedDataDidBecomeAvailable` after an unlock, both end in a delivery. The first is a process
already running with a network; the second is the moment Health stops being sealed, which is exactly
when waiting edits can be written.

**A locked phone counts instead of stopping.** The guard on protected data moves off the delivery
and onto the Health write inside it: the queue is listed, what is waiting is written to the journal,
and the items go in at the unlock.

**A record of the last look.** Every delivery writes down when it finished and what stopped it if
something did. The everyday screen reads that: a last-checked time, and the condition holding
delivery back when there is one — including which layer the app is running on, since a person who
refused the wake should see slow delivery as their own choice.

One line carries all of it, under the dial, because it is one question to the person looking: is
anything coming, and if not, why. `EditWords.delivery` writes it and nothing else does. The order is
the design: a pause first, because it is why there was no look at all and it is a decision rather
than a fault; then an unanswered Health question, because it stops the queue being read and a bare
"not checked yet" would send the person hunting for a fault in their agent; then what stopped the
last run; then what the phone's own settings have taken away; then, when nothing has, when that run
happened. Only the two that are wrong — the unanswered question and a run that failed — are drawn in
the alarm colour. A locked phone is neither wrong nor finished: the queue was read, and the line says
how many items go in at the next unlock. Before this, a delivery that stopped left its only trace in
the log, which is a place nobody looks.

**The two layers the phone can take away.** `EditWords.Reach` is how far an edit gets without
somebody opening the app, and `Services.reach` is the phone's answer. `nothingInTheBackground` is
background app refresh switched off or restricted in the system settings, which removes the catch-up
task and silent wakes together; `noWake` is Apple refusing to say how to reach this phone, or the
archive never being told the token it gave. Both are read from the everyday screen's own two-second
ticker as well as at launch, because a person changes them while this app is not running. Neither is
raised in the alarm colour: they are settings outside the app, nothing is broken, and an edit still
arrives — later. They sit below what stopped the last run, which is about this moment, and above the
last-checked time, which is about to stop moving for exactly this reason: a still clock with no cause
beside it is what STATE-2 exists to prevent.

A refusal is written down and a silence never is. Registration is asked for on every launch and Apple
answers on its own time, so `wakeRefused` is set only when something failed — a phone that has simply
not been answered yet must not be called refused.

The fifth condition STATE-2 names, an archive that was never made, cannot reach this line: `finishSetup`
refuses without a destination and `disconnect` takes `setupComplete` away again, so a phone with
nowhere to send is on the walkthrough and not on the everyday screen at all.

**The notice question moves earlier.** Connecting an agent asks about notices. Today the question
waits until an agent has already written something, which guarantees the first edit is silent.

## What the Worker reaching APNs cost to prove

A Worker running on Cloudflare's edge reaches `api.push.apple.com`. Proved on 2026-09-19 without any
key at all: an unsigned POST to `/3/device/<64 zeroes>` was answered `403 MissingProviderToken` in
728 ms, with an `apns-id` header. An answer of that shape can only come from APNs itself, so HTTP/2,
TLS and the route all work and the provider token is the only thing missing. The probe was a
throwaway script run through `wrangler dev --remote`, which uploads to the edge and keeps no
published address behind it.

One trap came with it: the factory's Cloudflare API token cannot open a remote preview session — the
account call for `subdomain/edge-preview` answers "No access to the specified resource", which reads
like the script being wrong rather than the token being narrow. Wrangler's own OAuth session opens
it, so the probe runs with `CLOUDFLARE_API_TOKEN` unset.

## The journal: what happened, and who asked

The journal (`editLog`) is the only copy of what an agent ever did — the service is told counts and
codes on purpose — so how a row is written down decides what can still be answered years later.
Until build 21 one column held two different facts at once. `applied` and `deleted` said what the
**agent** did; `undone` said what the **person** did and hid what had actually happened to the
record, because taking back an addition removes it while taking back a removal or a replacement
writes one. A reader could answer neither question.

Since v8 the row carries two fields, and WORD-1 to WORD-4 are what they exist for.

- `state` — what the record is: `written`, `removed`, `failed`, plus `waiting` and `declined`,
  which no build produces any more and which are kept because a decision an older build recorded is
  never reopened.
- `askedBy` — `agent` or `person`. A row begins as the agent's and becomes the person's the moment
  they change it; there is no third party and no third state.

So the four cases read in one verb set: the agent wrote, the agent removed, the person removed what
the agent wrote, the person wrote back what the agent removed. `EditWords` is where that becomes
screen text, `Notices` says the same two verbs on the lock screen, and the key on a row is named for
the operation the press performs rather than for the fact that it reverses something.

**The migration reads each old row off its own evidence, and guesses at nothing.** `applied` and
`deleted` map straight across, `refused`, `waiting` and `declined` keep their meaning, and an `undone` row
becomes the person's with the operation worked out from the item: no metric means the item was a
removal, so the person wrote a record back; a metric with nothing displaced means a plain addition,
so they removed one; a metric with something displaced means a replacement, so they wrote the
displaced record back. `undoneAt` is renamed `personActedAt` in the same step, because it never meant
"undone" — it meant when the person acted. `EditLogTests` builds a database at v7 holding a row of
every old state and asserts the whole mapping: this is the one migration where a mistake costs
history rather than a redraw.

**v9 renames the third word.** An item that never happened was called `refused`, which reads as a
decision somebody made; nine of the eleven codes for why are not a decision at all. It is now
`failed`, which is what the service has always called an edit holding one of them, so the two levels
finally agree. The rename runs the whole way down — `EditEntry.State.failed`, `WriteFailed`,
`Outcome.failed` on the wire, `failed` in the JSON the phone sends and in the listing the agent
reads — and the word `refused` is left only where somebody really did refuse: the service turning a
request away, Apple turning an attestation down, the system turning down a wake, and the code
`healthRefused`. The service reads the old metadata key as well as the new one, because an outcome
stored before the rename is a real answer and reading it as zero would call a failed edit applied.

**The rows are written per item and read per record.** The key has to stay `(editName, item)`:
an edit applied twice must land on the row the first attempt made. Health, though, keeps one record
per id, and a second `put` under an id replaces the sample rather than adding one — which is how an
agent corrects a record it wrote before. So two rows can describe one record, and a screen that drew
both put a key on each: the earlier one removed the later one's record, and the later one offered to
write the earlier one's value back. The owner met that on 2026-09-20 as a record they could not
remove. `Store.recordHistories` gathers the rows by id and hands out a `RecordHistory` — every item
that named the record, newest first, with `current` the one that speaks for it. The list draws one
line per record, the line's key follows what stands in Health (`EditEntry.personRestores`: only a
record that is out is written back), and the earlier items are read on the record's own page under
"before this". Going back to a value an earlier item held is not offered as a key at all: it is a
value the agent chose and the person never saw. WORD-6.

## Walking the screens before a release

Every screen past setup needs an archive, claiming an archive needs App Attest, and App Attest
refuses a simulator — so a walk on a simulator used to stop at "Creating your archive" and the rest
of the app could not be looked at in either appearance or at an accessibility text size. `--demo`
hands the running app the same made-up figures the store screenshots are rendered from, one step
further along: an agent connected and a day and a half of its work behind it, so the strip, the list
of what an agent changed and the screen for one change are reachable. Nothing real is touched — an
in-memory store, no Health, no Keychain, no network, no Apple — and the launch says so in its own
log. It sits beside `--snapshot`, which the release binary already carries.

Made-up figures are enough for a walk over the layout and nothing like enough for the path this app
exists to run: read Health, seal a day, send it, hear what the archive says. Two more flags open that
path on a simulator, against a service running on the same machine. `--service <url>` moves both
addresses this run uses — where days are sent and where an agent is told to read — because a handoff
that named the live service while the days went somewhere else would hand an agent an archive
holding none of them. `--pretend-attested` stands in for Apple: `Rehearsal.attester` hands back a
`PretendedAttester` whose bytes are only the shape a claim travels in. Both live in
`src/App/Sources/Rehearsal.swift` and both are compiled out of a release binary — `#if DEBUG` makes
`isPretending` a compile-time `false`, so there is nothing in a shipped build to switch on.

The service has to agree, and only a copy on this machine will. `deno task server:dev:simulator`
runs `wrangler dev` with `UNATTESTED_CLAIMS=yes`, and `attestedClaim` takes an unattested claim only
when that variable is set *and* the request arrived at a loopback address. The live service refuses
such a claim however its variables end up, because a Worker with a route answers at its hostname and
never at loopback. The task also passes `--local-upstream localhost`: without it wrangler rewrites
every local request to the production hostname from `routes`, the address half of the check is never
true, and the claim is refused with "this service cannot check attestations" — which reads like a
missing secret rather than a rewritten address.

Walked end to end on 2026-09-20 against a simulator seeded with 90 days of Health: the claim was
taken (201), 91 days were built, sealed and accepted, and `efferent status` on this machine answered
"91 days, 0.1 MiB, 2026-06-22 … 2026-09-20" from that same archive.

Two things the walk on 2026-09-19 settled. The palette is pinned to light at the root
(`RootView.preferredColorScheme(.light)`), and that pin holds everywhere it was checked, including
sheets and the system alert — so dark mode is not half-supported, it is not used. And the app's own
text does not follow the system text size: every size is a fixed `.system(size:)`, so at
accessibility-extra-large only the sheet titles and the chevrons grow. Nothing clips or overlaps,
but a person who enlarges text sees no change in the app's own words.

## What is not verified yet

These are claims the design leans on and nobody has run.
- How it behaves over days rather than over an evening. Every shape of the run was watched on
  2026-09-19 and each finished on its own, but all of it was watched inside two hours on one phone
  with a development signature.
- How hard Apple throttles in practice. Three an hour is Apple's own number and the service now
  holds to it, but the throttle that was actually seen was the other kind: an app that failed to
  answer one wake stopped being given the next.
- Whether a delivery on every unlock is too much for a phone unlocked dozens of times an hour. If
  it is, the answer is a minimum interval between deliveries, not a removed trigger.
- What an unlock is worth at all. The notice that Health can be written to again reaches an app that
  is already running, and on 2026-09-19 a phone unlocked at about 20:58 delivered it at 21:00:22 —
  when something else had launched the app. So it is a trigger for a running app and not a way in.

**A swipe acts, a key asks.** The two are the same operation, and they are deliberately reached
differently: a swipe in the list is a gesture aimed at one row, while the key at the foot of a
record's own page is the end of reading about it. Only the page asks first. Decided by the owner on
2026-09-20, after the verbs were settled.

## Open decisions

- The 15-second ticker is a guess at a person's patience, not a measurement.
- Whether refusing the wake is a separate question to the person or rides on the notice permission
  they are already asked for.
