/**
 * App Attest: proving that a bucket is being claimed by this app on a real
 * iPhone, and not by a script.
 *
 * The service has no accounts, so claiming is open to whoever reaches it. That
 * is fine for the archive itself — the first writer keeps the bucket and only
 * their key is accepted afterwards — but it leaves the bill undefended by
 * anything except the ceilings. Apple will vouch for the caller, and this is
 * the whole of what it takes to read that voucher.
 *
 * Only the claim is attested. An upload is already bound to its bucket by the
 * signing key the claim registered, so attesting each one would buy nothing and
 * cost an elliptic-curve verification and a counter object per request.
 *
 * There is no challenge endpoint. Apple wants the attestation to cover
 * something the server chose, and the canonical bytes of the claim already are
 * that: they carry the bucket, an empty day list, an empty body and a timestamp
 * the service refuses when it is far from its own clock. So the challenge is
 * those bytes, the server recomputes it, and no state is kept between two
 * requests that would otherwise have to exist.
 *
 * Everything here is pure and uses only WebCrypto, because it runs in a Worker.
 */

/** Apple's App Attest root, from https://www.apple.com/certificateauthority/ */
const APPLE_ROOT_CA_BASE64 = [
  "MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYw",
  "JAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwK",
  "QXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNa",
  "Fw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlv",
  "biBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9y",
  "bmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdh",
  "NbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9au",
  "Yen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/",
  "MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYw",
  "CgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn",
  "53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijV",
  "oyFraWVIyd/dganmrduC1bmTBGwD",
].join("");

/** The nonce Apple puts in the credential certificate lives under this OID. */
const NONCE_EXTENSION_OID = "1.2.840.113635.100.8.2";

const ECDSA_WITH_SHA256 = "1.2.840.10045.4.3.2";
const ECDSA_WITH_SHA384 = "1.2.840.10045.4.3.3";
const EC_PUBLIC_KEY = "1.2.840.10045.2.1";
const P256 = "1.2.840.10045.3.1.7";
const P384 = "1.3.132.0.34";

/**
 * Which of Apple's two App Attest services vouched for the key.
 *
 * A build installed straight onto a phone attests in `development`, and the
 * owner's own copies are installed that way, so refusing it would mean the
 * service could only ever be exercised by a build from the store. Both are
 * bound to this team and this bundle id by the app id below, which is the part
 * that matters.
 */
export type Environment = "production" | "development";

export type Attested = {
  /** The attested key, uncompressed P-256 point, 65 bytes. */
  publicKey: Uint8Array;
  environment: Environment;
};

export class AttestationError extends Error {}

function fail(message: string): never {
  throw new AttestationError(message);
}

// --- CBOR ------------------------------------------------------------------
// Enough of it to read one attestation object: unsigned integers, byte and text
// strings, arrays and maps. Nothing Apple sends needs more.

type Cbor = number | string | Uint8Array | Cbor[] | { [key: string]: Cbor };

function cborValue(bytes: Uint8Array, at: number): [Cbor, number] {
  if (at >= bytes.length) fail("the attestation ended in the middle of a value");
  const major = bytes[at] >> 5;
  const minor = bytes[at] & 31;
  let offset = at + 1;
  let count = minor;
  if (minor === 24) count = bytes[offset++];
  else if (minor === 25) {
    count = (bytes[offset] << 8) | bytes[offset + 1];
    offset += 2;
  } else if (minor === 26) {
    count = new DataView(bytes.buffer, bytes.byteOffset + offset, 4).getUint32(0);
    offset += 4;
  } else if (minor > 26) fail("the attestation uses a length this reader does not accept");

  switch (major) {
    case 0:
      return [count, offset];
    case 2: {
      const end = offset + count;
      if (end > bytes.length) fail("a byte string runs past the end of the attestation");
      return [bytes.subarray(offset, end), end];
    }
    case 3: {
      const end = offset + count;
      if (end > bytes.length) fail("a text string runs past the end of the attestation");
      return [new TextDecoder().decode(bytes.subarray(offset, end)), end];
    }
    case 4: {
      const items: Cbor[] = [];
      for (let i = 0; i < count; i++) {
        const [item, next] = cborValue(bytes, offset);
        items.push(item);
        offset = next;
      }
      return [items, offset];
    }
    case 5: {
      const map: { [key: string]: Cbor } = {};
      for (let i = 0; i < count; i++) {
        const [key, afterKey] = cborValue(bytes, offset);
        const [value, afterValue] = cborValue(bytes, afterKey);
        if (typeof key !== "string") fail("the attestation has a map key that is not text");
        map[key] = value;
        offset = afterValue;
      }
      return [map, offset];
    }
    default:
      fail("the attestation holds a kind of value this reader does not accept");
  }
}

export function decodeCbor(bytes: Uint8Array): Cbor {
  const [value] = cborValue(bytes, 0);
  return value;
}

// --- DER -------------------------------------------------------------------
// A certificate is a tree of tag-length-value triples. Only the parts a chain
// check needs are read: what was signed, what signed it, who issued it, when it
// is valid, its public key and its extensions.

