/**
 * Sealing a batch for a reader who is not present.
 *
 * The phone holds only the reading *public* key, so it can write to the bucket
 * and cannot read it back — an important property in itself: a lost or seized
 * phone gives up nothing about the history it already sent. Each batch gets a
 * throwaway key pair whose private half is discarded the moment the shared
 * secret is derived, so there is no long-lived key on the device to steal.
 *
 * This is the base mode of HPKE built out of the pieces every platform already
 * ships: X25519 to agree, HKDF-SHA256 to turn the agreement into a key, and
 * AES-256-GCM to encrypt. Deliberately no third-party crypto library — CryptoKit
 * and WebCrypto both have all three.
 */

export const SEALED_VERSION = 1;

const EPHEMERAL_KEY_BYTES = 32;
const NONCE_BYTES = 12;
const HEADER_BYTES = 1 + EPHEMERAL_KEY_BYTES + NONCE_BYTES;

const INFO = new TextEncoder().encode("efferent/v1 sealed box");

/**
 * `[version][ephemeral public key][nonce][ciphertext and tag]`.
 *
 * The version byte comes first so a future change of algorithm is a decision
 * the reader can make, rather than a decode that fails in a confusing way.
 */
export async function seal(
  readingPublicKey: Uint8Array,
  plaintext: Uint8Array,
  associatedData: Uint8Array,
): Promise<Uint8Array> {
  const recipient = await importPublic(readingPublicKey);
  const ephemeral = await crypto.subtle.generateKey({ name: "X25519" }, true, [
    "deriveBits",
  ]) as CryptoKeyPair;
  const ephemeralPublic = new Uint8Array(
    await crypto.subtle.exportKey("raw", ephemeral.publicKey),
  );

  const key = await deriveKey(ephemeral.privateKey, recipient, ephemeralPublic, readingPublicKey);
  const nonce = crypto.getRandomValues(new Uint8Array(NONCE_BYTES));
  const ciphertext = new Uint8Array(
    await crypto.subtle.encrypt(
      {
        name: "AES-GCM",
        iv: nonce as BufferSource,
        additionalData: associatedData as BufferSource,
      },
      key,
      plaintext as BufferSource,
    ),
  );

  const blob = new Uint8Array(HEADER_BYTES + ciphertext.length);
  blob[0] = SEALED_VERSION;
  blob.set(ephemeralPublic, 1);
  blob.set(nonce, 1 + EPHEMERAL_KEY_BYTES);
  blob.set(ciphertext, HEADER_BYTES);
  return blob;
}

export async function open(
  readingPrivateKey: CryptoKey,
  readingPublicKey: Uint8Array,
  blob: Uint8Array,
  associatedData: Uint8Array,
): Promise<Uint8Array> {
  if (blob.length <= HEADER_BYTES) throw new Error("sealed blob is too short to hold a message");
  if (blob[0] !== SEALED_VERSION) {
    throw new Error(`sealed blob version ${blob[0]} is newer than this reader understands`);
  }

  const ephemeralPublic = blob.slice(1, 1 + EPHEMERAL_KEY_BYTES);
  const nonce = blob.slice(1 + EPHEMERAL_KEY_BYTES, HEADER_BYTES);
  const ciphertext = blob.slice(HEADER_BYTES);

  const key = await deriveKey(
    readingPrivateKey,
    await importPublic(ephemeralPublic),
    ephemeralPublic,
    readingPublicKey,
  );
  const plaintext = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: nonce as BufferSource, additionalData: associatedData as BufferSource },
    key,
    ciphertext as BufferSource,
  );
  return new Uint8Array(plaintext);
}

/**
 * What the ciphertext is bound to.
 *
 * Feeding the bucket and the sequence range in as associated data means a blob
 * cannot be moved to another bucket or relabelled with a different range: the
 * tag stops matching. Without it, a server could shuffle history around
 * undetected even while unable to read a word of it.
 */
export function associatedData(bucket: string, seqFrom: number, seqTo: number): Uint8Array {
  return new TextEncoder().encode(`efferent/v1\n${bucket}\n${seqFrom}\n${seqTo}`);
}

/**
 * Both sides bind the derivation to both public keys via the salt, so a key
 * agreed for one recipient can never be reused against another.
 */
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
  salt.set(ephemeralPublic, 0);
  salt.set(readingPublic, ephemeralPublic.length);

  const bits = await crypto.subtle.deriveBits(
    { name: "HKDF", hash: "SHA-256", salt: salt as BufferSource, info: INFO as BufferSource },
    material,
    256,
  );
  return await crypto.subtle.importKey("raw", bits, { name: "AES-GCM" }, false, [
    "encrypt",
    "decrypt",
  ]);
}

function importPublic(raw: Uint8Array): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", raw as BufferSource, { name: "X25519" }, true, []);
}
