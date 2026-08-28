/**
 * Legacy Efferent sealed boxes.
 *
 * Version 1 predates RFC 9180 interoperability. Readers keep this decoder so
 * an archive remains readable while the phone replaces its days with HPKE
 * version 2. New writes must use `sealedbox.ts` instead.
 */

const VERSION = 1;
const EPHEMERAL_KEY_BYTES = 32;
const NONCE_BYTES = 12;
const HEADER_BYTES = 1 + EPHEMERAL_KEY_BYTES + NONCE_BYTES;
const INFO = new TextEncoder().encode("efferent/v1 sealed box");

export async function openLegacy(
  readingPrivateRaw: Uint8Array,
  readingPublicRaw: Uint8Array,
  blob: Uint8Array,
  associatedData: Uint8Array,
): Promise<Uint8Array> {
  if (blob.length <= HEADER_BYTES) throw new Error("sealed v1 blob is too short");
  if (blob[0] !== VERSION) throw new Error(`expected sealed version 1, got ${blob[0]}`);

  const ephemeralPublic = blob.slice(1, 1 + EPHEMERAL_KEY_BYTES);
  const nonce = blob.slice(1 + EPHEMERAL_KEY_BYTES, HEADER_BYTES);
  const ciphertext = blob.slice(HEADER_BYTES);
  const privateKey = await importPrivate(readingPrivateRaw, readingPublicRaw);
  const key = await deriveKey(
    privateKey,
    await importPublic(ephemeralPublic),
    ephemeralPublic,
    readingPublicRaw,
  );
  const plaintext = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: asArrayBuffer(nonce), additionalData: asArrayBuffer(associatedData) },
    key,
    asArrayBuffer(ciphertext),
  );
  return new Uint8Array(plaintext);
}

/** Test-only producer for proving that the compatibility decoder remains live. */
export async function sealLegacy(
  readingPublicRaw: Uint8Array,
  plaintext: Uint8Array,
  associatedData: Uint8Array,
): Promise<Uint8Array> {
  const recipient = await importPublic(readingPublicRaw);
  const ephemeral = await crypto.subtle.generateKey({ name: "X25519" }, true, [
    "deriveBits",
  ]) as CryptoKeyPair;
  const ephemeralPublic = new Uint8Array(
    await crypto.subtle.exportKey("raw", ephemeral.publicKey),
  );
  const key = await deriveKey(
    ephemeral.privateKey,
    recipient,
    ephemeralPublic,
    readingPublicRaw,
  );
  const nonce = crypto.getRandomValues(new Uint8Array(NONCE_BYTES));
  const ciphertext = new Uint8Array(
    await crypto.subtle.encrypt(
      { name: "AES-GCM", iv: asArrayBuffer(nonce), additionalData: asArrayBuffer(associatedData) },
      key,
      asArrayBuffer(plaintext),
    ),
  );

  const blob = new Uint8Array(HEADER_BYTES + ciphertext.length);
  blob[0] = VERSION;
  blob.set(ephemeralPublic, 1);
  blob.set(nonce, 1 + EPHEMERAL_KEY_BYTES);
  blob.set(ciphertext, HEADER_BYTES);
  return blob;
}

async function deriveKey(
  privateKey: CryptoKey,
  publicKey: CryptoKey,
  ephemeralPublic: Uint8Array,
  readingPublic: Uint8Array,
): Promise<CryptoKey> {
  const shared = await crypto.subtle.deriveBits(
    { name: "X25519", public: publicKey },
    privateKey,
    256,
  );
  const material = await crypto.subtle.importKey("raw", shared, "HKDF", false, ["deriveBits"]);
  const salt = new Uint8Array(ephemeralPublic.length + readingPublic.length);
  salt.set(ephemeralPublic);
  salt.set(readingPublic, ephemeralPublic.length);
  const bits = await crypto.subtle.deriveBits(
    {
      name: "HKDF",
      hash: "SHA-256",
      salt: asArrayBuffer(salt),
      info: asArrayBuffer(INFO),
    },
    material,
    256,
  );
  return await crypto.subtle.importKey("raw", bits, { name: "AES-GCM" }, false, [
    "encrypt",
    "decrypt",
  ]);
}

function importPublic(raw: Uint8Array): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", asArrayBuffer(raw), { name: "X25519" }, true, []);
}

function importPrivate(privateRaw: Uint8Array, publicRaw: Uint8Array): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "jwk",
    {
      kty: "OKP",
      crv: "X25519",
      d: privateRaw.toBase64({ alphabet: "base64url", omitPadding: true }),
      x: publicRaw.toBase64({ alphabet: "base64url", omitPadding: true }),
      ext: false,
      key_ops: ["deriveBits"],
    },
    { name: "X25519" },
    false,
    ["deriveBits"],
  );
}

function asArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  return bytes.slice().buffer;
}
