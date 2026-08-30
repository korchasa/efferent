/**
 * What a sealed day unpacks into, and how it was packed.
 *
 * A day used to be one JSON object per line, each carrying the HealthKit record
 * id it came from. Measured over a decade of real days, those ids were 58% of
 * everything the phone uploaded, and no reader ever looked at one. So a day is
 * now a set of columns: rows that agree on kind, metric, bucket, unit and source
 * share a series and say all of that once, instants travel as whole seconds
 * counted from the first row of the series, and the id is gone. The same decade
 * comes out at an eighth of the size.
 *
 * Reading gives back exactly the events the line format gave back, id included —
 * the id is simply computed here rather than carried. Everything above this
 * layer sees no change at all.
 *
 * Two rules exist because trying the format broke without them:
 *
 * - **An instant is not a name.** Two sleep stages begin in the same second and
 *   two watches report the same beat: over a decade of real days 3 620 events
 *   land on an identity another event already has. Rows that collide are
 *   numbered `#1`, `#2` in the order the series holds them, which the encoder
 *   fixes, so the same day always rebuilds the same ids.
 * - **The columns are a closed set.** A field with no column would travel no
 *   further and nothing would say so, which is why ``pack`` refuses one.
 */

/** The layout stamped on a day this code writes. */
export const DAY_FORMAT_VERSION = 2;

/** The version stamped on each event a reader unpacks. It has not moved. */
export const EVENT_SCHEMA_VERSION = 1;

export interface DayEvent {
  id: string;
  v: number;
  metric?: string;
  bucket?: string;
  start?: string;
  end?: string;
  [key: string]: unknown;
}

/** What every row of a series has in common, and therefore says once. */
const SHARED = ["metric", "bucket", "unit", "source"] as const;
/** What varies row by row, past the two instants. */
const COLUMNS = ["value", "stage", "activity", "duration"] as const;

const KNOWN = new Set<string>([
  "id",
  "v",
  "start",
  "end",
  ...SHARED,
  ...COLUMNS,
]);

interface Series {
  k: string;
  t0: number;
  t: number[];
  d: number[];
  [key: string]: unknown;
}

// MARK: - Reading

/**
 * Turn the bytes inside a sealed day into events.
 *
 * Both layouts are accepted, and have to be: an archive written before this
 * change still holds days in the line format, and a phone replaces them one day
 * at a time. The two are told apart by shape rather than by a byte — a columnar
 * day is a single object with a `series` array in it, and no line of the old
 * format ever was.
 */
export function expand(text: string): DayEvent[] {
  const trimmed = text.trim();
  if (!trimmed) return [];

  if (trimmed.startsWith("{") && !trimmed.includes("\n")) {
    const document = JSON.parse(trimmed) as { v?: number; series?: Series[] };
    if (Array.isArray(document.series)) return fromSeries(document);
  }

  return trimmed.split("\n").filter((line) => line.trim()).map((line) =>
    JSON.parse(line) as DayEvent
  );
}

function fromSeries(document: { v?: number; series?: Series[] }): DayEvent[] {
  if (document.v !== DAY_FORMAT_VERSION) {
    throw new Error(
      `this day is written in layout ${document.v}, and this reader speaks ${DAY_FORMAT_VERSION}`,
    );
  }

  const events: DayEvent[] = [];
  for (const series of document.series ?? []) {
    let moment = series.t0;
    for (let row = 0; row < series.t.length; row++) {
      if (series.d.length !== series.t.length) {
        throw new Error(`a series has ${series.t.length} instants and ${series.d.length} lengths`);
      }
      moment += series.t[row];
      const event: DayEvent = {
        id: "",
        v: EVENT_SCHEMA_VERSION,
        end: instant(moment + series.d[row]),
        start: instant(moment),
      };
      for (const name of SHARED) {
        const shared = series[name];
        if (shared !== undefined) event[name] = shared as string;
      }
      for (const name of COLUMNS) {
        const column = series[name] as unknown[] | undefined;
        if (!column) continue;
        if (column.length !== series.t.length) {
          throw new Error(
            `column ${name} has ${column.length} entries for ${series.t.length} rows`,
          );
        }
        if (column[row] !== null) event[name] = column[row];
      }
      event.id = `${series.k}:${event.metric}:${event.start}${
        event.bucket ? `:${event.bucket[0]}` : ""
      }`;
      events.push(event);
    }
  }
  return number(events);
}

