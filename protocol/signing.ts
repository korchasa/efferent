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
  /** The days packed into this body, in the order they are packed in it. */
  days: string[];
  /** Unix seconds. Bounds how long a captured request stays replayable. */
  timestamp: number;
}

/**
 * The exact bytes that get signed.
 *
 * Every field that the server acts on is in here, including the hash of the
 * body. A signature over the headers alone would let anyone swap the payload
 * for another one.
 *
 * The days are named as well as hashed, which looks like a belt over braces
 * since they are inside the body the hash covers. What it actually buys is that
 * the server has to prove its own reading of the frame: it signs the days it
 * unpacked, so a parse that came out differently from what the phone packed
 * fails here instead of storing a day under a date nobody meant.
 */
export async function canonicalRequest(header: UploadHeader, body: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", body as BufferSource);
  return [
    PROTOCOL,
    header.bucket,
    header.days.join(","),
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

/**
 * The Ed25519 keys that are not keys: points of small order.
 *
 * Almost every 32 bytes that decode to a curve point generate the whole group,
 * and forging a signature against one means solving a discrete logarithm. These
 * seven generate a subgroup of at most eight elements, and against them a
 * signature of sixty-four zero bytes verifies for about one message in four —
 * with nobody holding a private key at all. Thirty-two zero bytes is one of
 * them, which is how this was found: on 2026-09-05 a claim signed that way was
 * accepted by the live service.
 *
 * It grants a stranger nothing they could not get by generating a real key,
 * since a bucket is claimed by whoever signs for it first. It is still a
 * signature check that can be passed without a key, and this is the whole of
 * what says who may write.
 *
 * The list is the one libsodium refuses. The high bit of the last byte is the
 * sign of x and decodes to the same point either way, so it is cleared before
 * the comparison rather than doubling the list.
 */
const SMALL_ORDER = [
  "0000000000000000000000000000000000000000000000000000000000000000",
  "0100000000000000000000000000000000000000000000000000000000000000",
  "e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800",
  "5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224edddd09f157",
  "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
  "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
  "eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
];

export function hasSmallOrder(publicKey: Uint8Array): boolean {
  if (publicKey.length !== 32) return false;
  const canonical = Uint8Array.from(publicKey);
  canonical[31] &= 0x7f;
  const hex = [...canonical].map((byte) => byte.toString(16).padStart(2, "0")).join("");
  return SMALL_ORDER.includes(hex);
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
  // Refused here rather than only where a key is registered, so that no caller
  // can verify against a key nobody holds by taking a different path in.
  if (hasSmallOrder(publicKey)) return false;
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
