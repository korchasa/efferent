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
import { base64url, canonicalEdit, fromBase64url, signMessage } from "../protocol/signing.ts";
import { associatedData, open, rawPrivateKey, seal } from "../protocol/sealedbox.ts";
import { decompress } from "../protocol/framing.ts";
import { expand } from "../protocol/day.ts";
import {
  editAssociatedData,
  type EditItem,
  type Outcome,
  type OutcomeCode,
  packEdits,
  validateItems,
} from "../protocol/edits.ts";

export { dayBefore, isDay };

export interface ReadingKey {
  /** X25519 private key, pkcs8. The whole secret of the system. */
  readingPrivate: string;
  readingPublic: string;
}

/** The key that signs edits. It cannot open a day; whoever holds it can ask
 * the phone to write into Health, which is why it is kept like the other one. */
export interface EditorKey {
  /** Ed25519 private key, pkcs8. */
  editorPrivate: string;
  editorPublic: string;
}

/** What one item was about, kept locally so a later session can find the id
 * it needs to replace or delete a sample it wrote. Never a value. */
export interface SubmittedItem {
  op: "put" | "delete";
  id: string;
  metric?: string;
  /** The UTC day the item began on. The phone cuts days in its own zone, so
   * this is a place to look rather than the day the archive will show. */
  day?: string;
}

/** One edit this profile submitted, as the service named it. */
export interface SubmittedEdit {
  name: string;
  at: string;
  items: SubmittedItem[];
}

