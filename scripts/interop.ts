/**
 * `deno task interop` — do the two implementations still agree?
 *
 * `protocol/` and the Swift under `src/Core` describe the same bytes twice, in
 * two languages, and nothing but a test keeps them in step. A Swift test packs,
 * seals and signs a real request of two days; this unpacks it, opens each day
 * with the matching private key and checks the signature. Drift between the two
 * shows up here rather than on a phone.
 *
 * Two days rather than one on purpose: a batch of one would never exercise the
 * boundary between them, which is where a framing disagreement would live.
 *
 * The reading key below is a fixture. Its public half is in `WireTests.swift`,
 * its private half is right here in the open — it guards nothing.
 */

import { fail, run, section } from "./lib.ts";
import { SCHEME, systemToolPath, WORKSPACE } from "./config.ts";
import { generate } from "./generate.ts";
import { associatedData, open, rawPrivateKey } from "../protocol/sealedbox.ts";
import { decompress } from "../protocol/framing.ts";
import { type DayEvent, expand, pack } from "../protocol/day.ts";
import { unpackDays } from "../protocol/batch.ts";
import {
  base64url,
  canonicalEdit,
  canonicalRequest,
  fromBase64url,
  signMessage,
  verifyUpload,
} from "../protocol/signing.ts";
import { bucketId } from "../protocol/ids.ts";
import { editAssociatedData, type EditItem, packEdits } from "../protocol/edits.ts";
import { seal } from "../protocol/sealedbox.ts";
import { parseConnectionHandoff } from "../tools/connection.ts";

/**
 * A throwaway key pair, generated for this check and used nowhere else.
 *
 * It is committed on purpose: the check has to open what Swift sealed, so both
 * halves must be identical on every machine, and a key that must be identical
 * everywhere cannot be a secret. It guards nothing — the bucket it addresses
 * holds two days of made-up steps.
 *
 * The scanner flags keys of exactly this shape, and `.gitleaks.toml` excuses
 * this one by naming both the file and the value, so pasting a different key
 * here still fails the check. That narrowness is the point: the risk is not the
 * fixture, it is the day somebody replaces it with a real reading key — which
 * would be published the moment it was committed, and decrypts everything the
 * archive has ever held.
 */
const READING_PRIVATE = "MC4CAQAwBQYDK2VuBCIEIB-BUIZTXqbNIR0MFd8VXE2BPlP2ohi2pcpCd_FksGD6";
const READING_PUBLIC = "YAvPaXBsGTnyrLF6FcE1oI2EjHmIeKAg07zRX51nI2w";
const DAY = "2026-08-07";
const SECOND_DAY = "2026-08-08";

await generate();

section("Sealing and signing an edit for the phone to open");
// Writing goes the other way round, so this side seals and the phone opens.
// Both keys are made here for this run and never leave the process: the
// reading key travels to the test as its raw private half, the editor key as
// its public half beside the signature, all through the environment.
const edit = await sealAnEdit();

section("Producing a request from the Swift side, and opening the edit there");
const { stdout } = await run("xcodebuild", {
  args: [
    "test",
    "-workspace",
    WORKSPACE,
    "-scheme",
    SCHEME,
    "-destination",
    `platform=iOS Simulator,id=${await anyAvailableIPhone()}`,
    "-only-testing:EfferentTests/InteropTests",
    "-only-testing:EfferentTests/EditInteropTests",
    // Deliberately not `-quiet`: what the test prints is the whole point, and
    // quiet mode swallows it.
  ],
  env: { ...systemToolPath(), TEST_RUNNER_EFFERENT_EDIT_FIXTURE: edit.fixture },
  capture: true,
});

const emitted = {
  frame: marker(stdout, "FRAME"),
  writer: marker(stdout, "WRITER"),
  signature: marker(stdout, "SIGNATURE"),
  timestamp: Number(marker(stdout, "TIMESTAMP")),
  handoff: marker(stdout, "HANDOFF"),
};

section("Importing the phone-owned reading key locally");
const handoff = new TextDecoder().decode(fromBase64url(emitted.handoff));
const importedConnection = await parseConnectionHandoff(handoff);
expect(
  importedConnection.mcpURL ===
    `https://efferent.example/mcp/b/${importedConnection.bucket}`,
  "the local importer did not keep the bucket embedded in the phone's MCP URL",
);
expect(
  importedConnection.reading.readingPrivate.length > 40,
  "the phone's raw private key did not become a local PKCS8 reading key",
);

section("Unpacking the request the phone built");
const readingPublic = fromBase64url(READING_PUBLIC);
const bucket = await bucketId(readingPublic);

const privateRaw = await rawPrivateKey(fromBase64url(READING_PRIVATE));

