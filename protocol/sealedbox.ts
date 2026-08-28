/** RFC 9180 HPKE envelopes written by the phone and opened only locally. */

import { Chacha20Poly1305 } from "@hpke/chacha20poly1305";
import { CipherSuite, HkdfSha256 } from "@hpke/core";
import { DhkemX25519HkdfSha256 } from "@hpke/dhkem-x25519";

import { openLegacy } from "./sealedbox-v1.ts";

export const SEALED_VERSION = 2;
export const HPKE_INFO = "efferent/v2 hpke";

const LEGACY_VERSION = 1;
const INFO = new TextEncoder().encode(HPKE_INFO);
const suite = new CipherSuite({
  kem: new DhkemX25519HkdfSha256(),
  kdf: new HkdfSha256(),
  aead: new Chacha20Poly1305(),
});
const HEADER_BYTES = 1 + suite.kem.encSize;
const TAG_BYTES = 16;

/** RFC 9180 base mode: `[version][encapsulated key][ciphertext and tag]`. */
export async function seal(
  readingPublicRaw: Uint8Array,
  plaintext: Uint8Array,
  associatedData: Uint8Array,
): Promise<Uint8Array> {
  const recipientPublicKey = await suite.kem.importKey(
    "raw",
    asArrayBuffer(readingPublicRaw),
    true,
  );
  const sender = await suite.createSenderContext({ recipientPublicKey, info: INFO });
  const ciphertext = new Uint8Array(await sender.seal(plaintext, associatedData));

  const blob = new Uint8Array(HEADER_BYTES + ciphertext.length);
  blob[0] = SEALED_VERSION;
  blob.set(new Uint8Array(sender.enc), 1);
  blob.set(ciphertext, HEADER_BYTES);
  return blob;
}

/** Open HPKE v2, while retaining read compatibility with already stored v1 days. */
export async function open(
  readingPrivateRaw: Uint8Array,
  readingPublicRaw: Uint8Array,
  blob: Uint8Array,
  associatedData: Uint8Array,
): Promise<Uint8Array> {
  if (blob.length === 0) throw new Error("sealed blob has no version byte");
  if (blob[0] === LEGACY_VERSION) {
    return await openLegacy(readingPrivateRaw, readingPublicRaw, blob, associatedData);
  }
  if (blob[0] !== SEALED_VERSION) throw new Error(`unsupported sealed version ${blob[0]}`);
  if (blob.length < HEADER_BYTES + TAG_BYTES) throw new Error("sealed v2 blob is too short");

  const recipientKey = await suite.kem.importKey(
    "raw",
    asArrayBuffer(readingPrivateRaw),
    false,
  );
  const recipient = await suite.createRecipientContext({
    recipientKey,
    enc: blob.subarray(1, HEADER_BYTES),
    info: INFO,
  });
  return new Uint8Array(
    await recipient.open(blob.subarray(HEADER_BYTES), associatedData),
  );
}

/** Bucket and day stay bound to the ciphertext across the envelope migration. */
export function associatedData(bucket: string, day: string): Uint8Array {
  return new TextEncoder().encode(`efferent/v1\n${bucket}\n${day}`);
}

/** Convert the local reader's historical PKCS8 storage to RFC 9180 raw X25519. */
export async function rawPrivateKey(pkcs8: Uint8Array): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey(
    "pkcs8",
    asArrayBuffer(pkcs8),
    { name: "X25519" },
    true,
    ["deriveBits"],
  );
  const jwk = await crypto.subtle.exportKey("jwk", key);
  if (!jwk.d) throw new Error("the stored reading key has no private X25519 value");
  return Uint8Array.fromBase64(jwk.d, { alphabet: "base64url" });
}

function asArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  return bytes.slice().buffer;
}