/** One line of the service's listing, with what this profile knows about it. */
export interface EditEntry {
  name: string;
  bytes: number;
  at: string;
  status: "pending" | "applied" | "partial" | "failed";
  applied?: number;
  refused?: number;
  /** Present when this profile submitted the edit. */
  items?: SubmittedItem[];
  /** Present when the phone refused something: which item, which word, and the
   * id it carried when this profile submitted it. */
  refusals?: { item: number; code: OutcomeCode; id?: string }[];
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
const EDITOR = "editor-key.json";
const EDITS = "edits.json";

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
 *
 * Laid out unless asked otherwise, because these are the files somebody opens
 * when the reader is behaving strangely. `compact` is for the one that is not
 * read by people: laying that one out tripled it, from 1.3 MB to 4.3 MB, and it
 * is read whole every time it is used.
 */
export async function write(
  name: string,
  value: unknown,
  options: { compact?: boolean } = {},
): Promise<void> {
  await privateDirectory(HOME);
  const temporary = `${HOME}/${name}.partial`;
  const text = options.compact ? JSON.stringify(value) : JSON.stringify(value, null, 2);
  await Deno.writeTextFile(temporary, text + "\n");
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

// MARK: - The editor key and the record of edits

/**
 * The key that signs edits, or a sentence saying why there is none.
 *
 * A reader connected from a three-field handoff has no such key: the phone
 * that made that handoff did not write yet. The cure is a fresh handoff from
 * the phone, which `installConnectionHandoff` adds to this reader without
 * touching the rest.
 */
export async function loadEditor(): Promise<EditorKey> {
  try {
    return await load<EditorKey>(EDITOR);
  } catch {
    throw new Error(
      `no editor key in ${resolve(HOME)} — the handoff this reader was connected with predates ` +
        `writing; ask the phone for a fresh one and run \`efferent connect\` with it`,
    );
  }
}

/** Every edit this profile submitted, oldest first. */
export async function submittedEdits(): Promise<SubmittedEdit[]> {
  try {
    return await load<SubmittedEdit[]>(EDITS);
  } catch {
    return [];
  }
}

async function recordSubmitted(edit: SubmittedEdit): Promise<void> {
  await write(EDITS, [...await submittedEdits(), edit]);
}

function summarize(item: EditItem): SubmittedItem {
  if (item.op === "delete") return { op: "delete", id: item.id };
  return {
    op: "put",
    id: item.id,
    metric: item.metric,
    day: new Date(item.start * 1000).toISOString().slice(0, 10),
  };
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

/**
 * Every mirrored day with a fingerprint of the file it is in, in order.
 *
 * The fingerprint is size and modification time, which is the ordinary way to
 * ask whether a file has changed, and it is deliberately not the archive's
 * upload time: a day can sit in the mirror with no record of where it came from
 * — copied by an older release, or left behind when the archive lost it — and a
 * question about the file is the one thing always answerable about a file.
 *
 * A stat apiece rather than a read: 3 914 days cost 84 ms this way against two
 * seconds to open them all.
 */
export async function mirrorVersions(): Promise<Map<string, string>> {
  const versions = new Map<string, string>();
  try {
    for await (const entry of Deno.readDir(`${HOME}/${DAYS}`)) {
      const day = entry.name.replace(/\.ndjson$/, "");
      if (!entry.isFile || day === entry.name || !isDay(day)) continue;
      const stat = await Deno.stat(`${HOME}/${DAYS}/${entry.name}`);
      versions.set(day, `${stat.size}:${stat.mtime?.getTime() ?? 0}`);
    }
  } catch {
    return versions;
  }
  return new Map([...versions].sort(([left], [right]) => left.localeCompare(right)));
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
  /** Seal, sign and hand over an edit; the service answers with its name. */
  submitEdits(items: EditItem[]): Promise<{ name: string; at: string; bytes: number }>;
  /** One page of the queue and, with `status: "all"`, of what became of it. */
  edits(
    options: { after?: string; status?: "pending" | "all"; limit?: number },
  ): Promise<{ edits: EditEntry[]; next: string | null }>;
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

  /**
   * An edit, the way the phone will check it: sealed to the reading key with
   * the bucket in the tag, signed by the editor key over the canonical message.
   *
   * Validated before anything is sealed, so a wrong unit is a sentence here
   * rather than a refusal code from the phone a day later. Written down
   * locally afterwards, because the service knows an edit by a name and a
   * count and nothing else — the ids inside it are the agent's, and a later
   * session has no other way to find them.
   */
  async function submitEdits(
    items: EditItem[],
  ): Promise<{ name: string; at: string; bytes: number }> {
    validateItems(items);
    const editor = await loadEditor();
    const sealed = await seal(readingPublic, await packEdits(items), editAssociatedData(bucket));

    const timestamp = Math.floor(Date.now() / 1000);
    const signingKey = await crypto.subtle.importKey(
      "pkcs8",
      fromBase64url(editor.editorPrivate) as BufferSource,
      { name: "Ed25519" },
      false,
      ["sign"],
    );
    const signature = await signMessage(signingKey, await canonicalEdit(bucket, timestamp, sealed));

    const response = await fetch(`${endpoint}/b/${bucket}/edits`, {
      method: "POST",
      headers: {
        "content-type": "application/octet-stream",
        "x-efferent-timestamp": String(timestamp),
        "x-efferent-editor": editor.editorPublic,
        "x-efferent-signature": base64url(signature),
      },
      body: sealed as BodyInit,
    });
    if (!response.ok) {
      throw new Error(
        `the service refused the edit: ${response.status} ${await refusal(response)}`,
      );
    }
    const answer = await response.json() as { name: string; at: string; bytes: number };
    await recordSubmitted({ name: answer.name, at: answer.at, items: items.map(summarize) });
    return answer;
  }

  /**
   * The service's listing, with this profile's own record laid over it.
   *
   * An edit the phone refused part of is worth a second request: the listing
   * carries counts, the outcome carries which item and which word, and with the
   * local record the item becomes an id the agent recognises.
   */
  async function edits(
    options: { after?: string; status?: "pending" | "all"; limit?: number },
  ): Promise<{ edits: EditEntry[]; next: string | null }> {
    const parameters = new URLSearchParams();
    if (options.after) parameters.set("after", options.after);
    if (options.status) parameters.set("status", options.status);
    if (options.limit) parameters.set("limit", String(options.limit));
    const page = await fetchJSON<{ edits: EditEntry[]; next: string | null }>(
      `${endpoint}/b/${bucket}/edits?${parameters}`,
    );

    const known = new Map((await submittedEdits()).map((edit) => [edit.name, edit.items]));
    const entries: EditEntry[] = [];
    for (const entry of page.edits) {
      const items = known.get(entry.name);
      const laid: EditEntry = items ? { ...entry, items } : { ...entry };
      if ((entry.refused ?? 0) > 0) {
        const outcome = await fetchJSON<Outcome>(`${endpoint}/b/${bucket}/o/${entry.name}`);
        laid.refusals = outcome.refused.map((refusal) => ({
          ...refusal,
          ...(items?.[refusal.item] ? { id: items[refusal.item].id } : {}),
        }));
      }
      entries.push(laid);
    }
    return { edits: entries, next: page.next };
  }

  return { bucket, day, list, several, stats, submitEdits, edits };
}

/** The one sentence a refusal carries, or the status text when it carries none. */
async function refusal(response: Response): Promise<string> {
  const text = await response.text();
  try {
    const parsed = JSON.parse(text) as { error?: unknown };
    if (typeof parsed.error === "string") return parsed.error;
  } catch {
    // not JSON
  }
  return text || response.statusText;
}

export async function fetchJSON<T>(url: string): Promise<T> {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`${url}: ${response.status} ${await response.text()}`);
  return await response.json() as T;
}
