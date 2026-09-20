# Two journal rows over one record, and the keys they offer

Opened 2026-09-20 on the owner's instruction, after they reported a water record
of 20 September 15:53 in the app's own history that they could not remove.
Rewritten the same evening once the cause was traced; the first draft guessed at
it and guessed wrong.

## How the record came about

Three edits were sent to the live bucket that afternoon while TestFlight wakes
were being checked. Times are UTC; the owner is three hours ahead.

- `1789908242585-badzll7g`, 12:44:02Z — `put testflight-wake-2026-09-20`, water.
- `1789908563103-fhnhqr3v`, 12:49:23Z — `put testflight-wake-2026-09-20-b`, 100 mL.
- `1789908791213-k4p6oymf`, 12:53:11Z — `put testflight-wake-2026-09-20-b`, 150 mL.

The last two carry **one id**. That was an oversight on the agent's side, but it
is a case the protocol invites: reusing an id is how an agent corrects its own
record, and the phone handles it exactly as designed — a higher version replaces
the sample atomically, so Health ends with one record of 150 mL at 15:53 local.

The journal does not work that way. A row is written per edit and item index
(`Store.recordEdit`, keyed by `editName` + `item`), while Health keys a sample
by id. So one record left two rows on the history screen.

## What the app then offers on those two rows

The key on a row is chosen by what its item displaced (`EditWords.restores`,
`EditEntry.personCanAct`):

- The 15:49 row displaced nothing, so its key is **Remove the record** — and
  what it removes is whatever now stands under that id, which is the 15:53
  record, not the one the row describes.
- The 15:53 row displaced the 100 mL, so its key is **Write the record back** —
  pressing it would put the 15:49 record into Health again, under the same id.

That is why the owner found no way to remove the 15:53 row: the app does not
offer removal there. It offers restoration of a record they never asked for.

The rest follows from the same crossing. The log of that evening shows six
person-initiated removals: five removed a record, and one at 19:17:31Z answered
`the person removed a record Health no longer had` — the second row of the pair,
acting on a sample its twin had already taken out. An agent `delete` of the id
at 19:45:03Z (`1789933503858-lbkqtlha`) answered `notFound` for the same reason.

## What is not wrong

The removal path itself works. A water record written and removed straight
afterwards on 2026-09-20 was answered `{"applied":1,"failed":[]}` on the first
try. And the record in question is out of Health: the archive's copy of
20 September, uploaded 19:47:35Z, carries no water at 12:49Z or 12:53Z.

## What a fix has to decide

- Whether a journal row should be keyed by the record rather than by the item,
  so that writing the same id twice adds to one row's history instead of making
  a second row that speaks for the same sample.
- If two rows stay, what each may offer. A row whose id another row has already
  acted on must not offer a key that works on the other's record.
- Whether "write the record back" should exist at all for a displacement the
  person never saw. Restoring a 100 mL record from four minutes earlier is not
  an undo of anything the person did.

## Order of work

Read the two rows on the phone and confirm the words each shows → decide the
question above with the owner → implement → walk the history screen in both
appearances, with a pair of rows over one id among the data.

## Five whys

The failure, stated as the person met it: a record the agent wrote could not be
removed from the app's own history.

1. **Why?** The row for it offers no removal. Its key reads *Write the record
   back*.
2. **Why that key?** A row's action is chosen by one test — whether the item
   displaced anything (`EditWords.restores` is `!entry.displaced.isEmpty`). That
   item displaced 100 mL, so the app offers to put the 100 mL back.
3. **Why did the item displace anything, when Health holds one record?** Two
   edits four minutes apart carried one id, and a `put` under an id this app has
   already written replaces the sample. That is the protocol working as
   designed: reusing an id is how an agent corrects its own record.
4. **Why does the journal then hold two rows with independent keys?** A row is
   keyed by edit name and item index; Health keys a sample by id. Two edits over
   one id are two rows, and neither knows the other exists.
5. **Why is the row keyed that way?** For replay. An edit is applied again
   whenever a run dies between writing and answering, and the repeat must land
   on the row the first attempt made. The migration comment for `v4.editLog`
   states the key also covers the correction case — "the same id is also how an
   agent corrects a record it wrote before: both must land on one row, and the
   second must not stand beside the first" — but the key cannot deliver that
   half: a correction arrives in a **different** edit, so its name differs and
   the row is new.

**Root cause.** The journal records what each item of each edit did. The screen
asks what the record is now and what may be done to it. Nothing in the app
materialises a record's own history, so the key on a row is computed from one
item in ignorance of every other item that touched the same id. The v4 comment
shows this was not the intent — the implementation has quietly disagreed with
its own stated contract since the journal was written.
