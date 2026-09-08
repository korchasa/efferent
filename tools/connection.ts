/** Import the phone's connection handoff without sending its reading key anywhere. */

import { bucketId, isBucketId } from "../protocol/ids.ts";
import { base64url, fromBase64url } from "../protocol/signing.ts";
import { type EditorKey, HOME, load, type ReadingKey, write } from "./archive.ts";

export interface ImportedConnection {
  mcpURL: string;
  endpoint: string;
  bucket: string;
  reading: ReadingKey;
  /** Absent on a handoff from before writing existed. Such a connection reads
   * and cannot write, and says so rather than guessing a key. */
  editor?: EditorKey;
}

export async function parseConnectionHandoff(text: string): Promise<ImportedConnection> {
  const instruction = field(text, "Instruction");
  const mcp = webURL(field(text, "MCP"), "MCP");
  const encodedKey = field(text, "Reading key");
  const encodedEditor = optionalField(text, "Editor key");

  if (
    !instruction.includes("setup_guide") ||
    !/Keep the reading key( and the editor key)? local/.test(instruction)
  ) {
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
  const editor = encodedEditor ? await importEditor(encodedEditor) : undefined;

  return {
    mcpURL: mcp.toString(),
    endpoint,
    bucket,
    reading,
    ...(editor ? { editor } : {}),
  };
}

/**
 * Move a validated handoff into the existing local reader's private files.
 *
 * A reader that already exists is not overwritten — except for one case that
 * would otherwise cost a whole re-sync: a fresh handoff for the *same* archive,
 * from a phone that has since learnt to write, adds the editor key to a reader
 * that has none and touches nothing else.
 */
export async function installConnectionHandoff(text: string): Promise<ImportedConnection> {
  const connection = await parseConnectionHandoff(text);
  if (connection.editor && await sameReader(connection) && !await exists("editor-key.json")) {
    await write("editor-key.json", connection.editor);
    return connection;
  }
  for (const name of ["reading-key.json", "mirror.json", "editor-key.json"]) {
    if (await exists(name)) {
      throw new Error(
        `${HOME}/${name} already exists — use a different EFFERENT_HOME; refusing to overwrite it`,
      );
    }
  }

  await write("reading-key.json", connection.reading);
  await write("mirror.json", { endpoint: connection.endpoint, days: {}, syncedAt: "" });
  if (connection.editor) await write("editor-key.json", connection.editor);
  return connection;
}

/** Whether the reader in `HOME` holds this very reading key. */
async function sameReader(connection: ImportedConnection): Promise<boolean> {
  try {
    const held = await load<ReadingKey>("reading-key.json");
    return held.readingPublic === connection.reading.readingPublic;
  } catch {
    return false;
  }
}

async function exists(name: string): Promise<boolean> {
  try {
    await Deno.lstat(`${HOME}/${name}`);
    return true;
  } catch (error) {
    if (error instanceof Deno.errors.NotFound) return false;
    throw error;
  }
}

function field(text: string, name: string): string {
  const value = optionalField(text, name);
  if (!value) throw new Error(`the handoff has no ${name} field`);
  return value;
}

function optionalField(text: string, name: string): string | undefined {
  const expression = new RegExp(`(?:^|\\n)${name}:\\s*\\r?\\n([^\\r\\n]+)`);
  return expression.exec(text)?.[1]?.trim() || undefined;
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

function decodePart(value: string, name: string, key = "reading key"): Uint8Array {
  try {
    return fromBase64url(value);
  } catch {
    throw new Error(`the ${name} half of the ${key} is not base64url`);
  }
}

/**
 * The editor key: `efferent-editor-v1.<private>.<public>`, two raw Ed25519
 * halves. Kept the way the reading key is — PKCS8 for the private half, raw
 * for the public — and proved to belong together by signing something with one
 * and checking it with the other, because the two halves came as separate
 * strings and nothing else says they are a pair.
 */
async function importEditor(encoded: string): Promise<EditorKey> {
  const parts = encoded.split(".");
  if (parts.length !== 3 || parts[0] !== "efferent-editor-v1") {
    throw new Error("the editor key is not an Efferent editor key version 1");
  }
  const privateRaw = decodePart(parts[1], "private", "editor key");
  const publicRaw = decodePart(parts[2], "public", "editor key");
  if (privateRaw.length !== 32 || publicRaw.length !== 32) {
    throw new Error("the editor key must contain two 32-byte Ed25519 keys");
  }

  let privateKey: CryptoKey;
  let publicKey: CryptoKey;
  try {
    privateKey = await crypto.subtle.importKey(
      "jwk",
      {
        kty: "OKP",
        crv: "Ed25519",
        d: base64url(privateRaw),
        x: base64url(publicRaw),
        ext: true,
        key_ops: ["sign"],
      },
      { name: "Ed25519" },
      true,
      ["sign"],
    );
    publicKey = await crypto.subtle.importKey(
      "raw",
      publicRaw as BufferSource,
      { name: "Ed25519" },
      false,
      ["verify"],
    );
  } catch {
    throw new Error("the editor key is not a valid Ed25519 key pair");
  }
  const probe = new TextEncoder().encode("efferent editor key probe");
  const signature = await crypto.subtle.sign("Ed25519", privateKey, probe as BufferSource);
  if (!await crypto.subtle.verify("Ed25519", publicKey, signature, probe as BufferSource)) {
    throw new Error("the private and public halves of the editor key do not match");
  }
  return {
    editorPrivate: base64url(new Uint8Array(await crypto.subtle.exportKey("pkcs8", privateKey))),
    editorPublic: base64url(publicRaw),
  };
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
