/**
 * The service, against an R2 that lives in memory.
 *
 * What is worth testing here is not the happy path — days go up, a day comes
 * back — but the properties that fail silently. A listing that cannot page past
 * its own page size reports the end of the world as an empty answer. A range
 * that quietly drops its first day loses exactly the day that was asked about.
 * A batch that stored the days it managed to parse and answered as though it
 * stored all of them would have the phone forget the rest. And a second write
 * of a day has to replace the first, because the whole design leans on it.
 */

import { assert, assertEquals } from "@std/assert";
import worker, {
  MAX_BUCKET_BYTES,
  MAX_DAY_BYTES,
  MAX_SERVICE_BYTES,
  SERVICE_BYTES_ALREADY_TAKEN,
} from "./src/index.ts";
import {
  dayKey,
  dayPrefix,
  SERVICE_TAKEN_OBJECT,
  signingKeyObject,
  takenObject,
} from "../protocol/ids.ts";
import { MAX_DAYS_PER_REQUEST, packDays, type SealedDay } from "../protocol/batch.ts";
import { base64url, signUpload, type UploadHeader } from "../protocol/signing.ts";

const BUCKET = "flgs7wibu26oz5lcrnuc5ftuuk";

class MemoryBucket {
  readonly store = new Map<string, { body: Uint8Array; uploaded: Date }>();
  /** Distinct write times without a clock: a day written later must be
   * distinguishable from one written earlier, and a test that ran fast enough
   * would otherwise stamp both the same. */
  private writes = 0;

  private object(key: string) {
    const stored = this.store.get(key)!;
    return {
      key,
      size: stored.body.length,
      uploaded: stored.uploaded,
      body: new Blob([stored.body.slice().buffer]).stream(),
      // deno-lint-ignore require-await
      arrayBuffer: async () => stored.body.buffer.slice(0) as ArrayBuffer,
      // deno-lint-ignore require-await
      text: async () => new TextDecoder().decode(stored.body),
    };
  }

  // deno-lint-ignore require-await
  async head(key: string) {
    return this.store.has(key) ? this.object(key) : null;
  }

  // deno-lint-ignore require-await
  async get(key: string) {
    return this.store.has(key) ? this.object(key) : null;
  }

  // deno-lint-ignore require-await
  async put(key: string, value: ArrayBuffer | Uint8Array | string) {
    this.store.set(key, {
      // Copied, and copied *within the view's bounds*: a day out of a batch is a
      // window onto the request body, and keeping the window would store the
      // whole batch under one day's name. Real R2 respects the bounds, so a
      // stand-in that did not would pass tests the service cannot.
      body: typeof value === "string"
        ? new TextEncoder().encode(value)
        : value instanceof Uint8Array
        ? value.slice()
        : new Uint8Array(value),
      uploaded: new Date(1_760_000_000_000 + this.writes++ * 1000),
    });
  }

  /**
   * A listing, with the two behaviours the service actually leans on.
   *
   * The limit is a limit on what is *read*, not on what comes back. That is the
   * part worth copying faithfully: a rolled-up listing gathers its prefixes from
   * the objects it happened to scan, so it can answer four years out of twelve
   * and say it is truncated, and code that took that page for the whole answer
   * would lose the rest of the archive without an error. Measured against real
   * R2 on 2026-09-05: twelve years came back as two pages.
   */
  // deno-lint-ignore require-await
  async list(
    options: {
      prefix?: string;
      startAfter?: string;
      limit?: number;
      delimiter?: string;
      cursor?: string;
    },
  ) {
    const prefix = options.prefix ?? "";
    const from = options.cursor ?? options.startAfter;
    const keys = [...this.store.keys()]
      .filter((key) => key.startsWith(prefix))
      .filter((key) => !from || key > from)
      .sort();

    const limit = options.limit ?? 1000;
    const scanned = keys.slice(0, limit);
    const truncated = keys.length > scanned.length;

    // A delimiter rolls up every scanned key that holds one after the prefix
    // into the stretch ending at its first occurrence; such a key is then not an
    // object of its own.
    const objects: string[] = [];
    const delimitedPrefixes: string[] = [];
    for (const key of scanned) {
      const at = options.delimiter ? key.indexOf(options.delimiter, prefix.length) : -1;
      if (at < 0) {
        objects.push(key);
        continue;
      }
      const delimited = key.slice(0, at + options.delimiter!.length);
      if (!delimitedPrefixes.includes(delimited)) delimitedPrefixes.push(delimited);
    }

    return {
      objects: objects.map((key) => this.object(key)),
      delimitedPrefixes,
      truncated,
      cursor: truncated ? scanned[scanned.length - 1] : undefined,
    };
  }
}

