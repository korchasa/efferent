/**
 * The reading side, as a command line tool.
 *
 * This is where the reading key lives. It never leaves this machine: the phone
 * only ever gets the public half, and the bucket service only gets ciphertext.
 *
 * The service is an archive, not a letterbox, so this tool is a mirror of it
 * rather than a viewer. `sync` walks everything new, decrypts it and folds it
 * into a local file; `query` answers from that file with the network switched
 * off. An agent that wants "how did I sleep last week" should be able to ask
 * without downloading a year of history first, and without the machine holding
 * the reading key being awake at the moment the phone happened to send.
 */

import { bucketId, parseObjectName } from "../protocol/ids.ts";
import { base64url, fromBase64url, signUpload, type UploadHeader } from "../protocol/signing.ts";
import { associatedData, open, seal } from "../protocol/sealedbox.ts";
import { compress, decompress } from "../protocol/framing.ts";
import { frame, type ManifestEntry, unframe } from "../protocol/manifest.ts";
import qrcode from "qrcode-terminal";

interface ReadingKey {
  /** X25519 private key, pkcs8. The whole secret of the system. */
  readingPrivate: string;
  readingPublic: string;
}

interface WriterKey {
  /** Ed25519 private key, pkcs8. Stands in for the one a phone would make. */
  writerPrivate: string;
  writerPublic: string;
}

/** Where the mirror stopped, so the next sync asks only for what came after. */
interface MirrorState {
  endpoint: string;
  cursor: number;
  syncedAt: string;
}

/** One fact, as it left the phone, plus the sequence number it travelled under. */
interface Event {
  id: string;
  seq: number;
  v: number;
  type: string;
  metric?: string;
  bucket?: string;
  start?: string;
  end?: string;
  [key: string]: unknown;
}

const HOME = Deno.env.get("EFFERENT_HOME") ?? ".efferent";
const EVENTS = "events.ndjson";
const STATE = "mirror.json";

if (import.meta.main) await main(Deno.args);

async function main(args: string[]): Promise<void> {
  const [command, ...rest] = args;
  const options = parseOptions(rest);

  switch (command) {
    case "keygen":
      return await keygen();
    case "pair":
      return await pair(requireOption(options, "url"));
    case "send":
      return await send(requireOption(options, "url"), Number(options.count ?? "3"));
    case "read":
      return await read(requireOption(options, "url"), Number(options.after ?? "0"));
    case "sync":
      return await sync(options.url);
    case "query":
      return await query(options);
    case "ask":
      return await ask(options);
    case "status":
      return await status(options.url);
    default:
      console.error(
        [
          "usage:",
          "  efferent keygen                       create the reading key pair",
          "  efferent pair --url <endpoint>        print what the phone needs",
          "  efferent send --url <endpoint>        pretend to be a phone",
          "  efferent read --url <endpoint>        fetch and decrypt, straight to stdout",
          "  efferent sync [--url <endpoint>]      fold everything new into the local mirror",
          "  efferent status [--url <endpoint>]    what the archive holds, and how far the mirror got",
          "  efferent query [filters]              answer from the mirror, offline",
          "  efferent ask [filters]                answer from the archive, fetching only what matches",
          "",
          "filters (both query and ask):",
          "  --type <health.agg|health.sample>    --metric <steps|sleep|…>",
          "  --bucket <hour|day>                  --since <ISO date>  --until <ISO date>",
          "  --limit <n>                          --format <ndjson|summary>",
        ].join("\n"),
      );
      Deno.exit(2);
  }
}

// MARK: - Commands

async function keygen(): Promise<void> {
  const pair = await crypto.subtle.generateKey({ name: "X25519" }, true, [
    "deriveBits",
  ]) as CryptoKeyPair;
  const key: ReadingKey = {
    readingPrivate: base64url(
      new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey)),
    ),
    readingPublic: base64url(new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey))),
  };
  await write("reading-key.json", key);

  console.log(`bucket: ${await bucketId(fromBase64url(key.readingPublic))}`);
  console.log(`saved:  ${HOME}/reading-key.json — this file is the only way to read the data`);
}

