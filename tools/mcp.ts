/**
 * The archive as an MCP server, so any agent can read it without being taught
 * how.
 *
 * **It runs here, next to the reading key, and it has to.** Answering a question
 * means decrypting days, and the private half of the reading key never leaves
 * this machine — that is the whole design. A version of this living on the
 * bucket service would need that key, which would hand the service the one thing
 * it must never have. So the agent connects to a process on the reader's own
 * machine, and the service stays a place that holds ciphertext it cannot open.
 *
 * **The tools answer questions, not queries.** Handing an agent a `select`
 * against a million events would make it responsible for the traps in this data:
 * summing overlapping sleep, adding hourly steps to daily steps, reading a blood
 * oxygen of 0.97 as "0.97%". So the surface is nights, workouts, daily totals
 * and distributions — shapes where the corrections have already happened — with
 * one raw escape hatch for the questions nobody anticipated.
 *
 * The descriptions carry what a reader has to know, because that is the point:
 * no prompt is written anywhere, so anything the agent needs must arrive with
 * the tool.
 *
 * Transport is JSON-RPC 2.0 over stdio, newline-delimited, spoken directly
 * rather than through a library — it is a hundred lines and it keeps the reading
 * side free of dependencies that would have to be trusted with this of all data.
 */

import {
  type Archive,
  type Event,
  isDay,
  loadState,
  mirroredDays,
  type MirrorState,
  openArchive,
  readDay,
  saveState,
  type Stats,
  writeDay,
} from "./archive.ts";
import {
  addDays,
  dailyTotals,
  type Distribution,
  distribution,
  type Grouping,
  groupOf,
  nights,
  RECORDS,
  summarise,
  TOTALS,
  UNIT_NOTES,
  workouts,
} from "./analysis.ts";

const NAME = "efferent";
const VERSION = "1.0.0";
/** Versions this server knows how to speak, newest first. A client asking for
 * one of them gets it back; anything else gets the newest and finds out at once
 * rather than halfway through a call. */
const PROTOCOL_VERSIONS = ["2025-06-18", "2025-03-26", "2024-11-05"];

/** How long an answer may go on trusting the mirror before asking the archive
 * whether anything moved. Short enough that "today" means today, long enough
 * that a conversation of twenty questions costs one check. */
const FRESH_FOR_MS = 5 * 60 * 1000;

/** Days re-listed on every check. The phone re-reads the last week on every
 * refresh, so this is where rewrites actually happen; the day count catches
 * everything else. */
const RECENT_DAYS = 14;

/** Rows one answer will return. Past this the answer is data to be processed
 * rather than read, and the caller wants a coarser grouping or a shorter range —
 * which the refusal says outright instead of quietly truncating. */
const MAX_ROWS = 1000;

// MARK: - The archive, kept close

/** Everything the tools read through, so freshness is decided once. */
class Reader {
  private state: MirrorState | null = null;
  private archive: Archive | null = null;
  private checkedAt = 0;
  /** Set when the archive could not be reached, and returned with the answer.
   * A quietly stale answer about health data is worse than a late one. */
  warning: string | null = null;

  async open(): Promise<{ state: MirrorState; archive: Archive }> {
    if (!this.state || !this.archive) {
      this.state = await loadState();
      this.archive = await openArchive(this.state.endpoint);
    }
    return { state: this.state, archive: this.archive };
  }

  async stats(): Promise<Stats | null> {
    try {
      const { archive } = await this.open();
      return await archive.stats();
    } catch (error) {
      this.warning = `the archive could not be reached (${message(error)}); ` +
        `answering from the local mirror, which may be behind`;
      return null;
    }
  }

  /**
   * Bring the mirror in line with the archive, cheaply.
   *
   * Two requests in the ordinary case: what the archive holds in total, and the
   * last fortnight in detail. The count catches history arriving, the fortnight
   * catches the days the phone rewrites. A mismatch that neither explains falls
   * through to a full listing, which is six requests and happens almost never.
   */
  async refresh(force = false): Promise<void> {
    if (!force && Date.now() - this.checkedAt < FRESH_FOR_MS) return;
    this.warning = null;

    const remote = await this.stats();
    if (!remote) return;
    const { state, archive } = await this.open();
    this.checkedAt = Date.now();

    try {
      await this.take(archive, state, await archive.list({ from: addDays(today(), -RECENT_DAYS) }));
      if (remote.days !== Object.keys(state.days).length) {
        await this.take(archive, state, await archive.list({}));
      }
    } catch (error) {
      this.warning = `the mirror could not be brought up to date (${message(error)}); ` +
        `answering from what it already had`;
    }
  }

