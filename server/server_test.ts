/**
 * The service, against an R2 that lives in memory.
 *
 * What is worth testing here is not the happy path — a batch goes up, a batch
 * comes back — but the two properties that make this an archive instead of a
 * letterbox, because both fail silently. A listing that cannot page past its
 * first page reports the end of the world as an empty answer, and a write that
 * replaces an existing object loses history without anything going wrong at the
 * time.
 */

import { assert, assertEquals } from "@std/assert";
import { DatabaseSync } from "node:sqlite";
import worker from "./src/index.ts";
import { objectKey, signingKeyObject } from "../protocol/ids.ts";
import { base64url, signUpload, type UploadHeader } from "../protocol/signing.ts";
import { frame, type ManifestEntry } from "../protocol/manifest.ts";

const BUCKET = "flgs7wibu26oz5lcrnuc5ftuuk";

/**
 * The index, on real SQLite rather than something that pretends to read SQL.
 *
 * What is worth testing about the index is the query itself — overlap at the
 * edges of a window, one row per batch, `json_each` unrolling five hundred
 * events from one bound value. A hand-rolled fake would only ever prove that
 * the fake agrees with itself.
 */
class MemoryIndex {
  readonly db = new DatabaseSync(":memory:");

  constructor() {
    this.db.exec(Deno.readTextFileSync(`${import.meta.dirname}/schema.sql`));
  }

  prepare(sql: string) {
    const db = this.db;
    let bound: unknown[] = [];
    const statement = {
      bind(...values: unknown[]) {
        bound = values;
        return statement;
      },
      // deno-lint-ignore require-await
      async all<T>() {
        return { results: db.prepare(sql).all(...bound as never[]) as T[] };
      },
      // deno-lint-ignore require-await
      async run() {
        return db.prepare(sql).run(...bound as never[]);
      },
    };
    return statement;
  }
}

class MemoryBucket {
  readonly store = new Map<string, Uint8Array>();

  // deno-lint-ignore require-await
  async head(key: string) {
    const value = this.store.get(key);
    return value ? { key, size: value.length } : null;
  }

  // deno-lint-ignore require-await
  async get(key: string) {
    const value = this.store.get(key);
    if (!value) return null;
    return {
      key,
      size: value.length,
      // deno-lint-ignore require-await
      arrayBuffer: async () => value.buffer.slice(0) as ArrayBuffer,
    };
  }

  // deno-lint-ignore require-await
  async put(key: string, value: ArrayBuffer | Uint8Array) {
    this.store.set(key, value instanceof Uint8Array ? value : new Uint8Array(value));
  }