async function pair(url: string): Promise<void> {
  const key = await load<ReadingKey>("reading-key.json");
  // Nothing here is secret: an address and a public key. That is the point —
  // this payload can be shown on a screen or photographed without consequence,
  // which is why pairing is a scan rather than a careful transfer.
  const payload = JSON.stringify({ v: 1, url, pk: key.readingPublic });

  await new Promise<void>((resolve) => {
    qrcode.generate(payload, { small: true }, (code: string) => {
      console.log(code);
      resolve();
    });
  });
  console.log(`bucket: ${await bucketId(fromBase64url(key.readingPublic))}`);
  console.log(payload);
}

async function send(url: string, count: number): Promise<void> {
  const reading = await load<ReadingKey>("reading-key.json");
  const writer = await loadOrCreateWriter();
  const bucket = await bucketId(fromBase64url(reading.readingPublic));

  const seqFrom = Number(Deno.env.get("EFFERENT_SEQ_FROM") ?? "1");
  const seqTo = seqFrom + count - 1;
  const day = 24 * 60 * 60;
  const start = Math.floor(Date.now() / 1000) - count * day;
  const events = Array.from({ length: count }, (_, index) => {
    const seq = seqFrom + index;
    return {
      id: `agg:steps:probe-${seq}:h`,
      seq,
      v: 1,
      type: "health.agg",
      metric: "steps",
      start: new Date((start + index * day) * 1000).toISOString(),
      end: new Date((start + (index + 1) * day) * 1000).toISOString(),
      value: 100 + seq,
      unit: "count",
    };
  });
  const lines = events.map((event) => JSON.stringify(event)).join("\n") + "\n";

  const sealed = await seal(
    fromBase64url(reading.readingPublic),
    await compress(new TextEncoder().encode(lines)),
    associatedData(bucket, seqFrom, seqTo),
  );
  // Framed exactly as a phone frames it, manifest included — a probe that
  // skipped it would exercise a path no device uses.
  const manifest: ManifestEntry[] = events.map((event) => ({
    seq: event.seq,
    type: event.type,
    metric: event.metric,
    start: Math.floor(Date.parse(event.start) / 1000),
    end: Math.floor(Date.parse(event.end) / 1000),
  }));
  const body = await frame(manifest, sealed);

  const header: UploadHeader = { bucket, seqFrom, seqTo, timestamp: Math.floor(Date.now() / 1000) };
  const privateKey = await crypto.subtle.importKey(
    "pkcs8",
    fromBase64url(writer.writerPrivate) as BufferSource,
    { name: "Ed25519" },
    false,
    ["sign"],
  );

  const response = await fetch(`${url}/b/${bucket}`, {
    method: "POST",
    headers: {
      "content-type": "application/octet-stream",
      "x-efferent-seq-from": String(seqFrom),
      "x-efferent-seq-to": String(seqTo),
      "x-efferent-timestamp": String(header.timestamp),
      "x-efferent-writer": writer.writerPublic,
      "x-efferent-signature": base64url(await signUpload(privateKey, header, body)),
    },
    // A typed-array body is perfectly valid here; the cast only settles a
    // disagreement between the DOM lib's BodyInit and Deno's Uint8Array.
    body: body as BodyInit,
  });

  console.log(`${response.status} ${await response.text()}`);
  if (!response.ok) Deno.exit(1);
}

async function read(url: string, after: number): Promise<void> {
  const reader = await openArchive(url);
  for await (const batch of reader.walk(after)) {
    await Deno.stdout.write(
      new TextEncoder().encode(
        batch.lines.map((event) => JSON.stringify(event)).join("\n") + "\n",
      ),
    );
  }
}

/**
 * Fold everything new into the local mirror.
 *
 * Runs from wherever the mirror stopped, so calling it twice in a row costs one
 * listing and nothing else. Safe to interrupt: the cursor only moves once a
 * batch has been written down.
 */
