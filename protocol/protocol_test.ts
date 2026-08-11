import { assert, assertEquals, assertRejects } from "@std/assert";

import { base32, bucketId, dayBefore, dayKey, isBucketId, isDay } from "./ids.ts";
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

/// Paging walks a plain lexicographic listing, so the order days sort in has
/// to be the order they happen in. `YYYY-MM-DD` gives that for free; any
/// friendlier format would not, and reads would silently skip data.
Deno.test("day keys sort in the order the days happened", () => {
  const keys = [
    dayKey("b", "2026-01-02"),
    dayKey("b", "2025-12-31"),
    dayKey("b", "2026-01-10"),
  ].sort();

  assertEquals(keys, [
    dayKey("b", "2025-12-31"),
    dayKey("b", "2026-01-02"),
    dayKey("b", "2026-01-10"),
  ]);
});

/// A date the regex accepts but the calendar does not could be written and then
/// never asked for again.
Deno.test("only dates that exist count as days", () => {
  assert(isDay("2026-02-28"));
  assert(isDay("2024-02-29"), "2024 is a leap year");
  assert(!isDay("2026-02-29"), "2026 is not");
  assert(!isDay("2026-13-01"));
  assert(!isDay("2026-8-7"), "a day is always ten characters");
  assert(!isDay(""));
});

/// A range asks *from* a day while a listing skips *past* a key, so this is
/// what keeps the first day of every range from disappearing.
Deno.test("the day before a boundary crosses months and years", () => {
  assertEquals(dayBefore("2026-08-07"), "2026-08-06");
  assertEquals(dayBefore("2026-08-01"), "2026-07-31");
  assertEquals(dayBefore("2026-01-01"), "2025-12-31");
  assertEquals(dayBefore("2024-03-01"), "2024-02-29");
});

Deno.test("a signature covers the body, not just the headers", async () => {
  const { privateKey, publicRaw } = await writerKeys();
  const header = { bucket: "a".repeat(26), day: "2026-08-07", timestamp: 1_700_000_000 };
  const body = encoder.encode("the batch as sent");

  const signature = await signUpload(privateKey, header, body);

  assert(await verifyUpload(publicRaw, signature, header, body));
  assert(!await verifyUpload(publicRaw, signature, header, encoder.encode("a different batch")));
});

Deno.test("a signature does not carry over to another day", async () => {
  const { privateKey, publicRaw } = await writerKeys();
  const header = { bucket: "a".repeat(26), day: "2026-08-07", timestamp: 1_700_000_000 };
  const body = encoder.encode("batch");

  const signature = await signUpload(privateKey, header, body);

  assert(!await verifyUpload(publicRaw, signature, { ...header, day: "2026-08-08" }, body));
});

Deno.test("someone else's key does not verify the signature", async () => {
  const mine = await writerKeys();
  const theirs = await writerKeys();
  const header = { bucket: "a".repeat(26), day: "2026-08-07", timestamp: 1_700_000_000 };
  const body = encoder.encode("batch");

  const signature = await signUpload(mine.privateKey, header, body);

  assert(!await verifyUpload(theirs.publicRaw, signature, header, body));
});

Deno.test("the canonical request names every field the server acts on", async () => {
  const line = await canonicalRequest(
    { bucket: "b".repeat(26), day: "2026-08-07", timestamp: 1_700_000_000 },
    encoder.encode("x"),
  );

  assertEquals(line.split("\n").slice(0, 4), [
    "efferent/v1",
    "b".repeat(26),
    "2026-08-07",
    "1700000000",
  ]);
});

Deno.test("what the phone seals, the reading key opens", async () => {
  const { privateKey, publicRaw } = await readingKeys();
  const aad = associatedData("c".repeat(26), "2026-08-07");
  const plaintext = encoder.encode('{"metric":"steps"}');

  const blob = await seal(publicRaw, plaintext, aad);

  assertEquals(await open(privateKey, publicRaw, blob, aad), plaintext);
});

/// The phone holds only the public half, so a stolen phone gives up nothing
/// about what it already sent. Sealing twice must not produce the same bytes.
Deno.test("sealing the same batch twice gives different ciphertext", async () => {
  const { publicRaw } = await readingKeys();
  const aad = associatedData("c".repeat(26), "2026-08-07");
  const plaintext = encoder.encode("same every time");

  const first = await seal(publicRaw, plaintext, aad);
  const second = await seal(publicRaw, plaintext, aad);

  assert(!first.every((byte, index) => byte === second[index]));
});

/// A service that cannot read a day could still answer one date with another
/// date's object. Binding the day into the tag makes that fail loudly instead
/// of handing back Tuesday for Monday.
Deno.test("a day cannot be passed off as another day", async () => {
  const { privateKey, publicRaw } = await readingKeys();
  const bucket = "d".repeat(26);
  const blob = await seal(publicRaw, encoder.encode("a day"), associatedData(bucket, "2026-08-07"));

  await assertRejects(() =>
    open(privateKey, publicRaw, blob, associatedData(bucket, "2026-08-08"))
  );
});

Deno.test("a day cannot be moved to another bucket", async () => {
  const { privateKey, publicRaw } = await readingKeys();
  const day = associatedData("d".repeat(26), "2026-08-07");
  const blob = await seal(publicRaw, encoder.encode("a day"), day);

  await assertRejects(() =>
    open(privateKey, publicRaw, blob, associatedData("e".repeat(26), "2026-08-07"))
  );
});

Deno.test("another reading key cannot open the blob", async () => {
  const mine = await readingKeys();
  const theirs = await readingKeys();
  const aad = associatedData("f".repeat(26), "2026-08-07");
  const blob = await seal(mine.publicRaw, encoder.encode("batch"), aad);

  await assertRejects(() => open(theirs.privateKey, theirs.publicRaw, blob, aad));
});

Deno.test("a flipped byte in the ciphertext is refused, not returned", async () => {
  const { privateKey, publicRaw } = await readingKeys();
  const aad = associatedData("g".repeat(26), "2026-08-07");
  const blob = await seal(publicRaw, encoder.encode("batch"), aad);
  blob[blob.length - 1] ^= 0x01;

  await assertRejects(() => open(privateKey, publicRaw, blob, aad));
});

Deno.test("NDJSON survives the compression it travels under", async () => {
  const lines = Array.from(
    { length: 200 },
    (_, index) => `{"id":"agg:steps:${index}:h","v":1,"metric":"steps","bucket":"hour"}`,
  ).join("\n");
  const original = encoder.encode(lines);

  const packed = await compress(original);

  assertEquals(await decompress(packed), original);
  assert(packed.length < original.length / 5, `expected real compression, got ${packed.length}`);
});
