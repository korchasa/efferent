/**
 * The part of a batch the service is allowed to read.
 *
 * Everything else here exists to keep the service blind, so this file is the
 * one deliberate exception and it is worth being explicit about what it costs.
 * The manifest carries, for every event in the batch, its sequence number, its
 * kind, its metric and the interval it covers — and nothing else. No values, no
 * ids, no source. So the service can answer "which batches hold sleep in
 * August" without being able to say how anyone slept.
 *
 * The trade is not free: times and kinds are the shape of a life. From this
 * alone a determined reader of the archive can tell when you sleep, when you
 * train and when you took the watch off. What it cannot tell is any number.
 * That was the choice — questions answerable without downloading a decade, at
 * the price of a visible rhythm.
 *
 * The manifest travels inside the signed body rather than beside it, so it is
 * covered by the same signature as the ciphertext and cannot be rewritten in
 * flight by anyone who did not claim the bucket.
 */

import { compress, decompress } from "./framing.ts";

/** `[2][uint32 manifest length][deflated manifest][sealed blob]`. */
export const FRAMED_VERSION = 2;

const LENGTH_BYTES = 4;
const PREFIX_BYTES = 1 + LENGTH_BYTES;

/**
 * One event, as much of it as the service sees.
 *
 * Times are whole seconds since 1970 rather than strings: half the bytes, no
 * time zone to get wrong, and directly comparable in the index the service
 * keeps. `null` covers a deletion, which names an event without describing one.
 */
export interface ManifestEntry {
  seq: number;
  type: string;
  metric: string | null;
  start: number | null;
  end: number | null;
}

export async function frame(entries: ManifestEntry[], sealed: Uint8Array): Promise<Uint8Array> {
  const manifest = await compress(new TextEncoder().encode(JSON.stringify(entries)));
  const body = new Uint8Array(PREFIX_BYTES + manifest.length + sealed.length);
  body[0] = FRAMED_VERSION;
  new DataView(body.buffer).setUint32(1, manifest.length, false);
  body.set(manifest, PREFIX_BYTES);
  body.set(sealed, PREFIX_BYTES + manifest.length);
  return body;
}

/**
 * Split a body back into what the service reads and what only the reader can.
 *
 * Every batch is framed. There was briefly an archive of bare sealed blobs from
 * before the manifest existed, and the code to read both shapes came out with
 * them — one accepted format is one fewer thing to be wrong about.
 */
export function unframe(body: Uint8Array): { manifest: Uint8Array; sealed: Uint8Array } {
  if (body.length < PREFIX_BYTES || body[0] !== FRAMED_VERSION) {
    throw new Error(`body starts with ${body[0]}, which is not a framed batch`);
  }
  const length = new DataView(body.buffer, body.byteOffset).getUint32(1, false);
  if (PREFIX_BYTES + length > body.length) {
    throw new Error(`manifest claims ${length} bytes, more than the body holds`);
  }
  return {
    manifest: body.subarray(PREFIX_BYTES, PREFIX_BYTES + length),
    sealed: body.subarray(PREFIX_BYTES + length),
  };
}

export async function readManifest(manifest: Uint8Array): Promise<ManifestEntry[]> {
  const text = new TextDecoder().decode(await decompress(manifest));
  const parsed = JSON.parse(text);
  if (!Array.isArray(parsed)) throw new Error("manifest is not a list of entries");
  return parsed as ManifestEntry[];
}
