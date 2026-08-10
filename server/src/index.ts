/**
 * The bucket service: an append-only archive that cannot read what it holds.
 *
 * It does three things — check that a writer is the one who claimed the bucket,
 * keep blobs in sequence order, and hand them back. It never sees a key that
 * decrypts anything, so there is deliberately no code here that could.
 *
 * There are no accounts and no registration. A bucket comes into existence on
 * its first write, and its name already proves who it belongs to.
 *
 * It is an archive rather than a letterbox: nothing here deletes, expires or
 * overwrites, so a reader can come back months later and walk the whole history
 * from the beginning. Two properties carry that promise, and both are easy to
 * lose by accident — a write never replaces an object that already exists, and
 * a listing skips in the store rather than filtering a page after the fact.
 */

import {
  DATA_PREFIX,
  isBucketId,
  listingStartAfter,
  objectKey,
  objectName,
  parseObjectName,
  signingKeyObject,
} from "../../protocol/ids.ts";
import {
  fromBase64url,
  TIMESTAMP_TOLERANCE_SECONDS,
  type UploadHeader,
  verifyUpload,
} from "../../protocol/signing.ts";
import { type ManifestEntry, readManifest, unframe } from "../../protocol/manifest.ts";

/** Room for a large batch; well under what a Worker can hold in memory. */
const MAX_BODY_BYTES = 4 * 1024 * 1024;
const MAX_OBJECTS_PER_PAGE = 200;
/** How many batches one `find` will name. A question whose answer is more than
 * this is a question better asked in narrower slices. */
const MAX_FIND_OBJECTS = 500;
/** How far `stats` will walk before it answers "at least this much". Bounded so
 * that asking what is in an archive never costs more than a moment. */
const STATS_PAGE_LIMIT = 20;

/** Only the parts of R2 this service uses. Spelled out rather than pulled from
 * a types package, so the whole repository stays checkable without one. */
interface R2Object {
  key: string;
  size: number;
}
interface R2ObjectBody extends R2Object {
  arrayBuffer(): Promise<ArrayBuffer>;
}
interface R2Bucket {
  get(key: string): Promise<R2ObjectBody | null>;
  head(key: string): Promise<R2Object | null>;
  put(key: string, value: ArrayBuffer | Uint8Array): Promise<unknown>;
  list(
    options: { prefix?: string; startAfter?: string; limit?: number },
  ): Promise<{ objects: R2Object[]; truncated: boolean }>;
}

/** Likewise for D1: only what the index needs. */
interface D1PreparedStatement {
  bind(...values: unknown[]): D1PreparedStatement;
  all<T>(): Promise<{ results: T[] }>;
  run(): Promise<unknown>;
}
interface D1Database {
  prepare(sql: string): D1PreparedStatement;
}

export interface Env {
  BLOBS: R2Bucket;
  /** When each event happened and what kind it is — never a value. See
   * `protocol/manifest.ts` for what that buys and what it costs. */
  INDEX: D1Database;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const segments = url.pathname.split("/").filter(Boolean);

    if (segments.length === 1 && segments[0] === "health") {
      return json({ ok: true });
    }
    if (segments[0] !== "b" || !segments[1]) {
      return problem(404, "unknown path");
    }

    const bucket = segments[1];
    if (!isBucketId(bucket)) return problem(400, "malformed bucket id");

    if (request.method === "POST" && segments.length === 2) {
      return await append(request, env, bucket);
    }
    if (request.method === "GET" && segments.length === 3 && segments[2] === "objects") {
      return await listObjects(env, bucket, url);
    }
    if (request.method === "GET" && segments.length === 3 && segments[2] === "stats") {
      return await describe(env, bucket);
    }
    if (request.method === "GET" && segments.length === 3 && segments[2] === "find") {
      return await find(env, bucket, url);
    }
    if (request.method === "GET" && segments.length === 4 && segments[2] === "o") {
      return await fetchObject(env, bucket, segments[3]);
    }
    return problem(405, `${request.method} is not allowed here`);
  },
};

