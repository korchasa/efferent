import { assert, assertEquals, assertRejects } from "@std/assert";
import { AttestationError, verifyAttestation } from "./attestation.ts";

/**
 * The attestations here are made up, and made properly: a root, an intermediate
 * and a credential certificate signed in turn, with a real nonce over real
 * authenticator data. Apple's own root cannot be used, because nobody outside
 * Apple can sign under it — so the test hands the verifier its own root and
 * changes nothing else. What is being tested is every reason to refuse.
 */

// --- Just enough DER to build a certificate --------------------------------

function der(tag: number, content: Uint8Array): Uint8Array {
  const header = content.length < 0x80
    ? [tag, content.length]
    : content.length < 0x100
    ? [tag, 0x81, content.length]
    : [tag, 0x82, content.length >> 8, content.length & 0xff];
  return new Uint8Array([...header, ...content]);
}

function join(...parts: Uint8Array[]): Uint8Array {
  return new Uint8Array(parts.reduce<number[]>((all, part) => all.concat([...part]), []));
}

function sequence(...parts: Uint8Array[]): Uint8Array {
  return der(0x30, join(...parts));
}

function oid(text: string): Uint8Array {
  const parts = text.split(".").map(Number);
  const body = [parts[0] * 40 + parts[1]];
  for (const part of parts.slice(2)) {
    const seven: number[] = [];
    let rest = part;
    do {
      seven.unshift(rest & 0x7f);
      rest >>>= 7;
    } while (rest > 0);
    for (let i = 0; i < seven.length - 1; i++) seven[i] |= 0x80;
    body.push(...seven);
  }
  return der(0x06, new Uint8Array(body));
}

function integer(value: number): Uint8Array {
  return der(0x02, new Uint8Array([value]));
}

function name(text: string): Uint8Array {
  return sequence(der(0x31, sequence(oid("2.5.4.3"), der(0x0c, new TextEncoder().encode(text)))));
}

function utcTime(at: Date): Uint8Array {
  const two = (n: number) => String(n).padStart(2, "0");
  const text =
    `${two(at.getUTCFullYear() % 100)}${two(at.getUTCMonth() + 1)}${two(at.getUTCDate())}` +
    `${two(at.getUTCHours())}${two(at.getUTCMinutes())}${two(at.getUTCSeconds())}Z`;
  return der(0x17, new TextEncoder().encode(text));
}

/** WebCrypto signs into two fixed-width halves; a certificate wants integers. */
function derSignature(raw: Uint8Array): Uint8Array {
  const half = raw.length / 2;
  const part = (bytes: Uint8Array) => {
    let at = 0;
    while (at < bytes.length - 1 && bytes[at] === 0) at++;
    const trimmed = bytes.subarray(at);
    return der(0x02, trimmed[0] & 0x80 ? join(new Uint8Array([0]), trimmed) : trimmed);
  };
  return sequence(part(raw.subarray(0, half)), part(raw.subarray(half)));
}

const ECDSA_SHA256 = "1.2.840.10045.4.3.2";
const ECDSA_SHA384 = "1.2.840.10045.4.3.3";

type Pair = { keys: CryptoKeyPair; spki: Uint8Array };

async function pair(curve: "P-256" | "P-384"): Promise<Pair> {
  const keys = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: curve }, true, [
    "sign",
    "verify",
  ]);
  return { keys, spki: new Uint8Array(await crypto.subtle.exportKey("spki", keys.publicKey)) };
}

async function certificate(
  { subject, issuer, subjectKey, issuerKey, algorithm, extensions = [], from, until }: {
    subject: string;
    issuer: string;
    subjectKey: Pair;
    issuerKey: CryptoKey;
    algorithm: string;
    extensions?: Uint8Array[];
    from: Date;
    until: Date;
  },
): Promise<Uint8Array> {
  const tbs = sequence(
    der(0xa0, integer(2)),
    integer(1),
    sequence(oid(algorithm)),
    name(issuer),
    sequence(utcTime(from), utcTime(until)),
    name(subject),
    subjectKey.spki,
    ...(extensions.length ? [der(0xa3, sequence(...extensions))] : []),
  );
  const hash = algorithm === ECDSA_SHA384 ? "SHA-384" : "SHA-256";
  const raw = new Uint8Array(
    await crypto.subtle.sign({ name: "ECDSA", hash }, issuerKey, tbs as BufferSource),
  );
  return sequence(
    tbs,
    sequence(oid(algorithm)),
    der(0x03, join(new Uint8Array([0]), derSignature(raw))),
  );
}