  /** Copy the days whose stored version is not the one the archive now holds. */
  private async take(
    archive: Archive,
    state: MirrorState,
    listing: { day: string; uploaded: string }[],
  ): Promise<void> {
    const stale = listing.filter((entry) => state.days[entry.day] !== entry.uploaded);
    if (stale.length === 0) return;
    for await (const fetched of archive.several(stale.map((entry) => entry.day))) {
      await writeDay(fetched.day, fetched.events);
      state.days[fetched.day] = stale.find((entry) => entry.day === fetched.day)!.uploaded;
    }
    await saveState(state);
  }

  /**
   * The events in a range that a caller cares about, day by day.
   *
   * `keep` is applied before anything is held on to, because a decade of heart
   * rate is eight hundred thousand readings and a question about sleep has no
   * use for any of them.
   */
  async collect(
    from: string,
    to: string,
    keep: (event: Event) => boolean,
  ): Promise<{ day: string; events: Event[] }[]> {
    await this.refresh();
    const days = await mirroredDays({ from, to });
    const out: { day: string; events: Event[] }[] = [];
    for (const day of days) {
      out.push({ day, events: (await readDay(day)).filter(keep) });
    }
    return out;
  }

  async mirrored(): Promise<string[]> {
    return await mirroredDays({});
  }
}

const reader = new Reader();

// MARK: - Tools

interface Tool {
  name: string;
  title: string;
  description: string;
  inputSchema: Record<string, unknown>;
  run(input: Record<string, unknown>): Promise<unknown>;
}

const SINCE = {
  type: "string",
  description: "First day, YYYY-MM-DD, inclusive. Defaults to 90 days before today.",
};
const UNTIL = {
  type: "string",
  description: "Last day, YYYY-MM-DD, inclusive. Defaults to today.",
};

