import { assert, assertEquals, assertRejects, assertThrows } from "@std/assert";

import { base32, bucketId, dayBefore, dayKey, isBucketId, isDay } from "./ids.ts";
import { canonicalRequest, signUpload, verifyUpload } from "./signing.ts";
import { associatedData, open, seal } from "./sealedbox.ts";
import { compress, decompress } from "./framing.ts";
import { packDays, type SealedDay, unpackDays } from "./batch.ts";

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
  const header = { bucket: "a".repeat(26), days: ["2026-08-07"], timestamp: 1_700_000_000 };
  const body = encoder.encode("the batch as sent");

  const signature = await signUpload(privateKey, header, body);

  assert(await verifyUpload(publicRaw, signature, header, body));
  assert(!await verifyUpload(publicRaw, signature, header, encoder.encode("a different batch")));
});

Deno.test("a signature does not carry over to another day", async () => {
  const { privateKey, publicRaw } = await writerKeys();
  const header = { bucket: "a".repeat(26), days: ["2026-08-07"], timestamp: 1_700_000_000 };
  const body = encoder.encode("batch");

  const signature = await signUpload(privateKey, header, body);

  assert(!await verifyUpload(publicRaw, signature, { ...header, days: ["2026-08-08"] }, body));
});

/// A batch is authorised as a whole. Dropping one day out of it must not leave
/// the rest signed, or a service could store the part of a batch it preferred.
Deno.test("a signature over a batch does not verify for part of it", async () => {
  const { privateKey, publicRaw } = await writerKeys();
  const days = ["2026-08-06", "2026-08-07", "2026-08-08"];
  const header = { bucket: "a".repeat(26), days, timestamp: 1_700_000_000 };
  const body = encoder.encode("three days");

  const signature = await signUpload(privateKey, header, body);

  assert(!await verifyUpload(publicRaw, signature, { ...header, days: days.slice(0, 2) }, body));
  assert(!await verifyUpload(publicRaw, signature, { ...header, days: days.toReversed() }, body));
});

Deno.test("someone else's key does not verify the signature", async () => {
  const mine = await writerKeys();
  const theirs = await writerKeys();
  const header = { bucket: "a".repeat(26), days: ["2026-08-07"], timestamp: 1_700_000_000 };
  const body = encoder.encode("batch");

  const signature = await signUpload(mine.privateKey, header, body);

  assert(!await verifyUpload(theirs.publicRaw, signature, header, body));
});

Deno.test("the canonical request names every field the server acts on", async () => {
  const line = await canonicalRequest(
    { bucket: "b".repeat(26), days: ["2026-08-06", "2026-08-07"], timestamp: 1_700_000_000 },
    encoder.encode("x"),
  );

  assertEquals(line.split("\n").slice(0, 4), [
    "efferent/v1",
    "b".repeat(26),
    "2026-08-06,2026-08-07",
    "1700000000",
  ]);
});

// MARK: - Batching

/// The one thing framing has to get right: what came out is what went in, byte
/// for byte and under the right date. Everything else in this file is about
/// refusing frames that are wrong.
Deno.test("days survive a round trip through a frame", () => {
  const batch: SealedDay[] = [
    { day: "2025-12-31", blob: new Uint8Array([1, 2, 3]) },
    { day: "2026-01-01", blob: new Uint8Array(300).fill(9) },
    { day: "2026-01-02", blob: new Uint8Array([7]) },
  ];

  const unpacked = unpackDays(packDays(batch));

  assertEquals(unpacked.map((entry) => entry.day), batch.map((entry) => entry.day));
  for (let index = 0; index < batch.length; index++) {
    assertEquals([...unpacked[index].blob], [...batch[index].blob]);
  }
});

/// The same days in the same versions have to pack to the same bytes, because
/// the body's hash is what the signature covers.
Deno.test("the same days always pack to the same bytes", () => {
  const batch: SealedDay[] = [
    { day: "2026-08-06", blob: new Uint8Array([1]) },
    { day: "2026-08-07", blob: new Uint8Array([2, 2]) },
  ];

  assertEquals([...packDays(batch)], [...packDays(batch)]);
});

/// Two copies of a day in one batch would ask which one wins — a question with
/// no answer the sender could predict. Ordering removes it rather than
/// resolving it.
Deno.test("a batch refuses repeated or out-of-order days", () => {
  const blob = new Uint8Array([1]);

  assertThrows(() => packDays([{ day: "2026-08-07", blob }, { day: "2026-08-07", blob }]));
  assertThrows(() => packDays([{ day: "2026-08-07", blob }, { day: "2026-08-06", blob }]));
  assertThrows(() => packDays([{ day: "not a day", blob }]));
  assertThrows(() => packDays([]));
});

/// A frame that unpacked to whatever parsed before it went wrong would have the
/// service store part of a batch and answer as though it stored all of it. The
/// sender would then stop marking the days that never arrived.
Deno.test("a truncated frame is refused rather than salvaged", () => {
  const whole = packDays([
    { day: "2026-08-06", blob: new Uint8Array([1, 2]) },
    { day: "2026-08-07", blob: new Uint8Array([3, 4, 5, 6]) },
  ]);

  assertThrows(() => unpackDays(whole.slice(0, whole.length - 1)), Error, "and only");
  // Cut inside the second day's header, where there is not even a date to name.
  assertThrows(() => unpackDays(whole.slice(0, 16 + 4)), Error, "left over");
  assertThrows(() => unpackDays(new Uint8Array(0)));
});

/// Frames are unpacked out of a request body that owns a larger buffer, and a
/// reader working from `buffer` rather than from the view would silently unpack
/// the bytes on either side of it.
Deno.test("a frame is read within its own bounds", () => {
  const frame = packDays([{ day: "2026-08-07", blob: new Uint8Array([4, 5]) }]);
  const padded = new Uint8Array(frame.length + 8);
  padded.set(frame, 4);

  const unpacked = unpackDays(padded.subarray(4, 4 + frame.length));

  assertEquals(unpacked.length, 1);
  assertEquals([...unpacked[0].blob], [4, 5]);
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
