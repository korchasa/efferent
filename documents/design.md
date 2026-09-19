# Design

## Scope

How the app is arranged to meet [`requirements.md`](requirements.md). Written one subsystem at a
time; today it covers the delivery of an agent's edits and the notices about them. Everything above
this — what the app collects, the wire format, who can read the archive — is `README.md`, and the
boundary with the service is [`connection.md`](connection.md).

## Two chains, and only one of them is visible

An agent's edit reaches the person over two chains, and they are often confused for each other.

- **Delivery** puts the edit into Health. `Services.applyEdits()` calls `Applier.run()`, which lists
  the archive's `e/` prefix, checks each edit's signature, opens it with the reading key, writes its
  items, marks the days that changed, and answers the service.
- **Telling** puts it in front of the person. `Notices.tell` writes one local notification, and the
  strip on the everyday screen counts unseen rows of the edit journal.

Telling depends entirely on delivery: until a delivery has happened, the journal is empty and there
is nothing to say. Every complaint that starts "the app did not tell me" is a delivery question
first.

## The states the app can be in

**Process states.**

- *Never launched since installation.* The Health observer is not registered and the catch-up task
  is not asked for — both happen in `didFinishLaunchingWithOptions`. Nothing arrives.
- *Swiped away by the person.* iOS stops waking the app with Health deliveries and stops running its
  background task until the next launch by hand. Nothing arrives, and the app is not told.
- *Unloaded by the system.* A Health delivery or the catch-up task starts the process again in the
  background, and it behaves like any background launch.
- *Suspended in the background.* Health deliveries queue; resuming the process runs the handler.
- *Running in the background with no screen.* Three ways in: a Health delivery, the catch-up
  `BGProcessingTask`, and a relaunch to finish transfers started earlier.
- *In front but not active* — app switcher, notification shade, an incoming call, a system sheet.
  No trigger of its own.
- *In front and active.* The everyday screen runs a 2-second loop, which reads the local database
  and nothing else.

**Conditions that stop a run whatever the process is doing.**

- *The phone is locked.* Health is sealed, so a pass returns before it starts. Keys are stored
  `AfterFirstUnlock` and the day database is `completeUntilFirstUserAuthentication`, so both are
  reachable — the lock stops writing to Health, not reading the queue.
- *Sending is paused.* One guard at the head of `sendNow` holds days and edits alike.
- *No archive, or no reading key.* `applierIfPaired()` returns nothing and the run ends silently.
- *Writing to Health has never been answered.* `Applier.run()` returns `.notAsked` without reading
  the queue. The system's question can only be put by a launch with a screen.
- *Background refresh off, or low power mode.* The catch-up task does not run. The app writes this
  to the log at launch and shows nothing.

## How it works today

`applyEdits()` runs at the head of `sendNow()`, and `sendNow()` has five callers: Health's new-data
observer, the catch-up task, releasing a pause, undoing an edit, and queueing history. Four of those
are the person's own doing. The fifth — the Health observer — is the only one that fires by itself,
and it fires when Health has new data, which an agent's edit never produces.

That is why the app looks as it does from outside: switching into the app appears to fetch edits,
because the resume is what makes Health hand over what accumulated while the screen was elsewhere.
An app left open on a still phone gets no Health delivery, so it fetches nothing. The 2-second loop
on the screen keeps redrawing the same numbers, which makes the app look alive while nothing is
being asked.

## How it is arranged instead

**One entry point for delivery, separate from sending.** `deliverEdits()` does what `applyEdits()`
does and is callable on its own, without reading Health and without sending days. `sendNow()` keeps
calling it first, so a full pass is unchanged. Everything below calls the new entry point.
Serialisation stays where it already is, in `Applier.claimPass()` — that is DELIVERY-6 for every
caller at once.

**A ticker while the screen is in front.** The everyday screen's existing `.task` loop gains a
second cadence: the local statistics every 2 seconds as now, and a delivery every 15 seconds. It is
cancelled with the view, so an app in the background costs nothing. 15 seconds against the
requirement's ceiling of 20 leaves room for the listing itself. This is DELIVERY-1.

**The scene's own trigger.** The `scenePhase` handler that already asks about Health writing and
notices also calls the delivery. This is DELIVERY-2, and it turns today's accidental behaviour into
a stated one.

**Every awake launch asks.** The relaunch that finishes background transfers, and
`protectedDataDidBecomeAvailable` after an unlock, both end in a delivery. The first one is a
process that is already running with a network; the second is the moment Health stops being sealed,
which is exactly when waiting edits can finally be written. This is DELIVERY-3.

**A locked phone counts instead of stopping.** The guard on protected data moves off delivery and
onto the Health write inside it: the queue is listed, the count is written to the journal as
waiting, and the items are written when the phone is next unlocked. This is DELIVERY-7, and it is
what makes NOTICE-4 sayable — the strip can show "waiting" where today it shows nothing at all.

**A record of the last look.** Each delivery writes down when it last finished, and what stopped it
if something did. The everyday screen reads that: a last-checked time, and the condition holding
delivery back when there is one. This is STATE-1, STATE-2 and STATE-3 — a person who swiped the app
away sees a last-checked time from yesterday instead of an app that looks fine and does nothing.

**The notice question moves earlier.** Connecting an agent asks about notices; today the question
waits until an agent has already written something, which guarantees the first edit is silent. This
is NOTICE-3.

## Why not a push notification

A push from the service would remove the polling and would reach a phone with the app closed. It is
the right end state and the wrong next step: it needs an APNs key, device tokens kept by the
service, a new background launch mode and a line in the privacy description, and it moves knowledge
of "an edit is waiting for this phone" into the service, which today knows nothing about the phone's
schedule. The design above closes the hole the person actually meets — an open app that ignores an
edit — with one listing request every 15 seconds while somebody is looking at the screen. Push stays
on the table as its own piece of work.

## Open decisions

- The 15-second cadence is a guess at a human's patience, not a measurement.
- Listing the queue on a locked phone has not been run on a device yet; the two protection classes
  say it should work, and that is not the same as having seen it.
- A delivery on every unlock will fire on phones that unlock dozens of times an hour. If that turns
  out to be too much, the floor is a minimum interval between deliveries, not a removed trigger.