type Element = { tag: number; content: Uint8Array; whole: Uint8Array; end: number };

function element(bytes: Uint8Array, at: number): Element {
  if (at + 1 >= bytes.length) fail("a certificate ended in the middle of a value");
  const tag = bytes[at];
  let offset = at + 1;
  let length = bytes[offset++];
  if (length & 0x80) {
    const wide = length & 0x7f;
    if (wide === 0 || wide > 4) fail("a certificate uses a length this reader does not accept");
    length = 0;
    for (let i = 0; i < wide; i++) length = (length << 8) | bytes[offset++];
  }
  const end = offset + length;
  if (end > bytes.length) fail("a certificate value runs past the end of the certificate");
  return { tag, content: bytes.subarray(offset, end), whole: bytes.subarray(at, end), end };
}

function children(sequence: Uint8Array): Element[] {
  const out: Element[] = [];
  let at = 0;
  while (at < sequence.length) {
    const item = element(sequence, at);
    out.push(item);
    at = item.end;
  }
  return out;
}

function oid(content: Uint8Array): string {
  const parts = [Math.floor(content[0] / 40), content[0] % 40];
  let value = 0;
  for (let i = 1; i < content.length; i++) {
    value = (value << 7) | (content[i] & 0x7f);
    if ((content[i] & 0x80) === 0) {
      parts.push(value);
      value = 0;
    }
  }
  return parts.join(".");
}

type Certificate = {
  tbs: Uint8Array;
  signatureAlgorithm: string;
  signature: Uint8Array;
  issuer: Uint8Array;
  subject: Uint8Array;
  notBefore: Date;
  notAfter: Date;
  spki: Uint8Array;
  curve: string;
  point: Uint8Array;
  extensions: Map<string, Uint8Array>;
};

function time(item: Element): Date {
  const text = new TextDecoder().decode(item.content);
  // UTCTime carries two digits of year and is always this century here;
  // GeneralizedTime carries four.
  const [year, rest] = item.tag === 0x17
    ? [2000 + Number(text.slice(0, 2)), text.slice(2)]
    : [Number(text.slice(0, 4)), text.slice(4)];
  const at = (from: number, to: number) => Number(rest.slice(from, to));
  return new Date(Date.UTC(year, at(0, 2) - 1, at(2, 4), at(4, 6), at(6, 8), at(8, 10)));
}

export function parseCertificate(der: Uint8Array): Certificate {
  const [tbsItem, algorithmItem, signatureItem] = children(element(der, 0).content);
  const fields = children(tbsItem.content);
  // An explicit version tag is optional, and everything after it shifts.
  const start = fields[0].tag === 0xa0 ? 1 : 0;
  const validity = children(fields[start + 3].content);
  const spkiFields = children(fields[start + 5].content);
  const algorithm = children(spkiFields[0].content);
  if (oid(algorithm[0].content) !== EC_PUBLIC_KEY) fail("a certificate key is not on a curve");

  const extensions = new Map<string, Uint8Array>();
  for (const field of fields.slice(start + 6)) {
    if (field.tag !== 0xa3) continue;
    for (const extension of children(element(field.content, 0).content)) {
      const parts = children(extension.content);
      const value = parts[parts.length - 1];
      extensions.set(oid(parts[0].content), value.content);
    }
  }

  return {
    tbs: tbsItem.whole,
    signatureAlgorithm: oid(children(algorithmItem.content)[0].content),
    // A BIT STRING's first content byte counts the unused trailing bits; the
    // signature itself is what follows it.
    signature: signatureItem.content.subarray(1),
    issuer: fields[start + 2].whole,
    subject: fields[start + 4].whole,
    notBefore: time(validity[0]),
    notAfter: time(validity[1]),
    spki: fields[start + 5].whole,
    curve: oid(algorithm[1].content),
    // A BIT STRING's first content byte counts the unused trailing bits.
    point: spkiFields[1].content.subarray(1),
    extensions,
  };
}

/**
 * WebCrypto wants the two halves of an ECDSA signature side by side and padded;
 * a certificate carries them as two integers that may be short or carry a
 * leading zero to keep them positive.
 */
function rawSignature(der: Uint8Array, size: number): Uint8Array {
  const [r, s] = children(element(der, 0).content);
  const out = new Uint8Array(size * 2);
  for (const [index, part] of [r, s].entries()) {
    const bytes = part.content[0] === 0 ? part.content.subarray(1) : part.content;
    if (bytes.length > size) fail("a signature half is longer than its curve");
    out.set(bytes, size * index + (size - bytes.length));
  }
  return out;
}

async function verifySignature(child: Certificate, parent: Certificate): Promise<boolean> {
  const size = parent.curve === P384 ? 48 : 32;
  const hash = child.signatureAlgorithm === ECDSA_WITH_SHA384 ? "SHA-384" : "SHA-256";
  if (
    child.signatureAlgorithm !== ECDSA_WITH_SHA256 && child.signatureAlgorithm !== ECDSA_WITH_SHA384
  ) {
    fail("a certificate is signed with an algorithm this reader does not accept");
  }
  const key = await crypto.subtle.importKey(
    "spki",
    parent.spki as BufferSource,
    { name: "ECDSA", namedCurve: parent.curve === P384 ? "P-384" : "P-256" },
    false,
    ["verify"],
  );
  return await crypto.subtle.verify(
    { name: "ECDSA", hash },
    key,
    rawSignature(child.signature, size) as BufferSource,
    child.tbs as BufferSource,
  );
}