async function sync(url?: string): Promise<void> {
  const state = await loadState(url);
  const reader = await openArchive(state.endpoint);

  const events = await loadEvents();
  const before = events.size;
  let batches = 0;
  let cursor = state.cursor;

  for await (const batch of reader.walk(cursor)) {
    for (const event of batch.lines) apply(events, event);
    cursor = batch.seqTo;
    batches++;
    // Written after every batch rather than at the end: a sync interrupted
    // halfway should cost the batches it did not reach, not the ones it did.
    await saveEvents(events);
    await write(STATE, { ...state, cursor, syncedAt: new Date().toISOString() });
  }

  console.log(
    batches === 0
      ? `already up to date at seq ${cursor}, ${events.size} events`
      : `${batches} batch${batches === 1 ? "" : "es"} folded in: ${events.size} events ` +
        `(${events.size - before >= 0 ? "+" : ""}${events.size - before}), now at seq ${cursor}`,
  );
}

/** What the archive holds and how much of it is mirrored here. */
async function status(url?: string): Promise<void> {
  const state = await loadState(url);
  const reading = await load<ReadingKey>("reading-key.json");
  const bucket = await bucketId(fromBase64url(reading.readingPublic));

  const remote = await fetchJSON<{
    exists: boolean;
    objects: number;
    bytes: number;
    lowestSeq: number | null;
    highestSeq: number;
    complete: boolean;
  }>(`${state.endpoint}/b/${bucket}/stats`);

  const events = await loadEvents();
  const spans = [...events.values()].map((event) => event.start).filter((s): s is string => !!s)
    .sort();

  console.log(`bucket   ${bucket}`);
  console.log(
    `archive  ${remote.objects}${remote.complete ? "" : "+"} batches, ` +
      `${(remote.bytes / 1024).toFixed(0)} KiB, up to seq ${remote.highestSeq}`,
  );
  console.log(
    `mirror   ${events.size} events, up to seq ${state.cursor}` +
      (state.cursor < remote.highestSeq
        ? `  — ${remote.highestSeq - state.cursor} behind, run sync`
        : "  — up to date"),
  );
  if (spans.length > 0) {
    console.log(`covering ${spans[0].slice(0, 10)} … ${spans[spans.length - 1].slice(0, 10)}`);
  }
}

/** Answer from the mirror. No network, so it works on a plane and it is fast
 * enough to call in a loop. */
async function query(options: Record<string, string>): Promise<void> {
  report([...(await loadEvents()).values()].filter((event) => matches(event, options)), options);
}

/**
 * Answer from the archive, without a mirror.
 *
 * The service keeps an index of when each event happened and what kind it is,
 * so it can name the handful of batches worth downloading. A question about one
 * August then costs those batches instead of the whole decade — which is what
 * made holding a full local copy feel obligatory in the first place.
 *
 * The narrowing the service does is coarse: it answers with whole batches, and
 * a batch holds whatever else was queued beside the events asked for. The exact
 * filtering happens here, after decryption, because only here is there anything
 * to filter.
 */
async function ask(options: Record<string, string>): Promise<void> {
  const state = await loadState(options.url);
  const archive = await openArchive(state.endpoint);

  const parameters = new URLSearchParams({
    from: options.since ?? "",
    to: options.until ?? "",
  });
  if (options.metric) parameters.set("metric", options.metric);
  if (options.type) parameters.set("type", options.type);

  const found = await fetchJSON<{
    objects: { name: string; count: number }[];
    events: number;
    truncated: boolean;
  }>(`${state.endpoint}/b/${archive.bucket}/find?${parameters}`);

  if (found.truncated) {
    console.error(
      `the service named ${found.objects.length} batches and stopped counting there — ` +
        "ask for a narrower stretch of time to see the rest",
    );
  }

  const collected: Event[] = [];
  for await (const batch of archive.several(found.objects.map((object) => object.name))) {
    for (const event of batch.lines) {
      if (matches(event, options)) collected.push(event);
    }
  }
  console.error(
    `${found.objects.length} batches fetched, ${collected.length} of ${found.events} events kept`,
  );
  report(collected, options);
}