async function append(request: Request, env: Env, bucket: string): Promise<Response> {
  const header = readHeader(request, bucket);
  if (typeof header === "string") return problem(400, header);

  const signature = request.headers.get("x-efferent-signature");
  const writerKey = request.headers.get("x-efferent-writer");
  if (!signature || !writerKey) return problem(400, "missing writer key or signature");

  const drift = Math.abs(Math.floor(Date.now() / 1000) - header.timestamp);
  if (drift > TIMESTAMP_TOLERANCE_SECONDS) {
    return problem(400, `timestamp is ${drift}s away from this server's clock`);
  }

  const body = new Uint8Array(await request.arrayBuffer());
  if (body.length === 0) return problem(400, "empty body");
  if (body.length > MAX_BODY_BYTES) return problem(413, "batch is larger than 4 MiB");

  const claimed = fromBase64url(writerKey);
  const registered = await env.BLOBS.get(signingKeyObject(bucket));
  if (registered) {
    const known = new Uint8Array(await registered.arrayBuffer());
    if (!sameBytes(known, claimed)) {
      return problem(403, "this bucket already belongs to another writer");
    }
  }

  if (!await verifyUpload(claimed, fromBase64url(signature), header, body)) {
    return problem(403, "signature does not match the request");
  }

  // Registered only after the signature checked out, so a stranger cannot claim
  // an unused bucket by presenting a key they do not hold.
  if (!registered) await env.BLOBS.put(signingKeyObject(bucket), claimed);

  // Split before storing, so a malformed body is refused rather than archived.
  // The whole body goes to R2 all the same: it is what was signed, and the
  // reader checks the signature against exactly these bytes.
  let manifest: ManifestEntry[] = [];
  try {
    const parts = unframe(body);
    if (parts.manifest) manifest = await readManifest(parts.manifest);
  } catch (cause) {
    return problem(400, `body is not a batch this service understands: ${cause}`);
  }

  // Never replace what is already stored. A device that did not hear the answer
  // sends the same range again, and it must be acknowledged rather than allowed
  // to rewrite history — an archive whose past can change is not an archive.
  const key = objectKey(bucket, header.seqFrom, header.seqTo);
  if (!await env.BLOBS.head(key)) await env.BLOBS.put(key, body);
  // After the object, and ignoring rows that are already there: the index is a
  // pointer into the archive, so it must never claim something the archive does
  // not hold.
  if (manifest.length > 0) {
    await indexBatch(env, bucket, header.seqFrom, header.seqTo, manifest);
  }
  return json({ ack: header.seqTo });
}

/**
 * Write one batch's manifest into the index.
 *
 * One statement for the whole batch rather than a row at a time: SQLite unrolls
 * the list itself with `json_each`, which keeps this to four bound values no
 * matter how many events a batch carries. A loop here would be five hundred
 * round trips inside a request that has to finish quickly.
 */
async function indexBatch(
  env: Env,
  bucket: string,
  seqFrom: number,
  seqTo: number,
  manifest: ManifestEntry[],
): Promise<void> {
  await env.INDEX.prepare(
    `INSERT OR IGNORE INTO events (bucket, seq, type, metric, start, end, seq_from, seq_to)
     SELECT ?1,
            entry.value ->> 'seq',
            entry.value ->> 'type',
            entry.value ->> 'metric',
            entry.value ->> 'start',
            entry.value ->> 'end',
            ?2, ?3
     FROM json_each(?4) AS entry`,
  ).bind(bucket, seqFrom, seqTo, JSON.stringify(manifest)).run();
}

/**
 * Which batches hold the events someone is asking about.
 *
 * The answer is a list of objects to fetch, not data — the service still cannot
 * read a single reading. What it saves is the download: a question about one
 * August comes back as a handful of batches instead of a decade of them.
 *
 * An event counts as inside the window when its interval overlaps it, so a
 * night of sleep that began before midnight on the first is found by a query
 * that starts at midnight. Filtering on the start alone would silently drop it.
 */
async function find(env: Env, bucket: string, url: URL): Promise<Response> {
  const from = instant(url.searchParams.get("from"));
  const to = instant(url.searchParams.get("to"));
  if (from === undefined) return problem(400, "from must be a time");
  if (to === undefined) return problem(400, "to must be a time");

  const metric = url.searchParams.get("metric");
  const type = url.searchParams.get("type");
  const asked = Number(url.searchParams.get("limit") ?? MAX_OBJECTS_PER_PAGE);
  if (!Number.isSafeInteger(asked) || asked < 1) return problem(400, "limit must be a count");
  const limit = Math.min(asked, MAX_FIND_OBJECTS);

  const { results } = await env.INDEX.prepare(
    `SELECT seq_from, seq_to, COUNT(*) AS count
     FROM events
     WHERE bucket = ?1
       AND (?2 IS NULL OR start < ?2)
       AND (?3 IS NULL OR COALESCE(end, start) >= ?3)
       AND (?4 IS NULL OR metric = ?4)
       AND (?5 IS NULL OR type = ?5)
     GROUP BY seq_from, seq_to
     ORDER BY seq_from
     LIMIT ?6`,
  ).bind(bucket, to, from, metric, type, limit + 1).all<
    { seq_from: number; seq_to: number; count: number }
  >();

  const truncated = results.length > limit;
  const objects = results.slice(0, limit).map((row) => ({
    name: objectName(row.seq_from, row.seq_to),
    seqFrom: row.seq_from,
    seqTo: row.seq_to,
    count: row.count,
  }));
  return json({
    objects,
    events: objects.reduce((total, object) => total + object.count, 0),
    // True when there are more batches than this answer names. Saying so beats
    // handing back a convenient prefix that reads like the whole answer.
    truncated,
  });
}

/**
 * A time, however it was written: seconds since 1970, or anything `Date` reads.
 *
 * `null` means "no bound", which is why an absent parameter is a value here
 * rather than an error — asking for all the sleep there has ever been is a
 * reasonable question.
 */
