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
- **Wake** — the message the service sends the phone when an edit lands, saying only that there is
  something to look at.
- **Floor** — the triggers that fetch the queue without a wake, so that a wake never delivered
  costs time rather than the edit.
- **Pass** — the wider run delivery belongs to: edits first, then the days those edits changed.
- **Notice** — the local notification this app puts on the lock screen.
- **Strip** — the dark panel at the top of the everyday screen that counts what an agent changed.
- **Write** — one of the app's two operations against Health: a record stands there afterwards.
- **Remove** — the other: the record is out of Health afterwards.
- **Journal** — the phone's own account of every item an agent applied, and of every one the person
  has since changed. Nothing in it reaches the service.

## The agent starts the delivery

**DELIVERY-1 — An edit reaching the service wakes the phone.** The agent's write is the trigger, not
the person's attention and not Health. The phone fetches within 60 seconds wherever iOS delivers a
background wake: the app in front, in the background, suspended, or not running after the system
unloaded it. A locked phone counts as covered — it lists the queue and writes down what is waiting,
and puts the items into Health at the next unlock.

*Why.* The inbound direction rides the outbound export today, so it fires when Health has new data.
An edit produces no Health data, which is why an app left open on a still phone never learns
anything. The direction that an agent starts has to be started by the agent.

**DELIVERY-2 — The wake carries nothing.** No count, no name, no metric, no day. It says that the
phone should look, and the phone finds out the rest for itself.

**DELIVERY-3 — The phone still decides everything.** Checking the editor's signature, opening the
edit with the reading key, writing into Health and answering the service are unchanged by the wake.
A service able to make the phone write would be a service able to write into Health.

**DELIVERY-4 — The wake is never the only way in.** Apple does not promise to deliver a background
wake, and several ordinary states swallow it: the app swiped out of the switcher, background
refresh turned off, low power mode, no network at that moment, the person having refused. The floor
below carries those, and every requirement in it holds whether or not a wake was ever sent.

**DELIVERY-5 — The person may refuse the wake, and the app keeps working.** Refusing costs latency
and nothing else. The screen says which of the two the app is running on, so a slow delivery is
recognisable as a choice rather than a fault.

**DELIVERY-5a — A wake ends inside the time it was given, and says so.** iOS allows 30 seconds of
wall-clock time from the wake arriving to the app reporting what came of it, and terminates an app
that has not reported. The app therefore carries its own budget well inside the 30 and reports
exactly once however the work ends — finished, out of budget, or the system taking the time back.
Cutting the *report* short costs nothing: the edit stays in the queue and the floor finds it.

**DELIVERY-5b — A run in flight asks not to be suspended, whoever started it.** Every trigger in
DELIVERY-9 starts the same work, and any of them can be the one running when a wake arrives. So the
request belongs to the run, not to the trigger: a delivery or a send pass asks for the time when it
starts and gives it back when it ends, and a caller that stops waiting leaves the run to finish
under its own protection.

*Why.* Kept neither promise, this fails in the shape that is hardest to notice. On 2026-09-19 a wake
arrived, the app began fetching the edit, the system suspended it, and the fetch stayed frozen for
224 901 ms. Nothing reported, and the system then stopped delivering wakes to the app: the next push
was accepted by Apple and never ran. The app looked healthy throughout. Asking around the wake
handler's own call was not enough, and the same evening proved it: an unlock had already started the
work, the handler's request to fetch was turned away in a moment, the handler reported and gave the
time back, and the run the unlock had started was frozen for another 97 794 ms.

**DELIVERY-5c — The service rings no more often than Apple allows.** Two or three an hour, which is
Apple's own number for a background wake; past it the app is throttled, and what is lost is the
wakes that matter rather than the ones over the line. The service counts per archive and spends its
allowance on the earliest edits of the hour, because one wake drains the whole queue.

**DELIVERY-6 — Disconnecting forgets the wake.** The phone deletes its registration at the service
in the same act that forgets its keys. An archive nobody can write to must not leave a way to ring
that phone.

## The floor

**DELIVERY-7 — An open app fetches on its own.** While the everyday screen is in front of the
person, an edit shows on the strip within 20 seconds of the service accepting it, with no wake, no
movement of the phone and nothing new in Health.

**DELIVERY-8 — Coming to the front fetches the queue.** An explicit trigger, not a side effect of
Health having queued a delivery while the app was away.

**DELIVERY-9 — Every launch that is awake anyway fetches the queue.** A Health delivery, the
catch-up task, a relaunch to finish transfers, and the return of protected data after an unlock all
end in a delivery. An awake process that does not ask makes the person wait a whole cycle.

