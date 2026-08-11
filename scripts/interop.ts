/**
 * `deno task interop` — do the two implementations still agree?
 *
 * `protocol/` and the Swift under `src/Core` describe the same bytes twice, in
 * two languages, and nothing but a test keeps them in step. A Swift test seals
 * and signs a real batch; this opens it with the matching private key and checks
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
import { readManifest, unframe } from "../protocol/manifest.ts";
import { canonicalRequest, fromBase64url, verifyUpload } from "../protocol/signing.ts";
import { bucketId } from "../protocol/ids.ts";

const READING_PRIVATE = "MC4CAQAwBQYDK2VuBCIEIB-BUIZTXqbNIR0MFd8VXE2BPlP2ohi2pcpCd_FksGD6";
const READING_PUBLIC = "YAvPaXBsGTnyrLF6FcE1oI2EjHmIeKAg07zRX51nI2w";
const SEQ_FROM = 1;
const SEQ_TO = 2;

await generate();

section("Producing a batch from the Swift side");
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
// The body is framed: a manifest the service reads, then the sealed blob only
// this side can. Both halves are inside what was signed.
const parts = unframe(blob);
const manifest = await readManifest(parts.manifest);
expect(manifest.length === 2, `the manifest describes ${manifest.length} events, expected 2`);
expect(
  manifest[0].metric === "steps" && manifest[0].start === 1_754_557_200,
  `the manifest's first entry is wrong: ${JSON.stringify(manifest[0])}`,
);
expect(
  manifest[1].type === "health.delete" && (manifest[1].start ?? null) === null,
  `a deletion has no interval, yet the manifest gave it one: ${JSON.stringify(manifest[1])}`,
);

const plaintext = await decompress(
  await open(privateKey, readingPublic, parts.sealed, associatedData(bucket, SEQ_FROM, SEQ_TO)),
);

const lines = new TextDecoder().decode(plaintext).trim().split("\n").map((line) =>
  JSON.parse(line) as Record<string, unknown>
);

expect(lines.length === 2, `expected 2 lines, got ${lines.length}`);
expect(lines[0].id === "agg:steps:2026-08-07T09:00:00Z:h", `first id was ${lines[0].id}`);
expect(lines[0].seq === 1 && lines[1].seq === 2, "sequence numbers did not survive");
expect(lines[0].type === "health.agg", `first type was ${lines[0].type}`);
expect(lines[0].metric === "steps" && lines[0].value === 842, "the payload fields did not survive");
expect(lines[1].type === "health.delete", `second type was ${lines[1].type}`);
expect(lines[1].metric === "sleep", "a deletion must name its metric");

section("Checking the signature the phone produced");
const verified = await verifyUpload(
  fromBase64url(emitted.writer),
  fromBase64url(emitted.signature),
  { bucket, seqFrom: SEQ_FROM, seqTo: SEQ_TO, timestamp: emitted.timestamp },
  blob,
);
expect(verified, "the reader could not verify a signature the phone made");

// A signature that verifies against the wrong body would mean the body hash is
// not really in the canonical string — the failure that lets anyone swap a batch.
const tampered = new Uint8Array(blob);
tampered[tampered.length - 1] ^= 0x01;
expect(
  !await verifyUpload(
    fromBase64url(emitted.writer),
    fromBase64url(emitted.signature),
    { bucket, seqFrom: SEQ_FROM, seqTo: SEQ_TO, timestamp: emitted.timestamp },
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
  section(`Posting the Swift batch to ${postTo}`);
  const response = await fetch(`${postTo}/b/${bucket}`, {
    method: "POST",
    headers: {
      "content-type": "application/octet-stream",
      "x-efferent-seq-from": String(SEQ_FROM),
      "x-efferent-seq-to": String(SEQ_TO),
      "x-efferent-timestamp": marker(stdout, "LIVETIMESTAMP"),
      "x-efferent-writer": emitted.writer,
      "x-efferent-signature": marker(stdout, "LIVESIGNATURE"),
    },
    body: blob as BodyInit,
  });
  const answer = await response.text();
  expect(response.ok, `the service refused a batch the phone made: ${response.status} ${answer}`);
  expect(JSON.parse(answer).ack === SEQ_TO, `expected ack ${SEQ_TO}, got ${answer}`);

  section("Reading it back out of the service");
  const listing = await (await fetch(`${postTo}/b/${bucket}/objects?after=0`)).json();
  expect(listing.objects.length >= 1, "the service listed nothing back");
  const stored = new Uint8Array(
    await (await fetch(`${postTo}/b/${bucket}/o/${listing.objects[0].name}`)).arrayBuffer(),
  );
  const readBack = new TextDecoder().decode(
    await decompress(
      await open(
        privateKey,
        readingPublic,
        unframe(stored).sealed,
        associatedData(bucket, SEQ_FROM, SEQ_TO),
      ),
    ),
  );
  expect(
    readBack.includes("agg:steps:2026-08-07T09:00:00Z:h"),
    "what came back is not what went in",
  );
  console.log(`  round trip: ${readBack.trim().split("\n").length} lines back, ${answer}`);
}

section(
  `Both sides agree: bucket ${bucket}, ${lines.length} lines, ${blob.length} bytes on the wire`,
);
console.log(
  `  canonical request the reader rebuilt:\n${
    (await canonicalRequest({
      bucket,
      seqFrom: SEQ_FROM,
      seqTo: SEQ_TO,
      timestamp: emitted.timestamp,
    }, blob))
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
