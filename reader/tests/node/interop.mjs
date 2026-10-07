// Do the phone and the Node client agree on the wire?
//
// The Node half of `deno task interop`, beside the Python one in
// reader/efferent/interop.py. `fixture <state>` seals and signs the edit the
// phone's test opens, so what the phone opens is what an agent's client sends.
// `check <state>` opens the two days the Swift test packed, rebuilds their ids,
// checks that each day is bound to its date, and makes the read key from the
// fixture's reading key and verifies the read the phone signed with it.
//
// The fixed reading key the Swift test seals days to is not repeated here: its
// private half lives in reader/efferent/interop.py, the one file the secret
// scanner excuses for it, and scripts/interop.ts hands it over in
// EFFERENT_INTEROP_READING_PRIVATE.

import { createPublicKey, generateKeyPairSync, verify } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { inflateRawSync } from "node:zlib";

import * as wire from "../../efferent.mjs";
import { packDay } from "./helpers.mjs";

const DAY = "2026-08-07";
const SECOND_DAY = "2026-08-08";
// The same items the Python fixture sealed, so the phone's test expects them.
const ITEMS = [
  {
    op: "put",
    id: "agent:meal:2026-08-07:lunch",
    metric: "dietaryEnergy",
    start: 1_754_568_000,
    end: 1_754_569_800,
    value: 640,
    unit: "kcal",
  },
  {
    op: "put",
    id: "agent:sleep:2026-08-06:core",
    metric: "sleep",
    start: 1_754_517_600,
    end: 1_754_542_800,
    stage: "asleepCore",
  },
  { op: "delete", id: "agent:meal:2026-08-01:dinner" },
];

function section(title) {
  process.stdout.write(`\n==> ${title}\n`);
}

function expect(condition, message) {
  if (condition) return;
  process.stderr.write(`error: ${message}\n`);
  process.exit(1);
}

function rawOf(privateKey) {
  return Buffer.from(privateKey.export({ format: "jwk" }).d, "base64url");
}

function verifies(publicRaw, signature, message) {
  const key = createPublicKey({
    key: Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), publicRaw]),
    format: "der",
    type: "spki",
  });
  return verify(null, Buffer.from(message), key, signature);
}

/**
 * An edit the way an agent's client makes one: packed, sealed to a reading key
 * with the bucket in the tag, signed by an editor key over the canonical
 * message. Both keys are made for this run; the reading key travels to the
 * test as its raw private half, the editor key as its public half.
 */
function fixture(statePath) {
  const reading = rawOf(generateKeyPairSync("x25519").privateKey);
  const readingPublic = wire.publicOf("x25519", reading);
  const bucket = wire.bucketOf(readingPublic);
  const editor = rawOf(generateKeyPairSync("ed25519").privateKey);

  wire.validateItems(ITEMS);
  const sealed = Buffer.concat([
    Buffer.from([wire.SEALED_VERSION]),
    wire.hpkeSeal(readingPublic, wire.INFO, wire.editAssociatedData(bucket), wire.packEdit(ITEMS)),
  ]);
  const timestamp = 1_700_000_000;
  const signature = wire.signEd25519(editor, wire.canonicalEdit(bucket, timestamp, sealed));
  const made = wire.toBase64url(Buffer.from(JSON.stringify({
    bucket,
    readingPrivate: wire.toBase64url(reading),
    editor: wire.toBase64url(wire.publicOf("ed25519", editor)),
    timestamp,
    signature: wire.toBase64url(signature),
    sealed: wire.toBase64url(sealed),
  })));
  writeFileSync(statePath, JSON.stringify({ fixture: made }));
  process.stdout.write(`${made}\n`);
}

/**
 * Open one sealed day, and require that the Node packer writes the very bytes
 * the phone wrote: a day packed two ways is a day re-uploaded for ever.
 */
function readDay(blob, day, privateRaw, publicRaw, bucket) {
  const plaintext = inflateRawSync(
    wire.openSealed(privateRaw, publicRaw, blob, wire.associatedData(bucket, day)),
  );
  const events = wire.eventsOf(plaintext);
  const repacked = packDay(events.map(({ id: _, ...rest }) => rest));
  expect(repacked === plaintext.toString(), `Swift and Node packed ${day} differently`);
  return events;
}

