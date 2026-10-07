// The wire half of efferent.mjs: HPKE, the handoff, days, the read key,
// frames and edits. Ported from tests/test_wire.py, with the same vectors.

import assert from "node:assert/strict";
import { createHash, createPublicKey, verify } from "node:crypto";
import { describe, test } from "node:test";
import { inflateRawSync } from "node:zlib";

import * as wire from "../../efferent.mjs";
import { editorPair, handoff, readingPair, sealLegacy } from "./helpers.mjs";

const aad = (text) => Buffer.from(text);

function verifyEd25519(publicRaw, message, signature) {
  const key = createPublicKey({
    key: Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), publicRaw]),
    format: "der",
    type: "spki",
  });
  return verify(null, Buffer.from(message), key, signature);
}

describe("HPKE", () => {
  test("RFC 9180 vectors seal and open as published", () => {
    assert.match(wire.selfTest(), /exactly as published/);
  });

  test("a fresh key opens what was sealed to it", () => {
    const { secret, publicRaw } = readingPair();
    const sealed = wire.hpkeSeal(publicRaw, wire.INFO, aad("aad"), aad("the day"));
    assert.equal(wire.hpkeOpen(secret, wire.INFO, aad("aad"), sealed).toString(), "the day");
  });

  test("sealing twice differs and both open", () => {
    const { secret, publicRaw } = readingPair();
    const first = wire.hpkeSeal(publicRaw, wire.INFO, aad("aad"), aad("x"));
    const second = wire.hpkeSeal(publicRaw, wire.INFO, aad("aad"), aad("x"));
    assert.notDeepEqual(first, second);
    assert.equal(wire.hpkeOpen(secret, wire.INFO, aad("aad"), second).toString(), "x");
  });

  test("another day, another bucket or another key is refused", () => {
    const { secret, publicRaw } = readingPair();
    const other = readingPair().secret;
    const sealed = wire.hpkeSeal(publicRaw, wire.INFO, aad("efferent/v1\nb\n2026-01-01"), aad("x"));
    assert.throws(() =>
      wire.hpkeOpen(secret, wire.INFO, aad("efferent/v1\nb\n2026-01-02"), sealed)
    );
    assert.throws(() =>
      wire.hpkeOpen(secret, wire.INFO, aad("efferent/v1\nc\n2026-01-01"), sealed)
    );
    assert.throws(() => wire.hpkeOpen(other, wire.INFO, aad("efferent/v1\nb\n2026-01-01"), sealed));
  });

  test("a flipped byte is refused, not returned", () => {
    const { secret, publicRaw } = readingPair();
    const sealed = wire.hpkeSeal(publicRaw, wire.INFO, aad("aad"), Buffer.alloc(40, "x"));
    sealed[sealed.length - 1] ^= 1;
    assert.throws(() => wire.hpkeOpen(secret, wire.INFO, aad("aad"), sealed), /does not open/);
  });

  test("the base32 bucket id matches the standard encoding", () => {
    const { publicRaw } = readingPair();
    // RFC 4648 base32 of the SHA-256, lower case, first 26 characters — the
    // Python reference spells it with base64.b32encode.
    const digest = createHash("sha256").update(publicRaw).digest();
    const alphabet = "abcdefghijklmnopqrstuvwxyz234567";
    let bits = "";
    for (const byte of digest) bits += byte.toString(2).padStart(8, "0");
    let expected = "";
    for (let index = 0; index + 5 <= bits.length; index += 5) {
      expected += alphabet[Number.parseInt(bits.slice(index, index + 5), 2)];
    }
    assert.equal(wire.bucketOf(publicRaw), expected.slice(0, 26));
  });
});