async function writerKey() {
  const pair = await crypto.subtle.generateKey({ name: "Ed25519" }, true, [
    "sign",
    "verify",
  ]) as CryptoKeyPair;
  return {
    privateKey: pair.privateKey,
    publicKey: base64url(new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey))),
  };
}

/**
 * A count that says yes, until a test says otherwise.
 *
 * Every test that is about something else has to get past it, so the default
 * answer is the permissive one; `answer = false` is how a test asks what
 * happens to a caller going too fast.
 */
class MemoryLimiter {
  answer = true;
  readonly keys: string[] = [];

  // deno-lint-ignore require-await
  async limit({ key }: { key: string }) {
    this.keys.push(key);
    return { success: this.answer };
  }
}

type Writer = { privateKey: CryptoKey; publicKey: string };
type Environment = { BLOBS: MemoryBucket; CLAIMS: MemoryLimiter; WRITES: MemoryLimiter };

/** The worker only ever touches the parts of R2 its interface names. */
function bindings(env: Environment): Parameters<typeof worker.fetch>[1] {
  return env as unknown as Parameters<typeof worker.fetch>[1];
}

function environment(): Environment {
  return { BLOBS: new MemoryBucket(), CLAIMS: new MemoryLimiter(), WRITES: new MemoryLimiter() };
}

function executionContext(): ExecutionContext {
  return {
    waitUntil() {},
    passThroughOnException() {},
    props: {},
  } as unknown as ExecutionContext;
}

/** Stand-in for a sealed day. The service never opens one, so its contents only
 * ever need to be recognisable. */
function sealedBody(...rest: number[]): Uint8Array {
  return new Uint8Array([1, ...rest]);
}

/**
 * Send a batch.
 *
 * `signedDays` and `body` are separable from what is packed so that the two
 * ways a request can lie — a signature over other days, a frame that does not
 * hold together — can be built at all.
 */
async function send(
  env: Environment,
  writer: Writer,
  days: SealedDay[],
  options: { signedDays?: string[]; body?: Uint8Array } = {},
): Promise<Response> {
  const body = options.body ?? packDays(days);
  const header: UploadHeader = {
    bucket: BUCKET,
    days: options.signedDays ?? days.map((entry) => entry.day),
    timestamp: Math.floor(Date.now() / 1000),
  };
  return await worker.fetch(
    new Request(`https://example.invalid/b/${BUCKET}/days`, {
      method: "PUT",
      headers: {
        "x-efferent-timestamp": String(header.timestamp),
        "x-efferent-writer": writer.publicKey,
        "x-efferent-signature": base64url(await signUpload(writer.privateKey, header, body)),
      },
      body: body as BodyInit,
    }),
    bindings(env),
  );
}

async function claim(env: Environment, writer: Writer): Promise<Response> {
  const body = new Uint8Array();
  const header: UploadHeader = {
    bucket: BUCKET,
    days: [],
    timestamp: Math.floor(Date.now() / 1000),
  };
  return await worker.fetch(
    new Request(`https://example.invalid/b/${BUCKET}`, {
      method: "PUT",
      headers: {
        "x-efferent-timestamp": String(header.timestamp),
        "x-efferent-writer": writer.publicKey,
        "x-efferent-signature": base64url(await signUpload(writer.privateKey, header, body)),
      },
      body,
    }),
    bindings(env),
  );
}

