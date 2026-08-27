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
import worker from "./src/index.ts";
import { dayKey, signingKeyObject } from "../protocol/ids.ts";
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
  async put(key: string, value: ArrayBuffer | Uint8Array) {
    this.store.set(key, {
      // Copied, and copied *within the view's bounds*: a day out of a batch is a
      // window onto the request body, and keeping the window would store the
      // whole batch under one day's name. Real R2 respects the bounds, so a
      // stand-in that did not would pass tests the service cannot.
      body: value instanceof Uint8Array ? value.slice() : new Uint8Array(value),
      uploaded: new Date(1_760_000_000_000 + this.writes++ * 1000),
    });
  }

  // deno-lint-ignore require-await
  async list(options: { prefix?: string; startAfter?: string; limit?: number }) {
    const keys = [...this.store.keys()]
      .filter((key) => !options.prefix || key.startsWith(options.prefix))
      .filter((key) => !options.startAfter || key > options.startAfter)
      .sort();
    const limit = options.limit ?? 1000;
    return {
      objects: keys.slice(0, limit).map((key) => this.object(key)),
      truncated: keys.length > limit,
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

type Writer = { privateKey: CryptoKey; publicKey: string };
type Environment = { BLOBS: MemoryBucket };

/** The worker only ever touches the parts of R2 its interface names. */
function bindings(env: Environment): Parameters<typeof worker.fetch>[1] {
  return env as unknown as Parameters<typeof worker.fetch>[1];
}

function environment(): Environment {
  return { BLOBS: new MemoryBucket() };
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

Deno.test("the versioned connection prompt is public and immutable", async () => {
  const response = await worker.fetch(
    new Request("https://example.invalid/prompts/connect/v1"),
    bindings(environment()),
  );
  const body = await response.text();

  assertEquals(response.status, 200);
  assertEquals(response.headers.get("cache-control"), "public, max-age=31536000, immutable");
  assert(body.includes("Keep the reading key on this machine"));
  assert(body.includes("health_overview"));
});

Deno.test("the bucket URL exposes only keyless ciphertext MCP tools", async () => {
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
    "archive_status",
    "list_sealed_days",
    "get_sealed_day",
  ]);
  for (const tool of body.result?.tools ?? []) {
    assertEquals(tool.inputSchema.properties?.readingKey, undefined);
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
