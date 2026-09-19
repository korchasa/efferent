# Design

Status, 2026-09-19: both layers are written. Every pull trigger below is in the app, a locked phone
counts what is on its way, the everyday screen says when the queue was last reached, and the service
rings the phone when it takes an edit. What has not happened yet is a wake observed end to end on a
real phone: it needs the four push secrets set on the deployed service and a build installed with
the new capability. Until then the phone runs on the floor alone, which is the state the floor was
built for.

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

## What is not verified yet

These are claims the design leans on and nobody has run.
- A wake observed end to end: agent writes, phone lights up, edit lands. Every piece is tested
  against a stand-in — the service against an APNs that lives in `server/device_test.ts`, the
  request against its own signature — and none of that is the same as a phone answering.
- How hard Apple throttles silent pushes for this traffic. The shape here is forgiving — a burst of
  edits coalesces into one fetch that drains the queue — but the budget is real and undocumented.
- Listing the queue on a locked phone. The two protection classes say it works; that is not the same
  as having seen it.
- Whether a delivery on every unlock is too much for a phone unlocked dozens of times an hour. If
  it is, the answer is a minimum interval between deliveries, not a removed trigger.

## Open decisions

- The 15-second ticker is a guess at a person's patience, not a measurement.
- Whether refusing the wake is a separate question to the person or rides on the notice permission
  they are already asked for.