function instant(value: string | null): number | null | undefined {
  if (value === null || value === "") return null;
  if (/^-?\d+$/.test(value)) return Number(value);
  const parsed = Date.parse(value);
  return Number.isNaN(parsed) ? undefined : Math.floor(parsed / 1000);
}

async function listObjects(env: Env, bucket: string, url: URL): Promise<Response> {
  const after = Number(url.searchParams.get("after") ?? "0");
  if (!Number.isSafeInteger(after) || after < 0) {
    return problem(400, "after must be a sequence number");
  }
  const asked = Number(url.searchParams.get("limit") ?? MAX_OBJECTS_PER_PAGE);
  if (!Number.isSafeInteger(asked) || asked < 1) return problem(400, "limit must be a count");
  const limit = Math.min(asked, MAX_OBJECTS_PER_PAGE);

  // Skipping in the store rather than filtering here is the whole reason a long
  // history can be walked: a filtered page runs out at the first page and says
  // so by returning nothing, which reads as "there is no more data".
  const page = await listPage(env, bucket, after, limit);
  return json({
    objects: page.objects,
    truncated: page.truncated,
    // Where to continue. Following this until it comes back null is how a
    // reader walks an archive of any size.
    next: page.truncated && page.objects.length > 0
      ? page.objects[page.objects.length - 1].seqTo
      : null,
  });
}

/** What is in here, without downloading it. Cheap enough for an agent to ask
 * before deciding whether it needs anything at all. */
async function describe(env: Env, bucket: string): Promise<Response> {
  let objects = 0;
  let bytes = 0;
  let highestSeq = 0;
  let lowestSeq: number | null = null;
  let complete = true;

  for (let page = 0; page < STATS_PAGE_LIMIT; page++) {
    const listing = await listPage(env, bucket, highestSeq, MAX_OBJECTS_PER_PAGE);
    for (const object of listing.objects) {
      objects++;
      bytes += object.size;
      if (lowestSeq === null) lowestSeq = object.seqFrom;
      highestSeq = Math.max(highestSeq, object.seqTo);
    }
    if (!listing.truncated || listing.objects.length === 0) break;
    if (page === STATS_PAGE_LIMIT - 1) complete = false;
  }

  const claimed = await env.BLOBS.head(signingKeyObject(bucket));
  return json({
    exists: claimed !== null || objects > 0,
    objects,
    bytes,
    lowestSeq,
    highestSeq,
    // False when the archive is larger than this endpoint will walk; the
    // numbers are then a floor, not a total. Saying so beats quietly rounding
    // an archive down to the part that was convenient to count.
    complete,
  });
}

async function listPage(
  env: Env,
  bucket: string,
  after: number,
  limit: number,
): Promise<
  { objects: { name: string; size: number; seqFrom: number; seqTo: number }[]; truncated: boolean }
> {
  const prefix = `${bucket}/${DATA_PREFIX}`;
  const listing = await env.BLOBS.list({
    prefix,
    startAfter: listingStartAfter(bucket, after),
    limit,
  });

  const objects = listing.objects
    .map((object) => {
      const name = object.key.slice(prefix.length);
      const range = parseObjectName(name);
      return range ? { name, size: object.size, ...range } : null;
    })
    .filter((entry) => entry !== null)
    // `startAfter` is a string comparison, so the object whose range *ends* at
    // `after` can still come back. It holds nothing new.
    .filter((entry) => entry.seqTo > after);

  return { objects, truncated: listing.truncated };
}

async function fetchObject(env: Env, bucket: string, name: string): Promise<Response> {
  if (!parseObjectName(name)) return problem(400, "malformed object name");

  const object = await env.BLOBS.get(`${bucket}/${DATA_PREFIX}${name}`);
  if (!object) return problem(404, "no such object");

  return new Response(await object.arrayBuffer(), {
    headers: { "content-type": "application/octet-stream" },
  });
}

function readHeader(request: Request, bucket: string): UploadHeader | string {
  const seqFrom = Number(request.headers.get("x-efferent-seq-from"));
  const seqTo = Number(request.headers.get("x-efferent-seq-to"));
  const timestamp = Number(request.headers.get("x-efferent-timestamp"));

  for (
    const [name, value] of [["seq-from", seqFrom], ["seq-to", seqTo], [
      "timestamp",
      timestamp,
    ]] as const
  ) {
    if (!Number.isSafeInteger(value) || value < 0) {
      return `x-efferent-${name} must be a whole number`;
    }
  }
  if (seqFrom > seqTo) return "x-efferent-seq-from is above x-efferent-seq-to";

  return { bucket, seqFrom, seqTo, timestamp };
}

function sameBytes(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index++) difference |= left[index] ^ right[index];
  return difference === 0;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

/** Errors say what is wrong in words, so a failure on a phone with no debugger
 * still tells you something. */
function problem(status: number, detail: string): Response {
  return json({ error: detail }, status);
}