/** An instant is not a name. Rows that land on one are numbered in series order. */
function number(events: DayEvent[]): DayEvent[] {
  const total = new Map<string, number>();
  for (const event of events) total.set(event.id, (total.get(event.id) ?? 0) + 1);

  const running = new Map<string, number>();
  for (const event of events) {
    if ((total.get(event.id) ?? 0) < 2) continue;
    const seen = (running.get(event.id) ?? 0) + 1;
    running.set(event.id, seen);
    event.id = `${event.id}#${seen}`;
  }
  return events;
}

function instant(seconds: number): string {
  return new Date(seconds * 1000).toISOString().replace(".000Z", "Z");
}

// MARK: - Writing

/**
 * Pack events into a day, byte for byte the way the phone does.
 *
 * The order events arrive in must not change the bytes: the body is what decides
 * whether a day has changed since it was last sent. Sorting by id did that
 * before; with no id left it is the content itself — series by their shared
 * fields, rows by their instants and then their values.
 */
export function pack(events: DayEvent[]): string {
  const groups = new Map<string, DayEvent[]>();
  for (const event of events) {
    const strangers = Object.keys(event).filter((name) => !KNOWN.has(name));
    if (strangers.length) throw new Error(`no column for ${strangers.sort().join(", ")}`);
    const key = JSON.stringify([kindOf(event), ...SHARED.map((name) => event[name] ?? null)]);
    const group = groups.get(key);
    group ? group.push(event) : groups.set(key, [event]);
  }

  const series: Record<string, unknown>[] = [];
  for (const key of [...groups.keys()].sort()) {
    const rows = groups.get(key)!.sort(precedes);
    const first = epoch(rows[0].start);

    let previous = first;
    const starts: number[] = [];
    const lengths: number[] = [];
    for (const row of rows) {
      const moment = epoch(row.start);
      starts.push(moment - previous);
      previous = moment;
      lengths.push(epoch(row.end) - moment);
    }

    const entry: Record<string, unknown> = { k: kindOf(rows[0]) };
    for (const name of SHARED) {
      if (rows[0][name] !== undefined) entry[name] = rows[0][name];
    }
    entry.t0 = first;
    entry.t = starts;
    entry.d = lengths;
    for (const name of COLUMNS) {
      if (rows.some((row) => row[name] !== undefined)) {
        entry[name] = rows.map((row) => row[name] ?? null);
      }
    }
    series.push(sorted(entry));
  }

  return JSON.stringify(sorted({ series, v: DAY_FORMAT_VERSION }));
}

function kindOf(event: DayEvent): string {
  return event.bucket === undefined ? "hk" : "agg";
}

/** Keys sorted, the way the phone's encoder sorts them. */
function sorted(object: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(Object.keys(object).sort().map((key) => [key, object[key]]));
}

function epoch(instant: string | undefined): number {
  if (!instant) throw new Error("an event with no instant cannot be placed in a day");
  return Math.floor(Date.parse(instant) / 1000);
}

/** Nothing sorts before something, and two of nothing are equal. */
function precedes(left: DayEvent, right: DayEvent): number {
  const byStart = epoch(left.start) - epoch(right.start);
  if (byStart) return byStart;
  const byEnd = epoch(left.end) - epoch(right.end);
  if (byEnd) return byEnd;
  for (const name of COLUMNS) {
    const order = compare(left[name], right[name]);
    if (order) return order;
  }
  return 0;
}

function compare(left: unknown, right: unknown): number {
  if (left === undefined && right === undefined) return 0;
  if (left === undefined) return -1;
  if (right === undefined) return 1;
  if (typeof left === "number" && typeof right === "number") return left - right;
  return String(left) < String(right) ? -1 : String(left) > String(right) ? 1 : 0;
}