function put(
  env: Environment,
  writer: Writer,
  day: string,
  blob: Uint8Array = sealedBody(7, 7, 7),
): Promise<Response> {
  return send(env, writer, [{ day, blob }]);
}

async function days(env: Environment, query: string) {
  const response = await worker.fetch(
    new Request(`https://example.invalid/b/${BUCKET}/days?${query}`),
    bindings(env),
  );
  assertEquals(response.status, 200);
  return await response.json() as {
    days: { day: string; bytes: number; uploaded: string }[];
    next: string | null;
  };
}

function tally(env: Environment, key: string): number {
  return Number(new TextDecoder().decode(env.BLOBS.store.get(key)!.body));
}

function stored(env: Environment, day: string): number[] {
  return [...env.BLOBS.store.get(dayKey(BUCKET, day))!.body];
}

/// The premise of the whole design: the device re-reads a day and sends it
/// again, so the second write has to win. Keeping the first would mean keeping
/// a workout the person has since deleted.
Deno.test("writing a day again replaces it", async () => {
  const env = environment();
  const writer = await writerKey();

  assertEquals((await put(env, writer, "2026-08-07", sealedBody(2, 3))).status, 200);
  const second = await put(env, writer, "2026-08-07", sealedBody(9, 9, 9, 9));

  assertEquals(second.status, 200);
  assertEquals(await second.json(), { stored: ["2026-08-07"], bytes: 19 });
  assertEquals(stored(env, "2026-08-07"), [1, 9, 9, 9, 9]);
});

/// A batch is a way of travelling and nothing more. Every day in it has to end
/// up as its own object, holding its own bytes — a batch stored as a batch
/// would be a second shape in the archive, and reads know only one.
Deno.test("every day in a batch becomes its own object", async () => {
  const env = environment();
  const writer = await writerKey();

  const response = await send(env, writer, [
    { day: "2026-08-05", blob: sealedBody(5) },
    { day: "2026-08-06", blob: sealedBody(6, 6) },
    { day: "2026-08-07", blob: sealedBody(7, 7, 7) },
  ]);

  assertEquals(response.status, 200);
  assertEquals(
    (await response.json() as { stored: string[] }).stored,
    ["2026-08-05", "2026-08-06", "2026-08-07"],
  );
  assertEquals(stored(env, "2026-08-05"), [1, 5]);
  assertEquals(stored(env, "2026-08-06"), [1, 6, 6]);
  assertEquals(stored(env, "2026-08-07"), [1, 7, 7, 7]);
  assertEquals((await days(env, "")).days.map((entry) => entry.bytes), [2, 3, 4]);
});

/// The answer is what lets the sender stop marking days, so it has to name them
/// rather than count them. A batch that reported "3 stored" would be believed
/// about days it never wrote.
Deno.test("a batch that does not hold together stores nothing", async () => {
  const env = environment();
  const writer = await writerKey();
  const whole = packDays([
    { day: "2026-08-06", blob: sealedBody(6, 6) },
    { day: "2026-08-07", blob: sealedBody(7, 7, 7, 7, 7) },
  ]);

  // Cut inside the last day's blob: the frame still parses up to there, which
  // is exactly the shape that tempts an implementation to keep what it got.
  const response = await send(env, writer, [], {
    body: whole.slice(0, whole.length - 3),
    signedDays: ["2026-08-06", "2026-08-07"],
  });

  assertEquals(response.status, 400);
  assertEquals(env.BLOBS.store.has(dayKey(BUCKET, "2026-08-06")), false);
});

/// Every day in a batch is a separate write, and a Worker gets a limited
/// number of those per request. Refusing at the edge beats running out
/// somewhere in the middle, which would leave a batch half stored.
Deno.test("a day heavier than a day can be is refused, and nothing is stored", async () => {
  const env = environment();
  const writer = await writerKey();

  const response = await send(env, writer, [
    { day: "2026-01-01", blob: new Uint8Array(MAX_DAY_BYTES + 1) },
  ]);

  assertEquals(response.status, 413);
  assertEquals(env.BLOBS.store.size, 0);
});

