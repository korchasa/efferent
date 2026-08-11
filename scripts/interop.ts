/**
 * `deno task interop` — do the two implementations still agree?
 *
 * `protocol/` and the Swift under `src/Core` describe the same bytes twice, in
 * two languages, and nothing but a test keeps them in step. A Swift test seals
 * and signs a real day; this opens it with the matching private key and checks
 * the signature. Drift between the two shows up here rather than on a phone.
 *
 * The reading key below is a fixture. Its public half is in `WireTests.swift`,
 * its private half is right here in the open — it guards nothing.
 */

import { fail, run, section } from "./lib.ts";
import { SCHEME, systemToolPath, WORKSPACE } from "./config.ts";
import { generate } from "./generate.ts";
import { associatedData, open } from "../protocol/sealedbox.ts";
import { decompress } from "../protocol/framing.ts";
import { canonicalRequest, fromBase64url, verifyUpload } from "../protocol/signing.ts";
import { bucketId } from "../protocol/ids.ts";

const READING_PRIVATE = "MC4CAQAwBQYDK2VuBCIEIB-BUIZTXqbNIR0MFd8VXE2BPlP2ohi2pcpCd_FksGD6";
const READING_PUBLIC = "YAvPaXBsGTnyrLF6FcE1oI2EjHmIeKAg07zRX51nI2w";
const DAY = "2026-08-07";

await generate();

section("Producing a day from the Swift side");
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
  blob: marker(stdout, "BLOB"),
  writer: marker(stdout, "WRITER"),
  signature: marker(stdout, "SIGNATURE"),
  timestamp: Number(marker(stdout, "TIMESTAMP")),
};

section("Opening it with the reading key");
const readingPublic = fromBase64url(READING_PUBLIC);
const bucket = await bucketId(readingPublic);

const privateKey = await crypto.subtle.importKey(
  "pkcs8",
  fromBase64url(READING_PRIVATE) as BufferSource,
  { name: "X25519" },
  false,
  ["deriveBits"],
);

const blob = fromBase64url(emitted.blob);
const plaintext = await decompress(
  await open(privateKey, readingPublic, blob, associatedData(bucket, DAY)),
);

const lines = new TextDecoder().decode(plaintext).trim().split("\n").map((line) =>
  JSON.parse(line) as Record<string, unknown>
);

expect(lines.length === 2, `expected 2 lines, got ${lines.length}`);
// Sorted by id, which is what makes an unchanged day the same bytes twice.
expect(lines[0].id === "agg:steps:2026-08-07T09:00:00Z:h", `first id was ${lines[0].id}`);
expect(lines[0].metric === "steps" && lines[0].value === 842, "the payload fields did not survive");
expect(lines[0].bucket === "hour", "a total has to say which bucket it is");
expect(lines[1].id === "hk:sleep:9A2C", `second id was ${lines[1].id}`);
expect(lines[1].metric === "sleep" && lines[1].stage === "asleepCore", "the sleep stage was lost");
expect(lines[1].bucket === undefined, "a record must not look like a total");

section("Checking the signature the phone produced");
const verified = await verifyUpload(
  fromBase64url(emitted.writer),
  fromBase64url(emitted.signature),
  { bucket, day: DAY, timestamp: emitted.timestamp },
  blob,
);
expect(verified, "the reader could not verify a signature the phone made");

// A signature that verifies against the wrong body would mean the body hash is
// not really in the canonical string — the failure that lets anyone swap a day.
const tampered = new Uint8Array(blob);
tampered[tampered.length - 1] ^= 0x01;
expect(
  !await verifyUpload(
    fromBase64url(emitted.writer),
    fromBase64url(emitted.signature),
    { bucket, day: DAY, timestamp: emitted.timestamp },
    tampered,
  ),
  "a changed body still verified — the body is not covered by the signature",
);

// The bytes agree; whether a real service accepts them is a separate question,
// and the only way to answer it is to ask one.
const postTo = Deno.args.includes("--post")
  ? Deno.args[Deno.args.indexOf("--post") + 1]
  : undefined;

if (postTo) {
  section(`Posting the Swift day to ${postTo}`);
  const response = await fetch(`${postTo}/b/${bucket}/d/${DAY}`, {
    method: "PUT",
    headers: {
      "content-type": "application/octet-stream",
      "x-efferent-timestamp": marker(stdout, "LIVETIMESTAMP"),
      "x-efferent-writer": emitted.writer,
      "x-efferent-signature": marker(stdout, "LIVESIGNATURE"),
    },
    body: blob as BodyInit,
  });
  const answer = await response.text();
  expect(response.ok, `the service refused a day the phone made: ${response.status} ${answer}`);
  expect(JSON.parse(answer).stored === DAY, `expected the day back, got ${answer}`);

  section("Reading it back out of the service");
  const listing = await (await fetch(`${postTo}/b/${bucket}/days`)).json();
  expect(listing.days.length >= 1, "the service listed nothing back");
  const stored = new Uint8Array(
    await (await fetch(`${postTo}/b/${bucket}/d/${DAY}`)).arrayBuffer(),
  );
  const readBack = new TextDecoder().decode(
    await decompress(await open(privateKey, readingPublic, stored, associatedData(bucket, DAY))),
  );
  expect(
    readBack.includes("agg:steps:2026-08-07T09:00:00Z:h"),
    "what came back is not what went in",
  );
  console.log(`  round trip: ${readBack.trim().split("\n").length} lines back, ${answer}`);
}

section(
  `Both sides agree: bucket ${bucket}, day ${DAY}, ${lines.length} lines, ${blob.length} bytes`,
);
console.log(
  `  canonical request the reader rebuilt:\n${
    (await canonicalRequest({ bucket, day: DAY, timestamp: emitted.timestamp }, blob))
      .split("\n").map((part) => `    ${part}`).join("\n")
  }`,
);

// MARK: - Plumbing

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
