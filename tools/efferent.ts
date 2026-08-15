/**
 * The reading side, as a command line tool.
 *
 * This is where the reading key lives. It never leaves this machine: the phone
 * only ever gets the public half, and the bucket service only gets ciphertext.
 *
 * Everything is addressed by day, which is what makes both commands cheap.
 * `ask` goes to the service and downloads only the days a question covers.
 * `sync` keeps a local copy — one file per day — so `query` can answer with the
 * network switched off. Neither has a position to keep track of: a day in the
 * mirror is either the one the archive holds or an older version of it, and the
 * archive says which by when it was last written.
 */

import { bucketId } from "../protocol/ids.ts";
import { base64url, fromBase64url, signUpload, type UploadHeader } from "../protocol/signing.ts";
import { associatedData, seal } from "../protocol/sealedbox.ts";
import { compress } from "../protocol/framing.ts";
import { packDays, type SealedDay } from "../protocol/batch.ts";
import {
  dayBefore,
  type Event,
  HOME,
  isDay,
  load,
  loadState,
  mirroredDays,
  openArchive,
  readDay,
  type ReadingKey,
  saveState,
  write,
  writeDay,
} from "./archive.ts";
import qrcode from "qrcode-terminal";

interface WriterKey {
  /** Ed25519 private key, pkcs8. Stands in for the one a phone would make. */
  writerPrivate: string;
  writerPublic: string;
}

if (import.meta.main) {
  // The reading layer throws where this tool used to exit, and a stack trace is
  // not an error message. One place turns it back into a line a person can act
  // on, which is what `fail` has always printed.
  try {
    await main(Deno.args);
  } catch (error) {
    fail(error instanceof Error ? error.message : String(error));
  }
}