describe("Handoff", () => {
  test("four fields give endpoint, bucket and both keys", () => {
    const reading = readingPair();
    const editor = editorPair();
    const made = wire.connection(handoff(reading, editor));
    assert.equal(made.endpoint, "https://efferent.example");
    assert.equal(made.bucket, wire.bucketOf(reading.publicRaw));
    assert.deepEqual(made.privateRaw, reading.secret);
    assert.deepEqual(made.editorRaw, editor.secret);
  });

  test("three fields read and cannot write", () => {
    assert.equal(wire.connection(handoff(readingPair(), null)).editorRaw, null);
  });

  test("a key that belongs to another bucket is refused", () => {
    const text = handoff(readingPair(), null, "a".repeat(26));
    assert.throws(() => wire.connection(text), /different bucket/);
  });

  test("mismatched halves are refused", () => {
    const text = handoff(readingPair(), null);
    // The public half of another key in place of the real one: the private
    // half no longer derives it, and the importer says so before it looks at
    // the bucket.
    const forged = `${text.slice(0, text.lastIndexOf("."))}.${
      wire.toBase64url(readingPair().publicRaw)
    }`;
    assert.throws(() => wire.connection(forged), /do not match/);
  });

  test("mismatched editor halves are refused", () => {
    const text = handoff(readingPair(), editorPair());
    const forged = `${text.slice(0, text.lastIndexOf("."))}.${
      wire.toBase64url(editorPair().publicRaw)
    }`;
    assert.throws(() => wire.connection(forged), /editor key do not match/);
  });

  test("a query on the MCP URL is refused", () => {
    const text = handoff(readingPair(), null).replace("\n\nReading key", "?x=1\n\nReading key");
    assert.throws(() => wire.connection(text), /query/);
  });

  test("a missing field is named", () => {
    assert.throws(() => wire.connection("Instruction:\nx\n\nReading key:\ny\n"), /no MCP field/);
  });

  test("a path that is not /mcp/b/<bucket> is refused", () => {
    const text = handoff(readingPair(), null).replace("/mcp/b/", "/mcp/x/");
    assert.throws(() => wire.connection(text), /must end in \/mcp\/b\/<bucket-id>/);
  });
});

describe("Days", () => {
  test("a columnar day expands to one line per row", () => {
    const day = {
      v: 2,
      series: [{
        k: "agg",
        metric: "steps",
        bucket: "hour",
        unit: "count",
        source: "Watch",
        t0: 1_754_557_200,
        t: [0, 3600],
        d: [3600, 3600],
        value: [842, 120],
      }],
    };
    const lines = wire.expand(Buffer.from(JSON.stringify(day))).trim().split("\n");
    assert.equal(lines.length, 2);
    const first = JSON.parse(lines[0]);
    assert.equal(first.id, "agg:steps:2025-08-07T09:00:00Z:h");
    assert.equal(first.value, 842);
    assert.equal(first.end, "2025-08-07T10:00:00Z");
    assert.equal(first.bucket, "hour");
    assert.equal(JSON.parse(lines[1]).value, 120);
    // Keys sorted, as Python's json.dumps(sort_keys=True) writes them.
    assert.deepEqual(Object.keys(first), [...Object.keys(first)].sort());
  });

  test("rows that land on one instant are numbered", () => {
    const day = {
      v: 2,
      series: [{
        k: "hk",
        metric: "sleep",
        t0: 1_754_517_600,
        t: [0, 0],
        d: [600, 1200],
        stage: ["asleepCore", "asleepDeep"],
      }],
    };
    const ids = wire.expand(Buffer.from(JSON.stringify(day))).trim().split("\n")
      .map((line) => JSON.parse(line).id);
    assert.deepEqual(ids, ["hk:sleep:2025-08-06T22:00:00Z#1", "hk:sleep:2025-08-06T22:00:00Z#2"]);
  });

  test("a null in a column is left out of that row", () => {
    const day = {
      v: 2,
      series: [{ k: "hk", metric: "heartRate", t0: 100, t: [0, 1], d: [0, 0], value: [60, null] }],
    };
    const events = wire.eventsOf(Buffer.from(JSON.stringify(day)));
    assert.equal(events[0].value, 60);
    assert.equal("value" in events[1], false);
  });

  test("a day written as lines passes through", () => {
    const lines = '{"id":"a","v":1}\n{"id":"b","v":1}\n';
    assert.equal(wire.expand(Buffer.from(lines)), lines);
    assert.equal(wire.expand(Buffer.from("")), "");
  });

  test("a layout this reader does not speak is refused", () => {
    assert.throws(
      () => wire.expand(Buffer.from('{"v":3,"series":[]}')),
      /layout 3, and this reader speaks 2/,
    );
  });

  test("a day is a calendar day that exists", () => {
    assert.equal(wire.isDay("2026-02-28"), true);
    assert.equal(wire.isDay("2024-02-29"), true);
    assert.equal(wire.isDay("2026-02-29"), false);
    assert.equal(wire.isDay("2026-2-28"), false);
  });
});