// --- The attestation -------------------------------------------------------

function same(a: Uint8Array, b: Uint8Array): boolean {
  return a.length === b.length && a.every((byte, index) => byte === b[index]);
}

async function sha256(...parts: Uint8Array[]): Promise<Uint8Array> {
  const whole = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const part of parts) {
    whole.set(part, at);
    at += part.length;
  }
  return new Uint8Array(await crypto.subtle.digest("SHA-256", whole as BufferSource));
}

function base64(text: string): Uint8Array {
  return Uint8Array.from(atob(text), (c) => c.charCodeAt(0));
}

const PRODUCTION_AAGUID = new TextEncoder().encode("appattest\0\0\0\0\0\0\0");
const DEVELOPMENT_AAGUID = new TextEncoder().encode("appattestdevelop");

/**
 * Read one attestation and answer with the key it vouches for.
 *
 * `appId` is `<team id>.<bundle id>`. It is not written down in this repository
 * — the team id names the account rather than the app, so the service takes it
 * as a variable at deploy time.
 *
 * `challenge` is what the attestation must cover: for a claim, the canonical
 * bytes of that claim.
 */
export async function verifyAttestation(
  { attestation, keyId, appId, challenge, now = new Date(), rootCertificate }: {
    attestation: Uint8Array;
    keyId: Uint8Array;
    appId: string;
    challenge: Uint8Array;
    now?: Date;
    /** Only a test replaces Apple's root; the service always uses Apple's. */
    rootCertificate?: Uint8Array;
  },
): Promise<Attested> {
  const object = decodeCbor(attestation);
  if (typeof object !== "object" || object instanceof Uint8Array || Array.isArray(object)) {
    fail("the attestation is not an object");
  }
  if (object.fmt !== "apple-appattest") fail("the attestation is not an App Attest one");
  const statement = object.attStmt;
  const authData = object.authData;
  if (
    typeof statement !== "object" || statement === null || Array.isArray(statement) ||
    statement instanceof Uint8Array || !(authData instanceof Uint8Array)
  ) fail("the attestation is missing its statement or its authenticator data");
  const chain = (statement as { [key: string]: Cbor }).x5c;
  if (!Array.isArray(chain) || chain.length < 2) {
    fail("the attestation carries no certificate chain");
  }
  const [credentialDer, intermediateDer] = chain;
  if (!(credentialDer instanceof Uint8Array) || !(intermediateDer instanceof Uint8Array)) {
    fail("the certificate chain is not made of certificates");
  }

  const credential = parseCertificate(credentialDer);
  const intermediate = parseCertificate(intermediateDer);
  if (credential.curve !== P256) fail("an attested key is on the wrong curve");
  const root = parseCertificate(rootCertificate ?? base64(APPLE_ROOT_CA_BASE64));

  for (const certificate of [credential, intermediate, root]) {
    if (now < certificate.notBefore || now > certificate.notAfter) {
      fail("a certificate in the chain is not valid at this moment");
    }
  }
  if (!same(credential.issuer, intermediate.subject)) fail("the chain does not join up");
  if (!same(intermediate.issuer, root.subject)) fail("the chain does not reach the root");
  if (!await verifySignature(credential, intermediate)) {
    fail("the credential certificate is not signed by its issuer");
  }
  if (!await verifySignature(intermediate, root)) fail("the chain is not signed by Apple's root");

  // The nonce is what ties this certificate to this request. Without it a
  // recorded attestation would claim any bucket.
  const nonce = await sha256(authData, await sha256(challenge));
  const extension = credential.extensions.get(NONCE_EXTENSION_OID);
  if (!extension) fail("the credential certificate carries no nonce");
  const stated = element(element(element(extension, 0).content, 0).content, 0).content;
  if (!same(stated, nonce)) fail("the attestation was not made for this request");

  if (!same(await sha256(credential.point), keyId)) {
    fail("the key id does not name the attested key");
  }

  const rpIdHash = authData.subarray(0, 32);
  if (!same(rpIdHash, await sha256(new TextEncoder().encode(appId)))) {
    fail("the attestation was made by another app");
  }
  const counter = new DataView(authData.buffer, authData.byteOffset + 33, 4).getUint32(0);
  if (counter !== 0) fail("an attested key must be fresh");

  const aaguid = authData.subarray(37, 53);
  const environment: Environment = same(aaguid, PRODUCTION_AAGUID)
    ? "production"
    : same(aaguid, DEVELOPMENT_AAGUID)
    ? "development"
    : fail("the attestation did not come from App Attest");

  const idLength = new DataView(authData.buffer, authData.byteOffset + 53, 2).getUint16(0);
  const credentialId = authData.subarray(55, 55 + idLength);
  if (!same(credentialId, keyId)) fail("the attestation names another key");

  return { publicKey: credential.point, environment };
}