function matches(event: Event, options: Record<string, string>): boolean {
  if (options.type && event.type !== options.type) return false;
  if (options.metric && event.metric !== options.metric) return false;
  if (options.bucket && event.bucket !== options.bucket) return false;
  if (options.since && (event.start ?? "") < options.since) return false;
  if (options.until && (event.start ?? "") > options.until) return false;
  return true;
}

function report(events: Event[], options: Record<string, string>): void {
  const ordered = events.sort((left, right) =>
    (left.start ?? "").localeCompare(right.start ?? "") || left.seq - right.seq
  );

  if (options.format === "summary") {
    const counts = new Map<string, number>();
    for (const event of ordered) {
      const key = `${event.type}${event.metric ? ` ${event.metric}` : ""}${
        event.bucket ? `/${event.bucket}` : ""
      }`;
      counts.set(key, (counts.get(key) ?? 0) + 1);
    }
    console.log(`${ordered.length} events`);
    for (const [key, count] of [...counts].sort((a, b) => b[1] - a[1])) {
      console.log(`  ${String(count).padStart(7)}  ${key}`);
    }
    return;
  }

  const limited = options.limit ? ordered.slice(0, Number(options.limit)) : ordered;
  const out = limited.map((event) => JSON.stringify(event)).join("\n");
  if (out) console.log(out);
}

// MARK: - The archive, as something to walk

/**
 * A reader over the whole bucket, page by page.
 *
 * The paging matters more than it looks. A listing that fetches one page and
 * filters it can only ever return the beginning of an archive, and it reports
 * that as an empty answer — so a reader that does not follow `next` quietly
 * stops seeing data the moment the history outgrows a page.
 */
async function openArchive(endpoint: string) {
  const reading = await load<ReadingKey>("reading-key.json");
  const readingPublic = fromBase64url(reading.readingPublic);
  const bucket = await bucketId(readingPublic);
  const privateKey = await crypto.subtle.importKey(
    "pkcs8",
    fromBase64url(reading.readingPrivate) as BufferSource,
    { name: "X25519" },
    false,
    ["deriveBits"],
  );

  async function batch(name: string) {
    const range = parseObjectName(name);
    if (!range) throw new Error(`the service returned an object it cannot name: ${name}`);

    const response = await fetch(`${endpoint}/b/${bucket}/o/${name}`);
    if (!response.ok) {
      throw new Error(`${name}: ${response.status} ${await response.text()}`);
    }

    // The manifest in front of the sealed blob is what the service reads to
    // answer questions about time and kind. It holds nothing that is not also
    // in the events themselves, so here it is stepped over.
    const { sealed } = unframe(new Uint8Array(await response.arrayBuffer()));
    const plaintext = await decompress(
      await open(
        privateKey,
        readingPublic,
        sealed,
        associatedData(bucket, range.seqFrom, range.seqTo),
      ),
    );
    const lines = new TextDecoder().decode(plaintext).trim().split("\n")
      .filter((line) => line.length > 0)
      .map((line) => JSON.parse(line) as Event);
    return { ...range, lines };
  }

  async function* walk(after: number) {
    let cursor = after;
    for (;;) {
      const listing = await fetchJSON<
        { objects: { name: string }[]; next: number | null }
      >(`${endpoint}/b/${bucket}/objects?after=${cursor}`);
      if (listing.objects.length === 0) return;

      for (const object of listing.objects) {
        const fetched = await batch(object.name);
        yield fetched;
        cursor = fetched.seqTo;
      }

      if (listing.next === null) return;
      cursor = listing.next;
    }
  }

  /**
   * Named batches, several at a time, in the order they were asked for.
   *
   * One at a time is what made a long archive slow: the cost is a round trip
   * per batch and almost nothing else, so waiting for each before starting the
   * next spends the whole time idle. The window is small on purpose — enough to
   * fill the link, not enough to look like an attack on it.
   */
  async function* several(names: string[], width = 8) {
    for (let start = 0; start < names.length; start += width) {
      const window = await Promise.all(names.slice(start, start + width).map(batch));
      for (const fetched of window) yield fetched;
    }
  }

  return { bucket, batch, walk, several };
}

