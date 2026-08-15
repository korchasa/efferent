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
import { associatedData, open } from "../protocol/sealedbox.ts";
import { decompress } from "../protocol/framing.ts";
import { unpackDays } from "../protocol/batch.ts";
import { canonicalRequest, fromBase64url, verifyUpload } from "../protocol/signing.ts";
import { bucketId } from "../protocol/ids.ts";

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

section("Producing a request from the Swift side");
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
    // Deliberately not `-quiet`: what the test prints is the whole point, and
    // quiet mode swallows it.
  ],
  env: systemToolPath(),
  capture: true,
});

const emitted = {
  frame: marker(stdout, "FRAME"),
  writer: marker(stdout, "WRITER"),
  signature: marker(stdout, "SIGNATURE"),
  timestamp: Number(marker(stdout, "TIMESTAMP")),
};

section("Unpacking the request the phone built");
const readingPublic = fromBase64url(READING_PUBLIC);
const bucket = await bucketId(readingPublic);

const privateKey = await crypto.subtle.importKey(
  "pkcs8",
  fromBase64url(READING_PRIVATE) as BufferSource,
  { name: "X25519" },
  false,
  ["deriveBits"],
);

const frame = fromBase64url(emitted.frame);
const packed = unpackDays(frame);
expect(packed.length === 2, `expected 2 days in the frame, got ${packed.length}`);
expect(
  packed.map((entry) => entry.day).join(",") === `${DAY},${SECOND_DAY}`,
  `the frame named ${packed.map((entry) => entry.day).join(",")}`,
);

section("Opening each day with the reading key");
const lines = await read(packed[0].blob, DAY);
expect(lines.length === 2, `expected 2 lines, got ${lines.length}`);
// Sorted by id, which is what makes an unchanged day the same bytes twice.
expect(lines[0].id === "agg:steps:2026-08-07T09:00:00Z:h", `first id was ${lines[0].id}`);
expect(lines[0].metric === "steps" && lines[0].value === 842, "the payload fields did not survive");
expect(lines[0].bucket === "hour", "a total has to say which bucket it is");
expect(lines[1].id === "hk:sleep:9A2C", `second id was ${lines[1].id}`);
expect(lines[1].metric === "sleep" && lines[1].stage === "asleepCore", "the sleep stage was lost");
expect(lines[1].bucket === undefined, "a record must not look like a total");

const second = await read(packed[1].blob, SECOND_DAY);
expect(second.length === 1, `expected 1 line on the second day, got ${second.length}`);
expect(second[0].value === 1201, `the second day's total was ${second[0].value}`);

// Each day is sealed to its own date, so the one cannot be opened as the other.
// Without that, a service could hand back Friday for Thursday and nothing would
// notice — the day is only in the tag, never in the ciphertext.
let moved = false;
try {
  await open(privateKey, readingPublic, packed[1].blob, associatedData(bucket, DAY));
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
      await decompress(await open(privateKey, readingPublic, stored, associatedData(bucket, day))),
    );
    expect(readBack.includes(id), `what came back for ${day} is not what went in`);
    console.log(
      `  ${day}: ${readBack.trim().split("\n").length} lines back, ${stored.length} bytes`,
    );
  }

  const listing = await (await fetch(`${postTo}/b/${bucket}/days`)).json();
  expect(listing.days.length >= 2, `the service listed ${listing.days.length} days back`);
}

section(
  `Both sides agree: bucket ${bucket}, ${packed.length} days, ${frame.length} bytes on the wire`,
);
console.log(
  `  canonical request the reader rebuilt:\n${
    (await canonicalRequest(header, frame))
      .split("\n").map((part) => `    ${part}`).join("\n")
  }`,
);

// MARK: - Plumbing

/** Open one sealed day and read its lines back. */
async function read(blob: Uint8Array, day: string): Promise<Record<string, unknown>[]> {
  const plaintext = await decompress(
    await open(privateKey, readingPublic, blob, associatedData(bucket, day)),
  );
  return new TextDecoder().decode(plaintext).trim().split("\n").map((line) =>
    JSON.parse(line) as Record<string, unknown>
  );
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