const frame = fromBase64url(emitted.frame);
const packed = unpackDays(frame);
expect(packed.length === 2, `expected 2 days in the frame, got ${packed.length}`);
expect(
  packed.map((entry) => entry.day).join(",") === `${DAY},${SECOND_DAY}`,
  `the frame named ${packed.map((entry) => entry.day).join(",")}`,
);

section("Opening each day with the reading key");
const lines = await read(packed[0].blob, DAY);
expect(lines.length === 2, `expected 2 events, got ${lines.length}`);
// Totals before records, which is what makes an unchanged day the same bytes
// twice — and the id below is rebuilt here, not carried on the wire.
expect(lines[0].id === "agg:steps:2025-08-07T09:00:00Z:h", `first id was ${lines[0].id}`);
expect(lines[0].metric === "steps" && lines[0].value === 842, "the fields did not survive");
expect(lines[0].bucket === "hour", "a total has to say which bucket it is");
expect(lines[1].id === "hk:sleep:2025-08-06T22:00:00Z", `second id was ${lines[1].id}`);
expect(lines[1].metric === "sleep" && lines[1].stage === "asleepCore", "the sleep stage was lost");
expect(lines[1].bucket === undefined, "a record must not look like a total");

const second = await read(packed[1].blob, SECOND_DAY);
expect(second.length === 1, `expected 1 event on the second day, got ${second.length}`);
expect(second[0].value === 1201, `the second day's total was ${second[0].value}`);

// Each day is sealed to its own date, so the one cannot be opened as the other.
// Without that, a service could hand back Friday for Thursday and nothing would
// notice — the day is only in the tag, never in the ciphertext.
let moved = false;
try {
  await open(privateRaw, readingPublic, packed[1].blob, associatedData(bucket, DAY));
  moved = true;
} catch { /* what should happen */ }
expect(!moved, "a day opened under another date — the date is not bound into the tag");

section("Checking the signature the phone produced");
const header = { bucket, days: [DAY, SECOND_DAY], timestamp: emitted.timestamp };
const verified = await verifyUpload(
  fromBase64url(emitted.writer),
  fromBase64url(emitted.signature),
  header,
  frame,
);
expect(verified, "the reader could not verify a signature the phone made");

// A signature that verifies against the wrong body would mean the body hash is
// not really in the canonical string — the failure that lets anyone swap a day.
const tampered = new Uint8Array(frame);
tampered[tampered.length - 1] ^= 0x01;
expect(
  !await verifyUpload(
    fromBase64url(emitted.writer),
    fromBase64url(emitted.signature),
    header,
    tampered,
  ),
  "a changed body still verified — the body is not covered by the signature",
);
expect(
  !await verifyUpload(
    fromBase64url(emitted.writer),
    fromBase64url(emitted.signature),
    { ...header, days: [DAY] },
    frame,
  ),
  "dropping a day from the batch still verified — the days are not in the canonical string",
);

// The bytes agree; whether a real service accepts them is a separate question,
// and the only way to answer it is to ask one.
const postTo = Deno.args.includes("--post")
  ? Deno.args[Deno.args.indexOf("--post") + 1]
  : undefined;

if (postTo) {
  section(`Posting the Swift request to ${postTo}`);
  const response = await fetch(`${postTo}/b/${bucket}/days`, {
    method: "PUT",
    headers: {
      "content-type": "application/octet-stream",
      "x-efferent-timestamp": marker(stdout, "LIVETIMESTAMP"),
      "x-efferent-writer": emitted.writer,
      "x-efferent-signature": marker(stdout, "LIVESIGNATURE"),
    },
    body: frame as BodyInit,
  });
  const answer = await response.text();
  expect(response.ok, `the service refused a request the phone made: ${response.status} ${answer}`);
  expect(
    JSON.parse(answer).stored.join(",") === `${DAY},${SECOND_DAY}`,
    `expected both days back, got ${answer}`,
  );

  section("Reading them back out of the service");
  // Each day has to come back on its own: a batch is a way of travelling, and
  // an archive that kept it as one object would answer a date with a frame.
  for (
    const [day, id] of [[DAY, "agg:steps:2026-08-07T09:00:00Z:h"], [
      SECOND_DAY,
      "agg:steps:2026-08-08T09:00:00Z:h",
    ]]
  ) {
    const stored = new Uint8Array(
      await (await fetch(`${postTo}/b/${bucket}/d/${day}`)).arrayBuffer(),
    );
    const readBack = new TextDecoder().decode(
      await decompress(await open(privateRaw, readingPublic, stored, associatedData(bucket, day))),
    );
    expect(readBack.includes(id), `what came back for ${day} is not what went in`);
    console.log(
      `  ${day}: ${readBack.trim().split("\n").length} lines back, ${stored.length} bytes`,
    );
  }

  const listing = await (await fetch(`${postTo}/b/${bucket}/days`)).json();
  expect(listing.days.length >= 2, `the service listed ${listing.days.length} days back`);
}