/// A bucket holds one object per date, so the dates it will take are what
/// bounds how much of it can ever exist. Days nobody lived through are how that
/// bound is lost.
Deno.test("a day from before anybody's health is refused", async () => {
  const env = environment();
  const writer = await writerKey();

  const response = await put(env, writer, "1899-12-31");

  assertEquals(response.status, 400);
  assertEquals(env.BLOBS.store.size, 0);
});

Deno.test("a day nobody has reached yet is refused", async () => {
  const env = environment();
  const writer = await writerKey();
  const ahead = new Date(Date.now() + 3 * 24 * 60 * 60 * 1000).toISOString().slice(0, 10);

  const response = await put(env, writer, ahead);

  assertEquals(response.status, 400);
  assertEquals(env.BLOBS.store.size, 0);
});

/// Tomorrow here is today somewhere: a phone in New Zealand is on a date this
/// server has not reached, and the day it is living through is a real one.
Deno.test("the day a phone further east is already on is taken", async () => {
  const env = environment();
  const writer = await writerKey();
  const tomorrow = new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString().slice(0, 10);

  const response = await put(env, writer, tomorrow);

  assertEquals(response.status, 200);
});

Deno.test("a bucket that has been handed its fill takes no more", async () => {
  const env = environment();
  const writer = await writerKey();
  await put(env, writer, "2026-01-01");
  await env.BLOBS.put(takenObject(BUCKET), String(MAX_BUCKET_BYTES));

  const response = await put(env, writer, "2026-01-02");

  assertEquals(response.status, 507);
  assertEquals(env.BLOBS.store.has(dayKey(BUCKET, "2026-01-02")), false);
});

/// The ceiling that actually bounds the bill: while anybody can claim a bucket,
/// a limit on one bucket is a limit on nothing.
Deno.test("the service stops taking days once it has taken its fill", async () => {
  const env = environment();
  const writer = await writerKey();
  await env.BLOBS.put(SERVICE_TAKEN_OBJECT, String(MAX_SERVICE_BYTES));

  const response = await put(env, writer, "2026-01-01");

  assertEquals(response.status, 507);
  assertEquals(env.BLOBS.store.has(dayKey(BUCKET, "2026-01-01")), false);
});

/// What a write costs is the write. A tally of what the archive holds would say
/// the same number twice here, and would have to read every day it replaces to
/// say it.
Deno.test("the tally counts what was handed over, so one day sent twice counts twice", async () => {
  const env = environment();
  const writer = await writerKey();

  await put(env, writer, "2026-01-01");
  const once = tally(env, takenObject(BUCKET));
  await put(env, writer, "2026-01-01");
  const twice = tally(env, takenObject(BUCKET));

  assertEquals(twice, once * 2);
  assertEquals(tally(env, SERVICE_TAKEN_OBJECT), SERVICE_BYTES_ALREADY_TAKEN + twice);
});

Deno.test("a caller uploading too fast is refused before the archive is touched", async () => {
  const env = environment();
  const writer = await writerKey();
  env.WRITES.answer = false;

  const response = await put(env, writer, "2026-01-01");

  assertEquals(response.status, 429);
  assertEquals(env.BLOBS.store.size, 0);
});

/// The live service accepted this claim on 2026-09-05, before the refusal
/// existed. It gave a stranger nothing a generated key would not have given
/// them, and it was still a signature check passed without a key.
Deno.test("a claim signed with a key nobody holds is refused", async () => {
  const env = environment();

  const response = await worker.fetch(
    new Request(`https://example.invalid/b/${BUCKET}`, {
      method: "PUT",
      headers: {
        "x-efferent-timestamp": String(Math.floor(Date.now() / 1000)),
        "x-efferent-writer": base64url(new Uint8Array(32)),
        "x-efferent-signature": base64url(new Uint8Array(64)),
      },
      body: new Uint8Array(),
    }),
    bindings(env),
  );

  assertEquals(response.status, 400);
  assertEquals(env.BLOBS.store.size, 0);
});

