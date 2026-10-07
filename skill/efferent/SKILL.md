---
name: efferent
description: Read and write one person's Apple Health history from their Efferent archive — sleep, steps, heart rate, workouts, meals, weight. Use when the user asks about their health data, sleep, activity, heart rate, workouts, nutrition or weight, or asks to log a meal, a night of sleep or a weight into Apple Health. Decrypts locally with a key that never leaves this machine.
---

# Efferent

Efferent keeps a person's Apple Health history in an end-to-end encrypted archive. Their phone
writes it; the service that holds it cannot open it. This skill reads it on this machine with
`efferent.mjs`, a single file beside this one that needs Node 22 or newer and nothing else.

Every command below is run as:

```bash
EFFERENT_HOME="$HOME/.efferent/reader" node <this skill's folder>/efferent.mjs <command>
```

`EFFERENT_HOME` is the private directory holding the reading key and the local copy of the
archive. Always name it explicitly: the default is `.efferent` in the current directory, which
would put a key inside whatever project the session happens to be in.

## Connecting, once

The person's phone shares a prompt with four fields: `Instruction`, `MCP`, `Reading key` and
`Editor key`. When the profile above has no `reading-key.json` yet, ask for that prompt, save it to
a private temporary file, and run:

```bash
EFFERENT_HOME="$HOME/.efferent/reader" node efferent.mjs connect --handoff <file>
```

Then delete the temporary file. The keys now live in `EFFERENT_HOME`, readable only by this user,
and every later session reads from there. `connect` refuses to overwrite a profile of another
archive; a fresh prompt for the same archive only adds an editor key that was missing.

Never print, quote, log or send the keys anywhere — not into the chat, not into a tool argument,
not to the service. Nothing else needs them.

## Answering

Start with `overview`: what the archive covers, when each metric starts, and how to read it. Every
answer is JSON in the same shape as the matching MCP tool, with a `warning` first when the local
copy may be behind.

- `overview` — the range of days, every metric with its kind, unit and first day, and what can be
  written.
- `daily [--since D] [--until D] [--metrics a,b]` — one row per day of totals (steps, energy,
  distance, exercise, nutrition). At most 400 days.
- `statistics --metric M [--since D] [--until D] [--group-by day|week|month|year]` — distribution
  per group; the tool for trends and for anything spanning years.
- `sleep [--since D] [--until D]` — one row per night, stages broken out.
- `workouts [--since D] [--until D] [--activity A]`
- `samples --metric M [--since D] [--until D] [--limit N]` — raw readings, when nothing else fits.
- `sync` — copy every changed day down; the other commands refresh what they need on their own.
- `tools [name]` — every tool's description and arguments, or one tool's.
- `call <tool> [json]` — any MCP tool by name, for example
  `call phone_data_statistics '{"metric":"heartRate","group_by":"year"}'`.

Days are `YYYY-MM-DD`, both ends included. The data has traps the commands already correct for;
say them when they matter rather than redoing the arithmetic:

- Totals (steps, distance, energy) are already summed by Health. Never add records up again —
  several devices write the same minutes.
- Sleep stretches overlap and are merged, never added. A night runs noon to noon and is named by the
  evening it began in.
- Blood oxygen is a fraction: 0.97 means 97%, whatever the unit says.
- A metric's first day is when the device that measures it arrived; earlier is not a gap.
- A missing night or day means nothing was recorded, not a zero.

## Writing into Health

Meals (dietary energy, protein, carbohydrates, fat, water), sleep by stage and body mass can be
written. Put the items in a JSON file and run `write --items <file>`; `tools phone_data_write`
prints the shape and every rule, and `overview` lists each metric with the one unit it takes. Pick
ids you can rebuild —
`agent:meal:2026-09-07:lunch` — so a correction reuses the id. The phone applies an edit the next
time it is opened or wakes; `edits` says what became of each.

## As an MCP server

`node efferent.mjs mcp` serves the same nine `phone_data_*` tools over stdio, for a client that
registers local MCP servers. Give it the same `EFFERENT_HOME` and an absolute path to `node`: a
client started from the desktop does not inherit the shell's `PATH`.