  // deno-lint-ignore require-await
  async list(options: { prefix?: string; startAfter?: string; limit?: number }) {
    const keys = [...this.store.keys()]
      .filter((key) => !options.prefix || key.startsWith(options.prefix))
      .filter((key) => !options.startAfter || key > options.startAfter)
      .sort();
    const limit = options.limit ?? 1000;
    return {
      objects: keys.slice(0, limit).map((key) => ({ key, size: this.store.get(key)!.length })),
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

type Environment = { BLOBS: MemoryBucket; INDEX?: MemoryIndex };

/** The worker only ever touches the parts of R2 and D1 its interfaces name. */
function bindings(env: Environment): Parameters<typeof worker.fetch>[1] {
  return env as unknown as Parameters<typeof worker.fetch>[1];
}

function environment(): { BLOBS: MemoryBucket; INDEX: MemoryIndex } {
  return { BLOBS: new MemoryBucket(), INDEX: new MemoryIndex() };
}

/** Stand-in for the sealed blob. The service never opens one, so its contents
 * only ever need to be recognisable. */
function sealedBody(...rest: number[]): Uint8Array {
  return new Uint8Array([1, ...rest]);
}

async function post(
  env: Environment,
  writer: { privateKey: CryptoKey; publicKey: string },
  seqFrom: number,
  seqTo: number,
  body: Uint8Array,
): Promise<Response> {
  const header: UploadHeader = {
    bucket: BUCKET,
    seqFrom,
    seqTo,
    timestamp: Math.floor(Date.now() / 1000),
  };
  return await worker.fetch(
    new Request(`https://example.invalid/b/${BUCKET}`, {
      method: "POST",
      headers: {
        "x-efferent-seq-from": String(seqFrom),
        "x-efferent-seq-to": String(seqTo),
        "x-efferent-timestamp": String(header.timestamp),
        "x-efferent-writer": writer.publicKey,
        "x-efferent-signature": base64url(await signUpload(writer.privateKey, header, body)),
      },
      body: body as BodyInit,
    }),
    bindings(env),
  );
}

async function postWithManifest(
  env: Environment,
  writer: { privateKey: CryptoKey; publicKey: string },
  seqFrom: number,
  seqTo: number,
  manifest: ManifestEntry[],
): Promise<Response> {
  return await post(env, writer, seqFrom, seqTo, await frame(manifest, sealedBody(7, 7, 7)));
}

/** One ordinary entry, for tests that care about the archive rather than the
 * index. */
function entry(seq: number): ManifestEntry[] {
  return [{ seq, type: "health.agg", metric: "steps", start: 1_760_000_000, end: null }];
}

function at(iso: string): number {
  return Math.floor(Date.parse(iso) / 1000);
}

async function find(env: Environment, query: string) {
  const response = await worker.fetch(
    new Request(`https://example.invalid/b/${BUCKET}/find?${query}`),
    bindings(env),
  );
  assertEquals(response.status, 200);
  return await response.json() as {
    objects: { name: string; seqFrom: number; seqTo: number; count: number }[];
    events: number;
    truncated: boolean;
  };
}

Deno.test("a stored batch is never replaced by a later one claiming its range", async () => {
  const env = environment();
  const writer = await writerKey();

  const first = await frame(entry(1), sealedBody(2, 3));
  assertEquals((await post(env, writer, 1, 10, first)).status, 200);
  const answer = await post(env, writer, 1, 10, await frame(entry(1), sealedBody(9, 9, 9)));

  // Acknowledged, so a device that missed the first answer stops retrying…
  assertEquals(answer.status, 200);
  assertEquals(await answer.json(), { ack: 10 });
  // …but what was written first is what is still there.
  assertEquals([...env.BLOBS.store.get(objectKey(BUCKET, 1, 10))!], [...first]);
});

Deno.test("the listing walks past its own page size", async () => {
  const env = environment();
  const writer = await writerKey();

  // 250 batches: more than one page, which is exactly where a listing that
  // filters after fetching stops being able to see anything.
  for (let index = 0; index < 250; index++) {
    const from = index * 10 + 1;
    await postWithManifest(env, writer, from, from + 9, [
      { seq: from, type: "health.agg", metric: "steps", start: 1_760_000_000 + index, end: null },
    ]);
  }

  const seen: number[] = [];
  let after = 0;
  for (let page = 0; page < 10; page++) {
    const response = await worker.fetch(
      new Request(`https://example.invalid/b/${BUCKET}/objects?after=${after}`),
      bindings(env),
    );
    const body = await response.json() as {
      objects: { seqFrom: number; seqTo: number }[];
      next: number | null;
    };
    for (const object of body.objects) seen.push(object.seqFrom);
    if (body.next === null) break;
    after = body.next;
  }

  assertEquals(seen.length, 250, "the walk did not reach every batch");
  assertEquals(seen[0], 1);
  assertEquals(seen[seen.length - 1], 2491);
});

Deno.test("stats says what is in the archive without handing any of it over", async () => {
  const env = environment();
  const writer = await writerKey();
  await postWithManifest(env, writer, 1, 10, entry(1));
  await postWithManifest(env, writer, 11, 20, entry(11));

  const response = await worker.fetch(
    new Request(`https://example.invalid/b/${BUCKET}/stats`),
    bindings(env),
  );
  const body = await response.json() as Record<string, unknown>;

  assertEquals(body.objects, 2);
  assertEquals(body.lowestSeq, 1);
  assertEquals(body.highestSeq, 20);
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
    objects: 0,
    bytes: 0,
    lowestSeq: null,
    highestSeq: 0,
    complete: true,
  });
});

Deno.test("find names the batches holding a metric in a window, and no others", async () => {
  const env = environment();
  const writer = await writerKey();

  await postWithManifest(env, writer, 1, 2, [
    {
      seq: 1,
      type: "health.sample",
      metric: "sleep",
      start: at("2026-07-05T22:00:00Z"),
      end: at("2026-07-06T05:00:00Z"),
    },
    {
      seq: 2,
      type: "health.sample",
      metric: "heartRate",
      start: at("2026-07-05T22:10:00Z"),
      end: at("2026-07-05T22:10:00Z"),
    },
  ]);
  await postWithManifest(env, writer, 3, 4, [
    {
      seq: 3,
      type: "health.sample",
      metric: "sleep",
      start: at("2026-08-10T22:00:00Z"),
      end: at("2026-08-11T06:00:00Z"),
    },
    {
      seq: 4,
      type: "health.agg",
      metric: "steps",
      start: at("2026-08-11T00:00:00Z"),
      end: at("2026-08-12T00:00:00Z"),
    },
  ]);

  const august = await find(env, "metric=sleep&from=2026-08-01T00:00:00Z&to=2026-09-01T00:00:00Z");

  assertEquals(august.objects.length, 1, "July's batch was named for an August question");
  assertEquals(august.objects[0].seqFrom, 3);
  assertEquals(august.events, 1, "the steps total in the same batch was counted as sleep");
  assertEquals(august.truncated, false);
});

/// A night starts before midnight and ends after it. Filtering on the start
/// alone would drop it from a query for that day, silently and plausibly.
Deno.test("find keeps an event that straddles the edge of the window", async () => {
  const env = environment();
  const writer = await writerKey();

  await postWithManifest(env, writer, 1, 1, [
    {
      seq: 1,
      type: "health.sample",
      metric: "sleep",
      start: at("2026-08-10T21:50:00Z"),
      end: at("2026-08-11T05:30:00Z"),
    },
  ]);

  const eleventh = await find(env, "from=2026-08-11T00:00:00Z&to=2026-08-12T00:00:00Z");

  assertEquals(eleventh.objects.length, 1);
  assertEquals(eleventh.events, 1);
});

/// The whole point of the index is to save the download, not to become one.
Deno.test("find answers with batch names and never with data", async () => {
  const env = environment();
  const writer = await writerKey();
  await postWithManifest(env, writer, 1, 1, [
    {
      seq: 1,
      type: "health.sample",
      metric: "sleep",
      start: at("2026-08-10T22:00:00Z"),
      end: at("2026-08-11T06:00:00Z"),
    },
  ]);

  const answer = await find(env, "from=&to=");
  const text = JSON.stringify(answer);

  assertEquals(answer.objects[0].name, "00000000000000001-00000000000000001");
  assert(!text.includes("7"), `the answer carried payload bytes: ${text}`);
});

/// A batch with no manifest would be data the index cannot see, and an index
/// with holes in it answers "nothing here" for events that are. Refusing the
/// body is the only version of that failure anyone notices.
Deno.test("a body with no manifest is refused rather than archived", async () => {
  const env = environment();
  const writer = await writerKey();

  const answer = await post(env, writer, 1, 500, sealedBody(2, 3));

  assertEquals(answer.status, 400);
  assertEquals(env.BLOBS.store.has(objectKey(BUCKET, 1, 500)), false);
});