describe("Read key", () => {
  // Nobody stores it: the phone and every reader make it from the reading key,
  // so the derivation itself is the contract, and these vectors are what the
  // Swift side is held to as well.
  const READING_PRIVATE = Buffer.from(Array.from({ length: 32 }, (_, index) => index + 1));
  const BUCKET = "abucketidmadeupforthistest";
  const TARGET = `/b/${BUCKET}/d?from=2026-08-01&to=2026-08-31`;

  test("the read key matches the published vector", () => {
    const seed = wire.readKey(READING_PRIVATE);
    assert.equal(
      seed.toString("hex"),
      "39e7d153a3e583b4036f36b661bf06e3714d6c29d969c347d2bbe45e6bdc87be",
    );
    assert.equal(
      wire.publicOf("ed25519", seed).toString("hex"),
      "434172a1e4cbfe85eb1097bdc785a22e5a293a0c05ddee75ff146822f9ee53b5",
    );
  });

  test("a read signature matches the published vector", () => {
    const message = wire.canonicalRead(BUCKET, TARGET, 1_700_000_000);
    assert.equal(
      message,
      "efferent/v1 read\nabucketidmadeupforthistest\n" +
        "/b/abucketidmadeupforthistest/d?from=2026-08-01&to=2026-08-31\n1700000000",
    );
    assert.equal(
      wire.signEd25519(wire.readKey(READING_PRIVATE), message).toString("hex"),
      "babf8af472d036155a4cbb7bb5385cb0dc360aa18e27c825660609b5d28937f9" +
        "502366c466fbfb9fc724e8d0d3615e47f77b6f9fe62c312b80f3a8267d037900",
    );
  });

  test("the headers sign the path and query exactly as sent", () => {
    const headers = wire.readHeaders(
      `https://efferent.example${TARGET}`,
      BUCKET,
      READING_PRIVATE,
      1_700_000_000,
    );
    assert.equal(headers["X-Efferent-Timestamp"], "1700000000");
    const publicRaw = wire.publicOf("ed25519", wire.readKey(READING_PRIVATE));
    assert.equal(headers["X-Efferent-Reader"], wire.toBase64url(publicRaw));
    assert.ok(verifyEd25519(
      publicRaw,
      wire.canonicalRead(BUCKET, TARGET, 1_700_000_000),
      wire.fromBase64url(headers["X-Efferent-Signature"]),
    ));

    // No query, no question mark: the service signs what the URL parser leaves
    // of it, and an empty query leaves nothing.
    const bare = wire.readHeaders(
      `https://efferent.example/b/${BUCKET}/stats`,
      BUCKET,
      READING_PRIVATE,
      1,
    );
    assert.ok(verifyEd25519(
      publicRaw,
      wire.canonicalRead(BUCKET, `/b/${BUCKET}/stats`, 1),
      wire.fromBase64url(bare["X-Efferent-Signature"]),
    ));
  });

  test("another reading key makes another read key", () => {
    const other = Buffer.from(Array.from({ length: 32 }, (_, index) => index + 2));
    assert.notDeepEqual(
      wire.publicOf("ed25519", wire.readKey(READING_PRIVATE)),
      wire.publicOf("ed25519", wire.readKey(other)),
    );
  });
});

describe("Frames", () => {
  // A range answer: the upload frame travelling back.
  const frame = (...days) =>
    Buffer.concat(days.flatMap(([day, blob]) => {
      const length = Buffer.alloc(4);
      length.writeUInt32BE(blob.length);
      return [Buffer.from(day), length, Buffer.from(blob)];
    }));

  test("days come back in order with their bytes", () => {
    const days = wire.unpackFrame(frame(["2026-08-01", "one"], ["2026-08-03", "three"]));
    assert.deepEqual(days.map(([day, blob]) => [day, blob.toString()]), [
      ["2026-08-01", "one"],
      ["2026-08-03", "three"],
    ]);
  });

  test("an empty answer is a range with no days", () => {
    assert.deepEqual(wire.unpackFrame(Buffer.alloc(0)), []);
  });

  test("every way a frame is wrong is refused whole", () => {
    const good = frame(["2026-08-01", "one"]);
    const cases = [
      [good.subarray(0, -1), /only 2 are there/],
      [Buffer.concat([good, Buffer.from("2026-08")]), /left over/],
      [frame(["2026-08-01", "one"], ["2026-08-01", "again"]), /ascend/],
      [frame(["2026-02-30", "one"]), /not a day/],
      [frame(["2026-08-01", ""]), /no body/],
    ];
    for (const [body, pattern] of cases) assert.throws(() => wire.unpackFrame(body), pattern);
  });
});

