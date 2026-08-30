/**
 * Where days come from, for everything on the reading side.
 *
 * This is the layer that holds the reading key, opens sealed days and keeps the
 * mirror. Both the command line tool and the MCP server sit on it, so there is
 * one implementation of "fetch a day and decrypt it" rather than two that drift.
 *
 * The key never leaves this machine. The bucket service only ever handed over
 * ciphertext and only ever will.
 */

import { bucketId, dayBefore, isDay } from "../protocol/ids.ts";
import { fromBase64url } from "../protocol/signing.ts";
import { associatedData, open, rawPrivateKey } from "../protocol/sealedbox.ts";
import { decompress } from "../protocol/framing.ts";
import { expand } from "../protocol/day.ts";

export { dayBefore, isDay };

export interface ReadingKey {
  /** X25519 private key, pkcs8. The whole secret of the system. */
  readingPrivate: string;
  readingPublic: string;
}

/** One fact, in the shape a reader sees it.
 *
 * The id is not on the wire any more — ``expand`` rebuilds it from the metric
 * and the instant the record began. Nothing above this layer can tell the
 * difference, which is the whole reason the change was cheap. */
export interface Event {
  id: string;
  v: number;
  metric?: string;
  /** Present on a total, absent on a record — which is the only difference
   * between the two now that nothing carries a kind. */
  bucket?: string;
  start?: string;
  end?: string;
  [key: string]: unknown;
}

/**
 * What the mirror has, and when each day was written when it took its copy.
 *
 * The upload time is the whole of the bookkeeping. A day can be rewritten at any
 * moment — the phone re-reads it from Health and puts it up again — so "I have
 * everything up to here" is not a thing that can be known. "I have this version
 * of this day" is.
 */
export interface MirrorState {
  endpoint: string;
  days: Record<string, string>;
  syncedAt: string;
}

export interface DayEntry {
  day: string;
  uploaded: string;
}

export interface Stats {
  exists: boolean;
  days: number;
  bytes: number;
  firstDay: string | null;
  lastDay: string | null;
  complete: boolean;
}

export const HOME = Deno.env.get("EFFERENT_HOME") ?? ".efferent";
const DAYS = "days";
const STATE = "mirror.json";

/** An absolute path, for error messages. A relative one in a message about a
 * missing directory tells the reader nothing about where it was looked for. */
function resolve(path: string): string {
  return path.startsWith("/") ? path : `${Deno.cwd()}/${path}`;
}

// MARK: - Files

export async function load<T>(name: string): Promise<T> {
  return JSON.parse(await Deno.readTextFile(`${HOME}/${name}`)) as T;
}

/**
 * Through a temporary file, for the same reason a day is.
 *
 * Two processes keep this mirror — the command line tool and the MCP server —
 * and both read the state at the start of every pass. Writing in place gives a
 * reader a window in which the file is half a document, and the two ways that
 * lands are both bad: the record parses as nothing mirrored and the whole
 * archive is fetched again, or it does not parse and the reader says there is no
 * archive configured. A rename is the one write nobody can catch half of.
 */
export async function write(name: string, value: unknown): Promise<void> {
  await privateDirectory(HOME);
  const temporary = `${HOME}/${name}.partial`;
  await Deno.writeTextFile(temporary, JSON.stringify(value, null, 2) + "\n");
  await Deno.chmod(temporary, 0o600);
  await Deno.rename(temporary, `${HOME}/${name}`);
}

export async function loadState(url?: string): Promise<MirrorState> {
  let stored: MirrorState | null = null;
  try {
    stored = await load<MirrorState>(STATE);
  } catch {
    stored = null;
  }
  const endpoint = url ?? stored?.endpoint;
  if (!endpoint) {
    // Named in full, because the commonest way to see this is a server started
    // by an agent from some other directory: the default home is relative, so
    // it resolved somewhere with no archive in it and the real fault is the
    // path rather than the endpoint.
    throw new Error(
      `no archive is configured in ${resolve(HOME)} — point EFFERENT_HOME at the directory ` +
        `holding reading-key.json, or run \`efferent status --url <endpoint>\` there once`,
    );
  }
  const state = { endpoint, days: stored?.days ?? {}, syncedAt: stored?.syncedAt ?? "" };
  // Written here rather than by whichever command happens to save afterwards.
  // "After that it is remembered" has to be true of the first command a person
  // runs, not only of the ones that keep a mirror.
  if (endpoint !== stored?.endpoint) await write(STATE, state);
  return state;
}

export async function saveState(state: MirrorState): Promise<void> {
  await write(STATE, { ...state, syncedAt: new Date().toISOString() });
}

// MARK: - The mirror, one file per day

