# A journal row whose record is already gone, and the only key on it always fails

Opened 2026-09-20 on the owner's instruction, after they reported a water record
dated 20 September 15:53 in the app's own history that cannot be removed. Every
attempt answers the same way and the row stays where it is.

## What is known

The record is not in Health any more, and it is not in the archive either. On
2026-09-20 the dev archive's day for 20 September came back with no water events
at all — the two the day did hold were written and removed by a check run the
same evening, and nothing of the owner's was among them. So the row on screen
outlived the thing it describes.

The log says the same from the other side. Two runs tried to remove it:

- `19:09:36 apply … 1 applied, failed 1:notFound`
- `19:45:06 apply … 0 applied, failed 0:notFound`

`notFound` is the phone answering that the id names no sample it wrote. That is
the correct answer for a sample that is already gone; what is wrong is that the
app keeps offering removal as the one thing you may do to the row, and says
nothing about why it never works.

## The suspected cause, not yet proved

Two edits written during the earlier walk (`items2.json` and `items3.json`)
reused one agent id. The phone keeps a version per id and replaces the sample
atomically, so the second edit did not add a second sample — it replaced the
first. The journal, though, records rows per edit, so one Health sample ended up
with two rows behind it. Removing the sample satisfied the first row; the second
row has nothing left to remove and answers `notFound` for good.

This has to be confirmed against the phone's journal before anything is built:
if the two rows carry the same id, the cause is settled.

## What a fix has to decide

- Whether a row whose id is already gone should be shown as removed rather than
  as removable. The record is gone either way — the row is the only thing left
  that disagrees.
- Whether two journal rows may ever describe one sample, or whether writing the
  same id twice should collapse into the row that already exists.
- What the app says when a removal answers `notFound`. Today it says nothing the
  person can act on, which is why the same key was pressed twice, half an hour
  apart.

## Order of work

Confirm the cause on the phone (the two rows and their ids) → decide the
question above with the owner → implement → walk the history screen in both
appearances, including a row in the new state.
