import { assert, assertEquals, assertRejects } from "@std/assert";

import { base32, bucketId, isBucketId, objectKey, parseObjectName } from "./ids.ts";
import { canonicalRequest, signUpload, verifyUpload } from "./signing.ts";
import { associatedData, open, seal } from "./sealedbox.ts";
import { compress, decompress } from "./framing.ts";

const encoder = new TextEncoder();

async function readingKeys(): Promise<{ privateKey: CryptoKey; publicRaw: Uint8Array }> {
  const pair = await crypto.subtle.generateKey({ name: "X25519" }, true, [
    "deriveBits",
  ]) as CryptoKeyPair;
  return {
    privateKey: pair.privateKey,
    publicRaw: new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey)),
  };
}

async function writerKeys(): Promise<{ privateKey: CryptoKey; publicRaw: Uint8Array }> {
  const pair = await crypto.subtle.generateKey({ name: "Ed25519" }, true, [
    "sign",
    "verify",
  ]) as CryptoKeyPair;
  return {
    privateKey: pair.privateKey,
    publicRaw: new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey)),
  };
}

Deno.test("base32 matches RFC 4648 in lowercase", () => {
  assertEquals(base32(encoder.encode("foobar")), "mzxw6ytboi");
});

Deno.test("the same reading key always names the same bucket", async () => {
  const { publicRaw } = await readingKeys();

  const first = await bucketId(publicRaw);
  const second = await bucketId(publicRaw);

  assertEquals(first, second);
  assert(isBucketId(first), `${first} should look like a bucket id`);
});

Deno.test("different reading keys name different buckets", async () => {
  const one = await bucketId((await readingKeys()).publicRaw);
  const another = await bucketId((await readingKeys()).publicRaw);

  assert(one !== another);
});

/// Paging walks a plain lexicographic listing, so blob 100 must sort after
/// blob 20 — without the padding it would not, and reads would skip data.
Deno.test("object names sort in sequence order", () => {
  const names = [
    objectKey("b", 100, 199),
    objectKey("b", 20, 99),
    objectKey("b", 1, 19),
  ].sort();

  assertEquals(names.map((name) => parseObjectName(name.split("/")[2])?.seqFrom), [1, 20, 100]);
});

Deno.test("a signature covers the body, not just the headers", async () => {
  const { privateKey, publicRaw } = await writerKeys();
  const header = { bucket: "a".repeat(26), seqFrom: 1, seqTo: 5, timestamp: 1_700_000_000 };
  const body = encoder.encode("the batch as sent");

  const signature = await signUpload(privateKey, header, body);

  assert(await verifyUpload(publicRaw, signature, header, body));
  assert(!await verifyUpload(publicRaw, signature, header, encoder.encode("a different batch")));
});

Deno.test("a signature does not carry over to another sequence range", async () => {
  const { privateKey, publicRaw } = await writerKeys();
  const header = { bucket: "a".repeat(26), seqFrom: 1, seqTo: 5, timestamp: 1_700_000_000 };
  const body = encoder.encode("batch");

  const signature = await signUpload(privateKey, header, body);

  assert(!await verifyUpload(publicRaw, signature, { ...header, seqTo: 6 }, body));
});

Deno.test("someone else's key does not verify the signature", async () => {
  const mine = await writerKeys();
  const theirs = await writerKeys();
  const header = { bucket: "a".repeat(26), seqFrom: 1, seqTo: 1, timestamp: 1_700_000_000 };
  const body = encoder.encode("batch");

  const signature = await signUpload(mine.privateKey, header, body);

  assert(!await verifyUpload(theirs.publicRaw, signature, header, body));
});

Deno.test("the canonical request names every field the server acts on", async () => {
  const line = await canonicalRequest(
    { bucket: "b".repeat(26), seqFrom: 7, seqTo: 9, timestamp: 1_700_000_000 },
    encoder.encode("x"),
  );

  assertEquals(line.split("\n").slice(0, 5), [
    "efferent/v1",
    "b".repeat(26),
    "7",
    "9",
    "1700000000",
  ]);
});

Deno.test("what the phone seals, the reading key opens", async () => {
  const { privateKey, publicRaw } = await readingKeys();
  const aad = associatedData("c".repeat(26), 1, 3);
  const plaintext = encoder.encode('{"metric":"steps"}');

  const blob = await seal(publicRaw, plaintext, aad);

  assertEquals(await open(privateKey, publicRaw, blob, aad), plaintext);
});

/// The phone holds only the public half, so a stolen phone gives up nothing
/// about what it already sent. Sealing twice must not produce the same bytes.
Deno.test("sealing the same batch twice gives different ciphertext", async () => {
  const { publicRaw } = await readingKeys();
  const aad = associatedData("c".repeat(26), 1, 1);
  const plaintext = encoder.encode("same every time");

  const first = await seal(publicRaw, plaintext, aad);
  const second = await seal(publicRaw, plaintext, aad);

  assert(!first.every((byte, index) => byte === second[index]));
});

/// A service that cannot read a blob could still move it to another bucket or
/// relabel its range. Binding both into the tag makes that fail loudly.
Deno.test("a blob cannot be relabelled with another range", async () => {
  const { privateKey, publicRaw } = await readingKeys();
  const bucket = "d".repeat(26);
  const blob = await seal(publicRaw, encoder.encode("batch"), associatedData(bucket, 1, 3));

  await assertRejects(() => open(privateKey, publicRaw, blob, associatedData(bucket, 4, 6)));
});

Deno.test("a blob cannot be moved to another bucket", async () => {
  const { privateKey, publicRaw } = await readingKeys();
  const blob = await seal(publicRaw, encoder.encode("batch"), associatedData("d".repeat(26), 1, 3));

  await assertRejects(() =>
    open(privateKey, publicRaw, blob, associatedData("e".repeat(26), 1, 3))
  );
});

Deno.test("another reading key cannot open the blob", async () => {
  const mine = await readingKeys();
  const theirs = await readingKeys();
  const aad = associatedData("f".repeat(26), 1, 1);
  const blob = await seal(mine.publicRaw, encoder.encode("batch"), aad);

  await assertRejects(() => open(theirs.privateKey, theirs.publicRaw, blob, aad));
});

Deno.test("a flipped byte in the ciphertext is refused, not returned", async () => {
  const { privateKey, publicRaw } = await readingKeys();
  const aad = associatedData("g".repeat(26), 1, 1);
  const blob = await seal(publicRaw, encoder.encode("batch"), aad);
  blob[blob.length - 1] ^= 0x01;

  await assertRejects(() => open(privateKey, publicRaw, blob, aad));
});

Deno.test("NDJSON survives the compression it travels under", async () => {
  const lines = Array.from(
    { length: 200 },
    (_, index) => `{"id":"agg:steps:${index}:h","seq":${index},"v":1,"type":"health.agg"}`,
  ).join("\n");
  const original = encoder.encode(lines);

  const packed = await compress(original);

  assertEquals(await decompress(packed), original);
  assert(packed.length < original.length / 5, `expected real compression, got ${packed.length}`);
});
