#!/usr/bin/env node
/**
 * The reading side of Efferent, in one file an agent can save and run.
 *
 * Everything here runs next to the reading key, on the owner's machine, and it
 * has to: opening a day means decrypting it, and the key never leaves. The
 * service holds ciphertext it cannot open and only ever hands that back.
 *
 * One file serves three callers, so there is one implementation of reading
 * rather than three that drift: the command line an agent skill runs, the local
 * MCP server (`node efferent.mjs mcp`), and the program the service's
 * `setup_guide` hands an agent. It needs Node 20 or newer and nothing else —
 * no package, no install step — because an agent told to install whatever a
 * guide names is the last place to name a package nobody has audited.
 *
 * The sections below are the wire (HPKE, keys, days, edits), the profile kept
 * on this machine, the service, the answers, the MCP server and the command
 * line, in that order. The Python under `reader/` describes the same wire and
 * is the reference the phone's interop check holds both readers to.
 */

import {
  createCipheriv,
  createDecipheriv,
  createHash,
  createHmac,
  createPrivateKey,
  createPublicKey,
  diffieHellman,
  generateKeyPairSync,
  hkdfSync,
  sign as signWith,
  timingSafeEqual,
} from "node:crypto";
import {
  chmodSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  realpathSync,
  renameSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { isAbsolute, join, resolve } from "node:path";
import { createInterface } from "node:readline";
import { pathToFileURL } from "node:url";
import { deflateRawSync, inflateRawSync } from "node:zlib";

export const VERSION = "1.0.0";
const USER_AGENT = "efferent-local-reader/1.0";

// MARK: - The wire: HPKE

export const INFO = Buffer.from("efferent/v2 hpke");
export const SEALED_VERSION = 2;
const LEGACY_VERSION = 1;
const ENC_BYTES = 32;
// What one answer from the service may weigh before this reader stops reading
// it. A day is at most a mebibyte and a range answer at most eight.
const MAX_ANSWER_BYTES = 16 * 1024 * 1024;

// RFC 9180 HPKE, base mode, DHKEM(X25519, HKDF-SHA256), HKDF-SHA256 and
// ChaCha20-Poly1305, written out below rather than imported: `self-test` checks
// these lines against the vectors the RFC publishes for this exact suite
// (A.2.1). Every sealed object here is one message per context, so the
// sequence number is always 0 and the nonce is the base nonce itself.
const KEM_SUITE = Buffer.concat([Buffer.from("KEM"), u16(32)]);
const HPKE_SUITE = Buffer.concat([Buffer.from("HPKE"), u16(32), u16(1), u16(3)]);

function u16(value) {
  const out = Buffer.alloc(2);
  out.writeUInt16BE(value);
  return out;
}

function hkdfExtract(salt, ikm) {
  return createHmac("sha256", salt.length ? salt : Buffer.alloc(32)).update(ikm).digest();
}

function hkdfExpand(prk, info, length) {
  let out = Buffer.alloc(0);
  let block = Buffer.alloc(0);
  for (let counter = 1; out.length < length; counter++) {
    block = createHmac("sha256", prk)
      .update(Buffer.concat([block, info, Buffer.from([counter])]))
      .digest();
    out = Buffer.concat([out, block]);
  }
  return out.subarray(0, length);
}

function labeledExtract(suite, salt, label, ikm) {
  return hkdfExtract(salt, Buffer.concat([Buffer.from("HPKE-v1"), suite, Buffer.from(label), ikm]));
}

function labeledExpand(suite, prk, label, info, length) {
  const labeled = Buffer.concat([u16(length), Buffer.from("HPKE-v1"), suite, Buffer.from(label)]);
  return hkdfExpand(prk, Buffer.concat([labeled, info]), length);
}

function keyAndNonce(dh, enc, recipientPublic, info) {
  const shared = labeledExpand(
    KEM_SUITE,
    labeledExtract(KEM_SUITE, Buffer.alloc(0), "eae_prk", dh),
    "shared_secret",
    Buffer.concat([enc, recipientPublic]),
    32,
  );
  const context = Buffer.concat([
    Buffer.from([0]),
    labeledExtract(HPKE_SUITE, Buffer.alloc(0), "psk_id_hash", Buffer.alloc(0)),
    labeledExtract(HPKE_SUITE, Buffer.alloc(0), "info_hash", info),
  ]);
  const secret = labeledExtract(HPKE_SUITE, shared, "secret", Buffer.alloc(0));
  return [
    labeledExpand(HPKE_SUITE, secret, "key", context, 32),
    labeledExpand(HPKE_SUITE, secret, "base_nonce", context, 12),
  ];
}

// Raw keys travel as 32 bytes; Node takes them wrapped in DER. These are the
// fixed prefixes of PKCS8 and SPKI for the two curves, and nothing else.
const DER = {
  x25519: {
    private: Buffer.from("302e020100300506032b656e04220420", "hex"),
    public: Buffer.from("302a300506032b656e032100", "hex"),
  },
  ed25519: {
    private: Buffer.from("302e020100300506032b657004220420", "hex"),
    public: Buffer.from("302a300506032b6570032100", "hex"),
  },
};

function privateKey(curve, raw) {
  if (raw.length !== 32) throw new Error(`a ${curve} private key is 32 bytes, not ${raw.length}`);
  return createPrivateKey({
    key: Buffer.concat([DER[curve].private, raw]),
    format: "der",
    type: "pkcs8",
  });
}

function publicKey(curve, raw) {
  if (raw.length !== 32) throw new Error(`a ${curve} public key is 32 bytes, not ${raw.length}`);
  return createPublicKey({
    key: Buffer.concat([DER[curve].public, raw]),
    format: "der",
    type: "spki",
  });
}

/** The raw public half of a raw private key, X25519 or Ed25519 alike. */
export function publicOf(curve, raw) {
  return createPublicKey(privateKey(curve, raw)).export({ format: "der", type: "spki" }).subarray(
    12,
  );
}

function chacha(key, nonce) {
  return createCipheriv("chacha20-poly1305", key, nonce, { authTagLength: 16 });
}

/**
 * Encapsulated key followed by ciphertext and tag. The ephemeral key is
 * supplied only by the self-test; every real seal draws a fresh one.
 */
export function hpkeSeal(recipientPublic, info, aad, plaintext, ephemeralRaw) {
  const ephemeral = ephemeralRaw ?? randomX25519();
  const enc = publicOf("x25519", ephemeral);
  const dh = diffieHellman({
    privateKey: privateKey("x25519", ephemeral),
    publicKey: publicKey("x25519", recipientPublic),
  });
  const [key, nonce] = keyAndNonce(dh, enc, recipientPublic, info);
  const cipher = chacha(key, nonce);
  cipher.setAAD(aad, { plaintextLength: plaintext.length });
  return Buffer.concat([enc, cipher.update(plaintext), cipher.final(), cipher.getAuthTag()]);
}

export function hpkeOpen(recipientPrivate, info, aad, sealed) {
  if (sealed.length < ENC_BYTES + 16) throw new Error("the sealed object is too short to open");
  const enc = sealed.subarray(0, ENC_BYTES);
  const body = sealed.subarray(ENC_BYTES, sealed.length - 16);
  const dh = diffieHellman({
    privateKey: privateKey("x25519", recipientPrivate),
    publicKey: publicKey("x25519", enc),
  });
  const [key, nonce] = keyAndNonce(dh, enc, publicOf("x25519", recipientPrivate), info);
  const decipher = createDecipheriv("chacha20-poly1305", key, nonce, { authTagLength: 16 });
  decipher.setAAD(aad, { plaintextLength: body.length });
  decipher.setAuthTag(sealed.subarray(sealed.length - 16));
  try {
    return Buffer.concat([decipher.update(body), decipher.final()]);
  } catch {
    throw new Error("the sealed object does not open with this key, bucket and day");
  }
}

function randomX25519() {
  const { privateKey: made } = generateKeyPairSync("x25519");
  return Buffer.from(made.export({ format: "jwk" }).d, "base64url");
}

/**
 * RFC 9180 appendix A.2.1, the published base-mode vectors for this suite:
 * seal with the RFC's ephemeral key and expect its bytes, then open them.
 */
export function selfTest() {
  const hex = (text) => Buffer.from(text, "hex");
  const info = hex("4f6465206f6e2061204772656369616e2055726e");
  const ephemeral = hex("f4ec9b33b792c372c1d2c2063507b684ef925b8c75a42dbcbf57d63ccd381600");
  const recipientPrivate = hex("8057991eef8f1f1af18f4a9491d16a1ce333f695d4db8e38da75975c4478e0fb");
  const recipientPublic = hex("4310ee97d88cc1f088a5576c77ab0cf5c3ac797f3d95139c6c84b5429c59662a");
  const plaintext = hex("4265617574792069732074727574682c20747275746820626561757479");
  const aad = hex("436f756e742d30");
  const expected = hex(
    "1afa08d3dec047a643885163f1180476fa7ddb54c6a8029ea33f95796bf2ac4a" +
      "1c5250d8034ec2b784ba2cfd69dbdb8af406cfe3ff938e131f0def8c8b60b4db" +
      "21993c62ce81883d2dd1b51a28",
  );
  const sealed = hpkeSeal(recipientPublic, info, aad, plaintext, ephemeral);
  if (!sealed.equals(expected)) {
    throw new Error("self-test failed: the sealed bytes differ from RFC 9180 A.2.1");
  }
  if (!hpkeOpen(recipientPrivate, info, aad, sealed).equals(plaintext)) {
    throw new Error("self-test failed: the RFC 9180 A.2.1 ciphertext did not open");
  }
  return "RFC 9180 A.2.1: sealed and opened exactly as published";
}

// The envelope before RFC 9180: X25519, HKDF-SHA256 with both public halves as
// the salt, and AES-256-GCM. The phone replaces such days as it re-reads them,
// and until the last one is gone a reader that refused version 1 would report
// an old day as unreadable. Nothing writes version 1 any more.
const LEGACY_INFO = Buffer.from("efferent/v1 sealed box");
const LEGACY_HEADER = 1 + 32 + 12;

function openLegacy(privateRaw, publicRaw, blob, aad) {
  if (blob.length <= LEGACY_HEADER) throw new Error("sealed v1 blob is too short");
  const ephemeral = blob.subarray(1, 33);
  const nonce = blob.subarray(33, LEGACY_HEADER);
  const shared = diffieHellman({
    privateKey: privateKey("x25519", privateRaw),
    publicKey: publicKey("x25519", ephemeral),
  });
  const key = Buffer.from(
    hkdfSync("sha256", shared, Buffer.concat([ephemeral, publicRaw]), LEGACY_INFO, 32),
  );
  const body = blob.subarray(LEGACY_HEADER, blob.length - 16);
  const decipher = createDecipheriv("aes-256-gcm", key, nonce);
  decipher.setAAD(aad);
  decipher.setAuthTag(blob.subarray(blob.length - 16));
  try {
    return Buffer.concat([decipher.update(body), decipher.final()]);
  } catch {
    throw new Error("the sealed v1 day does not open with this key, bucket and day");
  }
}

/** Whichever envelope the day is in, as plaintext. */
export function openSealed(privateRaw, publicRaw, blob, aad) {
  if (!blob.length) throw new Error("sealed blob has no version byte");
  if (blob[0] === LEGACY_VERSION) return openLegacy(privateRaw, publicRaw, blob, aad);
  if (blob[0] !== SEALED_VERSION) throw new Error(`unsupported sealed version ${blob[0]}`);
  return hpkeOpen(privateRaw, INFO, aad, blob.subarray(1));
}

/** Bucket and day stay bound to the ciphertext, so a day cannot be moved. */
export function associatedData(bucket, day) {
  return Buffer.from(`efferent/v1\n${bucket}\n${day}`);
}

/** The bucket is bound into an edit; its name is given later, by the service. */
export function editAssociatedData(bucket) {
  return Buffer.from(`efferent/v1 edit\n${bucket}`);
}

// MARK: - The wire: keys and the handoff

export function toBase64url(bytes) {
  return Buffer.from(bytes).toString("base64url");
}

export function fromBase64url(text) {
  return Buffer.from(text, "base64url");
}

const BASE32 = "abcdefghijklmnopqrstuvwxyz234567";

/**
 * The bucket id: the reading public key hashed and written in base32. The
 * service never learns the key; it is handed the name.
 */
export function bucketOf(readingPublicRaw) {
  const digest = createHash("sha256").update(readingPublicRaw).digest();
  let bits = 0;
  let value = 0;
  let out = "";
  for (const byte of digest) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      out += BASE32[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  return out.slice(0, 26);
}

function escapeRegExp(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function optionalField(handoff, name) {
  const match = new RegExp(`(?:^|\\n)${escapeRegExp(name)}:\\s*\\r?\\n([^\\r\\n]+)`).exec(handoff);
  return match ? match[1].trim() : null;
}

export function field(handoff, name) {
  const value = optionalField(handoff, name);
  if (!value) throw new Error(`the handoff has no ${name} field`);
  return value;
}

function sameBytes(left, right) {
  return left.length === right.length && timingSafeEqual(left, right);
}

/**
 * The endpoint, the bucket, the raw reading private key, and the raw editor
 * private key when the handoff carries one. A handoff from before writing
 * existed has three fields; such a connection reads and cannot write.
 */
export function connection(handoff) {
  let mcp;
  try {
    mcp = new URL(field(handoff, "MCP"));
  } catch (error) {
    if (/no MCP field/.test(error.message)) throw error;
    throw new Error("MCP must be an HTTP URL without a query or fragment");
  }
  if (!["http:", "https:"].includes(mcp.protocol) || mcp.search || mcp.hash) {
    throw new Error("MCP must be an HTTP URL without a query or fragment");
  }
  const path = /^(.*)\/mcp\/b\/([a-z2-7]{26})$/.exec(mcp.pathname);
  if (!path) throw new Error("MCP must end in /mcp/b/<bucket-id>");
  const [, prefix, bucket] = path;

  const keyParts = field(handoff, "Reading key").split(".");
  if (keyParts.length !== 3 || keyParts[0] !== "efferent-reading-v1") {
    throw new Error("the reading key is not an Efferent reading key version 1");
  }
  const privateRaw = fromBase64url(keyParts[1]);
  const publicRaw = fromBase64url(keyParts[2]);
  if (privateRaw.length !== 32 || publicRaw.length !== 32) {
    throw new Error("the reading key must contain two 32-byte X25519 keys");
  }
  if (!sameBytes(publicOf("x25519", privateRaw), publicRaw)) {
    throw new Error("the private and public halves of the reading key do not match");
  }
  if (bucketOf(publicRaw) !== bucket) {
    throw new Error("the reading key belongs to a different bucket than the MCP URL");
  }

  let editorRaw = null;
  const editorField = optionalField(handoff, "Editor key");
  if (editorField) {
    const parts = editorField.split(".");
    if (parts.length !== 3 || parts[0] !== "efferent-editor-v1") {
      throw new Error("the editor key is not an Efferent editor key version 1");
    }
    editorRaw = fromBase64url(parts[1]);
    const editorPublic = fromBase64url(parts[2]);
    if (editorRaw.length !== 32 || editorPublic.length !== 32) {
      throw new Error("the editor key must contain two 32-byte Ed25519 keys");
    }
    if (!sameBytes(publicOf("ed25519", editorRaw), editorPublic)) {
      throw new Error("the private and public halves of the editor key do not match");
    }
  }

  const endpoint = `${mcp.protocol}//${mcp.host}${prefix}`.replace(/\/+$/, "");
  return { endpoint, bucket, privateRaw, editorRaw };
}

// Every read is signed. The key is an Ed25519 key whose seed is
// HKDF-SHA256(reading private key, salt empty, info "efferent/v1 read", 32), so
// whoever holds the reading key holds this one too and the reading key itself
// never travels. Once the phone registers the public half, the bucket id alone
// opens nothing, and a read must name this bucket, the path and query it asks
// for, and a moment near the service's clock. Before that the service ignores
// the signature, so signing always is what lets one reader read both.

const READ_INFO = Buffer.from("efferent/v1 read");

/** The raw Ed25519 seed of the read key. */
export function readKey(readingPrivateRaw) {
  return hkdfExpand(hkdfExtract(Buffer.alloc(0), readingPrivateRaw), READ_INFO, 32);
}

export function canonicalRead(bucket, target, timestamp) {
  return `efferent/v1 read\n${bucket}\n${target}\n${timestamp}`;
}

export function signEd25519(privateRaw, message) {
  return signWith(null, Buffer.from(message), privateKey("ed25519", privateRaw));
}

/**
 * The three headers that sign a read of this URL. What is signed is the path
 * and query exactly as they are sent, so a signature for one day opens no
 * other day and one page of a listing no other page.
 */
export function readHeaders(url, bucket, readingPrivateRaw, timestamp) {
  const parts = new URL(url);
  const target = parts.pathname + parts.search;
  const key = readKey(readingPrivateRaw);
  return {
    "X-Efferent-Timestamp": String(timestamp),
    "X-Efferent-Reader": toBase64url(publicOf("ed25519", key)),
    "X-Efferent-Signature": toBase64url(signEd25519(key, canonicalRead(bucket, target, timestamp))),
  };
}

// MARK: - The wire: days

const DAY_PATTERN = /^\d{4}-\d{2}-\d{2}$/;

/**
 * A calendar day, and one that exists: the pattern alone would accept the 31st
 * of February, and a day nobody can write is a day a reader could ask for
 * forever.
 */
export function isDay(value) {
  if (typeof value !== "string" || !DAY_PATTERN.test(value)) return false;
  const [year, month, day] = value.split("-").map(Number);
  const date = new Date(Date.UTC(year, month - 1, day));
  return date.getUTCFullYear() === year && date.getUTCMonth() === month - 1 &&
    date.getUTCDate() === day;
}

export function addDays(day, count) {
  const date = new Date(`${day}T00:00:00Z`);
  date.setUTCDate(date.getUTCDate() + count);
  return date.toISOString().slice(0, 10);
}

/**
 * Listings skip *after* a key while a range asks *from* one, so the boundary
 * is moved by a day, which is what it means.
 */
export function dayBefore(day) {
  return addDays(day, -1);
}

export function daysBetween(start, end) {
  return Math.round((Date.parse(`${end}T00:00:00Z`) - Date.parse(`${start}T00:00:00Z`)) / 86400000);
}

export function today() {
  return new Date().toISOString().slice(0, 10);
}

/** Milliseconds and a Z, the shape the reader's own files already carry. */
function nowIso() {
  return new Date().toISOString();
}

export function unixNow() {
  return Math.floor(Date.now() / 1000);
}

const FRAME_HEADER_BYTES = 14;

/**
 * A range answer, which is the frame an upload uses travelling back: ten bytes
 * of ASCII day, four of big-endian length, the sealed day, repeated to the end.
 * Days ascend and never repeat. An empty body is a range with no days in it;
 * anything left over is a truncated frame, refused whole rather than read as far
 * as it goes.
 */
export function unpackFrame(body) {
  const days = [];
  let offset = 0;
  let previous = "";
  while (offset < body.length) {
    const left = body.length - offset;
    if (left < FRAME_HEADER_BYTES) {
      throw new Error(`${left} bytes left over where a day was expected`);
    }
    const day = body.subarray(offset, offset + 10).toString("latin1");
    const length = body.readUInt32BE(offset + 10);
    if (!isDay(day)) throw new Error(`${JSON.stringify(day)} is not a day`);
    if (day <= previous) {
      throw new Error(`days must ascend without repeats: ${previous} then ${day}`);
    }
    if (length === 0) throw new Error(`${day} carries no body`);
    if (left - FRAME_HEADER_BYTES < length) {
      throw new Error(
        `${day} says ${length} bytes and only ${left - FRAME_HEADER_BYTES} are there`,
      );
    }
    const start = offset + FRAME_HEADER_BYTES;
    days.push([day, body.subarray(start, start + length)]);
    previous = day;
    offset = start + length;
  }
  return days;
}

export const DAY_FORMAT_VERSION = 2;
const SHARED = ["metric", "bucket", "unit", "source"];
const COLUMNS = ["value", "stage", "activity", "duration"];

/** Python's `str()` of a JSON value, which is how the identities were first spelt. */
function pyStr(value) {
  if (value === null || value === undefined) return "None";
  if (value === true) return "True";
  if (value === false) return "False";
  return String(value);
}

function sortedKeys(object) {
  const out = {};
  for (const key of Object.keys(object).sort()) out[key] = object[key];
  return out;
}

/**
 * A stored day as NDJSON: one JSON object per line.
 *
 * A day is stored as columns. Rows that agree on kind, metric, bucket, unit and
 * source share a series and name all of that once; instants travel as whole
 * seconds counted from the first row. An identity is rebuilt here from the
 * kind, the metric and the instant, because nothing on the wire carries one.
 * Two sleep stages can begin in the same second, so rows that land on one
 * identity are numbered #1, #2 in the order the series holds them. Days written
 * before this layout are lines already and pass through.
 */
export function expand(plaintext) {
  const text = Buffer.from(plaintext).toString("utf8").trim();
  if (!text || text.includes("\n") || !text.startsWith("{")) return text ? `${text}\n` : "";
  const document = JSON.parse(text);
  if (!("series" in document)) return `${text}\n`;
  if (document.v !== DAY_FORMAT_VERSION) {
    throw new Error(
      `this day is written in layout ${
        pyStr(document.v)
      }, and this reader speaks ${DAY_FORMAT_VERSION}`,
    );
  }

  const events = [];
  for (const series of document.series) {
    let moment = series.t0;
    series.t.forEach((step, row) => {
      moment += step;
      const event = { v: 1, start: instant(moment), end: instant(moment + series.d[row]) };
      for (const name of SHARED) if (name in series) event[name] = series[name];
      for (const name of COLUMNS) {
        if (name in series && series[name][row] !== null && series[name][row] !== undefined) {
          event[name] = series[name][row];
        }
      }
      const tail = "bucket" in event ? `:${String(event.bucket)[0]}` : "";
      event.id = `${series.k}:${pyStr(event.metric)}:${event.start}${tail}`;
      events.push(event);
    });
  }

  const repeated = new Map();
  for (const event of events) repeated.set(event.id, (repeated.get(event.id) ?? 0) + 1);
  const running = new Map();
  for (const event of events) {
    if (repeated.get(event.id) > 1) {
      const seen = (running.get(event.id) ?? 0) + 1;
      running.set(event.id, seen);
      event.id = `${event.id}#${seen}`;
    }
  }
  return events.map((event) => `${JSON.stringify(sortedKeys(event))}\n`).join("");
}

function instant(seconds) {
  return new Date(seconds * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");
}

/** A day's events, whichever layout it is stored in. */
export function eventsOf(plaintext) {
  return expand(plaintext).split("\n").filter(Boolean).map((line) => JSON.parse(line));
}

// MARK: - The wire: edits

// Writing into Health goes the other way: an edit is sealed to the phone's own
// reading key, signed with the editor key, and handed to the service, which
// stores it unopened. The phone opens it, checks the signature itself and puts
// the samples into Health. Nothing here, and nothing on the service, can put a
// number into Health directly.

export const EDIT_FORMAT_VERSION = 1;
export const MAX_ITEMS_PER_EDIT = 500;
export const SLEEP_STAGES = [
  "inBed",
  "awake",
  "asleepUnspecified",
  "asleepCore",
  "asleepDeep",
  "asleepREM",
];
export const WRITABLE = {
  sleep: null,
  dietaryEnergy: "kcal",
  dietaryProtein: "g",
  dietaryCarbohydrates: "g",
  dietaryFat: "g",
  dietaryWater: "mL",
  bodyMass: "kg",
};
const PUT_KEYS = ["op", "id", "metric", "start", "end", "value", "unit", "stage"];
const DELETE_KEYS = ["op", "id"];
const ITEM_ID = /^[A-Za-z0-9._:-]{1,120}$/;

/** Python's `repr()` of a value, which is how an unknown metric is named. */
function pyRepr(value) {
  return typeof value === "string" ? `'${value}'` : pyStr(value);
}

function isPlainObject(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Every way an item can be wrong is said here, before anything is sealed. */
export function validateItems(items) {
  if (!Array.isArray(items) || !items.length) {
    throw new Error("items must be a list with at least one item");
  }
  if (items.length > MAX_ITEMS_PER_EDIT) {
    throw new Error(`an edit may carry ${MAX_ITEMS_PER_EDIT} items, not ${items.length}`);
  }
  items.forEach((item, index) => {
    try {
      validateItem(item);
    } catch (error) {
      throw new Error(`item ${index}: ${error.message}`);
    }
  });
  return items;
}

function validateItem(item) {
  if (!isPlainObject(item)) throw new Error("an item must be an object");
  if (item.op !== "put" && item.op !== "delete") throw new Error("op must be put or delete");
  if (typeof item.id !== "string" || !ITEM_ID.test(item.id)) {
    throw new Error("id must be 1 to 120 characters of letters, digits, . _ : -");
  }
  const allowed = item.op === "put" ? PUT_KEYS : DELETE_KEYS;
  for (const key of Object.keys(item)) {
    if (!allowed.includes(key)) throw new Error(`${key} is not a field of a ${item.op} item`);
  }
  if (item.op === "delete") return;
  if (!Object.hasOwn(WRITABLE, item.metric)) {
    throw new Error(`metric ${pyRepr(item.metric)} cannot be written`);
  }
  for (const name of ["start", "end"]) {
    if (!Number.isInteger(item[name]) || item[name] < 0) {
      throw new Error(`${name} must be whole seconds since 1970`);
    }
  }
  if (item.end < item.start) throw new Error("end must not be before start");
  const unit = WRITABLE[item.metric];
  if (unit !== null) {
    if ("stage" in item) throw new Error("stage belongs to sleep, not to a quantity");
    if (typeof item.value !== "number" || !Number.isFinite(item.value) || item.value < 0) {
      throw new Error("value must be a finite number, zero or more");
    }
    if (item.unit !== unit) throw new Error(`unit must be ${unit} for ${item.metric}`);
  } else {
    if ("value" in item || "unit" in item) {
      throw new Error("value and unit belong to a quantity, not to sleep");
    }
    if (!SLEEP_STAGES.includes(item.stage)) {
      throw new Error(`stage must be one of ${SLEEP_STAGES.join(", ")}`);
    }
  }
}

/** Raw-deflate-compressed {"v":1,"items":[...]}, keys in a fixed order. */
export function packEdit(items) {
  const ordered = items.map((item) => {
    const out = {};
    for (const key of item.op === "put" ? PUT_KEYS : DELETE_KEYS) {
      if (key in item) out[key] = item[key];
    }
    return out;
  });
  return deflateRawSync(Buffer.from(JSON.stringify({ v: EDIT_FORMAT_VERSION, items: ordered })));
}

/** What an edit signs: the purpose, the bucket, the time and a digest of the bytes. */
export function canonicalEdit(bucket, timestamp, sealed) {
  const digest = toBase64url(createHash("sha256").update(sealed).digest());
  return ["efferent/v1 edit", bucket, String(timestamp), digest].join("\n");
}

/**
 * The phone's word for why it refused one item. `awaitingApproval` and
 * `declined` are legacy: a build that asked its owner first produced them, no
 * phone does now, and an outcome is told once and never revised. `replayed`
 * means the phone had already answered this very edit and wrote nothing the
 * second time.
 */
export const OUTCOME_CODES = [
  "unknownMetric",
  "badUnit",
  "badRange",
  "unauthorized",
  "notFound",
  "healthRefused",
  "badSignature",
  "cannotOpen",
  "malformed",
  "awaitingApproval",
  "declined",
  "replayed",
];

const EDIT_NAME = /^\d{13}-[a-z2-7]{8}$/;

export function isEditName(value) {
  return typeof value === "string" && EDIT_NAME.test(value);
}

/** What each writable metric takes, in the shape an agent is told it. */
export function writableShapes() {
  const shapes = {};
  for (const [name, unit] of Object.entries(WRITABLE)) {
    shapes[name] = unit === null
      ? { kind: "category", stages: [...SLEEP_STAGES] }
      : { kind: "quantity", unit };
  }
  return shapes;
}

// MARK: - The profile kept on this machine

const DAYS = "days";
const STATE = "mirror.json";
const READING = "reading-key.json";
const EDITOR = "editor-key.json";
const EDITS = "edits.json";
const METRICS = "metrics.json";

/** Something the reading side could not do, said in one sentence. */
export class ArchiveError extends Error {}

/**
 * `EFFERENT_HOME`, read when asked rather than once: tests keep several
 * readers apart in one process, and nothing else pays for the lookup.
 */
export function home() {
  return process.env.EFFERENT_HOME || ".efferent";
}

/** An absolute path, for messages: a relative one says nothing about where it looked. */
function resolved(path) {
  return isAbsolute(path) ? path : resolve(path);
}

// The stored keys are base64url PKCS8, the phone's handoff carries raw halves,
// and the two are one DER prefix apart. A profile the Python reader made is the
// same files, read the same way.

export function pkcs8(curve, raw) {
  return toBase64url(Buffer.concat([DER[curve].private, raw]));
}

/** The raw 32 bytes of a stored PKCS8 key, X25519 or Ed25519 alike. */
export function rawPrivate(stored) {
  const key = createPrivateKey({ key: fromBase64url(stored), format: "der", type: "pkcs8" });
  return Buffer.from(key.export({ format: "jwk" }).d, "base64url");
}

export function load(name) {
  return JSON.parse(readFileSync(join(home(), name), "utf8"));
}

function privateDirectory(path) {
  mkdirSync(path, { recursive: true, mode: 0o700 });
  // The mode applies only to a directory mkdir creates. Tighten an existing
  // one too: an older release left these at 0755.
  chmodSync(path, 0o700);
}

/**
 * Through a temporary file: two processes keep this mirror, and a rename is the
 * one write nobody can catch half of. Laid out unless asked otherwise, because
 * these are the files somebody opens when the reader behaves strangely.
 */
export function write(name, value, compact = false) {
  privateDirectory(home());
  const temporary = join(home(), `${name}.partial`);
  writeFileSync(temporary, `${compact ? JSON.stringify(value) : JSON.stringify(value, null, 2)}\n`);
  chmodSync(temporary, 0o600);
  renameSync(temporary, join(home(), name));
}

export function loadState(url) {
  let stored = null;
  try {
    stored = load(STATE);
  } catch {
    stored = null;
  }
  const endpoint = url || stored?.endpoint;
  if (!endpoint) {
    // Named in full, because the commonest way to see this is a server started
    // from some other directory: the default home is relative.
    throw new ArchiveError(
      `no archive is configured in ${resolved(home())} — point EFFERENT_HOME at the directory ` +
        "holding reading-key.json, or run `efferent.mjs connect --handoff <file>` there once",
    );
  }
  const state = { endpoint, days: stored?.days || {}, syncedAt: stored?.syncedAt || "" };
  // Written here rather than by whichever command saves next: "after that it is
  // remembered" has to be true of the first command a person runs.
  if (endpoint !== stored?.endpoint) write(STATE, state);
  return state;
}

export function saveState(state) {
  write(STATE, { ...state, syncedAt: nowIso() });
}

function loadEditor() {
  try {
    return load(EDITOR);
  } catch {
    throw new ArchiveError(
      `no editor key in ${resolved(home())} — the handoff this reader was connected with ` +
        "predates writing; ask the phone for a fresh one and run `efferent.mjs connect` with it",
    );
  }
}

function submittedEdits() {
  try {
    return load(EDITS);
  } catch {
    return [];
  }
}

/**
 * What one item was about, kept locally so a later session can find the id it
 * needs to replace or delete a sample it wrote. Never a value.
 */
function summarize(item) {
  if (item.op === "delete") return { op: "delete", id: item.id };
  const day = new Date(item.start * 1000).toISOString().slice(0, 10);
  return { op: "put", id: item.id, metric: item.metric, day };
}

/** Through a temporary file: a truncated day would look like a quiet one. */
export function writeDay(day, events) {
  privateDirectory(join(home(), DAYS));
  const temporary = join(home(), DAYS, `${day}.partial`);
  writeFileSync(temporary, events.map((event) => `${JSON.stringify(event)}\n`).join(""));
  chmodSync(temporary, 0o600);
  renameSync(temporary, join(home(), DAYS, `${day}.ndjson`));
}

export function readDay(day) {
  let text;
  try {
    text = readFileSync(join(home(), DAYS, `${day}.ndjson`));
  } catch {
    return [];
  }
  return eventsOf(text);
}

function dayFiles() {
  let entries;
  try {
    entries = readdirSync(join(home(), DAYS), { withFileTypes: true });
  } catch {
    return [];
  }
  const found = [];
  for (const entry of entries) {
    const day = entry.name.replace(/\.ndjson$/, "");
    if (day === entry.name || !isDay(day) || !entry.isFile()) continue;
    found.push([day, join(home(), DAYS, entry.name)]);
  }
  return found.sort(([left], [right]) => (left < right ? -1 : left > right ? 1 : 0));
}

/**
 * Every mirrored day with a fingerprint of its file, in order: size and
 * modification time, and deliberately not the archive's upload time.
 */
export function mirrorVersions() {
  const versions = {};
  for (const [day, path] of dayFiles()) {
    const stat = statSync(path, { bigint: true });
    versions[day] = `${stat.size}:${stat.mtimeNs / 1000000n}`;
  }
  return versions;
}

export function mirroredDays(start, end) {
  return dayFiles()
    .map(([day]) => day)
    .filter((day) => (!start || day >= start) && (!end || day <= end));
}

// MARK: - The service

/** How many ranges are asked for at once; a handful already fills the link. */
export const FETCH_WINDOW = 4;
/** The longest run of days one range asks for: what one answer holds. */
const SPAN_DAYS = 92;
/** How far apart two wanted days may be and still share a request. */
const GAP_DAYS = 7;

/**
 * One place every request goes through, so a test can stand in for the
 * service. Answers `{status, body, headers}`, headers named in lower case; a
 * refusal is a status, not an exception.
 */
async function fetchTransport(method, url, headers = {}, body = undefined) {
  let response;
  try {
    response = await fetch(url, {
      method,
      headers: { "User-Agent": USER_AGENT, ...headers },
      body,
      signal: AbortSignal.timeout(30000),
    });
  } catch (error) {
    const cause = error.cause?.message || error.cause?.code;
    throw new Error(cause ? `${error.message} (${cause})` : error.message);
  }
  const answer = Buffer.from(await response.arrayBuffer());
  if (answer.length > MAX_ANSWER_BYTES) {
    throw new Error("the answer exceeds the 16 MiB this reader will hold");
  }
  const named = {};
  response.headers.forEach((value, name) => {
    named[name.toLowerCase()] = value;
  });
  return { status: response.status, body: answer, headers: named };
}

/** Seams a test replaces: the network, and nothing else. */
export const io = { transport: fetchTransport };

/**
 * Wanted days as ranges to ask for, each with the wanted days inside it. A
 * range ends where the next wanted day is more than `GAP_DAYS` on, or where it
 * would pass `SPAN_DAYS`: a decade is a few dozen requests, and three
 * scattered days are three small ones rather than a year nobody asked for.
 */
export function spans(names) {
  const ranges = [];
  for (const day of [...new Set(names)].sort()) {
    const last = ranges.at(-1);
    if (last && day <= addDays(last[1], GAP_DAYS) && day < addDays(last[0], SPAN_DAYS)) {
      last[1] = day;
      last[2].push(day);
      continue;
    }
    ranges.push([day, day, [day]]);
  }
  return ranges;
}

/** The one sentence a refusal carries, or the status when it carries none. */
function refusal(body, status) {
  const text = Buffer.from(body).toString("utf8");
  try {
    const parsed = JSON.parse(text);
    if (isPlainObject(parsed) && typeof parsed.error === "string") return parsed.error;
  } catch {
    // Not JSON: the text itself is the answer.
  }
  return text || String(status);
}

function query(parameters) {
  const text = new URLSearchParams(parameters).toString();
  return text ? `?${text}` : "";
}

/** The archive behind an endpoint, opened with the reading key in `home()`. */
export class Archive {
  constructor(endpoint) {
    const reading = load(READING);
    this.endpoint = endpoint;
    this.readingPublic = fromBase64url(reading.readingPublic);
    this.privateRaw = rawPrivate(reading.readingPrivate);
    this.bucket = bucketOf(this.readingPublic);
  }

  /** A GET of `target`, signed with the read key made from the reading key. */
  read(target, accept = "application/json") {
    const url = `${this.endpoint}${target}`;
    const signed = readHeaders(url, this.bucket, this.privateRaw, unixNow());
    return io.transport("GET", url, { Accept: accept, ...signed });
  }

  async readJson(target) {
    const { status, body } = await this.read(target);
    if (status >= 400) throw new ArchiveError(`${target}: ${status} ${refusal(body, status)}`);
    return JSON.parse(Buffer.from(body).toString("utf8"));
  }

  opened(day, blob) {
    const sealed = openSealed(
      this.privateRaw,
      this.readingPublic,
      blob,
      associatedData(this.bucket, day),
    );
    return { day, events: eventsOf(inflateRawSync(sealed)) };
  }

  /**
   * Every day the archive holds from `first` to `last`, sealed, in as many
   * answers as the service needs: it names the last day it sent while more
   * remain, and that goes back as `after`.
   */
  async span(first, last) {
    const found = new Map();
    let after = "";
    for (;;) {
      const parameters = { from: first, to: last, ...(after ? { after } : {}) };
      const { status, body, headers } = await this.read(
        `/b/${this.bucket}/d${query(parameters)}`,
        "application/octet-stream",
      );
      if (status === 405) {
        throw new ArchiveError(
          `${first} to ${last}: the service does not hand ranges back yet — ` +
            "it predates this reader, and its Worker needs deploying first",
        );
      }
      if (status >= 400) {
        throw new ArchiveError(`${first} to ${last}: ${status} ${refusal(body, status)}`);
      }
      let days;
      try {
        days = unpackFrame(Buffer.from(body));
      } catch (error) {
        throw new ArchiveError(`${first} to ${last}: ${error.message}`);
      }
      for (const [day, blob] of days) {
        if (day < first || day > last || day <= after) {
          throw new ArchiveError(`the service answered ${first} to ${last} with ${day}`);
        }
        found.set(day, blob);
      }
      const following = headers["x-efferent-next"];
      if (!following) return found;
      if (following <= after) {
        throw new ArchiveError(`the service asked to go on from ${following} after ${after}`);
      }
      after = following;
    }
  }

  /**
   * One range, opened: the wanted days inside it and nothing else. A day asked
   * for and not handed back stops the fetch, because a mirror that recorded a
   * day it never received would never ask for it again.
   */
  async fetch([first, last, inside]) {
    const found = await this.span(first, last);
    const missing = inside.filter((day) => !found.has(day));
    if (missing.length) {
      throw new ArchiveError(`${missing[0]}: the archive no longer holds this day`);
    }
    return inside.map((day) => this.opened(day, found.get(day)));
  }

  /**
   * Which days the archive has in a range. Following `next` until it comes back
   * null is not optional: a listing that stopped at its first page would report
   * the rest of a decade as nothing at all.
   */
  async list(start, end) {
    const entries = [];
    let after = null;
    for (;;) {
      const parameters = {};
      if (after) parameters.after = after;
      else if (start) parameters.from = start;
      if (end) parameters.to = end;
      const page = await this.readJson(`/b/${this.bucket}/days${query(parameters)}`);
      entries.push(...page.days);
      if (page.next === null || page.next === undefined) return entries;
      after = page.next;
    }
  }

  /**
   * Named days, in the order they were asked for, fetched as ranges a window at
   * a time. The window is small on purpose — enough to fill the link, not
   * enough to look like an attack on it.
   */
  async *several(names, width = FETCH_WINDOW) {
    const order = [...new Set(names)];
    const ranges = spans(order);
    const ready = new Map();
    let position = 0;
    for (let start = 0; start < ranges.length; start += width) {
      const settled = await Promise.allSettled(
        ranges.slice(start, start + width).map((range) => this.fetch(range)),
      );
      for (const outcome of settled) {
        if (outcome.status === "rejected") throw outcome.reason;
        for (const day of outcome.value) ready.set(day.day, day);
      }
      // Whatever is next in the order asked for goes out as soon as it is here,
      // so a sync records its progress as it goes.
      while (position < order.length && ready.has(order[position])) {
        yield ready.get(order[position]);
        ready.delete(order[position]);
        position += 1;
      }
    }
  }

  stats() {
    return this.readJson(`/b/${this.bucket}/stats`);
  }

  /**
   * An edit, the way the phone will check it: sealed to the reading key with
   * the bucket in the tag, signed by the editor key over the canonical message.
   * Validated before anything is sealed, and written down locally afterwards,
   * because the service knows an edit by a name and a count.
   */
  async submitEdits(items) {
    validateItems(items);
    const editor = loadEditor();
    const sealed = Buffer.concat([
      Buffer.from([SEALED_VERSION]),
      hpkeSeal(this.readingPublic, INFO, editAssociatedData(this.bucket), packEdit(items)),
    ]);
    const timestamp = unixNow();
    const signature = signEd25519(
      rawPrivate(editor.editorPrivate),
      canonicalEdit(this.bucket, timestamp, sealed),
    );
    const { status, body } = await io.transport(
      "POST",
      `${this.endpoint}/b/${this.bucket}/edits`,
      {
        "Content-Type": "application/octet-stream",
        "X-Efferent-Timestamp": String(timestamp),
        "X-Efferent-Editor": editor.editorPublic,
        "X-Efferent-Signature": toBase64url(signature),
      },
      sealed,
    );
    if (status >= 400) {
      throw new ArchiveError(`the service refused the edit: ${status} ${refusal(body, status)}`);
    }
    const answer = JSON.parse(Buffer.from(body).toString("utf8"));
    write(EDITS, [
      ...submittedEdits(),
      { name: answer.name, at: answer.at, items: items.map(summarize) },
    ]);
    return answer;
  }

  /** The service's listing, with this profile's own record laid over it. */
  async edits({ after = null, status = null, limit = null } = {}) {
    const parameters = {};
    if (after) parameters.after = after;
    if (status) parameters.status = status;
    if (limit) parameters.limit = String(limit);
    const page = await this.readJson(`/b/${this.bucket}/edits${query(parameters)}`);
    const known = new Map(submittedEdits().map((edit) => [edit.name, edit.items]));
    const entries = [];
    for (const entry of page.edits) {
      const items = known.get(entry.name);
      const laid = items !== undefined && items !== null ? { ...entry, items } : { ...entry };
      // Items that did not land are `failed`. An outcome stored before the word
      // changed says `refused` and is a real answer, so it is read under that
      // name rather than reported as having none.
      if ((entry.failed || 0) > 0) {
        const outcome = await this.readJson(`/b/${this.bucket}/o/${entry.name}`);
        laid.refusals = (outcome.failed ?? outcome.refused ?? []).map((refused) => ({
          ...refused,
          ...(items?.length && refused.item < items.length ? { id: items[refused.item].id } : {}),
        }));
      }
      entries.push(laid);
    }
    return { edits: entries, next: page.next ?? null };
  }
}

// MARK: - Turning days into answers

// The awkward parts are the point. An agent handed raw events gets them wrong in
// ways that look plausible: it sums overlapping sleep and reports nine hours, it
// adds hourly steps to daily steps and doubles the day, it prints a blood oxygen
// of 0.97 as "0.97%". None of those fail loudly, so the tools answer in the
// shapes people ask about and the corrections happen below them.

/**
 * Metrics whose numbers are already summed by Health and must never be summed
 * again from records: several devices write the same minutes.
 */
export const TOTALS = [
  "steps",
  "distanceWalkingRunning",
  "flightsClimbed",
  "activeEnergy",
  "basalEnergy",
  "exerciseTime",
  "standTime",
  "dietaryEnergy",
  "dietaryProtein",
  "dietaryCarbohydrates",
  "dietaryFat",
  "dietaryWater",
];

/** Metrics that travel record by record, because a total of them says nothing. */
export const RECORDS = [
  "heartRate",
  "restingHeartRate",
  "heartRateVariability",
  "respiratoryRate",
  "oxygenSaturation",
  "bodyMass",
  "sleep",
  "workout",
];

/**
 * Where the unit written on an event would mislead a reader. HealthKit's
 * percent is a fraction, so blood oxygen leaves the phone as 0.97 with "%". The
 * label is corrected rather than the value, because rewriting the value would
 * put two meanings of one field into one history.
 */
export const UNIT_NOTES = {
  oxygenSaturation: "fraction of 1, not a percentage — 0.97 means 97%. " +
    "The unit written on the event says '%' and is wrong.",
};

/** HKWorkoutActivityType raw values, which is all the phone sends. */
const ACTIVITIES = {
  "9": "climbing",
  "11": "crossTraining",
  "13": "cycling",
  "16": "elliptical",
  "20": "functionalStrengthTraining",
  "24": "hiking",
  "29": "mindAndBody",
  "35": "rowing",
  "37": "running",
  "44": "stairClimbing",
  "46": "swimming",
  "50": "traditionalStrengthTraining",
  "52": "walking",
  "57": "yoga",
  "3000": "other",
};

export function activityName(raw) {
  const key = raw === null || raw === undefined ? "" : String(raw);
  return Object.hasOwn(ACTIVITIES, key) ? ACTIVITIES[key] : `activity-${key || "unknown"}`;
}

/**
 * Rounding the way the Python reader rounded: to the nearest at `digits`
 * decimals of the exact binary value, and a tie to the even digit. `toFixed`
 * rounds a tie away from zero, and a 225-second stage is exactly 0.0625 hours.
 */
export function roundTo(value, digits) {
  if (!Number.isFinite(value) || Math.abs(value) >= 1e21) return value;
  const exact = Math.abs(value).toFixed(20);
  const point = exact.indexOf(".");
  const rest = exact.slice(point + 1 + digits);
  if (rest[0] === "5" && /^5?0*$/.test(rest)) {
    const kept = exact.slice(0, point + 1 + digits);
    const last = Number(kept.at(-1) === "." ? kept.at(-2) : kept.at(-1));
    const scale = 10 ** digits;
    const truncated = Number(kept);
    const rounded = last % 2 === 0 ? truncated : (Math.round(truncated * scale) + 1) / scale;
    return Math.sign(value) * rounded;
  }
  // A negative value that rounds to nothing stays -0, as Python's does.
  return Number(value.toFixed(digits));
}

export function round3(value) {
  return roundTo(value, 3);
}

function round1(value) {
  return roundTo(value, 1);
}

/** Python's `sum()` of floats: Neumaier's compensated summation. */
function fsum(values) {
  let total = 0;
  let compensation = 0;
  for (const value of values) {
    const next = total + value;
    compensation += Math.abs(total) >= Math.abs(value)
      ? (total - next) + value
      : (value - next) + total;
    total = next;
  }
  return compensation && Number.isFinite(compensation) ? total + compensation : total;
}

const isNumber = (value) => typeof value === "number";
const byNumber = (left, right) => left - right;
const byString = (left, right) => (left < right ? -1 : left > right ? 1 : 0);

/**
 * What one day holds, per metric, and nothing about any other day. The
 * expensive half, and the half that never changes once a day is written.
 */
export function whatADayHolds(events) {
  const held = {};
  for (const event of events) {
    const metric = event.metric;
    if (!metric) continue;
    const bucket = typeof event.bucket === "string" ? event.bucket : null;
    const existing = held[metric];
    if (!existing) {
      held[metric] = {
        buckets: bucket ? [bucket] : [],
        unit: typeof event.unit === "string" ? event.unit : null,
        events: 1,
      };
      continue;
    }
    if (bucket && !existing.buckets.includes(bucket)) existing.buckets.push(bucket);
    existing.events += 1;
  }
  return held;
}

/**
 * Day summaries into one summary of the archive. A metric's kind and unit come
 * from the first day that holds it, so the days must arrive in order.
 */
export function fold(days) {
  const found = new Map();
  for (const entry of days) {
    const day = entry.day;
    for (const [metric, holding] of Object.entries(entry.held)) {
      const existing = found.get(metric);
      if (!existing) {
        found.set(metric, {
          kind: holding.buckets.length ? "total" : "record",
          unit: holding.unit,
          buckets: new Set(holding.buckets),
          first: day,
          last: day,
          days: new Set([day]),
          events: holding.events,
        });
        continue;
      }
      for (const bucket of holding.buckets) existing.buckets.add(bucket);
      if (day < existing.first) existing.first = day;
      if (day > existing.last) existing.last = day;
      existing.days.add(day);
      existing.events += holding.events;
    }
  }
  const summaries = [];
  for (const [metric, value] of found) {
    const summary = { metric, kind: value.kind, unit: value.unit };
    if (Object.hasOwn(UNIT_NOTES, metric)) summary.unitNote = UNIT_NOTES[metric];
    summary.buckets = [...value.buckets].sort();
    summary.firstDay = value.first;
    summary.lastDay = value.last;
    summary.daysCovered = value.days.size;
    summary.events = value.events;
    summaries.push(summary);
  }
  return summaries.sort((left, right) => byString(left.firstDay, right.firstDay));
}

/** What each metric is, when it starts, and how much of it there is. */
export function summarise(days) {
  return fold(days.map((entry) => ({ day: entry.day, held: whatADayHolds(entry.events) })));
}

/** Linear interpolation between the neighbouring ranks. */
function percentile(sorted, fraction) {
  if (sorted.length === 1) return sorted[0];
  const position = (sorted.length - 1) * fraction;
  const lower = Math.floor(position);
  const upper = lower + (position !== lower ? 1 : 0);
  if (lower === upper) return sorted[lower];
  return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - lower);
}

export function distribution(values) {
  if (!values.length) return null;
  const ordered = [...values].sort(byNumber);
  const total = fsum(ordered);
  return {
    n: ordered.length,
    min: round3(ordered[0]),
    p10: round3(percentile(ordered, 0.1)),
    median: round3(percentile(ordered, 0.5)),
    mean: round3(total / ordered.length),
    p90: round3(percentile(ordered, 0.9)),
    max: round3(ordered.at(-1)),
    sum: round3(total),
  };
}

function emptyDistribution() {
  return { n: 0, min: 0, p10: 0, median: 0, mean: 0, p90: 0, max: 0, sum: 0 };
}

/**
 * One row per day, one column per metric, from the day buckets only. The same
 * archive carries hourly buckets for recent days, and a reader that took both
 * would count those days twice.
 */
export function dailyTotals(days, metrics) {
  return days.map((entry) => {
    const values = Object.fromEntries(metrics.map((metric) => [metric, null]));
    for (const event of entry.events) {
      if (event.bucket !== "day" || !Object.hasOwn(values, event.metric)) continue;
      if (isNumber(event.value)) values[event.metric] = round3(event.value);
    }
    return { day: entry.day, values };
  });
}

/** The label a day falls under. Weeks are ISO weeks, named by their Monday. */
export function groupOf(day, grouping) {
  if (grouping === "day") return day;
  if (grouping === "month") return day.slice(0, 7);
  if (grouping === "year") return day.slice(0, 4);
  const weekday = (new Date(`${day}T00:00:00Z`).getUTCDay() + 6) % 7;
  return addDays(day, -weekday);
}

function parseInstant(value) {
  if (typeof value !== "string" || !value) return null;
  const parsed = Date.parse(value);
  return Number.isNaN(parsed) ? null : parsed / 1000;
}

/** The length of the union of a set of intervals, in seconds. */
function merged(events) {
  const intervals = [];
  for (const event of events) {
    const start = parseInstant(event.start);
    const end = parseInstant(event.end);
    if (start !== null && end !== null && end > start) intervals.push([start, end]);
  }
  intervals.sort((left, right) => left[0] - right[0] || left[1] - right[1]);
  let total = 0;
  let from = 0;
  let to = -1;
  for (const [start, end] of intervals) {
    if (start > to) {
      if (to > from) total += to - from;
      from = start;
      to = end;
    } else if (end > to) {
      to = end;
    }
  }
  if (to > from) total += to - from;
  return total;
}

/**
 * Nights, assembled out of the stretches the watch recorded. Overlaps are
 * merged, never added: more than one source can describe the same minutes. A
 * night is noon to noon, named by the evening it began in, so grouping by the
 * calendar day does not cut every night in half.
 */
export function nights(events) {
  const byNight = new Map();
  for (const event of events) {
    if (event.metric !== "sleep" || !event.start || !event.end) continue;
    const started = parseInstant(event.start);
    if (started === null) continue;
    const label = new Date((started - 12 * 3600) * 1000).toISOString().slice(0, 10);
    if (!byNight.has(label)) byNight.set(label, []);
    byNight.get(label).push(event);
  }

  const result = [];
  for (const night of [...byNight.keys()].sort()) {
    const stretches = byNight.get(night);
    const asleep = stretches.filter((event) => String(event.stage || "").startsWith("asleep"));
    const inBed = stretches.filter((event) => event.stage === "inBed");

    const stages = {};
    for (const stage of [...new Set(asleep.map((event) => pyStr(event.stage)))].sort()) {
      stages[stage] = round3(merged(asleep.filter((event) => event.stage === stage)) / 3600);
    }

    const chosen = asleep.length ? asleep : stretches;
    const starts = chosen.map((event) => pyStr(event.start)).sort();
    const ends = chosen.map((event) => pyStr(event.end)).sort();
    result.push({
      night,
      asleepHours: round3(merged(asleep) / 3600),
      inBedHours: inBed.length ? round3(merged(inBed) / 3600) : null,
      stages,
      start: starts.length ? starts[0] : null,
      end: ends.length ? ends.at(-1) : null,
      segments: asleep.length,
    });
  }
  return result;
}

export function workouts(days) {
  const found = [];
  for (const entry of days) {
    for (const event of entry.events) {
      if (event.metric !== "workout") continue;
      found.push({
        day: entry.day,
        activity: activityName(event.activity),
        start: String(event.start || ""),
        end: String(event.end || ""),
        minutes: round3(Number(event.duration || 0) / 60),
        source: typeof event.source === "string" ? event.source : null,
      });
    }
  }
  return found.sort((left, right) => byString(left.start, right.start));
}

// MARK: - The archive, kept close

/**
 * How long an answer may trust the mirror before asking the archive whether
 * anything moved: short enough that "today" means today, long enough that a
 * conversation of twenty questions costs one check.
 */
const FRESH_FOR = 5 * 60;
/** Days re-listed on every check: where the phone's rewrites actually happen. */
const RECENT_DAYS = 14;
/** Rows one answer will return; past this the answer refuses, never truncates. */
const MAX_ROWS = 1000;

/**
 * Whether the archive holds days this mirror has no record of. `days` is a
 * total only when the service walked the whole archive; past that it is a
 * floor, which can prove "behind" and nothing else.
 */
function behind(remote, state) {
  const mirrored = Object.keys(state.days).length;
  return remote.complete ? remote.days !== mirrored : remote.days > mirrored;
}

/** Everything the tools read through, so freshness is decided once. */
export class Reader {
  constructor() {
    this.state = null;
    this.archive = null;
    this.checkedAt = 0;
    /** What the archive said it holds at the last check, so nothing asks twice. */
    this.remote = null;
    /** Returned with the answer: a quietly stale answer about health is worse than a late one. */
    this.warning = null;
  }

  open() {
    if (this.state === null || this.archive === null) {
      this.state = loadState();
      this.archive = new Archive(this.state.endpoint);
    }
    return [this.state, this.archive];
  }

  async stats() {
    try {
      const [, archive] = this.open();
      this.remote = await archive.stats();
      return this.remote;
    } catch (error) {
      this.remote = null;
      this.warning = `the archive could not be reached (${error.message}); ` +
        "answering from the local mirror, which may be behind";
      return null;
    }
  }

  /** What the archive holds, as of the check that came with this answer. */
  async holds() {
    await this.refresh();
    return this.remote;
  }

  /**
   * Bring the mirror in line with the archive. Two requests in the ordinary
   * case: what the archive holds in total, and the last fortnight in detail. A
   * day older than the fortnight rewritten moves neither, so a forced check —
   * `phone_data_sync`, the only caller that forces — reads the whole listing.
   */
  async refresh(force = false) {
    if (!force && Date.now() / 1000 - this.checkedAt < FRESH_FOR) return;
    this.warning = null;

    const remote = await this.stats();
    if (!remote) return;
    const [held, archive] = this.open();
    const state = this.reload(held);
    this.checkedAt = Date.now() / 1000;

    try {
      if (force) {
        await this.takeWhole(archive, state);
        return;
      }
      await this.take(archive, state, await archive.list(addDays(today(), -RECENT_DAYS)));
      if (behind(remote, state)) await this.takeWhole(archive, state);
    } catch (error) {
      this.warning = `the mirror could not be brought up to date (${error.message}); ` +
        "answering from what it already had";
    }
  }

  /**
   * The mirror's record of itself, read fresh rather than remembered: the
   * command line keeps the same mirror, so a record held since the first
   * question is behind whatever it copied since. A record that cannot be read
   * does not stop an answer.
   */
  reload(held) {
    try {
      this.state = loadState();
      return this.state;
    } catch (error) {
      this.warning = `the mirror's own record could not be read (${error.message}); ` +
        "answering from what this session already had";
      return held;
    }
  }

  /**
   * The whole archive, listed and taken. Only a listing that walks to the end
   * can say a day has gone, and a day that has gone loses its record — the file
   * stays, since it may be the last copy left.
   */
  async takeWhole(archive, state) {
    const listing = await archive.list();
    const present = new Set(listing.map((entry) => entry.day));
    let dropped = false;
    for (const day of Object.keys(state.days)) {
      if (present.has(day)) continue;
      delete state.days[day];
      dropped = true;
    }
    await this.take(archive, state, listing, dropped);
  }

  /** Copy the days whose stored version is not the one the archive holds. */
  async take(archive, state, listing, save = false) {
    const stale = new Map();
    for (const entry of listing) {
      if (state.days[entry.day] !== entry.uploaded) stale.set(entry.day, entry.uploaded);
    }
    if (!stale.size) {
      if (save) saveState(state);
      return;
    }
    for await (const fetched of archive.several([...stale.keys()].sort())) {
      writeDay(fetched.day, fetched.events);
      state.days[fetched.day] = stale.get(fetched.day);
    }
    saveState(state);
  }

  /**
   * The events in a range a caller cares about, day by day. `keep` is applied
   * before anything is held on to: a decade of heart rate is eight hundred
   * thousand readings, and a question about sleep has no use for any of them.
   */
  async collect(from, to, keep) {
    await this.refresh();
    return mirroredDays(from, to).map((day) => ({ day, events: readDay(day).filter(keep) }));
  }
}

/**
 * What every mirrored day holds, worked out once per day and kept in
 * `metrics.json`. What is kept is a claim about a file, and the file is what
 * tests it: an entry whose size and modification time no longer match is
 * thrown away and worked out again. Deleting the file is always safe.
 */
export function whatEachDayHolds() {
  const versions = mirrorVersions();
  let kept;
  try {
    kept = load(METRICS);
    if (!isPlainObject(kept)) kept = {};
  } catch {
    kept = {};
  }
  const days = [];
  const rebuilt = {};
  let moved = false;
  // In day order, because the fold takes a metric's kind and unit from the
  // first day that holds it.
  for (const [day, version] of Object.entries(versions)) {
    const remembered = kept[day];
    if (isPlainObject(remembered) && remembered.v === version) {
      rebuilt[day] = remembered;
      days.push({ day, held: remembered.m });
      continue;
    }
    const held = whatADayHolds(readDay(day));
    rebuilt[day] = { v: version, m: held };
    days.push({ day, held });
    moved = true;
  }
  // A day that left the mirror leaves this record too.
  if (moved || Object.keys(kept).length !== Object.keys(rebuilt).length) {
    write(METRICS, rebuilt, true);
  }
  return days;
}

/**
 * How the readable part stands against the archive. Fewer days here means
 * history not yet copied; more days here means the archive has lost one, and
 * the local copy may be the last of it.
 */
function note(remote, mirrored) {
  if (!remote) return "the archive could not be asked what it holds";
  if (remote.days > mirrored) {
    return `${remote.days - mirrored} days of the archive are not copied here yet; ` +
      "run phone_data_sync to complete the picture";
  }
  if (remote.complete && mirrored > remote.days) {
    return `${mirrored - remote.days} days are readable here that the archive no longer holds; ` +
      "this copy of them may be the only one left";
  }
  return "the whole archive is readable";
}

// MARK: - The tools

function dayOf(value, name) {
  if (value === null || value === undefined || value === "") return null;
  const text = pyStr(value).slice(0, 10);
  if (!isDay(text)) throw new Error(`${name} must be a day, YYYY-MM-DD, got ${pyStr(value)}`);
  return text;
}

function rangeOf(given, defaultDays) {
  const to = dayOf(given.until, "until") || today();
  const from = dayOf(given.since, "since") || addDays(to, -defaultDays);
  if (from > to) throw new Error(`since (${from}) is after until (${to})`);
  return [from, to];
}

function namesOr(value, fallback) {
  return Array.isArray(value) && value.length ? value.map((name) => pyStr(name)) : fallback;
}

function unitsFor(days, metrics) {
  const units = Object.fromEntries(metrics.map((metric) => [metric, null]));
  for (const entry of days) {
    for (const event of entry.events) {
      if (
        Object.hasOwn(units, event.metric) && !units[event.metric] && typeof event.unit === "string"
      ) {
        units[event.metric] = event.unit;
      }
    }
  }
  return units;
}

/** When something happened comes first; everything else by name. */
const INSTANTS = ["start", "end"];
const place = (name) => (INSTANTS.includes(name) ? INSTANTS.indexOf(name) : INSTANTS.length);

/**
 * Rows as a table: what they all agree on said once, the rest in columns. The
 * columns are the keys the rows actually carry, never a list written here, so a
 * field nobody expected becomes a column rather than vanishing; a key only some
 * rows carry is a null in the others, which is not the same as a zero.
 */
export function table(rows, drop = []) {
  const kept = rows.map((row) => {
    const out = {};
    for (const [name, value] of Object.entries(row)) if (!drop.includes(name)) out[name] = value;
    return out;
  });
  const every = [...new Set(kept.flatMap((row) => Object.keys(row)))].sort((left, right) =>
    place(left) - place(right) || byString(left, right)
  );
  const same = {};
  const columns = [];
  for (const name of every) {
    const first = kept.length ? kept[0][name] : undefined;
    // Only a plain value every row carries, and only past one row: with a single
    // row every field trivially agrees and the row would come back empty.
    const agreed = kept.length > 1 && (typeof first !== "object" || first === null) &&
      kept.every((row) => Object.hasOwn(row, name) && row[name] === first);
    if (agreed) same[name] = first;
    else columns.push(name);
  }
  return {
    sameOnEveryRow: same,
    columns,
    rows: kept.map((row) => columns.map((name) => (Object.hasOwn(row, name) ? row[name] : null))),
  };
}

async function overview(_, reader) {
  const remote = await reader.holds();
  const days = whatEachDayHolds();
  const mirrored = days.map((entry) => entry.day);
  return {
    archive: remote
      ? {
        days: remote.days,
        firstDay: remote.firstDay,
        lastDay: remote.lastDay,
        megabytes: round1(remote.bytes / 1024 / 1024),
      }
      : "unreachable",
    readable: {
      days: mirrored.length,
      firstDay: mirrored.length ? mirrored[0] : null,
      lastDay: mirrored.length ? mirrored.at(-1) : null,
      note: note(remote, mirrored.length),
    },
    metrics: fold(days),
    writable: writableShapes(),
    howToRead: [
      "A total (steps, distance, energy, exercise and stand minutes) is already summed by",
      "Health and must never be summed again from records — several devices write the same",
      "minutes and adding them double-counts.",
      "Totals come bucketed by day, and by hour only from the day the app was installed.",
      "A record belongs to the day it started on, so a night that began before midnight is",
      "in the evening's day.",
      "`writable` is what phone_data_write may put into Health, with the one unit each",
      "takes; a metric written there shows up in the other tools once the phone has applied",
      "it and re-uploaded the day.",
    ],
  };
}

async function daily(given, reader) {
  const [from, to] = rangeOf(given, 90);
  if (daysBetween(from, to) > 400) {
    throw new Error(
      `${daysBetween(from, to)} days is too many for a daily table; ask for 400 or fewer, ` +
        "or use phone_data_statistics with group_by month or year",
    );
  }
  const metrics = namesOr(given.metrics, [...TOTALS]);
  const days = await reader.collect(from, to, (event) => event.bucket === "day");
  const rows = dailyTotals(days, metrics);
  return {
    units: unitsFor(days, metrics),
    columns: ["day", ...metrics],
    rows: rows.map((row) => [row.day, ...metrics.map((metric) => row.values[metric])]),
  };
}

async function statistics(given, reader) {
  const metric = pyStr(given.metric || "");
  if (!given.metric) throw new Error("metric is required");
  const [from, to] = rangeOf(given, 365);
  const grouping = given.group_by || "month";
  const isTotal = TOTALS.includes(metric);

  const days = await reader.collect(
    from,
    to,
    (event) => event.metric === metric && (isTotal ? event.bucket === "day" : !event.bucket),
  );

  const groups = new Map();
  let unit = null;
  for (const entry of days) {
    const label = groupOf(entry.day, grouping);
    if (!groups.has(label)) groups.set(label, []);
    const values = groups.get(label);
    for (const event of entry.events) {
      if (!isNumber(event.value)) continue;
      if (!unit && typeof event.unit === "string") unit = event.unit;
      values.push(event.value);
    }
  }

  const rows = [...groups.entries()]
    .filter(([, values]) => values.length)
    .map(([group, values]) => ({ group, ...(distribution(values) || emptyDistribution()) }))
    .sort((left, right) => byString(left.group, right.group));
  if (rows.length > MAX_ROWS) {
    throw new Error(
      `${rows.length} groups is more than an answer should carry; coarsen group_by or shorten the range`,
    );
  }

  const answer = { metric, unit };
  if (Object.hasOwn(UNIT_NOTES, metric)) answer.unitNote = UNIT_NOTES[metric];
  answer.over = isTotal ? "daily totals, one value per day" : "individual readings";
  answer.groupBy = grouping;
  answer.rows = rows;
  return answer;
}

async function sleep(given, reader) {
  const [from, to] = rangeOf(given, 90);
  // A night named by the last day of the range finishes on the day after it,
  // and the night before the first day reaches into it, so both ends widen.
  const days = await reader.collect(
    addDays(from, -1),
    addDays(to, 1),
    (event) => event.metric === "sleep",
  );
  const events = days.flatMap((entry) => entry.events);
  const rows = nights(events).filter((night) => from <= night.night && night.night <= to);
  if (rows.length > MAX_ROWS) throw new Error(`${rows.length} nights is too many; ask for less`);

  const hours = rows.map((night) => night.asleepHours).filter((value) => value > 0);
  return {
    nightsRecorded: rows.length,
    nightsInRange: daysBetween(from, to) + 1,
    asleepHours: distribution(hours),
    rows,
  };
}

async function workoutsTool(given, reader) {
  const [from, to] = rangeOf(given, 365);
  const days = await reader.collect(from, to, (event) => event.metric === "workout");
  const wanted = given.activity ? pyStr(given.activity) : null;
  const found = workouts(days).filter((workout) => !wanted || workout.activity === wanted);

  const byActivity = new Map();
  for (const workout of found) {
    if (!byActivity.has(workout.activity)) {
      byActivity.set(workout.activity, { count: 0, minutes: 0 });
    }
    const seen = byActivity.get(workout.activity);
    seen.count += 1;
    seen.minutes = round1(seen.minutes + workout.minutes);
  }
  const answer = {
    total: found.length,
    byActivity: Object.fromEntries(
      [...byActivity.entries()].sort((left, right) => right[1].count - left[1].count),
    ),
    ...table(found.slice(0, MAX_ROWS)),
  };
  if (found.length > MAX_ROWS) answer.note = `showing the first ${MAX_ROWS} of ${found.length}`;
  return answer;
}

/** `int()` the way the Python server read a limit: whole numbers, else nothing. */
function wholeNumber(value) {
  if (typeof value === "number" && Number.isFinite(value)) return Math.trunc(value);
  if (typeof value === "boolean") return value ? 1 : 0;
  if (typeof value === "string" && /^\s*[+-]?\d+\s*$/.test(value)) {
    return Number.parseInt(value, 10);
  }
  return null;
}

async function samples(given, reader) {
  const metric = pyStr(given.metric || "");
  if (!given.metric) throw new Error("metric is required");
  const [from, to] = rangeOf(given, 7);
  const asked = given.limit ? wholeNumber(given.limit) : 500;
  const limit = asked === null ? 500 : Math.min(asked || 500, 5000);

  const days = await reader.collect(from, to, (event) => event.metric === metric);
  const events = days
    .flatMap((entry) => entry.events)
    .sort((left, right) => byString(pyStr(left.start), pyStr(right.start)));

  const shown = events.slice(0, limit);
  const answer = { metric };
  if (Object.hasOwn(UNIT_NOTES, metric)) answer.unitNote = UNIT_NOTES[metric];
  answer.matched = events.length;
  answer.returned = shown.length;
  // The metric is named above and the identifier is derived from it and the
  // instant, both of which are in the table.
  return { ...answer, ...table(shown, ["id", "metric"]) };
}

async function writeTool(given, reader) {
  const items = given.items;
  if (!Array.isArray(items)) throw new Error("items must be a list");
  const [, archive] = reader.open();
  const answer = await archive.submitEdits(items);
  return {
    ...answer,
    items: items.length,
    note: "Stored sealed; the phone applies it the next time it is opened or wakes to " +
      "send. phone_data_edits reports what became of it, by this name.",
  };
}

async function editsTool(given, reader) {
  const status = given.status === "pending" ? "pending" : "all";
  const after = given.after ? pyStr(given.after) : null;
  if (after && !isEditName(after)) {
    throw new Error("after must be the name of an edit, as an earlier answer gave it");
  }
  const [, archive] = reader.open();
  const page = await archive.edits({ after, status });
  return { ...page, codes: [...OUTCOME_CODES] };
}

async function syncTool(_, reader) {
  const before = mirroredDays().length;
  await reader.refresh(true);
  const after = mirroredDays();
  return {
    copied: after.length - before,
    readable: after.length,
    firstDay: after.length ? after[0] : null,
    lastDay: after.length ? after.at(-1) : null,
  };
}

const SINCE = {
  type: "string",
  description: "First day, YYYY-MM-DD, inclusive. Defaults to 90 days before today.",
};
const UNTIL = {
  type: "string",
  description: "Last day, YYYY-MM-DD, inclusive. Defaults to today.",
};

const QUANTITIES = Object.entries(writableShapes())
  .filter(([, shape]) => shape.kind === "quantity")
  .map(([name, shape]) => `${name} in ${shape.unit}`)
  .join(", ");

// The descriptions carry what a reader has to know, because that is the point:
// no prompt is written anywhere else, so what the agent needs arrives with the
// tool. They are a public contract, held by `tests/node/tools.json`.
export const TOOLS = [
  {
    name: "phone_data_overview",
    title: "What the archive holds",
    description: [
      "Start here. Reports what this Health archive contains before anything is asked of it:",
      "the range of days, how many there are, and for every metric its kind, unit, first and",
      "last day, and how many days carry it.",
      "",
      "The first day of a metric is the day the device that measures it arrived, so a question",
      "about heart rate before that day is not a gap in the data — nothing was measuring.",
      "Takes no arguments.",
    ].join("\n"),
    inputSchema: { type: "object", properties: {} },
    run: overview,
  },
  {
    name: "phone_data_daily",
    title: "Daily totals",
    description: [
      "One row per day with the day's totals: steps, distance, flights, active and basal",
      "energy, exercise and stand minutes, and — once something has written them — dietary",
      "energy, protein, carbohydrates, fat and water. This is the table to answer 'how active",
      "was I' and 'what did I eat'.",
      "",
      "Reads the daily buckets only, so it can never double-count against the hourly ones.",
      "A null means the day carries no total for that metric, which is not the same as a zero.",
      "Refuses ranges over 400 days — use phone_data_statistics for anything longer.",
    ].join("\n"),
    inputSchema: {
      type: "object",
      properties: {
        metrics: {
          type: "array",
          items: { type: "string", enum: [...TOTALS] },
          description: `Which totals to include. Defaults to all of: ${TOTALS.join(", ")}.`,
        },
        since: SINCE,
        until: UNTIL,
      },
    },
    run: daily,
  },
  {
    name: "phone_data_statistics",
    title: "Distribution of a metric over time",
    description: [
      "How one metric is distributed, grouped by day, week, month or year: count, min, p10,",
      "median, mean, p90, max and sum per group. This is the tool for trends and for any",
      "question spanning years — it never returns the underlying readings.",
      "",
      "For a total, the numbers are over that metric's daily totals, one per day.",
      "For a record (heart rate, HRV, respiratory rate, blood oxygen), they are over the",
      "individual readings, of which there can be hundreds in a day.",
      "Blood oxygen arrives as a fraction: 0.97 means 97%.",
    ].join("\n"),
    inputSchema: {
      type: "object",
      required: ["metric"],
      properties: {
        metric: {
          type: "string",
          enum: [
            ...TOTALS,
            ...RECORDS.filter((metric) => metric !== "sleep" && metric !== "workout"),
          ],
          description: "The metric to describe. Sleep and workouts have their own tools.",
        },
        since: SINCE,
        until: UNTIL,
        group_by: {
          type: "string",
          enum: ["day", "week", "month", "year"],
          description: "How to group the days. Defaults to month.",
        },
      },
    },
    run: statistics,
  },
  {
    name: "phone_data_sleep",
    title: "Nights of sleep",
    description: [
      "One row per night: hours asleep, hours in bed, the breakdown by stage, and when it",
      "started and ended.",
      "",
      "Two things are decided here that a reader of the raw events would get wrong. Overlapping",
      "stretches are merged rather than added, because more than one source can describe the",
      "same minutes and adding them invents hours of sleep. A night runs noon to noon and is",
      "named by the evening it began in, so a night is one row rather than two halves.",
      "A missing night means nothing was recorded — the watch was off, not that nobody slept.",
    ].join("\n"),
    inputSchema: { type: "object", properties: { since: SINCE, until: UNTIL } },
    run: sleep,
  },
  {
    name: "phone_data_workouts",
    title: "Recorded workouts",
    description: [
      "Every workout in a range — activity, when it started, how long it lasted — plus a count",
      "and total minutes per activity.",
      "",
      "The workouts come as a table: `columns` names what each row holds, in order, and",
      "`sameOnEveryRow` holds the fields every workout agrees on, said once. The counts in",
      "`byActivity` are over every workout found, not only the rows shown.",
      "",
      "The phone sends Apple's activity number and this translates it, so an activity comes",
      "back as 'walking' rather than as 52. A workout is what was deliberately recorded; it is",
      "not the same as the day's movement, which lives in phone_data_daily.",
    ].join("\n"),
    inputSchema: {
      type: "object",
      properties: {
        since: SINCE,
        until: UNTIL,
        activity: {
          type: "string",
          description: "Keep only this activity, e.g. walking, cycling, swimming.",
        },
      },
    },
    run: workoutsTool,
  },
  {
    name: "phone_data_samples",
    title: "Raw readings",
    description: [
      "The individual readings for one metric. The escape hatch for questions the other tools",
      "do not shape — the time of day something happened, what a single reading was, which",
      "device recorded it.",
      "",
      "As a table: `columns` names what each row holds, in order, and `sameOnEveryRow` holds",
      "the fields every reading agrees on, said once instead of on every row. A null in a",
      "column means that reading carried nothing there, which is not the same as a zero.",
      "",
      "The identifier is not carried. It was only ever derived from the metric and the instant",
      "a reading began, and both are here. Two readings can begin in the same second — one",
      "heartbeat seen by two watches, two sleep stages starting together — and then they are",
      "two rows that may differ in nothing at all. That is the data, not a duplicate to remove.",
      "",
      "Capped, and deliberately so: a decade of heart rate is eight hundred thousand readings.",
      "For anything about a trend or an average, phone_data_statistics is both cheaper and harder",
      "to misread.",
    ].join("\n"),
    inputSchema: {
      type: "object",
      required: ["metric"],
      properties: {
        metric: { type: "string", description: "Which metric's readings to return." },
        since: SINCE,
        until: UNTIL,
        limit: {
          type: "integer",
          description: "How many readings at most. Defaults to 500, maximum 5000.",
        },
      },
    },
    run: samples,
  },
  {
    name: "phone_data_write",
    title: "Write into Health",
    description: [
      "Put entries into Apple Health through the phone: meals as dietary energy, protein,",
      "carbohydrates, fat and water; sleep by stage; body mass. The edit is sealed to the",
      "phone's key and signed here, the service stores it unopened, and the phone applies it",
      "the next time it is opened or wakes to send — minutes to hours, never at once.",
      "phone_data_edits says when it has, and the days it touched are re-uploaded so the",
      "other tools show the result.",
      "",
      "Each item is a `put` or a `delete`. The `id` is your handle for one entry: a second",
      "`put` under the same id replaces the entry, a `delete` removes it, so pick ids you can",
      "rebuild — `agent:meal:2026-09-07:lunch` — and reuse them for a correction. Only entries",
      "written this way can be replaced or removed; what the watch, the phone or another app",
      "recorded is Health's and stays as it is.",
      "",
      "`start` and `end` are whole seconds since 1970 and both must be in the past — Health",
      "refuses an entry that ends in the future. A quantity needs `value` and the metric's",
      `exact unit (${QUANTITIES}); sleep needs \`stage\` and no value.`,
      "A meal is a short interval; a night of sleep is one item per stage, or one",
      "asleepUnspecified stretch when the stages are not known. Anything wrong with an item",
      "is refused here, before anything is sealed, with the field named.",
    ].join("\n"),
    inputSchema: {
      type: "object",
      required: ["items"],
      properties: {
        items: {
          type: "array",
          minItems: 1,
          maxItems: MAX_ITEMS_PER_EDIT,
          description: `The entries to write, up to ${MAX_ITEMS_PER_EDIT} in one edit.`,
          items: {
            type: "object",
            required: ["op", "id"],
            properties: {
              op: {
                type: "string",
                enum: ["put", "delete"],
                description: "put adds or replaces the entry under this id; delete removes it.",
              },
              id: {
                type: "string",
                description:
                  "Your handle for the entry: 1 to 120 characters of letters, digits, . _ : -",
              },
              metric: {
                type: "string",
                enum: Object.keys(WRITABLE),
                description: "What the entry is. put only.",
              },
              start: { type: "integer", description: "Whole seconds since 1970. put only." },
              end: {
                type: "integer",
                description: "Whole seconds since 1970, not before start, in the past. put only.",
              },
              value: {
                type: "number",
                description: "For a quantity: the amount, zero or more, in the metric's unit.",
              },
              unit: {
                type: "string",
                description: "For a quantity: the metric's own unit, exactly.",
              },
              stage: {
                type: "string",
                enum: [...SLEEP_STAGES],
                description: "For sleep: which stage this stretch was.",
              },
            },
          },
        },
      },
    },
    run: writeTool,
  },
  {
    name: "phone_data_edits",
    title: "What became of the edits",
    description: [
      "The edits sent to the phone and what it did with each: `pending` until the phone has",
      "looked, then `applied`; `failed` if the phone could not do it, and `partial` when some",
      "of it landed. `awaiting` and `declined` come from a phone that used to ask before",
      "changing anything; no phone does now, and those only appear on old edits.",
      "For anything refused, the",
      "phone's word for why is listed per item — badRange for an end in the future, badUnit",
      "for a unit the metric does not take, unauthorized when Health access to that type was",
      "declined on the phone, notFound for a delete of an id never written, healthRefused when",
      "Health itself said no, replayed when the phone had already answered that very edit and",
      "wrote nothing the second time. Edits this machine submitted also show the ids they carried.",
      "",
      "Every item lands, including one that changes or removes a record already in Health —",
      "which can only ever be a record this app itself wrote for you. The phone keeps what",
      "each change pushed out and shows its owner what you did, so anything unwanted is put",
      "back by them, not prevented beforehand. An outcome is told once and never revised.",
      "",
      "An edit stays pending until the phone is opened or wakes to send, which can be hours.",
      "Newest last; follow `next` for more.",
    ].join("\n"),
    inputSchema: {
      type: "object",
      properties: {
        status: {
          type: "string",
          enum: ["pending", "all"],
          description: "pending lists only what the phone has not applied yet. Defaults to all.",
        },
        after: {
          type: "string",
          description: "Continue after this edit name, as the previous answer's `next` gave it.",
        },
      },
    },
    run: editsTool,
  },
  {
    name: "phone_data_sync",
    title: "Copy the archive down",
    description: [
      "Bring the local copy of the archive up to date. The other tools refresh what they need",
      "on their own, so this is only worth calling to make the whole history readable at once —",
      "phone_data_overview says when that is not already true.",
      "",
      "Safe to interrupt and safe to repeat: a day is either the version the archive holds or",
      "an older one, and this replaces the older ones.",
    ].join("\n"),
    inputSchema: { type: "object", properties: {} },
    run: syncTool,
  },
];

/**
 * One tool call, answered as the MCP server answers it: the warning first when
 * the mirror may be behind, then the answer. Shared by the server and the
 * command line, so the two can never say different things.
 */
export async function callTool(name, given, reader) {
  const tool = TOOLS.find((candidate) => candidate.name === name);
  if (!tool) throw new Error(`no such tool: ${name}`);
  const answer = await tool.run(isPlainObject(given) ? given : {}, reader);
  return reader.warning ? { warning: reader.warning, ...answer } : answer;
}

// MARK: - The MCP server: JSON-RPC 2.0 over stdio

// Spoken directly rather than through a library — it is a few dozen lines, and
// it keeps the reading side free of dependencies that would have to be trusted
// with this of all data.

const NAME = "efferent";
/** Newest first. A client asking for one of these gets it; anything else gets the newest. */
const PROTOCOL_VERSIONS = ["2025-06-18", "2025-03-26", "2024-11-05"];
export const INSTRUCTIONS = [
  "This is one person's Apple Health history, day by day, from an end-to-end encrypted",
  "archive. Call phone_data_overview first: it says what the data covers, when each metric",
  "starts, and the few ways this data misleads a reader who treats it as a plain table.",
  "phone_data_write puts meals, sleep and weight into Health through the phone.",
].join(" ");

function result(id, value) {
  return { jsonrpc: "2.0", id, result: value };
}

function text(body, isError = false) {
  const answer = { content: [{ type: "text", text: body }] };
  if (isError) answer.isError = true;
  return answer;
}

/** One request, answered; `null` for a notification, which takes no answer. */
export async function handle(request, reader) {
  const id = request.id ?? null;
  const notification = request.id === null || request.id === undefined;
  const method = request.method;
  const params = isPlainObject(request.params) ? request.params : {};

  if (method === "initialize") {
    const asked = String(params.protocolVersion || "");
    return result(id, {
      protocolVersion: PROTOCOL_VERSIONS.includes(asked) ? asked : PROTOCOL_VERSIONS[0],
      capabilities: { tools: {} },
      serverInfo: { name: NAME, version: VERSION },
      instructions: INSTRUCTIONS,
    });
  }
  if (method === "ping") return result(id, {});
  if (method === "tools/list") {
    return result(id, {
      tools: TOOLS.map(({ name, title, description, inputSchema }) => ({
        name,
        title,
        description,
        inputSchema,
      })),
    });
  }
  if (method === "tools/call") {
    const name = String(params.name || "");
    if (!TOOLS.some((tool) => tool.name === name)) {
      return result(id, text(`no such tool: ${name}`, true));
    }
    try {
      // Without indentation: nothing reads this but a model, which pays for
      // every character and is no better at reading the laid-out form.
      return result(id, text(JSON.stringify(await callTool(name, params.arguments, reader))));
    } catch (error) {
      // A failed call rather than a broken connection: the agent can read it,
      // correct the arguments and try again.
      return result(id, text(error.message, true));
    }
  }
  if (notification) return null;
  return { jsonrpc: "2.0", id, error: { code: -32601, message: `unknown method: ${method}` } };
}

/** Requests one at a time, in order, until stdin closes. */
export async function serve(input = process.stdin, output = process.stdout) {
  const reader = new Reader();
  for await (const raw of createInterface({ input, crlfDelay: Infinity })) {
    const line = raw.trim();
    if (!line) continue;
    let answer;
    try {
      const request = JSON.parse(line);
      if (!isPlainObject(request)) throw new Error("a request is a JSON object");
      answer = await handle(request, reader);
    } catch (error) {
      answer = {
        jsonrpc: "2.0",
        id: null,
        error: { code: -32700, message: `could not read that: ${error.message}` },
      };
    }
    if (answer !== null) output.write(`${JSON.stringify(answer)}\n`);
  }
}

// MARK: - The command line

const USAGE = `usage: node efferent.mjs <command> [options]

  self-test                         check HPKE against RFC 9180 A.2.1
  connect --handoff <file|->        import the phone's handoff into EFFERENT_HOME
  mcp                               run as a local MCP server over stdio

  overview                          what the archive holds; start here
  daily     [--since D] [--until D] [--metrics a,b]
  statistics --metric M [--since D] [--until D] [--group-by day|week|month|year]
  sleep     [--since D] [--until D]
  workouts  [--since D] [--until D] [--activity A]
  samples   --metric M [--since D] [--until D] [--limit N]
  write     --items <file.json>     put entries into Health through the phone
  edits     [--status pending|all] [--after NAME]
  tools     [name]                  every tool's description and arguments, or one tool's
  call <tool> [json]                any MCP tool by name, with its arguments as JSON

  sync      [--since D] [--until D] copy every day that changed down to this machine
  status                            what the archive holds, and what the mirror does
  query     [filters]               raw events from the mirror, offline
  ask       [filters]               raw events from the archive, fetching only those days
  read      [filters]               every event the archive holds in the range

filters: --metric <name> --bucket <hour|day> --since D --until D --limit N --format ndjson|summary
Every answer is JSON in the same shape the MCP tools return. Days are YYYY-MM-DD, both ends included.
The profile lives in EFFERENT_HOME (default ./.efferent): keys, mirror and record, readable only by you.`;

/** Something a person can act on, printed as one line. */
class Failure extends Error {}

/**
 * `--name value` pairs, and a bare `--name` at the end or before another option
 * is a flag; anything else is positional.
 */
function parseOptions(args) {
  const options = {};
  const positional = [];
  for (let index = 0; index < args.length; index++) {
    const argument = args[index];
    if (!argument.startsWith("--")) {
      positional.push(argument);
      continue;
    }
    const following = args[index + 1];
    if (following === undefined || following.startsWith("--")) {
      options[argument.slice(2)] = "true";
      continue;
    }
    options[argument.slice(2)] = following;
    index += 1;
  }
  return { options, positional };
}

function require_(options, name) {
  if (!options[name]) throw new Failure(`--${name} is required`);
  return options[name];
}

function readInput(path) {
  return path === "-" ? readFileSync(0, "utf8") : readFileSync(path, "utf8");
}

function say(line = "") {
  process.stdout.write(`${line}\n`);
}

/** The handoff, checked, as the files the reader keeps. */
export function parseConnectionHandoff(text) {
  const instruction = field(text, "Instruction");
  if (
    !instruction.includes("setup_guide") ||
    !/Keep the reading key( and the editor key)? local/.test(instruction)
  ) {
    throw new ArchiveError("the instruction must call setup_guide and keep the reading key local");
  }
  const mcp = field(text, "MCP");
  let parts;
  try {
    parts = new URL(mcp);
  } catch {
    throw new ArchiveError("MCP must use HTTP or HTTPS");
  }
  if (!["http:", "https:"].includes(parts.protocol)) {
    throw new ArchiveError("MCP must use HTTP or HTTPS");
  }
  if (parts.search || parts.hash || !parts.pathname.includes("/mcp/b/")) {
    throw new ArchiveError("MCP must end in /mcp/b/<bucket-id>, without a query or fragment");
  }
  const { endpoint, bucket, privateRaw, editorRaw } = connection(text);
  const made = {
    mcpURL: mcp,
    endpoint,
    bucket,
    reading: {
      readingPrivate: pkcs8("x25519", privateRaw),
      readingPublic: toBase64url(publicOf("x25519", privateRaw)),
    },
  };
  if (editorRaw !== null) {
    made.editor = {
      editorPrivate: pkcs8("ed25519", editorRaw),
      editorPublic: toBase64url(publicOf("ed25519", editorRaw)),
    };
  }
  return made;
}

function exists(name) {
  try {
    statSync(join(home(), name));
    return true;
  } catch {
    return false;
  }
}

/**
 * Move a validated handoff into the reader's private files. A reader that
 * already exists is not overwritten — except that a fresh handoff for the
 * *same* archive, from a phone that has since learnt to write, adds the editor
 * key to a reader that has none and touches nothing else.
 */
export function installConnectionHandoff(text) {
  const made = parseConnectionHandoff(text);
  let sameReader = false;
  try {
    sameReader = load(READING).readingPublic === made.reading.readingPublic;
  } catch {
    sameReader = false;
  }
  if (made.editor && sameReader && !exists(EDITOR)) {
    write(EDITOR, made.editor);
    return made;
  }
  for (const name of [READING, STATE, EDITOR]) {
    if (exists(name)) {
      throw new ArchiveError(
        `${
          join(home(), name)
        } already exists — use a different EFFERENT_HOME; refusing to overwrite it`,
      );
    }
  }
  write(READING, made.reading);
  write(STATE, { endpoint: made.endpoint, days: {}, syncedAt: "" });
  if (made.editor) write(EDITOR, made.editor);
  return made;
}

function connect(path) {
  const made = installConnectionHandoff(readInput(path));
  say(`connected: ${made.bucket}`);
  say(`saved:     ${join(home(), READING)}`);
  if (made.editor) say(`saved:     ${join(home(), EDITOR)}`);
  say(`archive:   ${made.endpoint}`);
  say("the reading key stayed on this machine");
  if (!made.editor) {
    say(
      "this handoff predates writing: the agent can read the archive and cannot write " +
        "into Health — a fresh handoff from the phone adds the editor key",
    );
  }
}

/**
 * Both bounds are days and are inclusive; the archive is cut into days, so an
 * hour is something to filter afterwards rather than to ask for.
 */
function filterFrom(options) {
  const day = (value, option) => {
    const text = value.slice(0, 10);
    if (!isDay(text)) throw new Failure(`${option} must be a day, YYYY-MM-DD, got ${value}`);
    return text;
  };
  return {
    metric: options.metric || null,
    bucket: options.bucket || null,
    since: options.since ? day(options.since, "--since") : null,
    until: options.until ? day(options.until, "--until") : null,
  };
}

/**
 * The days a question covers: one day earlier than asked, always, because a
 * night that began before midnight is in the evening's day.
 */
function bounds(wanted) {
  return [wanted.since ? dayBefore(wanted.since) : null, wanted.until];
}

/**
 * Whether an event belongs in the answer, by overlap rather than by its start:
 * an interval that began the evening before still happened on the day asked
 * about. Compared day against day, never instant against date.
 */
function matches(event, wanted) {
  if (wanted.metric && event.metric !== wanted.metric) return false;
  if (wanted.bucket && event.bucket !== wanted.bucket) return false;
  const start = String(event.start || "").slice(0, 10);
  if (wanted.since && String(event.end || event.start || "").slice(0, 10) < wanted.since) {
    return false;
  }
  if (wanted.until && start > wanted.until) return false;
  return true;
}

function report(events, options) {
  const ordered = [...events].sort((left, right) =>
    byString(left.start || "", right.start || "") || byString(left.id || "", right.id || "")
  );
  if (options.format === "summary") {
    const counts = new Map();
    for (const event of ordered) {
      const key = `${event.metric || "?"}${event.bucket ? `/${event.bucket}` : ""}`;
      counts.set(key, (counts.get(key) ?? 0) + 1);
    }
    say(`${ordered.length} events`);
    for (const [key, count] of [...counts.entries()].sort((left, right) => right[1] - left[1])) {
      say(`  ${String(count).padStart(7)}  ${key}`);
    }
    return;
  }
  const limited = options.limit ? ordered.slice(0, Number.parseInt(options.limit, 10)) : ordered;
  if (limited.length) say(limited.map((event) => JSON.stringify(event)).join("\n"));
}

async function sync(options) {
  const state = loadState(options.url);
  const archive = new Archive(state.endpoint);
  const listing = await archive.list(...bounds(filterFrom(options)));
  const stale = new Map();
  for (const entry of listing) {
    if (state.days[entry.day] !== entry.uploaded) stale.set(entry.day, entry.uploaded);
  }
  if (!stale.size) {
    say(`already up to date: ${Object.keys(state.days).length} days mirrored`);
    return;
  }
  let taken = 0;
  for await (const fetched of archive.several([...stale.keys()].sort())) {
    writeDay(fetched.day, fetched.events);
    state.days[fetched.day] = stale.get(fetched.day);
    taken += 1;
    // Every eight, one window of fetches: an interrupted sync loses almost
    // nothing, and a long one is not mostly writing a file about itself.
    if (taken % 8 === 0) saveState(state);
  }
  saveState(state);
  say(`${taken} day${taken === 1 ? "" : "s"} copied, ${Object.keys(state.days).length} mirrored`);
}

async function status(options) {
  const state = loadState(options.url);
  const archive = new Archive(state.endpoint);
  const remote = await archive.stats();
  const mirrored = Object.keys(state.days).sort();
  say(`bucket   ${archive.bucket}`);
  const span = remote.firstDay ? `, ${remote.firstDay} … ${remote.lastDay}` : "";
  const more = remote.complete ? "" : "+";
  say(`archive  ${remote.days}${more} days, ${(remote.bytes / 1024 / 1024).toFixed(1)} MiB${span}`);
  if (!mirrored.length) {
    say("mirror   nothing yet — run sync");
    return;
  }
  const gap = remote.days - mirrored.length;
  const tail = gap > 0 ? `  — ${gap} behind, run sync` : "  — up to date";
  say(`mirror   ${mirrored.length} days, ${mirrored[0]} … ${mirrored.at(-1)}${tail}`);
}

function query_(options) {
  const wanted = filterFrom(options);
  const events = [];
  for (const day of mirroredDays(...bounds(wanted))) {
    events.push(...readDay(day).filter((event) => matches(event, wanted)));
  }
  report(events, options);
}

/**
 * Answer from the archive without a mirror: a question about one August costs
 * that August, and the filtering still happens here, after decryption.
 */
async function ask(options) {
  const state = loadState(options.url);
  const archive = new Archive(state.endpoint);
  const wanted = filterFrom(options);
  const listing = await archive.list(...bounds(wanted));
  const collected = [];
  for await (const fetched of archive.several(listing.map((entry) => entry.day))) {
    collected.push(...fetched.events.filter((event) => matches(event, wanted)));
  }
  process.stderr.write(`${listing.length} days fetched, ${collected.length} events kept\n`);
  report(collected, options);
}

async function readAll(options) {
  const state = loadState(options.url);
  const archive = new Archive(state.endpoint);
  const listing = await archive.list(...bounds(filterFrom(options)));
  for await (const fetched of archive.several(listing.map((entry) => entry.day))) {
    if (fetched.events.length) say(fetched.events.map((event) => JSON.stringify(event)).join("\n"));
  }
}

/** The arguments of a tool, from the options that name them on the command line. */
function toolArguments(options, names) {
  const given = {};
  for (const [option, name] of names) {
    if (options[option] === undefined) continue;
    given[name] = name === "metrics"
      ? options[option].split(",").map((part) => part.trim())
      : options[option];
  }
  return given;
}

const RANGE = [["since", "since"], ["until", "until"]];
const TOOL_COMMANDS = {
  overview: ["phone_data_overview", []],
  daily: ["phone_data_daily", [...RANGE, ["metrics", "metrics"]]],
  statistics: ["phone_data_statistics", [...RANGE, ["metric", "metric"], ["group-by", "group_by"]]],
  sleep: ["phone_data_sleep", RANGE],
  workouts: ["phone_data_workouts", [...RANGE, ["activity", "activity"]]],
  samples: ["phone_data_samples", [...RANGE, ["metric", "metric"], ["limit", "limit"]]],
  edits: ["phone_data_edits", [["status", "status"], ["after", "after"]]],
};

async function answerTool(name, given) {
  say(JSON.stringify(await callTool(name, given, new Reader())));
}

/** One command, run; throwing inside it becomes a rejection, which `isMain` turns into a line. */
export async function main(argv = process.argv.slice(2)) {
  return await dispatch(argv);
}

const FILTERS = ["metric", "bucket", "since", "until", "limit", "format"];

/**
 * The options each command reads. Anything else is refused: an option nobody
 * reads would answer a different question — `--metirc` would answer for every
 * metric — and nothing in the answer would say so.
 */
const ACCEPTS = {
  "self-test": [],
  mcp: [],
  connect: ["handoff"],
  status: ["url"],
  query: FILTERS,
  ask: [...FILTERS, "url"],
  read: ["since", "until", "url"],
  sync: ["since", "until", "url"],
  write: ["items"],
  tools: [],
  call: [],
};

function refuseUnknown(command, options) {
  const accepted = Object.hasOwn(TOOL_COMMANDS, command)
    ? TOOL_COMMANDS[command][1].map(([option]) => option)
    : ACCEPTS[command];
  if (!accepted) return;
  const unknown = Object.keys(options).filter((option) => !accepted.includes(option));
  if (unknown.length) {
    const known = accepted.length ? accepted.map((option) => `--${option}`).join(", ") : "none";
    throw new Failure(`unknown option --${unknown[0]} for ${command}; it takes ${known}`);
  }
}

function dispatch(argv) {
  const [command, ...rest] = argv;
  const { options, positional } = parseOptions(rest);
  refuseUnknown(command, options);
  if (command === "self-test") return say(selfTest());
  if (command === "mcp") return serve();
  if (command === "connect") return connect(require_(options, "handoff"));
  if (command === "status") return status(options);
  if (command === "query") return query_(options);
  if (command === "ask") return ask(options);
  if (command === "read") return readAll(options);
  if (command === "sync") return sync(options);
  if (command === "write") {
    const loaded = JSON.parse(readInput(require_(options, "items")));
    return answerTool("phone_data_write", { items: isPlainObject(loaded) ? loaded.items : loaded });
  }
  if (command === "tools") {
    const [name] = positional;
    const listed = TOOLS.filter((tool) => !name || tool.name === name);
    if (!listed.length) throw new Failure(`no such tool: ${name}`);
    return say(JSON.stringify(
      listed.map(({ name, description, inputSchema }) => ({ name, description, inputSchema })),
      null,
      2,
    ));
  }
  if (command === "call") {
    const [name, json] = positional;
    if (!name) throw new Failure("call takes a tool name, and its arguments as JSON");
    return answerTool(name, json ? JSON.parse(json) : {});
  }
  if (Object.hasOwn(TOOL_COMMANDS, command)) {
    const [name, names] = TOOL_COMMANDS[command];
    return answerTool(name, toolArguments(options, names));
  }
  process.stderr.write(`${USAGE}\n`);
  process.exitCode = 2;
}

/** Whether this file is the program being run, rather than a module imported by one. */
function isMain() {
  if (!process.argv[1]) return false;
  try {
    return import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href;
  } catch {
    return false;
  }
}

if (isMain()) {
  // The reading layer throws where a command line exits, and a stack trace is
  // not an error message: one place turns it back into a line to act on.
  main().catch((error) => {
    process.stderr.write(`error: ${error.message}\n`);
    process.exitCode = 2;
  });
}
