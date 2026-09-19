# Requirements

## Scope

This document says what the app must do. It is written one subsystem at a time, as each is worked
through; today it covers one of them — how an edit an agent asked for reaches the phone, and how the
person learns that it did. The rest of the app is described in `README.md` and governed by
`AGENTS.md`. A subsystem missing from this document has not been written down yet; that is not a
claim that it has no requirements.

Every requirement carries an identifier so a task, a commit or a design note can point at it. A
requirement says what must be true. How it is arranged is [`design.md`](design.md).

## Vocabulary

- **Edit** — one request an agent left in the archive's `e/` queue, signed with the editor key and
  sealed to the phone's reading key.
- **Delivery** — one run that lists the queue, writes into Health what it can, and answers the
  service for each edit it took.
- **Pass** — the wider run delivery belongs to: edits first, then the days those edits changed.
- **Notice** — the local notification this app puts on the lock screen.
- **Strip** — the dark panel at the top of the everyday screen that counts what an agent changed.

## Delivery

**DELIVERY-1 — An open app learns about an edit by itself.** While the everyday screen is in front
of the person, the phone fetches the queue on its own, and an edit shows on the strip within 20
seconds of the service accepting it. Nothing about it depends on the phone moving, on the person
touching the screen, or on Health having anything new to say.

*Why.* This is the defect the subsystem was written down for. Fetching is glued to Health's
new-data signal, so an app left open on a still phone never learns anything, while switching away
and back appears to work — the resume is what makes Health deliver.

**DELIVERY-2 — Coming to the front fetches the queue.** The transition to active is a trigger of its
own, not a side effect of Health having queued a delivery while the app was away.

**DELIVERY-3 — Every launch that is awake anyway fetches the queue.** A Health delivery, the
catch-up task, a relaunch to finish transfers, and the return of protected data after an unlock all
end in a delivery. An awake process that does not ask is a fetch the person waits a whole cycle for.

**DELIVERY-4 — No single trigger is load-bearing.** The system decides when it wakes this app, and
several of the triggers can stay silent for hours. The requirements above must hold together, not
one at a time.

**DELIVERY-5 — A fetch from an open app costs one listing request.** It does not read Health and
does not send days. Reading Health every few seconds because somebody left the screen open is a
different feature, and not one anybody asked for.

**DELIVERY-6 — Two deliveries never overlap.** A trigger arriving while a delivery is running is
dropped, not queued.

**DELIVERY-7 — A locked phone counts what is waiting.** The queue is listed and the count written
down; nothing is written into Health until the phone is unlocked. The keys and the day database are
both reachable after the first unlock, so a locked phone has no excuse to know nothing.

**DELIVERY-8 — A pause holds edits back, and says so.** Sending held back by the person holds edits
as it holds days. The screen names that as the reason, so held-back edits never read as an app that
stopped working.

**DELIVERY-9 — An unanswered Health question stops delivery loudly.** Until the person has answered
the system's question about writing to Health, the queue is not read at all. The screen says what is
missing and offers the question, rather than showing an empty strip.

**DELIVERY-10 — An edit is answered once and taken out of the queue.** A run cut short leaves its
unanswered edits where they were; the next run applies them again, which the sync identifier and the
climbing version make safe.

## Notices

**NOTICE-1 — A notice carries a count and nothing else.** Never a metric, never a value, never a
day. It is read on a lock screen by whoever is holding the phone.

**NOTICE-2 — One notice at a time.** A newer one replaces the one before it. A column of
near-identical lines teaches a person to swipe without reading.

**NOTICE-3 — Permission is asked before the first edit can arrive.** The walkthrough asks, and
connecting an agent asks again if the walkthrough was walked past. Asking after the first edit has
landed means the first edit never produces a notice, which is exactly the one the person would have
wanted.

**NOTICE-4 — Only a change to Health is announced.** An edit that arrived and is waiting for an
unlock shows on the strip and produces no notice: unlocking the phone applies it anyway, and the
notice for that run will say so.

**NOTICE-5 — The strip follows the journal within 2 seconds.** What an agent changed appears on the
open screen without the person leaving it and coming back.

**NOTICE-6 — A delivery that stopped is visible on the screen.** What stopped it is said in one
sentence where the person can see it, not only in the log.

## What the app must be able to say about itself

**STATE-1 — The screen says when the queue was last checked.** Silence has two causes — nobody sent
anything, and nobody looked — and from the outside they are identical. One of them is a fault.

**STATE-2 — The screen names whatever is holding delivery back.** Paused sending, an unanswered
Health question, no archive yet, and background refresh turned off in the system settings each stop
an edit from arriving, and each looks from the inside like an agent that sent nothing.

**STATE-3 — An app that was force-quit is recognisable.** iOS stops waking an app the person swiped
away, and never says so. A last-checked time that has stopped moving is what makes that visible;
STATE-1 is how it is shown.