async function main(args: string[]): Promise<void> {
  const [command, ...rest] = args;
  const options = parseOptions(rest);

  switch (command) {
    case "keygen":
      return await keygen();
    case "pair":
      return await pair(requireOption(options, "url"));
    case "send":
      return await send(requireOption(options, "url"), options.day ?? today());
    case "read":
      return await read(options);
    case "sync":
      return await sync(options);
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
          "  efferent send --url <endpoint>        pretend to be a phone, write days",
          "                [--day <d>[,<d>…]]      one request, however many days",
          "  efferent read --url <endpoint>        fetch and decrypt, straight to stdout",
          "  efferent sync [--url <endpoint>]      copy every day that changed since last time",
          "  efferent status [--url <endpoint>]    what the archive holds, and what the mirror does",
          "  efferent query [filters]              answer from the mirror, offline",
          "  efferent ask [filters]                answer from the archive, fetching only those days",
          "",
          "filters (query, ask and read):",
          "  --metric <steps|sleep|…>             --bucket <hour|day>",
          "  --since <YYYY-MM-DD>                 --until <YYYY-MM-DD>",
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

/**
 * Stand in for a phone: build some days and write them exactly as a device
 * would — sealed one by one, packed into a single request, signed as a whole.
 *
 * `--day` takes a list so the batching path can be reached by hand. A phone
 * sends a month at a time and this is the only other thing that ever writes.
 */
async function send(url: string, dayList: string): Promise<void> {
  const wanted = dayList.split(",").map((part) => part.trim()).filter(Boolean).sort();
  for (const day of wanted) if (!isDay(day)) fail(`--day must be YYYY-MM-DD, got ${day}`);

  const reading = await load<ReadingKey>("reading-key.json");
  const writer = await loadOrCreateWriter();
  const bucket = await bucketId(fromBase64url(reading.readingPublic));

  const batch: SealedDay[] = [];
  for (const day of wanted) {
    const events = Array.from({ length: 3 }, (_, hour) => ({
      id: `agg:steps:${day}T${String(9 + hour).padStart(2, "0")}:00:00Z:h`,
      v: 1,
      metric: "steps",
      bucket: "hour",
      start: `${day}T${String(9 + hour).padStart(2, "0")}:00:00Z`,
      end: `${day}T${String(10 + hour).padStart(2, "0")}:00:00Z`,
      value: 100 + hour,
      unit: "count",
    }));
    const lines = events.map((event) => JSON.stringify(event)).join("\n") + "\n";

    batch.push({
      day,
      // Each day is sealed to its own date, so a day cannot be moved or handed
      // back as another one. The batch around them binds nothing.
      blob: await seal(
        fromBase64url(reading.readingPublic),
        await compress(new TextEncoder().encode(lines)),
        associatedData(bucket, day),
      ),
    });
  }

  let body: Uint8Array;
  try {
    body = packDays(batch);
  } catch (error) {
    return fail(`those days do not make a request: ${(error as Error).message}`);
  }

  const header: UploadHeader = { bucket, days: wanted, timestamp: Math.floor(Date.now() / 1000) };
  const privateKey = await crypto.subtle.importKey(
    "pkcs8",
    fromBase64url(writer.writerPrivate) as BufferSource,
    { name: "Ed25519" },
    false,
    ["sign"],
  );

  const response = await fetch(`${url}/b/${bucket}/days`, {
    method: "PUT",
    headers: {
      "content-type": "application/octet-stream",
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

async function read(options: Record<string, string>): Promise<void> {
  const state = await loadState(options.url);
  const archive = await openArchive(state.endpoint);
  const listing = await archive.list(bounds(filterFrom(options)));

  const encoder = new TextEncoder();
  for await (const fetched of archive.several(listing.map((entry) => entry.day))) {
    const out = fetched.events.map((event) => JSON.stringify(event)).join("\n");
    if (out) await Deno.stdout.write(encoder.encode(out + "\n"));
  }
}

/**
 * Copy every day the archive has that this mirror does not, or has an older
 * version of.
 *
 * Interrupting it costs the days it had not reached and nothing else: each day
 * is its own file, and the record of what was taken is written as it goes.
 */
async function sync(options: Record<string, string>): Promise<void> {
  const state = await loadState(options.url);
  const archive = await openArchive(state.endpoint);

  const listing = await archive.list(bounds(filterFrom(options)));
  const stale = listing.filter((entry) => state.days[entry.day] !== entry.uploaded);
  if (stale.length === 0) {
    console.log(`already up to date: ${Object.keys(state.days).length} days mirrored`);
    return;
  }

  let taken = 0;
  for await (const fetched of archive.several(stale.map((entry) => entry.day))) {
    await writeDay(fetched.day, fetched.events);
    state.days[fetched.day] = stale.find((entry) => entry.day === fetched.day)!.uploaded;
    taken++;
    // Every eight, which is one window of fetches. Often enough that an
    // interrupted sync loses almost nothing, rarely enough that a long run is
    // not mostly writing a file about itself.
    if (taken % 8 === 0) await saveState(state);
  }
  await saveState(state);

  console.log(
    `${taken} day${taken === 1 ? "" : "s"} copied, ${Object.keys(state.days).length} mirrored`,
  );
}

/** What the archive holds and what the mirror has of it. */
async function status(url?: string): Promise<void> {
  const state = await loadState(url);
  const archive = await openArchive(state.endpoint);
  const remote = await archive.stats();

  const mirrored = Object.keys(state.days).sort();
  console.log(`bucket   ${archive.bucket}`);
  console.log(
    `archive  ${remote.days}${remote.complete ? "" : "+"} days, ` +
      `${(remote.bytes / 1024 / 1024).toFixed(1)} MiB` +
      (remote.firstDay ? `, ${remote.firstDay} … ${remote.lastDay}` : ""),
  );
  if (mirrored.length === 0) {
    console.log("mirror   nothing yet — run sync");
    return;
  }
  const behind = remote.days - mirrored.length;
  console.log(
    `mirror   ${mirrored.length} days, ${mirrored[0]} … ${mirrored[mirrored.length - 1]}` +
      (behind > 0 ? `  — ${behind} behind, run sync` : "  — up to date"),
  );
}

/** Answer from the mirror. No network, so it works on a plane and it is fast
 * enough to call in a loop. */
async function query(options: Record<string, string>): Promise<void> {
  const filter = filterFrom(options);
  const events: Event[] = [];
  for (const day of await mirroredDays(bounds(filter))) {
    for (const event of await readDay(day)) {
      if (matches(event, filter)) events.push(event);
    }
  }
  report(events, options);
}

/**
 * Answer from the archive, without a mirror.
 *
 * A question about one August costs that August: the days it covers are named
 * by their dates, so the service hands over thirty-one objects and nothing else.
 * It is still the exact filtering that happens here, after decryption — a day
 * holds everything that happened in it, and the service cannot see inside.
 */
async function ask(options: Record<string, string>): Promise<void> {
  const state = await loadState(options.url);
  const archive = await openArchive(state.endpoint);

  const filter = filterFrom(options);
  const listing = await archive.list(bounds(filter));
  const collected: Event[] = [];
  for await (const fetched of archive.several(listing.map((entry) => entry.day))) {
    for (const event of fetched.events) {
      if (matches(event, filter)) collected.push(event);
    }
  }
  console.error(`${listing.length} days fetched, ${collected.length} events kept`);
  report(collected, options);
}

/**
 * What a question asks for, in the terms everything here is addressed by.
 *
 * Both bounds are days and are inclusive. Anything finer would be a promise
 * this tool cannot keep anyway: the archive is cut into days, so an hour is
 * something to filter with `jq` after the fact rather than something to ask for.
 */
interface Filter {
  metric?: string;
  bucket?: string;
  since?: string;
  until?: string;
}

function filterFrom(options: Record<string, string>): Filter {
  return {
    metric: options.metric || undefined,
    bucket: options.bucket || undefined,
    since: options.since ? dayOf(options.since, "--since") : undefined,
    until: options.until ? dayOf(options.until, "--until") : undefined,
  };
}

/**
 * The days a question covers.
 *
 * One day earlier than asked for, always. A night of sleep that began before
 * midnight is in the evening's day, so a question about the 11th that fetched
 * only the 11th would miss the night it is asking about — and would do it
 * silently, which is the worst way for a query to be wrong.
 */
function bounds(filter: Filter): { from?: string; to?: string } {
  return {
    from: filter.since ? dayBefore(filter.since) : undefined,
    to: filter.until,
  };
}

function dayOf(value: string, option: string): string {
  const day = value.slice(0, 10);
  if (!isDay(day)) fail(`${option} must be a day, YYYY-MM-DD, got ${value}`);
  return day;
}

/**
 * Whether an event belongs in the answer.
 *
 * Time is compared by overlap, not by the start alone. An interval that began
 * the evening before still happened during the day being asked about, and
 * dropping it would quietly lose exactly the nights a sleep question is about.
 *
 * Compared day against day. An event's times are instants and a bound is a
 * date, so comparing the two as strings would put every reading of the 6th
 * after the 6th — a whole day dropped from a query that named it.
 */
function matches(event: Event, filter: Filter): boolean {
  if (filter.metric && event.metric !== filter.metric) return false;
  if (filter.bucket && event.bucket !== filter.bucket) return false;
  const start = (event.start ?? "").slice(0, 10);
  if (filter.since && (event.end ?? event.start ?? "").slice(0, 10) < filter.since) return false;
  if (filter.until && start > filter.until) return false;
  return true;
}

function report(events: Event[], options: Record<string, string>): void {
  const ordered = events.sort((left, right) =>
    (left.start ?? "").localeCompare(right.start ?? "") || left.id.localeCompare(right.id)
  );

  if (options.format === "summary") {
    const counts = new Map<string, number>();
    for (const event of ordered) {
      const key = `${event.metric ?? "?"}${event.bucket ? `/${event.bucket}` : ""}`;
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

// MARK: - The stand-in phone's own key

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

// MARK: - Plumbing

function today(): string {
  return new Date().toISOString().slice(0, 10);
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
  if (!value) fail(`--${name} is required`);
  return value;
}

function fail(message: string): never {
  console.error(`error: ${message}`);
  Deno.exit(2);
}
