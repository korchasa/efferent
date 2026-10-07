// What the Node tests share: keys, a handoff, a day packed the way the phone
// packs it, a profile on disk, and an archive that answers.
//
// The archive is a port of tests/fake_archive.py. It is a real HTTP service:
// it seals days with the reading key the way the phone does, pages its listing
// the way R2 forces the real one to, hands a range back in frames the way the
// Worker does, and can be told to fail a named day or a named page. Given a read
// key, it refuses every read not signed with it, as the service does once the
// phone has registered one. It runs in the test's own process, so anything that
// waits on it — a command line run as a child — must be awaited, never run
// synchronously, or the archive cannot answer.

import { execFile } from "node:child_process";
import {
  createCipheriv,
  createHash,
  createHmac,
  createPrivateKey,
  createPublicKey,
  diffieHellman,
  generateKeyPairSync,
  verify,
} from "node:crypto";
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { deflateRawSync } from "node:zlib";

import * as wire from "../../efferent.mjs";

export const CLIENT = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "efferent.mjs");

// MARK: - Keys and the handoff

function rawOf(privateKey) {
  return Buffer.from(privateKey.export({ format: "jwk" }).d, "base64url");
}

export function readingPair() {
  const { privateKey } = generateKeyPairSync("x25519");
  const secret = rawOf(privateKey);
  return { secret, publicRaw: wire.publicOf("x25519", secret) };
}

export function editorPair() {
  const { privateKey } = generateKeyPairSync("ed25519");
  const secret = rawOf(privateKey);
  return { secret, publicRaw: wire.publicOf("ed25519", secret) };
}

export function handoff(reading, editor, bucket = null, url = "https://efferent.example") {
  const lines = [
    "Instruction:",
    "Connect the supplied Efferent MCP and call setup_guide first. Keep the reading key local.",
    "",
    "MCP:",
    `${url}/mcp/b/${bucket || wire.bucketOf(reading.publicRaw)}`,
    "",
    "Reading key:",
    `efferent-reading-v1.${wire.toBase64url(reading.secret)}.${
      wire.toBase64url(reading.publicRaw)
    }`,
  ];
  if (editor) {
    lines.push(
      "",
      "Editor key:",
      `efferent-editor-v1.${wire.toBase64url(editor.secret)}.${wire.toBase64url(editor.publicRaw)}`,
    );
  }
  return lines.join("\n");
}

/** The envelope before RFC 9180, which the archive may still hold for old days. */
export function sealLegacy(recipientPublic, aad, plaintext) {
  const ephemeral = readingPair();
  const shared = diffieHellman({
    privateKey: createPrivateKey({
      key: Buffer.concat([
        Buffer.from("302e020100300506032b656e04220420", "hex"),
        ephemeral.secret,
      ]),
      format: "der",
      type: "pkcs8",
    }),
    publicKey: createPublicKey({
      key: Buffer.concat([Buffer.from("302a300506032b656e032100", "hex"), recipientPublic]),
      format: "der",
      type: "spki",
    }),
  });
  const salt = Buffer.concat([ephemeral.publicRaw, recipientPublic]);
  const prk = createHmac("sha256", salt).update(shared).digest();
  const key = createHmac("sha256", prk).update(
    Buffer.concat([Buffer.from("efferent/v1 sealed box"), Buffer.from([1])]),
  )
    .digest();
  const nonce = Buffer.alloc(12, 7);
  const cipher = createCipheriv("aes-256-gcm", key, nonce);
  cipher.setAAD(aad);
  const body = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  return Buffer.concat([Buffer.from([1]), ephemeral.publicRaw, nonce, body, cipher.getAuthTag()]);
}

// MARK: - A day, packed the way the phone packs it

const SHARED = ["metric", "bucket", "unit", "source"];
const COLUMNS = ["value", "stage", "activity", "duration"];

const epoch = (instant) => Math.floor(Date.parse(instant) / 1000);
const kindOf = (event) => (event.bucket === undefined || event.bucket === null ? "hk" : "agg");

function compare(left, right) {
  if (left === undefined && right === undefined) return 0;
  if (left === undefined) return -1;
  if (right === undefined) return 1;
  if (typeof left === "number" && typeof right === "number") return Math.sign(left - right);
  return String(left) < String(right) ? -1 : String(left) > String(right) ? 1 : 0;
}