describe("Envelopes", () => {
  test("a version 1 day still opens during migration", () => {
    // Built here with the legacy recipe: X25519, HKDF salted with both public
    // halves, AES-256-GCM.
    const { secret, publicRaw } = readingPair();
    const sealed = sealLegacy(publicRaw, aad("efferent/v1\nb\n2026-01-01"), aad("old day"));
    assert.equal(sealed[0], 1);
    assert.equal(
      wire.openSealed(secret, publicRaw, sealed, aad("efferent/v1\nb\n2026-01-01")).toString(),
      "old day",
    );
    assert.throws(() =>
      wire.openSealed(secret, publicRaw, sealed, aad("efferent/v1\nb\n2026-01-02"))
    );
  });

  test("an envelope this reader does not speak is refused", () => {
    const { secret, publicRaw } = readingPair();
    assert.throws(
      () => wire.openSealed(secret, publicRaw, Buffer.from([3, 0, 0]), aad("x")),
      /unsupported sealed version 3/,
    );
  });
});

describe("Edits", () => {
  const PUT = {
    op: "put",
    id: "agent:meal:2026-08-28:lunch",
    metric: "dietaryEnergy",
    start: 1_756_382_400,
    end: 1_756_384_200,
    value: 640,
    unit: "kcal",
  };

  test("valid items pass and pack deterministically", () => {
    const items = [PUT, { op: "delete", id: "agent:meal:2026-08-20:dinner" }];
    assert.equal(wire.validateItems(items), items);
    const packed = wire.packEdit(items);
    const text = JSON.parse(inflateRawSync(packed).toString());
    assert.equal(text.v, wire.EDIT_FORMAT_VERSION);
    assert.deepEqual(text.items[1], { op: "delete", id: "agent:meal:2026-08-20:dinner" });
    assert.deepEqual(Object.keys(text.items[0]), [
      "op",
      "id",
      "metric",
      "start",
      "end",
      "value",
      "unit",
    ]);
    assert.deepEqual(packed, wire.packEdit(items));
  });

  test("every way an item is wrong names the item", () => {
    const cases = [
      [{ ...PUT, unit: "g" }, "unit"],
      [{ ...PUT, metric: "steps" }, "metric"],
      [{ ...PUT, end: PUT.start - 1 }, "before start"],
      [{ ...PUT, id: "bad id" }, "id"],
      [{ ...PUT, extra: 1 }, "extra"],
      [{ op: "delete" }, "id"],
      [{ op: "move", id: "x" }, "op"],
      [{ ...PUT, metric: "sleep", value: undefined, unit: undefined, stage: "nap" }, "stage|value"],
    ];
    for (const [item, pattern] of cases) {
      const clean = Object.fromEntries(
        Object.entries(item).filter(([, value]) => value !== undefined),
      );
      assert.throws(() => wire.validateItems([clean]), new RegExp(`item 0: .*(${pattern})`));
    }
  });

  test("an empty or oversized edit is refused", () => {
    assert.throws(() => wire.validateItems([]));
    assert.throws(
      () => wire.validateItems(Array(wire.MAX_ITEMS_PER_EDIT + 1).fill(PUT)),
      new RegExp(String(wire.MAX_ITEMS_PER_EDIT)),
    );
  });

  test("an edit signs the protocol, the bucket, the moment and the body", () => {
    const sealed = Buffer.from("sealed bytes");
    const digest = wire.toBase64url(createHash("sha256").update(sealed).digest());
    assert.equal(
      wire.canonicalEdit("bucket", 1700000000, sealed),
      `efferent/v1 edit\nbucket\n1700000000\n${digest}`,
    );
    assert.equal(wire.editAssociatedData("bucket").toString(), "efferent/v1 edit\nbucket");
    assert.equal(
      wire.associatedData("bucket", "2026-01-01").toString(),
      "efferent/v1\nbucket\n2026-01-01",
    );
  });
});