const TOOLS: Tool[] = [
  {
    name: "health_overview",
    title: "What the archive holds",
    description: [
      "Start here. Reports what this Health archive contains before anything is asked of it:",
      "the range of days, how many there are, and for every metric its kind, unit, first and",
      "last day, and how many days carry it.",
      "",
      "The first day of a metric is the day the device that measures it arrived, so a question",
      "about heart rate before that day is not a gap in the data — nothing was measuring.",
      "Takes no arguments.",
    ].join("\n"),
    inputSchema: { type: "object", properties: {} },
    run: async () => {
      const remote = await reader.stats();
      await reader.refresh();
      const mirrored = await reader.mirrored();
      const days: { day: string; events: Event[] }[] = [];
      for (const day of mirrored) days.push({ day, events: await readDay(day) });

      return {
        archive: remote
          ? {
            days: remote.days,
            firstDay: remote.firstDay,
            lastDay: remote.lastDay,
            megabytes: Math.round(remote.bytes / 1024 / 1024 * 10) / 10,
          }
          : "unreachable",
        readable: {
          days: mirrored.length,
          firstDay: mirrored[0] ?? null,
          lastDay: mirrored[mirrored.length - 1] ?? null,
          note: remote && remote.days > mirrored.length
            ? `${remote.days - mirrored.length} days of the archive are not copied here yet; ` +
              `run health_sync to complete the picture`
            : "the whole archive is readable",
        },
        metrics: summarise(days),
        howToRead: [
          "A total (steps, distance, energy, exercise and stand minutes) is already summed by",
          "Health and must never be summed again from records — several devices write the same",
          "minutes and adding them double-counts.",
          "Totals come bucketed by day, and by hour only from the day the app was installed.",
          "A record belongs to the day it started on, so a night that began before midnight is",
          "in the evening's day.",
        ],
      };
    },
  },
  {
    name: "health_daily",
    title: "Daily totals",
    description: [
      "One row per day with the day's totals: steps, distance, flights, active and basal",
      "energy, exercise and stand minutes. This is the table to answer 'how active was I'.",
      "",
      "Reads the daily buckets only, so it can never double-count against the hourly ones.",
      "A null means the day carries no total for that metric, which is not the same as a zero.",
      "Refuses ranges over 400 days — use health_statistics for anything longer.",
    ].join("\n"),
    inputSchema: {
      type: "object",
      properties: {
        metrics: {
          type: "array",
          items: { type: "string", enum: [...TOTALS] },
          description: `Which totals to include. Defaults to all of: ${TOTALS.join(", ")}.`,
        },
        since: SINCE,
        until: UNTIL,
      },
    },
    run: async (input) => {
      const { from, to } = range(input, 90);
      if (daysApart(from, to) > 400) {
        throw new Error(
          `${daysApart(from, to)} days is too many for a daily table; ask for 400 or fewer, ` +
            `or use health_statistics with group_by month or year`,
        );
      }
      const metrics = list(input.metrics, [...TOTALS]);
      const days = await reader.collect(from, to, (event) => event.bucket === "day");
      const rows = dailyTotals(days, metrics);
      return {
        units: unitsFor(days, metrics),
        columns: ["day", ...metrics],
        rows: rows.map((row) => [row.day, ...metrics.map((metric) => row.values[metric])]),
      };
    },
  },
  {
    name: "health_statistics",
    title: "Distribution of a metric over time",
    description: [
      "How one metric is distributed, grouped by day, week, month or year: count, min, p10,",
      "median, mean, p90, max and sum per group. This is the tool for trends and for any",
      "question spanning years — it never returns the underlying readings.",
      "",
      "For a total, the numbers are over that metric's daily totals, one per day.",
      "For a record (heart rate, HRV, respiratory rate, blood oxygen), they are over the",
      "individual readings, of which there can be hundreds in a day.",
      "Blood oxygen arrives as a fraction: 0.97 means 97%.",
    ].join("\n"),
    inputSchema: {
      type: "object",
      required: ["metric"],
      properties: {
        metric: {
          type: "string",
          enum: [...TOTALS, ...RECORDS.filter((m) => m !== "sleep" && m !== "workout")],
          description: "The metric to describe. Sleep and workouts have their own tools.",
        },
        since: SINCE,
        until: UNTIL,
        group_by: {
          type: "string",
          enum: ["day", "week", "month", "year"],
          description: "How to group the days. Defaults to month.",
        },
      },
    },
    run: async (input) => {
      const metric = String(input.metric ?? "");
      if (!metric) throw new Error("metric is required");
      const { from, to } = range(input, 365);
      const grouping = (input.group_by ?? "month") as Grouping;
      const isTotal = (TOTALS as readonly string[]).includes(metric);

      const days = await reader.collect(
        from,
        to,
        (event) => event.metric === metric && (isTotal ? event.bucket === "day" : !event.bucket),
      );

      const groups = new Map<string, number[]>();
      let unit: string | null = null;
      for (const { day, events } of days) {
        const label = groupOf(day, grouping);
        const values = groups.get(label) ?? [];
        for (const event of events) {
          if (typeof event.value !== "number") continue;
          if (!unit && typeof event.unit === "string") unit = event.unit;
          values.push(event.value);
        }
        groups.set(label, values);
      }

      const rows = [...groups.entries()]
        .map(([group, values]) => ({ group, ...(distribution(values) ?? empty()) }))
        .filter((row) => row.n > 0)
        .sort((left, right) => left.group.localeCompare(right.group));
      if (rows.length > MAX_ROWS) {
        throw new Error(
          `${rows.length} groups is more than an answer should carry; ` +
            `coarsen group_by or shorten the range`,
        );
      }

      return {
        metric,
        unit,
        ...(UNIT_NOTES[metric] ? { unitNote: UNIT_NOTES[metric] } : {}),
        over: isTotal ? "daily totals, one value per day" : "individual readings",
        groupBy: grouping,
        rows,
      };
    },
  },
  {
    name: "health_sleep",
    title: "Nights of sleep",
    description: [
      "One row per night: hours asleep, hours in bed, the breakdown by stage, and when it",
      "started and ended.",
      "",
      "Two things are decided here that a reader of the raw events would get wrong. Overlapping",
      "stretches are merged rather than added, because more than one source can describe the",
      "same minutes and adding them invents hours of sleep. A night runs noon to noon and is",
      "named by the evening it began in, so a night is one row rather than two halves.",
      "A missing night means nothing was recorded — the watch was off, not that nobody slept.",
    ].join("\n"),
    inputSchema: {
      type: "object",
      properties: { since: SINCE, until: UNTIL },
    },
    run: async (input) => {
      const { from, to } = range(input, 90);
      // A night named by the last day of the range is finished on the day after
      // it, and the night before the first day reaches into it. Both ends are
      // widened so neither night comes back as a half.
      const days = await reader.collect(
        addDays(from, -1),
        addDays(to, 1),
        (event) => event.metric === "sleep",
      );
      const rows = nights(days.flatMap((day) => day.events))
        .filter((night) => night.night >= from && night.night <= to);
      if (rows.length > MAX_ROWS) {
        throw new Error(`${rows.length} nights is too many; ask for less`);
      }

      const hours = rows.map((night) => night.asleepHours).filter((value) => value > 0);
      return {
        nightsRecorded: rows.length,
        nightsInRange: daysApart(from, to) + 1,
        asleepHours: distribution(hours),
        rows,
      };
    },
  },
  {
    name: "health_workouts",
    title: "Recorded workouts",
    description: [
      "Every workout in a range — activity, when it started, how long it lasted — plus a count",
      "and total minutes per activity.",
      "",
      "The phone sends Apple's activity number and this translates it, so an activity comes",
      "back as 'walking' rather than as 52. A workout is what was deliberately recorded; it is",
      "not the same as the day's movement, which lives in health_daily.",
    ].join("\n"),
    inputSchema: {
      type: "object",
      properties: {
        since: SINCE,
        until: UNTIL,
        activity: {
          type: "string",
          description: "Keep only this activity, e.g. walking, cycling, swimming.",
        },
      },
    },
    run: async (input) => {
      const { from, to } = range(input, 365);
      const days = await reader.collect(from, to, (event) => event.metric === "workout");
      const wanted = input.activity ? String(input.activity) : null;
      const found = workouts(days).filter((workout) => !wanted || workout.activity === wanted);

      const byActivity = new Map<string, { count: number; minutes: number }>();
      for (const workout of found) {
        const seen = byActivity.get(workout.activity) ?? { count: 0, minutes: 0 };
        seen.count++;
        seen.minutes = Math.round((seen.minutes + workout.minutes) * 10) / 10;
        byActivity.set(workout.activity, seen);
      }

      return {
        total: found.length,
        byActivity: Object.fromEntries(
          [...byActivity.entries()].sort((left, right) => right[1].count - left[1].count),
        ),
        rows: found.slice(0, MAX_ROWS),
        ...(found.length > MAX_ROWS
          ? { note: `showing the first ${MAX_ROWS} of ${found.length}` }
          : {}),
      };
    },
  },
  {
    name: "health_samples",
    title: "Raw readings",
    description: [
      "The individual events for one metric, exactly as they left the phone. The escape hatch",
      "for questions the other tools do not shape — the time of day something happened, what a",
      "single reading was, which device recorded it.",
      "",
      "Capped, and deliberately so: a decade of heart rate is eight hundred thousand readings.",
      "For anything about a trend or an average, health_statistics is both cheaper and harder",
      "to misread.",
    ].join("\n"),
    inputSchema: {
      type: "object",
      required: ["metric"],
      properties: {
        metric: { type: "string", description: "Which metric's readings to return." },
        since: SINCE,
        until: UNTIL,
        limit: {
          type: "integer",
          description: "How many readings at most. Defaults to 500, maximum 5000.",
        },
      },
    },
    run: async (input) => {
      const metric = String(input.metric ?? "");
      if (!metric) throw new Error("metric is required");
      const { from, to } = range(input, 7);
      const limit = Math.min(Number(input.limit ?? 500) || 500, 5000);

      const days = await reader.collect(from, to, (event) => event.metric === metric);
      const events = days.flatMap((day) => day.events)
        .sort((left, right) => String(left.start).localeCompare(String(right.start)));

      return {
        metric,
        ...(UNIT_NOTES[metric] ? { unitNote: UNIT_NOTES[metric] } : {}),
        matched: events.length,
        returned: Math.min(events.length, limit),
        rows: events.slice(0, limit),
      };
    },
  },
  {
    name: "health_sync",
    title: "Copy the archive down",
    description: [
      "Bring the local copy of the archive up to date. The other tools refresh what they need",
      "on their own, so this is only worth calling to make the whole history readable at once —",
      "health_overview says when that is not already true.",
      "",
      "Safe to interrupt and safe to repeat: a day is either the version the archive holds or",
      "an older one, and this replaces the older ones.",
    ].join("\n"),
    inputSchema: { type: "object", properties: {} },
    run: async () => {
      const before = (await reader.mirrored()).length;
      await reader.refresh(true);
      const after = await reader.mirrored();
      return {
        copied: after.length - before,
        readable: after.length,
        firstDay: after[0] ?? null,
        lastDay: after[after.length - 1] ?? null,
      };
    },
  },
];