/**
 * Fold one event into the mirror.
 *
 * A deletion carries the id of the sample it removes and nothing else, so it is
 * applied rather than stored — keeping it would mean every reader had to know
 * to look for it, which is exactly the bookkeeping the shared id was meant to
 * avoid.
 */
function apply(events: Map<string, Event>, event: Event): void {
  if (event.type === "health.delete") {
    events.delete(event.id);
    return;
  }
  events.set(event.id, event);
}

// MARK: - Storage

async function loadState(url?: string): Promise<MirrorState> {
  let stored: MirrorState | null = null;
  try {
    stored = await load<MirrorState>(STATE);
  } catch {
    stored = null;
  }
  const endpoint = url ?? stored?.endpoint;
  if (!endpoint) {
    console.error("error: --url is required the first time; after that it is remembered");
    Deno.exit(2);
  }
  return { endpoint, cursor: stored?.cursor ?? 0, syncedAt: stored?.syncedAt ?? "" };
}

async function loadEvents(): Promise<Map<string, Event>> {
  const events = new Map<string, Event>();
  let text: string;
  try {
    text = await Deno.readTextFile(`${HOME}/${EVENTS}`);
  } catch {
    return events;
  }
  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    const event = JSON.parse(line) as Event;
    events.set(event.id, event);
  }
  return events;
}

async function saveEvents(events: Map<string, Event>): Promise<void> {
  const ordered = [...events.values()].sort((left, right) => left.seq - right.seq);
  await Deno.mkdir(HOME, { recursive: true });
  // Through a temporary file: a mirror truncated by an interrupted write would
  // look like an archive that lost its history.
  const temporary = `${HOME}/${EVENTS}.partial`;
  await Deno.writeTextFile(
    temporary,
    ordered.map((event) => JSON.stringify(event)).join("\n") + "\n",
  );
  await Deno.rename(temporary, `${HOME}/${EVENTS}`);
}

async function loadOrCreateWriter(): Promise<WriterKey> {
  try {
    return await load<WriterKey>("writer-key.json");
  } catch {
    const pair = await crypto.subtle.generateKey({ name: "Ed25519" }, true, [
      "sign",
      "verify",
    ]) as CryptoKeyPair;
    const key: WriterKey = {
      writerPrivate: base64url(
        new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey)),
      ),
      writerPublic: base64url(new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey))),
    };
    await write("writer-key.json", key);
    return key;
  }
}

async function load<T>(name: string): Promise<T> {
  return JSON.parse(await Deno.readTextFile(`${HOME}/${name}`)) as T;
}

async function write(name: string, value: unknown): Promise<void> {
  await Deno.mkdir(HOME, { recursive: true });
  await Deno.writeTextFile(`${HOME}/${name}`, JSON.stringify(value, null, 2) + "\n");
  await Deno.chmod(`${HOME}/${name}`, 0o600);
}

// MARK: - Plumbing

async function fetchJSON<T>(url: string): Promise<T> {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`${url}: ${response.status} ${await response.text()}`);
  return await response.json() as T;
}

function parseOptions(args: string[]): Record<string, string> {
  const options: Record<string, string> = {};
  for (let index = 0; index < args.length; index++) {
    const argument = args[index];
    if (!argument.startsWith("--")) continue;
    options[argument.slice(2)] = args[index + 1] ?? "";
    index++;
  }
  return options;
}

function requireOption(options: Record<string, string>, name: string): string {
  const value = options[name];
  if (!value) {
    console.error(`error: --${name} is required`);
    Deno.exit(2);
  }
  return value;
}