section("Checking what the phone made of the edit");
expect(
  marker(stdout, "EDIT_ITEMS") === String(edit.items.length),
  `the phone unpacked ${marker(stdout, "EDIT_ITEMS")} items out of ${edit.items.length}`,
);
expect(
  marker(stdout, "EDIT_IDS") === edit.items.map((item) => item.id).join(","),
  `the phone read the ids as ${marker(stdout, "EDIT_IDS")}`,
);
expect(
  marker(stdout, "EDIT_METRICS") ===
    edit.items.map((item) => item.op === "put" ? item.metric : "delete").join(","),
  `the phone read the metrics as ${marker(stdout, "EDIT_METRICS")}`,
);

section(
  `Both sides agree: bucket ${bucket}, ${packed.length} days, ${frame.length} bytes on the wire, ` +
    `and an edit of ${edit.items.length} items opened on the phone`,
);
console.log(
  `  canonical request the reader rebuilt:\n${
    (await canonicalRequest(header, frame))
      .split("\n").map((part) => `    ${part}`).join("\n")
  }`,
);

// MARK: - Plumbing

/** Open one sealed day and read its lines back. */
async function read(blob: Uint8Array, day: string): Promise<DayEvent[]> {
  const plaintext = await decompress(
    await open(privateRaw, readingPublic, blob, associatedData(bucket, day)),
  );
  const text = new TextDecoder().decode(plaintext);
  const events = expand(text);

  // The strongest thing this check can say: the two implementations do not
  // merely agree about what a day means, they write the same bytes for it. A
  // day whose bytes differ between them is a day the phone would re-upload for
  // ever, because the fingerprint it compares is over exactly these bytes.
  expect(
    pack(events) === text,
    `Swift and TypeScript packed ${day} differently:\n  swift ${text}\n  deno  ${pack(events)}`,
  );
  return events;
}

/**
 * An edit the way `tools/archive.ts` and the Python reference make one: the
 * items packed, sealed to the reading key with the bucket in the tag, and
 * signed by the editor over the canonical message.
 */
async function sealAnEdit(): Promise<{ items: EditItem[]; fixture: string }> {
  const items: EditItem[] = [
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

  const reading = await crypto.subtle.generateKey({ name: "X25519" }, true, [
    "deriveBits",
  ]) as CryptoKeyPair;
  const readingJWK = await crypto.subtle.exportKey("jwk", reading.privateKey);
  if (!readingJWK.d) fail("WebCrypto did not export the private X25519 fixture");
  const readingPublic = new Uint8Array(await crypto.subtle.exportKey("raw", reading.publicKey));
  const editBucket = await bucketId(readingPublic);

  const editor = await crypto.subtle.generateKey({ name: "Ed25519" }, true, [
    "sign",
    "verify",
  ]) as CryptoKeyPair;
  const editorPublic = new Uint8Array(await crypto.subtle.exportKey("raw", editor.publicKey));

  const sealed = await seal(readingPublic, await packEdits(items), editAssociatedData(editBucket));
  const timestamp = 1_700_000_000;
  const signature = await signMessage(
    editor.privateKey,
    await canonicalEdit(editBucket, timestamp, sealed),
  );

  const fixture = base64url(new TextEncoder().encode(JSON.stringify({
    bucket: editBucket,
    readingPrivate: readingJWK.d,
    editor: base64url(editorPublic),
    timestamp,
    signature: base64url(signature),
    sealed: base64url(sealed),
  })));
  return { items, fixture };
}

function marker(output: string, name: string): string {
  const match = new RegExp(`EFFERENT_INTEROP_${name}=(\\S+)`).exec(output);
  if (!match) fail(`the Swift test did not print ${name} — did it run at all?`);
  return match[1];
}

function expect(condition: boolean, message: string): void {
  if (!condition) fail(message);
}

async function anyAvailableIPhone(): Promise<string> {
  const { stdout } = await run("xcrun", {
    args: ["simctl", "list", "devices", "available", "--json"],
    capture: true,
  });
  const devices = JSON.parse(stdout).devices as Record<string, { name: string; udid: string }[]>;
  for (const list of Object.values(devices)) {
    const iPhone = list.find((device) => device.name.startsWith("iPhone"));
    if (iPhone) return iPhone.udid;
  }
  fail("no iPhone simulator is available — install one in Xcode");
}