Deno.test("a caller claiming buckets too fast is refused", async () => {
  const env = environment();
  const writer = await writerKey();
  env.CLAIMS.answer = false;

  const response = await claim(env, writer);

  assertEquals(response.status, 429);
  assertEquals(env.BLOBS.store.size, 0);
});

Deno.test("more than a month of days in one request is refused", async () => {
  const env = environment();
  const writer = await writerKey();
  const cursor = new Date("2026-01-01T00:00:00Z");
  const batch: SealedDay[] = [];
  for (let index = 0; index < MAX_DAYS_PER_REQUEST + 1; index++) {
    batch.push({ day: cursor.toISOString().slice(0, 10), blob: sealedBody(1) });
    cursor.setUTCDate(cursor.getUTCDate() + 1);
  }

  const response = await send(env, writer, batch);

  assertEquals(response.status, 413);
  assertEquals(env.BLOBS.store.size, 0);
});

Deno.test("a day comes back exactly as it went in", async () => {
  const env = environment();
  const writer = await writerKey();
  await put(env, writer, "2026-08-07", sealedBody(4, 5, 6));

  const response = await worker.fetch(
    new Request(`https://example.invalid/b/${BUCKET}/d/2026-08-07`),
    bindings(env),
  );

  assertEquals(response.status, 200);
  assertEquals([...new Uint8Array(await response.arrayBuffer())], [1, 4, 5, 6]);
});

/// `from` is what a person means by it. Listings skip *past* a key, so an
/// implementation that passed `from` straight through would drop the first day
/// of every range — the one most likely to be the point of the question.
Deno.test("a range includes both of its ends", async () => {
  const env = environment();
  const writer = await writerKey();
  await send(
    env,
    writer,
    ["2026-07-31", "2026-08-01", "2026-08-02", "2026-08-03", "2026-08-04"]
      .map((day) => ({ day, blob: sealedBody(1) })),
  );

  const range = await days(env, "from=2026-08-01&to=2026-08-03");

  assertEquals(range.days.map((entry) => entry.day), ["2026-08-01", "2026-08-02", "2026-08-03"]);
  assertEquals(range.next, null);
});

Deno.test("the listing walks past its own page size", async () => {
  const env = environment();
  const writer = await writerKey();

  // 120 days across a year boundary: more than one page at the size asked for,
  // which is exactly where a listing that filters after fetching goes blind.
  // Sent as a phone would send them, a month at a time.
  const written: string[] = [];
  const cursor = new Date("2025-11-01T00:00:00Z");
  for (let index = 0; index < 120; index++) {
    written.push(cursor.toISOString().slice(0, 10));
    cursor.setUTCDate(cursor.getUTCDate() + 1);
  }
  for (let start = 0; start < written.length; start += 31) {
    const batch = written.slice(start, start + 31).map((day) => ({ day, blob: sealedBody(1) }));
    assertEquals((await send(env, writer, batch)).status, 200);
  }

  const seen: string[] = [];
  let after: string | null = null;
  for (let page = 0; page < 10; page++) {
    const body: { days: { day: string }[]; next: string | null } = await days(
      env,
      `limit=25${after ? `&after=${after}` : ""}`,
    );
    for (const entry of body.days) seen.push(entry.day);
    if (body.next === null) break;
    after = body.next;
  }

  assertEquals(seen.length, 120, "the walk did not reach every day");
  assertEquals(seen[0], written[0]);
  assertEquals(seen[seen.length - 1], written[written.length - 1]);
});