function check(statePath) {
  const state = JSON.parse(readFileSync(statePath, "utf8"));
  const emitted = state.emitted;
  const stored = process.env.EFFERENT_INTEROP_READING_PRIVATE;
  expect(stored, "EFFERENT_INTEROP_READING_PRIVATE is not set; run this through deno task interop");
  const privateRaw = wire.rawPrivate(stored);
  const publicRaw = wire.publicOf("x25519", privateRaw);
  const bucket = wire.bucketOf(publicRaw);

  section("Importing the phone-owned reading key into Node");
  const imported = wire.parseConnectionHandoff(wire.fromBase64url(emitted.handoff).toString());
  expect(
    imported.mcpURL === `https://efferent.example/mcp/b/${imported.bucket}`,
    "the Node importer did not keep the bucket embedded in the phone's MCP URL",
  );

  section("Unpacking the request the phone built");
  const frame = wire.fromBase64url(emitted.frame);
  const packed = wire.unpackFrame(frame);
  expect(
    packed.map(([day]) => day).join(",") === `${DAY},${SECOND_DAY}`,
    "the frame named other days",
  );

  section("Opening each day with the reading key");
  const lines = readDay(packed[0][1], DAY, privateRaw, publicRaw, bucket);
  expect(lines.length === 2, `expected 2 events, got ${lines.length}`);
  expect(lines[0].id === "agg:steps:2025-08-07T09:00:00Z:h", `first id was ${lines[0].id}`);
  expect(lines[0].metric === "steps" && lines[0].value === 842, "the fields did not survive");
  expect(lines[0].bucket === "hour", "a total has to say which bucket it is");
  expect(lines[1].id === "hk:sleep:2025-08-06T22:00:00Z", `second id was ${lines[1].id}`);
  expect(
    lines[1].stage === "asleepCore" && !("bucket" in lines[1]),
    "the sleep record did not survive",
  );
  const second = readDay(packed[1][1], SECOND_DAY, privateRaw, publicRaw, bucket);
  expect(second.length === 1 && second[0].value === 1201, "the second day did not survive");

  let moved = true;
  try {
    wire.openSealed(privateRaw, publicRaw, packed[1][1], wire.associatedData(bucket, DAY));
  } catch {
    moved = false;
  }
  expect(!moved, "a day opened under another date — the date is not bound into the tag");

  section("Making the read key the phone made, and verifying its read");
  const made = JSON.parse(wire.fromBase64url(state.fixture).toString());
  const readerPublic = wire.publicOf(
    "ed25519",
    wire.readKey(wire.fromBase64url(made.readingPrivate)),
  );
  expect(
    emitted.reader === wire.toBase64url(readerPublic),
    "the phone and Node made different read keys",
  );
  const target = `/b/${made.bucket}/d?from=${DAY}&to=${SECOND_DAY}`;
  const signature = wire.fromBase64url(emitted.readSignature);
  expect(
    verifies(readerPublic, signature, wire.canonicalRead(made.bucket, target, made.timestamp)),
    "Node could not verify a read the phone signed",
  );
  const widened = `/b/${made.bucket}/d?from=${DAY}&to=2026-12-31`;
  expect(
    !verifies(readerPublic, signature, wire.canonicalRead(made.bucket, widened, made.timestamp)),
    "a read signed for one range verified for another",
  );

  section("Checking what the phone made of the edit Node sealed");
  expect(
    emitted.editItems === String(ITEMS.length),
    `the phone unpacked ${emitted.editItems} items`,
  );
  expect(
    emitted.editIds === ITEMS.map((item) => item.id).join(","),
    `the phone read the ids as ${emitted.editIds}`,
  );
  expect(
    emitted.editMetrics === ITEMS.map((item) => item.metric ?? "delete").join(","),
    `the phone read the metrics as ${emitted.editMetrics}`,
  );
  section(`The phone and Node agree: bucket ${bucket}, 2 days, an edit of ${ITEMS.length} items`);
}

const [command, statePath] = process.argv.slice(2);
if (command === "fixture" && statePath) fixture(statePath);
else if (command === "check" && statePath) check(statePath);
else {
  process.stderr.write("usage: node interop.mjs fixture|check <state>\n");
  process.exit(2);
}
