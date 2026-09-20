# One word per operation: who did it, and what happened to the record

Opened 2026-09-20 on the owner's instruction, after the TestFlight run raised the
question by accident: the journal showed one row reading `undone` and another
reading `deleted`, and the two words looked like alternatives when they are not.

The owner's ruling, in their words: removing a record is **one operation**
whether the person or the agent does it, it is called a removal everywhere, and
it is the same operation at every level of the app. The TestFlight run stops
until this ships, and everything is re-tested on the build that carries it.

## What is actually wrong

Today one column carries two different facts at once. `applied` and `deleted`
say what the **agent** did. `undone` says what the **person** did, and hides what
actually happened to the record — undoing an addition removes it, while undoing a
removal or a replacement writes a record back. So a reader cannot answer either
question reliably, and the two words sit in the same place on the row.

A literal reading of "call it all a removal" cannot work: it would have the app
call a restoration a removal. What the ruling means, unpacked, is that the app
has exactly **two** operations against Health — **write** and **remove** — and
each one has somebody who asked for it. Undo is not a third operation; it is the
person performing one of the two.

## The target

Two fields instead of one.

- **What happened to the record**: `written` (a record stands because of this
  row), `removed` (it was taken out), `refused` (Health never took it; `code`
  says why). `waiting` and `declined` stay untouched — nothing produces them any
  more, they belong to the approval gate that was removed, and the rule that a
  decision an older build recorded is never reopened still holds.
- **Who asked**: the agent, or the person.

Then the four cases read as one verb set:

- agent added → agent · written
- agent removed → agent · removed
- person reversed an addition → person · removed
- person reversed a removal or a replacement → person · written

## Migrating the journal, which is the only copy there is

`editLog` holds the only record of what an agent did — the service is told counts
and codes and nothing else — so the migration must lose nothing. Every existing
row maps without guessing, because the row already carries the evidence:

- `applied` → written, agent
- `deleted` → removed, agent
- `refused` → refused, agent
- `waiting`, `declined` → unchanged, agent
- `undone` → person, and what happened is read off the row:
  - `metric` is null — the item was a removal, so the undo wrote the record back
    → written
  - `metric` present, `displaced` empty — a pure addition, so the undo removed it
    → removed
  - `metric` present, `displaced` non-empty — a replacement, so the undo wrote the
    displaced record back → written

A test has to build a database holding one row of every old state and assert the
mapping, because this is the one step where a mistake costs data.

## The surface

Eight files of code: `EditEntry`, `Store`, `Database` (a v8 migration),
`Applier`, `Services`, `EditWords`, `EditsView`, `Snapshot`. Four test files:
`ApplierTests`, `EditLogTests`, `EditWordsTests`, `HealthWriterTests`. Plus
`documents/design.md` and `documents/requirements.md`.

**Outside this repository**, in the hub: the store screenshots `04-edits.png` and
`05-edit.png` are the journal and an edit's page, rendered from this app's own
offscreen mode. New wording means re-rendering and re-uploading them, which is
store-visible and needs its own go-ahead.

## Still to decide, before any code

1. The words on screen for each of the four cases, and what the key that reverses
   a row says in each. This is screen copy, so it is the owner's.
2. Whether `undoneAt` is renamed. It now means "when the person acted", and the
   ruling says the vocabulary is the same at every level; the rename is one more
   line in the same migration.
3. What the notice says. It reads "3 records changed" today — a third verb, which
   the ruling did not sanction. A run that both wrote and removed needs an answer.
4. Whether the swipe in the list keeps removing at once while the key on an edit's
   page still asks first.

## What this does not change

Nothing about the wire, the archive, the reading path or the applier's reach. No
requirement changes about what an agent may touch. The journal's contents are
preserved; only how a row is written down and read out.
