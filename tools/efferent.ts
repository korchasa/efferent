/**
 * The reading side, as a command line tool.
 *
 * This is where the reading key lives. It never leaves this machine: the phone
 * only ever gets the public half, and the bucket service only gets ciphertext.
 * Later this grows into the tools an agent calls; for now it is what proves the
 * transfer works end to end, and `send` stands in for a phone that does not
 * exist yet.
 */

import { bucketId, parseObjectName } from "../protocol/ids.ts";
import { base64url, fromBase64url, signUpload, type UploadHeader } from "../protocol/signing.ts";
import { associatedData, open, seal } from "../protocol/sealedbox.ts";
import { compress, decompress } from "../protocol/framing.ts";

interface ReadingKey {
  /** X25519 private key, pkcs8. The whole secret of the system. */
  readingPrivate: string;
  readingPublic: string;
}

interface WriterKey {
  /** Ed25519 private key, pkcs8. Stands in for the one a phone would make. */
  writerPrivate: string;
  writerPublic: string;
}

const HOME = Deno.env.get("EFFERENT_HOME") ?? ".efferent";

if (import.meta.main) await main(Deno.args);

async function main(args: string[]): Promise<void> {
  const [command, ...rest] = args;
  const options = parseOptions(rest);

  switch (command) {
    case "keygen":
      return await keygen();
    case "pair":
      return await pair(requireOption(options, "url"));
    case "send":
      return await send(requireOption(options, "url"), Number(options.count ?? "3"));
    case "read":
      return await read(requireOption(options, "url"), Number(options.after ?? "0"));
    default:
      console.error(
        [
          "usage:",
          "  efferent keygen                       create the reading key pair",
          "  efferent pair --url <endpoint>        print what the phone needs",
          "  efferent send --url <endpoint>        pretend to be a phone",
          "  efferent read --url <endpoint>        fetch and decrypt",
        ].join("\n"),
      );
      Deno.exit(2);
  }
}

// MARK: - Commands

async function keygen(): Promise<void> {
  const pair = await crypto.subtle.generateKey({ name: "X25519" }, true, [
    "deriveBits",
  ]) as CryptoKeyPair;
  const key: ReadingKey = {
    readingPrivate: base64url(
      new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey)),
    ),
    readingPublic: base64url(new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey))),
  };
  await write("reading-key.json", key);

  console.log(`bucket: ${await bucketId(fromBase64url(key.readingPublic))}`);
  console.log(`saved:  ${HOME}/reading-key.json — this file is the only way to read the data`);
}

async function pair(url: string): Promise<void> {
  const key = await load<ReadingKey>("reading-key.json");
  // Nothing here is secret: an address and a public key. That is the point —
  // this payload can be shown on a screen or photographed without consequence.
  console.log(JSON.stringify({ v: 1, url, pk: key.readingPublic }));
}

async function send(url: string, count: number): Promise<void> {
  const reading = await load<ReadingKey>("reading-key.json");
  const writer = await loadOrCreateWriter();
  const bucket = await bucketId(fromBase64url(reading.readingPublic));

  const seqFrom = Number(Deno.env.get("EFFERENT_SEQ_FROM") ?? "1");
  const seqTo = seqFrom + count - 1;
  const lines = Array.from({ length: count }, (_, index) => {
    const seq = seqFrom + index;
    return JSON.stringify({
      id: `agg:steps:probe-${seq}:h`,
      seq,
      v: 1,
      type: "health.agg",
      metric: "steps",
      value: 100 + seq,
      unit: "count",
    });
  }).join("\n") + "\n";

  const body = await seal(
    fromBase64url(reading.readingPublic),
    await compress(new TextEncoder().encode(lines)),
    associatedData(bucket, seqFrom, seqTo),
  );

  const header: UploadHeader = { bucket, seqFrom, seqTo, timestamp: Math.floor(Date.now() / 1000) };
  const privateKey = await crypto.subtle.importKey(
    "pkcs8",
    fromBase64url(writer.writerPrivate) as BufferSource,
    { name: "Ed25519" },
    false,
    ["sign"],
  );

  const response = await fetch(`${url}/b/${bucket}`, {
    method: "POST",
    headers: {
      "content-type": "application/octet-stream",
      "x-efferent-seq-from": String(seqFrom),
      "x-efferent-seq-to": String(seqTo),
      "x-efferent-timestamp": String(header.timestamp),
      "x-efferent-writer": writer.writerPublic,
      "x-efferent-signature": base64url(await signUpload(privateKey, header, body)),
    },
    // A typed-array body is perfectly valid here; the cast only settles a
    // disagreement between the DOM lib's BodyInit and Deno's Uint8Array.
    body: body as BodyInit,
  });

  console.log(`${response.status} ${await response.text()}`);
  if (!response.ok) Deno.exit(1);
}

async function read(url: string, after: number): Promise<void> {
  const reading = await load<ReadingKey>("reading-key.json");
  const readingPublic = fromBase64url(reading.readingPublic);
  const bucket = await bucketId(readingPublic);
  const privateKey = await crypto.subtle.importKey(
    "pkcs8",
    fromBase64url(reading.readingPrivate) as BufferSource,
    { name: "X25519" },
    false,
    ["deriveBits"],
  );

  const listing = await fetchJSON<{ objects: { name: string }[] }>(
    `${url}/b/${bucket}/objects?after=${after}`,
  );

  for (const object of listing.objects) {
    const range = parseObjectName(object.name);
    if (!range) throw new Error(`the service returned an object it cannot name: ${object.name}`);

    const response = await fetch(`${url}/b/${bucket}/o/${object.name}`);
    if (!response.ok) {
      throw new Error(`${object.name}: ${response.status} ${await response.text()}`);
    }

    const plaintext = await open(
      privateKey,
      readingPublic,
      new Uint8Array(await response.arrayBuffer()),
      associatedData(bucket, range.seqFrom, range.seqTo),
    );
    await Deno.stdout.write(await decompress(plaintext));
  }
}

// MARK: - Storage

async function loadOrCreateWriter(): Promise<WriterKey> {
  try {
    return await load<WriterKey>("writer-key.json");
  } catch {
    const pair = await crypto.subtle.generateKey({ name: "Ed25519" }, true, [
      "sign",
      "verify",
    ]) as CryptoKeyPair;
    const key: WriterKey = {
      writerPrivate: base64url(
        new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey)),
      ),
      writerPublic: base64url(new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey))),
    };
    await write("writer-key.json", key);
    return key;
  }
}

async function load<T>(name: string): Promise<T> {
  return JSON.parse(await Deno.readTextFile(`${HOME}/${name}`)) as T;
}

async function write(name: string, value: unknown): Promise<void> {
  await Deno.mkdir(HOME, { recursive: true });
  await Deno.writeTextFile(`${HOME}/${name}`, JSON.stringify(value, null, 2) + "\n");
  await Deno.chmod(`${HOME}/${name}`, 0o600);
}

// MARK: - Plumbing

async function fetchJSON<T>(url: string): Promise<T> {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`${url}: ${response.status} ${await response.text()}`);
  return await response.json() as T;
}

function parseOptions(args: string[]): Record<string, string> {
  const options: Record<string, string> = {};
  for (let index = 0; index < args.length; index++) {
    const argument = args[index];
    if (!argument.startsWith("--")) continue;
    options[argument.slice(2)] = args[index + 1] ?? "";
    index++;
  }
  return options;
}

function requireOption(options: Record<string, string>, name: string): string {
  const value = options[name];
  if (!value) {
    console.error(`error: --${name} is required`);
    Deno.exit(2);
  }
  return value;
}
