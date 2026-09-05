/**
 * Names: how a bucket is identified and how its days are laid out.
 *
 * The bucket id is derived from the reading key, not chosen. That is what
 * removes accounts from the design entirely — there is nothing to register,
 * and knowing where to write follows from knowing who to write to.
 *
 * Inside a bucket the address of everything is a day. Not a sequence number: a
 * counter belongs to the device that keeps it, so a reinstall restarts it and
 * two devices could never share one archive. A date is the same date for
 * everyone, which is what makes a write idempotent and a query a range.
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
 * key sits outside it, so listing days never trips over it. */
export const DATA_PREFIX = "d/";

export function signingKeyObject(bucket: string): string {
  return `${bucket}/key`;
}

/**
 * `<bucket>/taken` and `taken`: how many bytes a bucket, and the service as a
 * whole, have been handed.
 *
 * Bytes taken, not bytes held — a day written twice counts twice. What a write
 * costs is a write, and a tally that tried to describe the store would have to
 * read every day it replaces, which is thirty-one more requests inside a
 * request that may make fifty. Both names sit outside `d/`, so no listing of
 * days ever trips over them, and `taken` is not a bucket id, which are always
 * twenty-six characters of base32.
 */
export function takenObject(bucket: string): string {
  return `${bucket}/taken`;
}

export const SERVICE_TAKEN_OBJECT = "taken";

/**
 * `<bucket>/d/2026-08-07`.
 *
 * `YYYY-MM-DD` sorts lexicographically in the same order it runs in time, which
 * is the whole reason a range of days is one listing rather than a scan.
 */
export function dayKey(bucket: string, day: string): string {
  return `${bucket}/${DATA_PREFIX}${day}`;
}

export function dayPrefix(bucket: string): string {
  return `${bucket}/${DATA_PREFIX}`;
}

/**
 * A calendar day, and one that exists.
 *
 * The regex alone would accept the 31st of February, and a day nobody can ever
 * write is a day a reader could ask for forever. Round-tripping through `Date`
 * is the cheapest way to insist on a real one.
 */
export function isDay(value: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const parsed = new Date(`${value}T00:00:00Z`);
  return !Number.isNaN(parsed.getTime()) && parsed.toISOString().slice(0, 10) === value;
}

/**
 * The day before `day`.
 *
 * Listings skip *after* a key, while a range asks *from* one. Rather than
 * decrementing the string — which works and reads like a trick — the boundary
 * is moved by a day, which is what it means.
 */
export function dayBefore(day: string): string {
  const date = new Date(`${day}T00:00:00Z`);
  date.setUTCDate(date.getUTCDate() - 1);
  return date.toISOString().slice(0, 10);
}
