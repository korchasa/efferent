/**
 * What sits inside a sealed blob: raw-deflate-compressed NDJSON.
 *
 * Compression has to happen before encryption — ciphertext does not compress —
 * and NDJSON of health readings shrinks by roughly ten times, which on a phone
 * is battery as much as bandwidth.
 *
 * Raw deflate rather than gzip because that is the format both sides already
 * have: Apple's Compression framework emits it as `COMPRESSION_ZLIB`, and the
 * web platform reads it as `deflate-raw`. Choosing gzip would mean hand-writing
 * a header on the phone for no benefit.
 */

export async function compress(bytes: Uint8Array): Promise<Uint8Array> {
  return await pipe(bytes, new CompressionStream("deflate-raw"));
}

export async function decompress(bytes: Uint8Array): Promise<Uint8Array> {
  return await pipe(bytes, new DecompressionStream("deflate-raw"));
}

async function pipe(
  bytes: Uint8Array,
  transform: TransformStream<BufferSource, Uint8Array>,
): Promise<Uint8Array> {
  const stream = new Blob([bytes as BlobPart]).stream().pipeThrough(transform);
  return new Uint8Array(await new Response(stream).arrayBuffer());
}
