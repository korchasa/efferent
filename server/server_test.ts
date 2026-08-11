/**
 * The service, against an R2 that lives in memory.
 *
 * What is worth testing here is not the happy path — a day goes up, a day comes
 * back — but the properties that fail silently. A listing that cannot page past
 * its own page size reports the end of the world as an empty answer. A range
 * that quietly drops its first day loses exactly the day that was asked about.
 * And a second write of a day has to replace the first, because the whole
 * design leans on it.
 */

import { assert, assertEquals } from "@std/assert";
import worker from "./src/index.ts";
import { dayKey, signingKeyObject } from "../protocol/ids.ts";
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
      body: value instanceof Uint8Array ? value : new Uint8Array(value),
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

/** Stand-in for a sealed day. The service never opens one, so its contents only
 * ever need to be recognisable. */
function sealedBody(...rest: number[]): Uint8Array {
  return new Uint8Array([1, ...rest]);
}

async function put(
  env: Environment,
  writer: Writer,
  day: string,
  body: Uint8Array = sealedBody(7, 7, 7),
): Promise<Response> {
  const header: UploadHeader = { bucket: BUCKET, day, timestamp: Math.floor(Date.now() / 1000) };
  return await worker.fetch(
    new Request(`https://example.invalid/b/${BUCKET}/d/${day}`, {
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

/// The premise of the whole design: the device re-reads a day and sends it
/// again, so the second write has to win. Keeping the first would mean keeping
/// a workout the person has since deleted.
Deno.test("writing a day again replaces it", async () => {
  const env = environment();
  const writer = await writerKey();

  assertEquals((await put(env, writer, "2026-08-07", sealedBody(2, 3))).status, 200);
  const second = await put(env, writer, "2026-08-07", sealedBody(9, 9, 9, 9));

  assertEquals(second.status, 200);
  assertEquals(await second.json(), { stored: "2026-08-07", bytes: 5 });
  assertEquals([...env.BLOBS.store.get(dayKey(BUCKET, "2026-08-07"))!.body], [1, 9, 9, 9, 9]);
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
  for (const day of ["2026-07-31", "2026-08-01", "2026-08-02", "2026-08-03", "2026-08-04"]) {
    await put(env, writer, day);
  }

  const range = await days(env, "from=2026-08-01&to=2026-08-03");

  assertEquals(range.days.map((entry) => entry.day), ["2026-08-01", "2026-08-02", "2026-08-03"]);
  assertEquals(range.next, null);
});

Deno.test("the listing walks past its own page size", async () => {
  const env = environment();
  const writer = await writerKey();

  // 120 days across a year boundary: more than one page at the size asked for,
  // which is exactly where a listing that filters after fetching goes blind.
  const written: string[] = [];
  const cursor = new Date("2025-11-01T00:00:00Z");
  for (let index = 0; index < 120; index++) {
    const day = cursor.toISOString().slice(0, 10);
    written.push(day);
    await put(env, writer, day);
    cursor.setUTCDate(cursor.getUTCDate() + 1);
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
  await put(env, writer, "2026-08-06", sealedBody(1, 2));
  await put(env, writer, "2026-08-07", sealedBody(3));

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

/// The bucket belongs to whoever wrote into it first. Without this, anyone who
/// learned a bucket id could overwrite a day with rubbish — and overwriting is
/// now the ordinary operation, so the check carries more weight than it did.
Deno.test("a second writer cannot touch a claimed bucket", async () => {
  const env = environment();
  const owner = await writerKey();
  await put(env, owner, "2026-08-07", sealedBody(1));

  const stranger = await put(env, await writerKey(), "2026-08-07", sealedBody(6, 6, 6));

  assertEquals(stranger.status, 403);
  assertEquals([...env.BLOBS.store.get(dayKey(BUCKET, "2026-08-07"))!.body], [1, 1]);
});

Deno.test("a signature over another day is refused", async () => {
  const env = environment();
  const writer = await writerKey();
  const body = sealedBody(1, 2);
  const header: UploadHeader = {
    bucket: BUCKET,
    day: "2026-08-06",
    timestamp: Math.floor(Date.now() / 1000),
  };

  const response = await worker.fetch(
    new Request(`https://example.invalid/b/${BUCKET}/d/2026-08-07`, {
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