/// A day can be rewritten at any time, so "everything after where I stopped" is
/// no longer a question a mirror can ask. `uploaded` is the replacement, and a
/// listing that did not move it on a rewrite would leave mirrors stale with
/// nothing to notice.
Deno.test("a rewritten day reports a later upload time", async () => {
  const env = environment();
  const writer = await writerKey();
  await put(env, writer, "2026-08-07", sealedBody(1));
  const first = (await days(env, "")).days[0].uploaded;

  await put(env, writer, "2026-08-07", sealedBody(2, 2));
  const second = (await days(env, "")).days[0];

  assertEquals(second.bytes, 3);
  assert(second.uploaded > first, `upload time did not move: ${first} then ${second.uploaded}`);
});

Deno.test("stats says what is in the archive without handing any of it over", async () => {
  const env = environment();
  const writer = await writerKey();
  await send(env, writer, [
    { day: "2026-08-06", blob: sealedBody(1, 2) },
    { day: "2026-08-07", blob: sealedBody(3) },
  ]);

  const response = await worker.fetch(
    new Request(`https://example.invalid/b/${BUCKET}/stats`),
    bindings(env),
  );
  const body = await response.json() as Record<string, unknown>;

  assertEquals(body.days, 2);
  assertEquals(body.bytes, 5);
  assertEquals(body.firstDay, "2026-08-06");
  assertEquals(body.lastDay, "2026-08-07");
  assertEquals(body.complete, true);
  assert(env.BLOBS.store.has(signingKeyObject(BUCKET)), "the writer never got registered");
});

Deno.test("stats counts a decade whose years are walked side by side", async () => {
  const env = environment();
  const writer = await writerKey();
  // Three years with a gap between them: the years are found from the keys, so
  // an archive that stopped for a while must not be counted as continuous, and
  // the ends of it come from the earliest and latest year rather than from
  // whichever listing happened to answer first.
  await send(env, writer, [
    { day: "2016-02-29", blob: sealedBody(1) },
    { day: "2016-12-31", blob: sealedBody(1, 2) },
    { day: "2019-06-01", blob: sealedBody(3) },
    { day: "2026-01-01", blob: sealedBody(4, 5, 6) },
  ]);

  const response = await worker.fetch(
    new Request(`https://example.invalid/b/${BUCKET}/stats`),
    bindings(env),
  );

  assertEquals(await response.json(), {
    exists: true,
    days: 4,
    bytes: 2 + 3 + 2 + 4,
    firstDay: "2016-02-29",
    lastDay: "2026-01-01",
    complete: true,
  });
});

Deno.test("stats finds the years a first page never reached", async () => {
  const env = environment();
  const writer = await writerKey();
  await claim(env, writer);

  // Over three years of days, which is more than one listing reads. The years
  // are gathered from the objects a page happened to scan, so the last year of
  // this archive exists only on the second page — and an answer that stopped at
  // the first would be short by a year and wrong about when the archive ends,
  // while looking exactly like a correct answer about a smaller archive. That
  // is what the real bucket did on 2026-09-05: 2 942 days of 3 914, and a last
  // day two and a half years early.
  const written: string[] = [];
  const cursor = new Date("2020-01-01T00:00:00Z");
  for (let index = 0; index < 1200; index++) {
    written.push(cursor.toISOString().slice(0, 10));
    cursor.setUTCDate(cursor.getUTCDate() + 1);
  }
  // Put straight into the store: what is under test is the counting, and 1 200
  // days is forty signed batches of nothing to do with it.
  for (const day of written) await env.BLOBS.put(dayKey(BUCKET, day), sealedBody(1));

  const response = await worker.fetch(
    new Request(`https://example.invalid/b/${BUCKET}/stats`),
    bindings(env),
  );

  assertEquals(await response.json(), {
    exists: true,
    days: written.length,
    bytes: written.length * 2,
    firstDay: written[0],
    lastDay: written[written.length - 1],
    complete: true,
  });
});

