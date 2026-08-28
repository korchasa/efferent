/** Import the phone's connection handoff without sending its reading key anywhere. */

import { bucketId, isBucketId } from "../protocol/ids.ts";
import { base64url, fromBase64url } from "../protocol/signing.ts";
import { HOME, type ReadingKey, write } from "./archive.ts";

export interface ImportedConnection {
  mcpURL: string;
  endpoint: string;
  bucket: string;
  reading: ReadingKey;
}

export async function parseConnectionHandoff(text: string): Promise<ImportedConnection> {
  const instruction = field(text, "Instruction");
  const mcp = webURL(field(text, "MCP"), "MCP");
  const encodedKey = field(text, "Reading key");

  if (!instruction.includes("setup_guide") || !instruction.includes("Keep the reading key local")) {
    throw new Error("the instruction must call setup_guide and keep the reading key local");
  }

  const marker = "/mcp/b/";
  const split = mcp.pathname.lastIndexOf(marker);
  if (split < 0 || mcp.search || mcp.hash) {
    throw new Error("MCP must end in /mcp/b/<bucket-id>, without a query or fragment");
  }
  const bucket = mcp.pathname.slice(split + marker.length);
  if (!isBucketId(bucket) || bucket.includes("/")) {
    throw new Error("the MCP URL does not contain a valid bucket id");
  }
  const endpointPath = mcp.pathname.slice(0, split);
  const endpoint = new URL(endpointPath || "/", mcp.origin).toString().replace(/\/$/, "");

  const parts = encodedKey.split(".");
  if (parts.length !== 3 || parts[0] !== "efferent-reading-v1") {
    throw new Error("the reading key is not an Efferent reading key version 1");
  }
  const privateRaw = decodePart(parts[1], "private");
  const publicRaw = decodePart(parts[2], "public");
  if (privateRaw.length !== 32 || publicRaw.length !== 32) {
    throw new Error("the reading key must contain two 32-byte X25519 keys");
  }

  const calculated = await bucketId(publicRaw);
  if (calculated !== bucket) {
    throw new Error("the reading key belongs to a different bucket than the MCP URL");
  }

  const privateKey = await importAndVerify(privateRaw, publicRaw);
  const reading: ReadingKey = {
    readingPrivate: base64url(
      new Uint8Array(await crypto.subtle.exportKey("pkcs8", privateKey)),
    ),
    readingPublic: base64url(publicRaw),
  };

  return {
    mcpURL: mcp.toString(),
    endpoint,
    bucket,
    reading,
  };
}

/** Move a validated handoff into the existing local reader's private files. */
export async function installConnectionHandoff(text: string): Promise<ImportedConnection> {
  const connection = await parseConnectionHandoff(text);
  for (const name of ["reading-key.json", "mirror.json"]) {
    try {
      await Deno.lstat(`${HOME}/${name}`);
      throw new Error(
        `${HOME}/${name} already exists — use a different EFFERENT_HOME; refusing to overwrite it`,
      );
    } catch (error) {
      if (error instanceof Deno.errors.NotFound) continue;
      throw error;
    }
  }

  await write("reading-key.json", connection.reading);
  await write("mirror.json", { endpoint: connection.endpoint, days: {}, syncedAt: "" });
  return connection;
}

function field(text: string, name: string): string {
  const expression = new RegExp(`(?:^|\\n)${name}:\\s*\\r?\\n([^\\r\\n]+)`);
  const value = expression.exec(text)?.[1]?.trim();
  if (!value) throw new Error(`the handoff has no ${name} field`);
  return value;
}

function webURL(value: string, fieldName: string): URL {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new Error(`${fieldName} is not a URL`);
  }
  if (url.protocol !== "https:" && url.protocol !== "http:") {
    throw new Error(`${fieldName} must use HTTP or HTTPS`);
  }
  return url;
}

function decodePart(value: string, name: string): Uint8Array {
  try {
    return fromBase64url(value);
  } catch {
    throw new Error(`the ${name} half of the reading key is not base64url`);
  }
}

async function importAndVerify(privateRaw: Uint8Array, publicRaw: Uint8Array): Promise<CryptoKey> {
  let privateKey: CryptoKey;
  let publicKey: CryptoKey;
  try {
    privateKey = await crypto.subtle.importKey(
      "jwk",
      {
        kty: "OKP",
        crv: "X25519",
        d: base64url(privateRaw),
        x: base64url(publicRaw),
        ext: true,
        key_ops: ["deriveBits"],
      },
      { name: "X25519" },
      true,
      ["deriveBits"],
    );
    publicKey = await crypto.subtle.importKey(
      "raw",
      publicRaw as BufferSource,
      { name: "X25519" },
      false,
      [],
    );
  } catch {
    throw new Error("the reading key is not a valid X25519 key pair");
  }

  const probe = await crypto.subtle.generateKey({ name: "X25519" }, false, [
    "deriveBits",
  ]) as CryptoKeyPair;
  const fromPrivate = new Uint8Array(
    await crypto.subtle.deriveBits(
      { name: "X25519", public: probe.publicKey },
      privateKey,
      256,
    ),
  );
  const fromPublic = new Uint8Array(
    await crypto.subtle.deriveBits(
      { name: "X25519", public: publicKey },
      probe.privateKey,
      256,
    ),
  );
  if (!sameBytes(fromPrivate, fromPublic)) {
    throw new Error("the private and public halves of the reading key do not match");
  }
  return privateKey;
}

function sameBytes(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index++) difference |= left[index] ^ right[index];
  return difference === 0;
}