// MARK: - Arguments

function range(input: Record<string, unknown>, defaultDays: number): { from: string; to: string } {
  const to = day(input.until, "until") ?? today();
  const from = day(input.since, "since") ?? addDays(to, -defaultDays);
  if (from > to) throw new Error(`since (${from}) is after until (${to})`);
  return { from, to };
}

function day(value: unknown, name: string): string | null {
  if (value === undefined || value === null || value === "") return null;
  const text = String(value).slice(0, 10);
  if (!isDay(text)) throw new Error(`${name} must be a day, YYYY-MM-DD, got ${String(value)}`);
  return text;
}

function list(value: unknown, fallback: string[]): string[] {
  if (!Array.isArray(value) || value.length === 0) return fallback;
  return value.map(String);
}

function daysApart(from: string, to: string): number {
  return Math.round((Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86_400_000);
}

function today(): string {
  return new Date().toISOString().slice(0, 10);
}

function unitsFor(
  days: { events: Event[] }[],
  metrics: string[],
): Record<string, string | null> {
  const units: Record<string, string | null> = {};
  for (const metric of metrics) units[metric] = null;
  for (const { events } of days) {
    for (const event of events) {
      const metric = event.metric;
      if (metric && metric in units && !units[metric] && typeof event.unit === "string") {
        units[metric] = event.unit;
      }
    }
  }
  return units;
}

function empty(): Distribution {
  return { n: 0, min: 0, p10: 0, median: 0, mean: 0, p90: 0, max: 0, sum: 0 };
}

function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

// MARK: - JSON-RPC over stdio

interface Request {
  jsonrpc: "2.0";
  id?: string | number | null;
  method: string;
  params?: Record<string, unknown>;
}

export async function handle(request: Request): Promise<unknown | null> {
  // A notification has no id and takes no answer. `notifications/initialized`
  // is the only one that arrives, and replying to it is a protocol error rather
  // than a harmless extra.
  const notification = request.id === undefined || request.id === null;

  switch (request.method) {
    case "initialize": {
      const asked = String(request.params?.protocolVersion ?? "");
      return result(request.id, {
        protocolVersion: PROTOCOL_VERSIONS.includes(asked) ? asked : PROTOCOL_VERSIONS[0],
        capabilities: { tools: {} },
        serverInfo: { name: NAME, version: VERSION },
        instructions: [
          "This is one person's Apple Health history, day by day, from an end-to-end encrypted",
          "archive. Call health_overview first: it says what the data covers, when each metric",
          "starts, and the few ways this data misleads a reader who treats it as a plain table.",
        ].join(" "),
      });
    }
    case "ping":
      return result(request.id, {});
    case "tools/list":
      return result(request.id, {
        tools: TOOLS.map((tool) => ({
          name: tool.name,
          title: tool.title,
          description: tool.description,
          inputSchema: tool.inputSchema,
        })),
      });
    case "tools/call": {
      const name = String(request.params?.name ?? "");
      const tool = TOOLS.find((candidate) => candidate.name === name);
      if (!tool) {
        return result(request.id, text(`no such tool: ${name}`, true));
      }
      try {
        const answer = await tool.run((request.params?.arguments ?? {}) as Record<string, unknown>);
        const body = reader.warning ? { warning: reader.warning, ...answer as object } : answer;
        return result(request.id, text(JSON.stringify(body, null, 1)));
      } catch (error) {
        // Reported as a failed tool call rather than as a broken connection: the
        // agent can read it, correct the arguments and try again.
        return result(request.id, text(message(error), true));
      }
    }
    default:
      if (notification) return null;
      return {
        jsonrpc: "2.0",
        id: request.id,
        error: { code: -32601, message: `unknown method: ${request.method}` },
      };
  }
}

function result(id: Request["id"], value: unknown): unknown {
  return { jsonrpc: "2.0", id, result: value };
}

function text(body: string, isError = false): unknown {
  return { content: [{ type: "text", text: body }], ...(isError ? { isError: true } : {}) };
}

async function serve(): Promise<void> {
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();
  let buffer = "";

  for await (const chunk of Deno.stdin.readable) {
    buffer += decoder.decode(chunk, { stream: true });
    let newline = buffer.indexOf("\n");
    while (newline >= 0) {
      const line = buffer.slice(0, newline).trim();
      buffer = buffer.slice(newline + 1);
      newline = buffer.indexOf("\n");
      if (!line) continue;

      let answer: unknown | null;
      try {
        answer = await handle(JSON.parse(line) as Request);
      } catch (error) {
        answer = {
          jsonrpc: "2.0",
          id: null,
          error: { code: -32700, message: `could not read that: ${message(error)}` },
        };
      }
      if (answer !== null) await Deno.stdout.write(encoder.encode(JSON.stringify(answer) + "\n"));
    }
  }
}

// Last line in the file, and it has to be. `serve` waits forever, so calling it
// any earlier stops the module evaluating and every `const` below it stays in
// the dead zone — the server then answers `initialize` and fails on the very
// next request with "cannot access TOOLS before initialization". Importing the
// module hides this completely, so only a test that spawns it catches it.
if (import.meta.main) await serve();