Deno.test("stats counts days, and a key that is not one is not a day", async () => {
  const env = environment();
  const writer = await writerKey();
  await send(env, writer, [{ day: "2026-08-07", blob: sealedBody(1) }]);
  // Two shapes of rubbish under the same prefix: one that holds no dash at all,
  // so no year can be read from it, and one that reads as a year and is still
  // not a date. Neither has ever been written by anything, and both would be
  // counted by a listing that trusted the prefix instead of the day.
  await env.BLOBS.put(`${dayPrefix(BUCKET)}notaday`, sealedBody(9, 9, 9));
  await env.BLOBS.put(`${dayPrefix(BUCKET)}2026-13-40`, sealedBody(9, 9, 9));

  const response = await worker.fetch(
    new Request(`https://example.invalid/b/${BUCKET}/stats`),
    bindings(env),
  );
  const body = await response.json() as Record<string, unknown>;

  assertEquals(body.days, 1);
  assertEquals(body.bytes, 2);
  assertEquals(body.firstDay, "2026-08-07");
  assertEquals(body.lastDay, "2026-08-07");
});

Deno.test("an unknown bucket is empty rather than an error", async () => {
  const env = environment();
  const response = await worker.fetch(
    new Request(`https://example.invalid/b/${BUCKET}/stats`),
    bindings(env),
  );
  assertEquals(await response.json(), {
    exists: false,
    days: 0,
    bytes: 0,
    firstDay: null,
    lastDay: null,
    complete: true,
  });
});

Deno.test("the phone claims an empty archive before any health day exists", async () => {
  const env = environment();
  const owner = await writerKey();

  const first = await claim(env, owner);
  const repeated = await claim(env, owner);

  assertEquals(first.status, 201);
  assertEquals(await first.json(), { bucket: BUCKET, created: true });
  assertEquals(repeated.status, 200);
  assertEquals(await repeated.json(), { bucket: BUCKET, created: false });
  assert(env.BLOBS.store.has(signingKeyObject(BUCKET)));
  assertEquals(env.BLOBS.store.has(dayKey(BUCKET, "2026-08-07")), false);
});

Deno.test("a writer that did not create the archive cannot upload into it", async () => {
  const env = environment();
  await claim(env, await writerKey());

  const stranger = await put(env, await writerKey(), "2026-08-07", sealedBody(6));

  assertEquals(stranger.status, 403);
  assertEquals(env.BLOBS.store.has(dayKey(BUCKET, "2026-08-07")), false);
});

Deno.test("the bucket URL exposes setup and keyless ciphertext MCP tools", async () => {
  const response = await worker.fetch(
    new Request(`http://localhost/mcp/b/${BUCKET}`, {
      method: "POST",
      headers: {
        "accept": "application/json",
        "content-type": "application/json",
        "host": "localhost",
        "mcp-method": "tools/list",
        "mcp-protocol-version": "2026-07-28",
      },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "tools/list",
        params: {
          _meta: {
            "io.modelcontextprotocol/protocolVersion": "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities": {},
          },
        },
      }),
    }),
    bindings(environment()),
    executionContext(),
  );
  const body = await response.json() as {
    result?: { tools?: { name: string; inputSchema: { properties?: Record<string, unknown> } }[] };
  };

  assertEquals(response.status, 200);
  assertEquals(body.result?.tools?.map((tool) => tool.name), [
    "setup_guide",
    "archive_status",
    "list_sealed_days",
    "get_sealed_day",
  ]);
  for (const tool of body.result?.tools ?? []) {
    assertEquals(tool.inputSchema.properties?.readingKey, undefined);
  }
});

Deno.test("setup_guide returns the complete local reader without receiving a key", async () => {
  const response = await worker.fetch(
    new Request(`http://localhost/mcp/b/${BUCKET}`, {
      method: "POST",
      headers: {
        "accept": "application/json",
        "content-type": "application/json",
        "host": "localhost",
        "mcp-method": "tools/call",
        "mcp-name": "setup_guide",
        "mcp-protocol-version": "2026-07-28",
      },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: {
          name: "setup_guide",
          arguments: {},
          _meta: {
            "io.modelcontextprotocol/protocolVersion": "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities": {},
          },
        },
      }),
    }),
    bindings(environment()),
    executionContext(),
  );
  const body = await response.json() as {
    result?: { content?: { type: string; text?: string }[] };
  };
  const guide = body.result?.content?.[0]?.text ?? "";

  assertEquals(response.status, 200, JSON.stringify(body));
  assert(guide.includes("# Set up Efferent"));
  assert(guide.includes("three fields"));
  assert(guide.includes("pyhpke==0.6.3"));
  assert(guide.includes('"User-Agent": "efferent-local-reader/1.0"'));
  assert(!guide.includes("github.com"));
  assert(!guide.includes("deno task"));
  assert(!guide.includes("Prompt:"));
});