export async function writeDay(day: string, events: Event[]): Promise<void> {
  await privateDirectory(`${HOME}/${DAYS}`);
  // Through a temporary file: a day truncated by an interrupted write would look
  // like a day on which almost nothing happened.
  const temporary = `${HOME}/${DAYS}/${day}.partial`;
  await Deno.writeTextFile(
    temporary,
    events.map((event) => JSON.stringify(event)).join("\n") + "\n",
  );
  await Deno.chmod(temporary, 0o600);
  await Deno.rename(temporary, `${HOME}/${DAYS}/${day}.ndjson`);
}

async function privateDirectory(path: string): Promise<void> {
  await Deno.mkdir(path, { recursive: true, mode: 0o700 });
  // mkdir's mode applies only when it creates the last component. Tighten an
  // existing reader too, because an older release created these directories
  // through the process umask and commonly left them at 0755.
  await Deno.chmod(path, 0o700);
}

export async function readDay(day: string): Promise<Event[]> {
  try {
    const text = await Deno.readTextFile(`${HOME}/${DAYS}/${day}.ndjson`);
    return expand(text) as Event[];
  } catch {
    return [];
  }
}

/** The mirrored days inside a range, in order. */
export async function mirroredDays(range: { from?: string; to?: string }): Promise<string[]> {
  const days: string[] = [];
  try {
    for await (const entry of Deno.readDir(`${HOME}/${DAYS}`)) {
      const day = entry.name.replace(/\.ndjson$/, "");
      if (!entry.isFile || day === entry.name || !isDay(day)) continue;
      if (range.from && day < range.from) continue;
      if (range.to && day > range.to) continue;
      days.push(day);
    }
  } catch {
    return [];
  }
  return days.sort();
}

// MARK: - The archive, as something to read from

export interface Archive {
  bucket: string;
  day(name: string): Promise<{ day: string; events: Event[] }>;
  list(range: { from?: string; to?: string }): Promise<DayEntry[]>;
  several(names: string[], width?: number): AsyncGenerator<{ day: string; events: Event[] }>;
  stats(): Promise<Stats>;
}

export async function openArchive(endpoint: string): Promise<Archive> {
  const reading = await load<ReadingKey>("reading-key.json");
  const readingPublic = fromBase64url(reading.readingPublic);
  const bucket = await bucketId(readingPublic);
  const privateRaw = await rawPrivateKey(fromBase64url(reading.readingPrivate));

  async function day(name: string): Promise<{ day: string; events: Event[] }> {
    const response = await fetch(`${endpoint}/b/${bucket}/d/${name}`);
    if (!response.ok) {
      throw new Error(`${name}: ${response.status} ${await response.text()}`);
    }

    const plaintext = await decompress(
      await open(
        privateRaw,
        readingPublic,
        new Uint8Array(await response.arrayBuffer()),
        associatedData(bucket, name),
      ),
    );
    const events = expand(new TextDecoder().decode(plaintext)) as Event[];
    return { day: name, events };
  }

  /**
   * Which days the archive has in a range.
   *
   * Following `next` until it comes back null is not optional. A listing that
   * stopped at its first page would report the rest of a decade as nothing at
   * all, and would do it without an error.
   */
  async function list(range: { from?: string; to?: string }): Promise<DayEntry[]> {
    const entries: DayEntry[] = [];
    let after: string | undefined;
    for (;;) {
      const parameters = new URLSearchParams();
      if (after) parameters.set("after", after);
      else if (range.from) parameters.set("from", range.from);
      if (range.to) parameters.set("to", range.to);

      const page = await fetchJSON<{ days: DayEntry[]; next: string | null }>(
        `${endpoint}/b/${bucket}/days?${parameters}`,
      );
      entries.push(...page.days);
      if (page.next === null) return entries;
      after = page.next;
    }
  }

  /**
   * Named days, several at a time, in the order they were asked for.
   *
   * One at a time is what makes a long history slow: the cost is a round trip
   * per day and almost nothing else, so waiting for each before starting the
   * next spends the whole time idle. The window is small on purpose — enough to
   * fill the link, not enough to look like an attack on it.
   */
  async function* several(names: string[], width = 8) {
    for (let start = 0; start < names.length; start += width) {
      const window = await Promise.all(names.slice(start, start + width).map(day));
      for (const fetched of window) yield fetched;
    }
  }

  const stats = () => fetchJSON<Stats>(`${endpoint}/b/${bucket}/stats`);

  return { bucket, day, list, several, stats };
}

export async function fetchJSON<T>(url: string): Promise<T> {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`${url}: ${response.status} ${await response.text()}`);
  return await response.json() as T;
}