// --- Just enough CBOR to build an attestation object ------------------------

function cborHead(major: number, count: number): number[] {
  if (count < 24) return [(major << 5) | count];
  if (count < 0x100) return [(major << 5) | 24, count];
  if (count < 0x10000) return [(major << 5) | 25, count >> 8, count & 0xff];
  return [(major << 5) | 26, count >>> 24, (count >> 16) & 0xff, (count >> 8) & 0xff, count & 0xff];
}

function cborBytes(value: Uint8Array): number[] {
  return [...cborHead(2, value.length), ...value];
}

function cborText(value: string): number[] {
  const bytes = new TextEncoder().encode(value);
  return [...cborHead(3, bytes.length), ...bytes];
}

// --- Building one whole attestation ----------------------------------------

async function sha256(...parts: Uint8Array[]): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", join(...parts) as BufferSource));
}

const APP_ID = "ABCDE12345.dev.korchasa.efferent";
const CHALLENGE = new TextEncoder().encode("the canonical bytes of a claim");

type Made = { attestation: Uint8Array; keyId: Uint8Array; root: Uint8Array; publicKey: Uint8Array };

async function attestation(
  {
    appId = APP_ID,
    challenge = CHALLENGE,
    aaguid = "appattest\0\0\0\0\0\0\0",
    counter = 0,
    breakChain = false,
    nonceOverride,
    from = new Date(Date.now() - 3600_000),
    until = new Date(Date.now() + 3600_000),
  }: {
    appId?: string;
    challenge?: Uint8Array;
    aaguid?: string;
    counter?: number;
    breakChain?: boolean;
    nonceOverride?: Uint8Array;
    from?: Date;
    until?: Date;
  } = {},
): Promise<Made> {
  const rootKeys = await pair("P-384");
  const intermediateKeys = await pair("P-384");
  const credentialKeys = await pair("P-256");
  const otherKeys = await pair("P-384");

  const root = await certificate({
    subject: "Test Root",
    issuer: "Test Root",
    subjectKey: rootKeys,
    issuerKey: rootKeys.keys.privateKey,
    algorithm: ECDSA_SHA384,
    from,
    until,
  });
  const intermediate = await certificate({
    subject: "Test Intermediate",
    issuer: "Test Root",
    subjectKey: intermediateKeys,
    issuerKey: (breakChain ? otherKeys : rootKeys).keys.privateKey,
    algorithm: ECDSA_SHA384,
    from,
    until,
  });

  // The attested key's identity is the hash of its uncompressed point, and the
  // point is everything after the bit string's unused-bit count.
  const point = credentialKeys.spki.subarray(credentialKeys.spki.length - 65);
  const keyId = await sha256(point);

  const authData = join(
    await sha256(new TextEncoder().encode(appId)),
    new Uint8Array([0x40]),
    new Uint8Array([0, 0, 0, counter]),
    new TextEncoder().encode(aaguid),
    new Uint8Array([0, keyId.length]),
    keyId,
  );
  const nonce = nonceOverride ?? await sha256(authData, await sha256(challenge));
  const extension = sequence(
    oid("1.2.840.113635.100.8.2"),
    der(0x04, sequence(der(0xa1, der(0x04, nonce)))),
  );
  const credential = await certificate({
    subject: "Test Credential",
    issuer: "Test Intermediate",
    subjectKey: credentialKeys,
    issuerKey: intermediateKeys.keys.privateKey,
    algorithm: ECDSA_SHA256,
    extensions: [extension],
    from,
    until,
  });

  const object = new Uint8Array([
    ...cborHead(5, 3),
    ...cborText("fmt"),
    ...cborText("apple-appattest"),
    ...cborText("attStmt"),
    ...cborHead(5, 1),
    ...cborText("x5c"),
    ...cborHead(4, 2),
    ...cborBytes(credential),
    ...cborBytes(intermediate),
    ...cborText("authData"),
    ...cborBytes(authData),
  ]);
  return { attestation: object, keyId, root, publicKey: point };
}

