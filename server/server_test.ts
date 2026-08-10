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
import worker from "./src/index.ts";
import { objectKey, signingKeyObject } from "../protocol/ids.ts";
import { base64url, signUpload, type UploadHeader } from "../protocol/signing.ts";

const BUCKET = "flgs7wibu26oz5lcrnuc5ftuuk";

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

async function post(
  env: { BLOBS: MemoryBucket },
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
    // The worker only ever touches the parts of R2 the interface names.
    { BLOBS: env.BLOBS } as unknown as Parameters<typeof worker.fetch>[1],
  );
}

Deno.test("a stored batch is never replaced by a later one claiming its range", async () => {
  const env = { BLOBS: new MemoryBucket() };
  const writer = await writerKey();

  assertEquals((await post(env, writer, 1, 10, new Uint8Array([1, 2, 3]))).status, 200);
  const answer = await post(env, writer, 1, 10, new Uint8Array([9, 9, 9, 9]));

  // Acknowledged, so a device that missed the first answer stops retrying…
  assertEquals(answer.status, 200);
  assertEquals(await answer.json(), { ack: 10 });
  // …but what was written first is what is still there.
  assertEquals([...env.BLOBS.store.get(objectKey(BUCKET, 1, 10))!], [1, 2, 3]);
});

Deno.test("the listing walks past its own page size", async () => {
  const env = { BLOBS: new MemoryBucket() };
  const writer = await writerKey();

  // 250 batches: more than one page, which is exactly where a listing that
  // filters after fetching stops being able to see anything.
  for (let index = 0; index < 250; index++) {
    const from = index * 10 + 1;
    await post(env, writer, from, from + 9, new Uint8Array([index & 0xff]));
  }

  const seen: number[] = [];
  let after = 0;
  for (let page = 0; page < 10; page++) {
    const response = await worker.fetch(
      new Request(`https://example.invalid/b/${BUCKET}/objects?after=${after}`),
      { BLOBS: env.BLOBS } as unknown as Parameters<typeof worker.fetch>[1],
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
  const env = { BLOBS: new MemoryBucket() };
  const writer = await writerKey();
  await post(env, writer, 1, 10, new Uint8Array([1, 2, 3]));
  await post(env, writer, 11, 20, new Uint8Array([4, 5]));

  const response = await worker.fetch(
    new Request(`https://example.invalid/b/${BUCKET}/stats`),
    { BLOBS: env.BLOBS } as unknown as Parameters<typeof worker.fetch>[1],
  );
  const body = await response.json() as Record<string, unknown>;

  assertEquals(body.objects, 2);
  assertEquals(body.bytes, 5);
  assertEquals(body.lowestSeq, 1);
  assertEquals(body.highestSeq, 20);
  assertEquals(body.complete, true);
  assert(env.BLOBS.store.has(signingKeyObject(BUCKET)), "the writer never got registered");
});

Deno.test("an unknown bucket is empty rather than an error", async () => {
  const env = { BLOBS: new MemoryBucket() };
  const response = await worker.fetch(
    new Request(`https://example.invalid/b/${BUCKET}/stats`),
    { BLOBS: env.BLOBS } as unknown as Parameters<typeof worker.fetch>[1],
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