**DELIVERY-10 — A fetch from an open app costs one listing request.** It does not read Health and
does not send days.

## What a delivery must do

**DELIVERY-11 — Two deliveries never overlap.** A trigger arriving while a delivery is running is
dropped, not queued.

**DELIVERY-12 — A locked phone counts what is waiting.** The queue is listed and the count written
down; nothing goes into Health until the phone is unlocked. Keys are stored `AfterFirstUnlock` and
the day database is `completeUntilFirstUserAuthentication`, so a locked phone has no excuse to know
nothing.

**DELIVERY-13 — A pause holds edits back, and says so.** Sending held back by the person holds edits
as it holds days, and the screen names that as the reason.

**DELIVERY-14 — An unanswered Health question stops delivery loudly.** Until the person has answered
the system's question about writing to Health, the queue is not read at all. The screen says what is
missing and offers the question rather than showing an empty strip.

**DELIVERY-15 — An edit is answered once and taken out of the queue.** A run cut short leaves its
unanswered edits where they were; the next run applies them again, which the sync identifier and the
climbing version make safe.

## What the service may learn

**PRIVACY-1 — The wake adds one line to what the service knows, and that line is written down.**
The service gains the ability to ring this phone, and a record of when it did. `README.md` lists
everything the service learns and promises to name each addition outright; the privacy copy of the
listing says the same. An addition that is not in both is not shipped.

**PRIVACY-2 — The registration is proved like every other write.** The phone registers the way to
reach it with its own device key, over the same signed request the editor key is registered with,
and the service keeps it under the bucket. Replacing it is one more registration; removing it is
DELIVERY-6.

**PRIVACY-3 — Nothing about the edit leaves the archive.** The wake is the only new traffic, and it
says nothing about what was sent, by whom, about which day, or about what the phone did with it.

## Notices

**NOTICE-1 — A notice carries counts and the two verbs, and nothing else.** Never a metric, never a
value, never a day. It says how many records were written and how many were removed, because those
are the app's two operations and a person who reads "changed" cannot tell which happened; a run that
did both says both. It is read on a lock screen by whoever is holding the phone.

**NOTICE-2 — The phone writes every notice.** The service never composes text that reaches a lock
screen: it knows a sealed edit arrived and nothing else, and a sentence about the person's health
written by something that cannot read it would be a guess.

**NOTICE-3 — One notice at a time.** A newer one replaces the one before it. A column of
near-identical lines teaches a person to swipe without reading.

**NOTICE-4 — Permission is asked before the first edit can arrive.** The walkthrough asks, and
connecting an agent asks again if the walkthrough was walked past. Asking after the first edit has
landed means the first edit never produces a notice, which is exactly the one the person wanted.

**NOTICE-5 — Only a change to Health is announced.** An edit that arrived and is waiting for an
unlock shows on the strip and produces no notice: unlocking applies it, and that run's notice says
so.

**NOTICE-6 — The strip follows the journal within 2 seconds.** What an agent changed appears on the
open screen without the person leaving it and coming back.

**NOTICE-7 — A delivery that stopped is visible on the screen.** What stopped it is said in one
sentence where the person can see it, not only in the log.

## What the journal says

**WORD-1 — The app has two operations against Health and no more.** A record is written, or it is
removed. Every screen, the journal, the notice and the key a person presses name the operation by
one of those two words, and no layer invents a third.

**WORD-2 — An operation is named the same whoever performed it.** The person taking a record out is
the same thing happening to Health as the agent taking it out, so both are a removal. Undo is not an
operation of its own; it is the person performing one of the two.

**WORD-3 — What happened to the record and who asked are separate facts.** One field says which of
the two operations the row ended on, another says whether the agent or the person asked for it. A
row that carried both in one word could answer neither question: taking back an addition removes a
record, while taking back a removal writes one.

**WORD-4 — A key says the operation the press performs.** Reversing an addition removes the record
and the key says so; reversing a removal writes the record back and the key says that instead. One
word for both would hide which of the two is about to happen.

## What the app must be able to say about itself

**STATE-1 — The screen says when the queue was last checked.** Silence has two causes — nobody sent
anything, and nobody looked — and from the outside they are identical. One of them is a fault.

**STATE-2 — The screen names whatever is holding delivery back.** Paused sending, an unanswered
Health question, no archive yet, a refused wake, and background refresh turned off in the system
settings each stop an edit from arriving, and each looks from the inside like an agent that sent
nothing.

**STATE-3 — An app that was force-quit is recognisable.** iOS stops waking an app the person swiped
away, and never says so. A last-checked time that has stopped moving is what makes that visible;
STATE-1 is how it is shown.