function precedes(left, right) {
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

/** Layout 2, the columnar day, from events written as the reader sees them. */
export function packDay(events) {
  const groups = new Map();
  for (const event of events) {
    const key = JSON.stringify([kindOf(event), ...SHARED.map((name) => event[name] ?? null)]);
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(event);
  }
  const series = [];
  for (const key of [...groups.keys()].sort()) {
    const rows = [...groups.get(key)].sort(precedes);
    const first = epoch(rows[0].start);
    let previous = first;
    const entry = { k: kindOf(rows[0]) };
    for (const name of SHARED) if (rows[0][name] !== undefined) entry[name] = rows[0][name];
    entry.t0 = first;
    entry.t = rows.map((row) => {
      const step = epoch(row.start) - previous;
      previous = epoch(row.start);
      return step;
    });
    entry.d = rows.map((row) => epoch(row.end) - epoch(row.start));
    for (const name of COLUMNS) {
      if (rows.some((row) => row[name] !== undefined)) {
        entry[name] = rows.map((row) => row[name] ?? null);
      }
    }
    // Keys in order, as the phone writes them.
    series.push(
      Object.fromEntries(Object.entries(entry).sort(([left], [right]) => (left < right ? -1 : 1))),
    );
  }
  return JSON.stringify({ series, v: 2 });
}

export function total(metric, on, value, unit = "count") {
  return { metric, bucket: "day", value, unit, start: `${on}T00:00:00Z`, end: `${on}T23:59:59Z` };
}

export function hourly(metric, on, hour, value, unit = "count") {
  const start = `${on}T${String(hour).padStart(2, "0")}:00:00Z`;
  const end = `${on}T${String(hour).padStart(2, "0")}:59:59Z`;
  return { metric, bucket: "hour", value, unit, start, end };
}

export function record(metric, start, end, fields = {}) {
  return { metric, start, end, ...fields };
}

// MARK: - A profile on disk

/** A home holding the reading key (and the editor key, unless told otherwise), pointing at `endpoint`. */
export function makeHome({ endpoint, reading = readingPair(), editor = editorPair() } = {}) {
  const home = mkdtempSync(join(tmpdir(), "efferent-node-"));
  writeFileSync(
    join(home, "reading-key.json"),
    JSON.stringify({
      readingPrivate: wire.pkcs8("x25519", reading.secret),
      readingPublic: wire.toBase64url(reading.publicRaw),
    }),
  );
  if (editor) {
    writeFileSync(
      join(home, "editor-key.json"),
      JSON.stringify({
        editorPrivate: wire.pkcs8("ed25519", editor.secret),
        editorPublic: wire.toBase64url(editor.publicRaw),
      }),
    );
  }
  if (endpoint) {
    writeFileSync(join(home, "mirror.json"), JSON.stringify({ endpoint, days: {}, syncedAt: "" }));
  }
  return { home, reading, editor };
}

/** Run `body` with EFFERENT_HOME pointing at `home`, and put the old value back after. */
export async function within(home, body) {
  const before = process.env.EFFERENT_HOME;
  process.env.EFFERENT_HOME = home;
  try {
    return await body();
  } finally {
    if (before === undefined) delete process.env.EFFERENT_HOME;
    else process.env.EFFERENT_HOME = before;
  }
}

export function mirroredState(home) {
  return JSON.parse(readFileSync(join(home, "mirror.json"), "utf8"));
}

export function mirroredFiles(home) {
  try {
    return readdirSync(join(home, "days")).filter((name) => name.endsWith(".ndjson"))
      .map((name) => name.slice(0, -".ndjson".length)).sort();
  } catch {
    return [];
  }
}

export function writeMirroredDay(home, day, events) {
  mkdirSync(join(home, "days"), { recursive: true });
  writeFileSync(
    join(home, "days", `${day}.ndjson`),
    events.map((event) => `${JSON.stringify(event)}\n`).join(""),
  );
}

export function remove(home) {
  rmSync(home, { recursive: true, force: true });
}

/** The command line, run to completion in a child process, without blocking the archive. */
export function cli(home, args, input = undefined) {
  return new Promise((resolve) => {
    const child = execFile(
      process.execPath,
      [CLIENT, ...args],
      { env: { ...process.env, EFFERENT_HOME: home, NO_COLOR: "1" }, maxBuffer: 64 * 1024 * 1024 },
      (error, stdout, stderr) => resolve({ code: error ? error.code ?? 1 : 0, stdout, stderr }),
    );
    if (input !== undefined) child.stdin.end(input);
  });
}

// MARK: - An archive that answers

// Days per listing page. Small on purpose: the walk past a page boundary is
// the part being tested, and the real ceiling of 1000 would never reach it.
const PAGE = 2;
// Days per range answer, for the same reason.
const FRAME = 3;
// How long the archive holds a day open: long enough that a window of fetches
// overlaps, which is what makes the count of them mean something.
const DAY_DELAY = 25;

const dayBefore = (day) => wire.addDays(day, -1);
const sleepFor = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

function plusASecond(stamp) {
  return new Date(Date.parse(stamp) + 1000).toISOString();
}

export class FakeArchive {
  constructor(readingPublic) {
    this.readingPublic = readingPublic;
    this.bucket = wire.bucketOf(readingPublic);
    this.days = new Map();
    /** Every path asked for, in the order it was asked. */
    this.asked = [];
    /** Every day handed back, in the order sent. */
    this.sent = [];
    /** The public half of the read key, once "the phone" registered one. */
    this.reader = null;
    this.maxInFlight = 0;
    this.inFlight = 0;
    this.fault = {};
    /** What `stats` reports instead of the truth, as the real service does past what it walks. */
    this.floor = null;
    /** Edits posted, and the answers the archive gives to the edit endpoints. */
    this.posted = [];
    this.editAnswer = {
      status: 200,
      body: { name: "1756382400000-abcdefgh", at: "2026-08-28T12:00:00.000Z" },
    };
    this.editListing = { edits: [], next: null };
    this.outcomes = {};
    this.server = createServer((request, response) => this.answer(request, response));
  }

  async start() {
    await new Promise((resolve) => this.server.listen(0, "127.0.0.1", resolve));
    this.url = `http://127.0.0.1:${this.server.address().port}`;
    return this;
  }

  stop() {
    this.server.closeAllConnections?.();
    return new Promise((resolve) => this.server.close(resolve));
  }

  /** Put a day in, or replace one. A replacement gets a later upload time. */
  put(day, events) {
    const blob = Buffer.concat([
      Buffer.from([wire.SEALED_VERSION]),
      wire.hpkeSeal(
        this.readingPublic,
        wire.INFO,
        wire.associatedData(this.bucket, day),
        deflateRawSync(Buffer.from(packDay(events))),
      ),
    ]);
    const previous = this.days.get(day);
    const uploaded = previous ? plusASecond(previous.uploaded) : "2026-01-01T00:00:00.000Z";
    this.days.set(day, { blob, uploaded });
  }

  drop(day) {
    this.days.delete(day);
  }

  forget() {
    this.asked.length = 0;
    this.sent.length = 0;
    this.maxInFlight = 0;
  }

  ranges() {
    return this.asked.filter((path) => new URL(path, "http://x").pathname.endsWith("/d"));
  }

  listings() {
    return this.asked.filter((path) => path.includes("/days")).length;
  }

  fullListings() {
    return this.asked.filter((path) =>
      path.includes("/days") && !path.includes("from=") && !path.includes("after=")
    )
      .length;
  }

  stats() {
    const names = [...this.days.keys()].sort();
    let bytes = 0;
    for (const { blob } of this.days.values()) bytes += blob.length;
    return {
      exists: true,
      days: this.floor ?? names.length,
      bytes,
      firstDay: names[0] ?? null,
      lastDay: names.at(-1) ?? null,
      complete: this.floor === null,
    };
  }

  async answer(request, response) {
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const body = Buffer.concat(chunks);
    const target = request.url;
    this.asked.push(target);
    const split = new URL(target, "http://x");
    const parts = split.pathname.split("/").filter(Boolean);
    const query = Object.fromEntries(split.searchParams);
    if (parts.length < 3 || parts[0] !== "b" || parts[1] !== this.bucket) {
      return json(response, { error: "unknown" }, 404);
    }
    if (request.method === "POST" && parts[2] === "edits") {
      this.posted.push({ headers: request.headers, body });
      return json(response, this.editAnswer.body, this.editAnswer.status);
    }
    const refused = this.refusal(request, target);
    if (refused) return json(response, { error: refused[1] }, refused[0]);
    if (parts[2] === "stats") return json(response, this.stats());
    if (parts[2] === "days") return this.list(response, query);
    if (parts[2] === "d" && parts.length === 3) return await this.frame(response, query);
    if (parts[2] === "edits") return json(response, this.editListing);
    if (parts[2] === "o") {
      return json(
        response,
        this.outcomes[parts[3]] ?? { error: "no such outcome" },
        this.outcomes[parts[3]] ? 200 : 404,
      );
    }
    return json(response, { error: "unknown" }, 405);
  }

  refusal(request, target) {
    if (this.reader === null) return null;
    const reader = request.headers["x-efferent-reader"];
    const signature = request.headers["x-efferent-signature"];
    const timestamp = Number(request.headers["x-efferent-timestamp"] || 0);
    if (!reader || !signature) {
      return [401, "this archive answers only reads signed with its read key"];
    }
    if (!wire.fromBase64url(reader).equals(this.reader)) {
      return [403, "that is not this archive's read key"];
    }
    const key = createPublicKey({
      key: Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), this.reader]),
      format: "der",
      type: "spki",
    });
    const message = wire.canonicalRead(this.bucket, target, timestamp);
    if (!verify(null, Buffer.from(message), key, wire.fromBase64url(signature))) {
      return [403, "signature does not match the request"];
    }
    return null;
  }

  list(response, query) {
    const start = query.after || (query.from ? dayBefore(query.from) : null);
    let names = [...this.days.keys()].sort().filter((day) => !start || day > start);
    const truncated = names.length > PAGE;
    names = names.slice(0, PAGE);
    const inside = query.to ? names.filter((day) => day <= query.to) : names;
    const reachedEnd = inside.length < names.length;
    // The page the reader is on, counted by how many it has already walked.
    if (this.fault.page !== undefined && this.listings() - 1 === this.fault.page) {
      return json(response, { error: "the listing broke" }, 500);
    }
    json(response, {
      days: inside.map((day) => ({
        day,
        bytes: this.days.get(day).blob.length,
        uploaded: this.days.get(day).uploaded,
      })),
      next: !reachedEnd && truncated && inside.length ? inside.at(-1) : null,
    });
  }

  async frame(response, query) {
    if (!query.from || !query.to) {
      return json(response, { error: "a range takes both from and to" }, 400);
    }
    const start = query.after || dayBefore(query.from);
    // `omit` is a day the listing still names and the range no longer hands
    // back: deleted between the two requests.
    const names = [...this.days.keys()].sort()
      .filter((day) => start < day && day <= query.to && day !== this.fault.omit);
    const chosen = names.slice(0, FRAME);
    this.inFlight += 1;
    this.maxInFlight = Math.max(this.maxInFlight, this.inFlight);
    try {
      await sleepFor(DAY_DELAY);
      if (chosen.includes(this.fault.day)) {
        return json(response, { error: `${this.fault.day} is refused` }, 500);
      }
      const body = Buffer.concat(chosen.flatMap((day) => {
        const { blob } = this.days.get(day);
        const length = Buffer.alloc(4);
        length.writeUInt32BE(blob.length);
        return [Buffer.from(day), length, blob];
      }));
      this.sent.push(...chosen);
      const headers = { "Content-Type": "application/octet-stream", "Content-Length": body.length };
      if (names.length > FRAME) headers["X-Efferent-Next"] = chosen.at(-1);
      response.writeHead(200, headers);
      response.end(body);
    } finally {
      this.inFlight -= 1;
    }
  }
}

function json(response, body, status = 200) {
  const encoded = Buffer.from(JSON.stringify(body));
  response.writeHead(status, {
    "Content-Type": "application/json",
    "Content-Length": encoded.length,
  });
  response.end(encoded);
}

/** SHA-256 in base64url, for checking what an edit signed. */
export function digest(bytes) {
  return wire.toBase64url(createHash("sha256").update(bytes).digest());
}