Deno.test("versioned HTTP prompts no longer exist", async () => {
  for (const version of ["v1", "v2", "v3"]) {
    const response = await worker.fetch(
      new Request(`https://example.invalid/prompts/connect/${version}`),
      bindings(environment()),
    );
    assertEquals(response.status, 404);
  }
});

/// The bucket belongs to the writer that claimed it. Without this, anyone who
/// learned a bucket id could overwrite a day with rubbish — and overwriting is
/// now the ordinary operation, so the check carries more weight than it did.
Deno.test("a second writer cannot touch a claimed bucket", async () => {
  const env = environment();
  const owner = await writerKey();
  await put(env, owner, "2026-08-07", sealedBody(1));

  const stranger = await put(env, await writerKey(), "2026-08-07", sealedBody(6, 6, 6));

  assertEquals(stranger.status, 403);
  assertEquals(stored(env, "2026-08-07"), [1, 1]);
});

/// The days are signed as the service unpacked them, not as the sender labelled
/// them. A signature that covered only the bytes would still be a signature
/// over the days — but this is what proves the service's own reading of the
/// frame is the reading that was authorised.
Deno.test("a signature over a different set of days is refused", async () => {
  const env = environment();
  const writer = await writerKey();

  const response = await send(
    env,
    writer,
    [{ day: "2026-08-07", blob: sealedBody(1, 2) }],
    { signedDays: ["2026-08-06"] },
  );

  assertEquals(response.status, 403);
  assertEquals(env.BLOBS.store.has(dayKey(BUCKET, "2026-08-07")), false);
});

/// The 31st of February parses in some readings and not others. A day that can
/// be written but never asked for again would be data lost in plain sight.
Deno.test("a date that does not exist is refused", async () => {
  const env = environment();
  const response = await worker.fetch(
    new Request(`https://example.invalid/b/${BUCKET}/d/2026-02-31`),
    bindings(env),
  );
  assertEquals(response.status, 400);
});

/// A phone cannot tell that its own clock is wrong: every request it signs is
/// refused for the same reason, and nothing it can measure says why. The
/// refusal is the one place the answer exists, so it carries this server's own
/// seconds — without them the phone stops sending for good.
Deno.test("a refusal for being out of time says what the time is", async () => {
  const env = environment();
  const writer = await writerKey();
  const body = packDays([{ day: "2026-08-07", blob: sealedBody(1, 2) }]);
  const header: UploadHeader = {
    bucket: BUCKET,
    days: ["2026-08-07"],
    timestamp: Math.floor(Date.now() / 1000) - 4231,
  };

  const response = await worker.fetch(
    new Request(`https://example.invalid/b/${BUCKET}/days`, {
      method: "PUT",
      headers: {
        "x-efferent-timestamp": String(header.timestamp),
        "x-efferent-writer": writer.publicKey,
        "x-efferent-signature": base64url(await signUpload(writer.privateKey, header, body)),
      },
      body: body as BodyInit,
    }),
    bindings(env),
  );

  assertEquals(response.status, 400);
  const answer = await response.json() as { error: string; now: number };
  assert(
    Math.abs(answer.now - Math.floor(Date.now() / 1000)) < 5,
    `the refusal did not carry this server's clock: ${JSON.stringify(answer)}`,
  );
  assertEquals(env.BLOBS.store.has(dayKey(BUCKET, "2026-08-07")), false);
});
