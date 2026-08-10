/**
 * Names: how a bucket is identified and how its objects are laid out.
 *
 * The bucket id is derived from the reading key, not chosen. That is what
 * removes accounts from the design entirely — there is nothing to register,
 * and knowing where to write follows from knowing who to write to.
 */

/** RFC 4648 base32, lowercase, no padding — safe in a URL and in a filename. */
const ALPHABET = "abcdefghijklmnopqrstuvwxyz234567";

export function base32(bytes: Uint8Array): string {
  let bits = 0;
  let value = 0;
  let out = "";
  for (const byte of bytes) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      out += ALPHABET[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) out += ALPHABET[(value << (5 - bits)) & 31];
  return out;
}

/**
 * 26 characters of base32 — 130 bits of the hash.
 *
 * The id is the only thing standing between a stranger and the ciphertext, so
 * it has to be far out of reach of guessing. It is not a secret in the sense
 * that losing it is fatal; it is a secret in the sense that it is never posted.
 */
export const BUCKET_ID_LENGTH = 26;

export async function bucketId(readingPublicKey: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", readingPublicKey as BufferSource);
  return base32(new Uint8Array(digest)).slice(0, BUCKET_ID_LENGTH);
}

export function isBucketId(value: string): boolean {
  if (value.length !== BUCKET_ID_LENGTH) return false;
  for (const character of value) {
    if (!ALPHABET.includes(character)) return false;
  }
  return true;
}

/** Everything a device writes lives under this prefix; the trust-on-first-use
 * key sits outside it, so listing data never trips over it. */
export const DATA_PREFIX = "d/";

export function signingKeyObject(bucket: string): string {
  return `${bucket}/key`;
}

/**
 * `<bucket>/d/00000000000000001-00000000000000500`.
 *
 * Zero-padded so that a plain lexicographic listing comes back in sequence
 * order. Without the padding, blob 100 would sort before blob 20 and paging
 * would silently skip data.
 */
export function objectKey(bucket: string, seqFrom: number, seqTo: number): string {
  return `${bucket}/${DATA_PREFIX}${objectName(seqFrom, seqTo)}`;
}

/** The same name without the bucket in front: what a listing hands back, and
 * what a reader asks for. */
export function objectName(seqFrom: number, seqTo: number): string {
  return `${pad(seqFrom)}-${pad(seqTo)}`;
}

export function parseObjectName(name: string): { seqFrom: number; seqTo: number } | null {
  const match = /^(\d{17})-(\d{17})$/.exec(name);
  if (!match) return null;
  return { seqFrom: Number(match[1]), seqTo: Number(match[2]) };
}

/**
 * The key to start a listing after, for a reader that already has everything up
 * to `seq`.
 *
 * This is what makes the archive walkable. A listing that fetches a page and
 * then filters it in the service can only ever return the first page: once a
 * bucket holds more objects than a page, everything past it is invisible, and
 * the symptom is an empty answer rather than an error. Skipping in the store
 * itself has no such ceiling.
 */
export function listingStartAfter(bucket: string, seq: number): string {
  return `${bucket}/${DATA_PREFIX}${pad(seq)}`;
}

/** 17 digits holds every value up to Number.MAX_SAFE_INTEGER. */
function pad(value: number): string {
  return String(value).padStart(17, "0");
}