async function refused(made: Made, extra: Partial<Parameters<typeof verifyAttestation>[0]> = {}) {
  return await assertRejects(
    () =>
      verifyAttestation({
        attestation: made.attestation,
        keyId: made.keyId,
        appId: APP_ID,
        challenge: CHALLENGE,
        rootCertificate: made.root,
        ...extra,
      }),
    AttestationError,
  );
}

Deno.test("an attestation Apple's chain vouches for names the key it attested", async () => {
  const made = await attestation();
  const attested = await verifyAttestation({
    attestation: made.attestation,
    keyId: made.keyId,
    appId: APP_ID,
    challenge: CHALLENGE,
    rootCertificate: made.root,
  });
  assertEquals([...attested.publicKey], [...made.publicKey]);
  assertEquals(attested.environment, "production");
});

Deno.test("a build installed straight onto a phone attests in development", async () => {
  const made = await attestation({ aaguid: "appattestdevelop" });
  const attested = await verifyAttestation({
    attestation: made.attestation,
    keyId: made.keyId,
    appId: APP_ID,
    challenge: CHALLENGE,
    rootCertificate: made.root,
  });
  assertEquals(attested.environment, "development");
});

Deno.test("an attestation made for another request is refused", async () => {
  const made = await attestation({ challenge: new TextEncoder().encode("some other claim") });
  const error = await refused(made);
  assert(error.message.includes("not made for this request"), error.message);
});

Deno.test("an attestation made by another app is refused", async () => {
  const made = await attestation({ appId: "ZZZZZ99999.com.example.other" });
  // The app id is inside the signed authenticator data, so the nonce still
  // agrees and the refusal has to come from the app id itself.
  const error = await refused(made);
  assert(error.message.includes("another app"), error.message);
});

Deno.test("a chain that does not reach the root is refused", async () => {
  const made = await attestation({ breakChain: true });
  const error = await refused(made);
  assert(error.message.includes("not signed by"), error.message);
});

Deno.test("an attestation not signed by Apple's own root is refused", async () => {
  const made = await attestation();
  const error = await assertRejects(
    () =>
      verifyAttestation({
        attestation: made.attestation,
        keyId: made.keyId,
        appId: APP_ID,
        challenge: CHALLENGE,
      }),
    AttestationError,
  );
  assert(error.message.includes("does not reach the root"), error.message);
});

Deno.test("a key that has already been used is refused", async () => {
  const made = await attestation({ counter: 3 });
  const error = await refused(made);
  assert(error.message.includes("fresh"), error.message);
});

Deno.test("an attestation from something that is not App Attest is refused", async () => {
  const made = await attestation({ aaguid: "somethingelse!!!" });
  const error = await refused(made);
  assert(error.message.includes("did not come from App Attest"), error.message);
});

Deno.test("an attestation of another key is refused", async () => {
  const made = await attestation();
  const error = await refused(made, { keyId: new Uint8Array(32) });
  assert(error.message.includes("does not name the attested key"), error.message);
});

Deno.test("a nonce that is merely present is not enough", async () => {
  const made = await attestation({ nonceOverride: new Uint8Array(32).fill(7) });
  const error = await refused(made);
  assert(error.message.includes("not made for this request"), error.message);
});

Deno.test("a chain that has expired is refused", async () => {
  const made = await attestation({
    from: new Date(Date.now() - 7200_000),
    until: new Date(Date.now() - 3600_000),
  });
  const error = await refused(made);
  assert(error.message.includes("not valid at this moment"), error.message);
});

Deno.test("something that is not an attestation at all is refused", async () => {
  await assertRejects(
    () =>
      verifyAttestation({
        attestation: new Uint8Array([1, 2, 3]),
        keyId: new Uint8Array(32),
        appId: APP_ID,
        challenge: CHALLENGE,
      }),
    AttestationError,
  );
});
