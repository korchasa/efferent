/**
 * Who is allowed to write into a bucket.
 *
 * Encryption keeps the contents private but does nothing about authorship: a
 * stranger who learned a bucket id could still fill it with rubbish and run up
 * the bill. So every upload is signed by a key the device makes on first launch
 * and never shows anyone. The first upload into an empty bucket registers that
 * key; afterwards only it is accepted.
 *
 * This key has nothing to do with reading. It cannot decrypt, and the reading
 * key cannot write — which is the point: handing an agent the ability to read
 * must not hand it the ability to forge.
 */

export const PROTOCOL = "efferent/v1";

/** How far apart the device's clock and the server's may be. */
export const TIMESTAMP_TOLERANCE_SECONDS = 300;

export interface UploadHeader {
  bucket: string;
  seqFrom: number;
  seqTo: number;
  /** Unix seconds. Bounds how long a captured request stays replayable. */
  timestamp: number;
}

/**
 * The exact bytes that get signed.
 *
 * Every field that the server acts on is in here, including the hash of the
 * body. A signature over the headers alone would let anyone swap the payload
 * for another one.
 */
export async function canonicalRequest(header: UploadHeader, body: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", body as BufferSource);
  return [
    PROTOCOL,
    header.bucket,
    String(header.seqFrom),
    String(header.seqTo),
    String(header.timestamp),
    base64url(new Uint8Array(digest)),
  ].join("\n");
}

export async function signUpload(
  privateKey: CryptoKey,
  header: UploadHeader,
  body: Uint8Array,
): Promise<Uint8Array> {
  const message = new TextEncoder().encode(await canonicalRequest(header, body));
  const signature = await crypto.subtle.sign("Ed25519", privateKey, message as BufferSource);
  return new Uint8Array(signature);
}

export async function verifyUpload(
  publicKey: Uint8Array,
  signature: Uint8Array,
  header: UploadHeader,
  body: Uint8Array,
): Promise<boolean> {
  let key: CryptoKey;
  try {
    key = await crypto.subtle.importKey(
      "raw",
      publicKey as BufferSource,
      { name: "Ed25519" },
      false,
      ["verify"],
    );
  } catch {
    return false; // 32 bytes that are not a point on the curve
  }
  const message = new TextEncoder().encode(await canonicalRequest(header, body));
  return await crypto.subtle.verify(
    "Ed25519",
    key,
    signature as BufferSource,
    message as BufferSource,
  );
}

export function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

export function fromBase64url(value: string): Uint8Array {
  const padded = value.replaceAll("-", "+").replaceAll("_", "/");
  const binary = atob(padded.padEnd(Math.ceil(padded.length / 4) * 4, "="));
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}
