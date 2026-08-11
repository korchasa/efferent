/**
 * The bucket service: an archive of days that cannot read what it holds.
 *
 * It does three things — check that a writer is the one who claimed the bucket,
 * keep one object per day, and hand days back by range. It never sees a key
 * that decrypts anything, so there is deliberately no code here that could.
 *
 * There are no accounts and no registration. A bucket comes into existence on
 * its first write, and its name already proves who it belongs to.
 *
 * A day is written whole and replaced whole. That is the one property worth
 * being careful about: the device does not send a difference it worked out, it
 * re-reads the day from Health and puts the result here, so writing the same
 * day twice is not a conflict to resolve but the ordinary case. It also means
 * this service needs no notion of what changed, no acknowledgement to get
 * right, and no way for a reinstalled phone to collide with its own past.
 *
 * What it learns is which days exist and how big they are. Not what happened in
 * them, not at what time, not of what kind.
 */

import {
  dayBefore,
  dayKey,
  dayPrefix,
  isBucketId,
  isDay,
  signingKeyObject,
} from "../../protocol/ids.ts";
import {
  fromBase64url,
  TIMESTAMP_TOLERANCE_SECONDS,
  type UploadHeader,
  verifyUpload,
} from "../../protocol/signing.ts";

/** Room for a busy day; well under what a Worker can hold in memory. */
const MAX_BODY_BYTES = 4 * 1024 * 1024;
/** Days per listing page. A year and a half in one answer, so an ordinary
 * question never pages at all. */
const MAX_DAYS_PER_PAGE = 500;
/** How far `stats` will walk before it answers "at least this much". Bounded so
 * that asking what is in an archive never costs more than a moment. */
const STATS_PAGE_LIMIT = 20;

/** Only the parts of R2 this service uses. Spelled out rather than pulled from
 * a types package, so the whole repository stays checkable without one. */
interface R2Object {
  key: string;
  size: number;
  /** When this day was last written. It is what tells a reader that a day it
   * already has was rewritten since — the only way to notice, now that a day
   * can legitimately change. */
  uploaded: Date;
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

export interface Env {
  BLOBS: R2Bucket;
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

    if (segments.length === 3 && segments[2] === "days" && request.method === "GET") {
      return await listDays(env, bucket, url);
    }
    if (segments.length === 3 && segments[2] === "stats" && request.method === "GET") {
      return await describe(env, bucket);
    }
    if (segments.length === 4 && segments[2] === "d") {
      const day = segments[3];
      if (!isDay(day)) return problem(400, "day must be YYYY-MM-DD and a date that exists");
      if (request.method === "PUT") return await putDay(request, env, bucket, day);
      if (request.method === "GET") return await getDay(env, bucket, day);
    }
    return problem(405, `${request.method} is not allowed here`);
  },
};

/**
 * Store one day, replacing whatever was there.
 *
 * Replacing is the point rather than a compromise. The body is the whole of
 * that day as Health has it now, so a second write is a correction — a workout
 * deleted, a watch that synced late — and keeping the older version would mean
 * keeping something the person has already changed.
 */
async function putDay(request: Request, env: Env, bucket: string, day: string): Promise<Response> {
  const signature = request.headers.get("x-efferent-signature");
  const writerKey = request.headers.get("x-efferent-writer");
  if (!signature || !writerKey) return problem(400, "missing writer key or signature");

  const timestamp = Number(request.headers.get("x-efferent-timestamp"));
  if (!Number.isSafeInteger(timestamp) || timestamp < 0) {
    return problem(400, "x-efferent-timestamp must be a whole number");
  }
  const drift = Math.abs(Math.floor(Date.now() / 1000) - timestamp);
  if (drift > TIMESTAMP_TOLERANCE_SECONDS) {
    return problem(400, `timestamp is ${drift}s away from this server's clock`);
  }

  const body = new Uint8Array(await request.arrayBuffer());
  if (body.length === 0) return problem(400, "empty body");
  if (body.length > MAX_BODY_BYTES) return problem(413, "a day larger than 4 MiB");

  const claimed = fromBase64url(writerKey);
  const registered = await env.BLOBS.get(signingKeyObject(bucket));
  if (registered) {
    const known = new Uint8Array(await registered.arrayBuffer());
    if (!sameBytes(known, claimed)) {
      return problem(403, "this bucket already belongs to another writer");
    }
  }

  const header: UploadHeader = { bucket, day, timestamp };
  if (!await verifyUpload(claimed, fromBase64url(signature), header, body)) {
    return problem(403, "signature does not match the request");
  }

  // Registered only after the signature checked out, so a stranger cannot claim
  // an unused bucket by presenting a key they do not hold.
  if (!registered) await env.BLOBS.put(signingKeyObject(bucket), claimed);

  await env.BLOBS.put(dayKey(bucket, day), body);
  return json({ stored: day, bytes: body.length });
}

async function getDay(env: Env, bucket: string, day: string): Promise<Response> {
  const object = await env.BLOBS.get(dayKey(bucket, day));
  if (!object) return problem(404, "no such day");

  return new Response(await object.arrayBuffer(), {
    headers: {
      "content-type": "application/octet-stream",
      "last-modified": object.uploaded.toUTCString(),
    },
  });
}

/**
 * Which days exist in a range, and when each was last written.
 *
 * `uploaded` is what keeps a mirror cheap to hold in step. A day the reader
 * already has can be rewritten at any time — that is what writing whole days
 * means — so "everything after where I stopped" stops being a question that can
 * be asked. "Everything that changed since I looked" still is, and it is the
 * same one listing.
 *
 * Both bounds are inclusive and both are optional: asking a bucket for
 * everything it has is a reasonable thing to do once.
 */
async function listDays(env: Env, bucket: string, url: URL): Promise<Response> {
  const from = url.searchParams.get("from");
  const to = url.searchParams.get("to");
  if (from && !isDay(from)) return problem(400, "from must be a day");
  if (to && !isDay(to)) return problem(400, "to must be a day");

  const asked = Number(url.searchParams.get("limit") ?? MAX_DAYS_PER_PAGE);
  if (!Number.isSafeInteger(asked) || asked < 1) return problem(400, "limit must be a count");
  const limit = Math.min(asked, MAX_DAYS_PER_PAGE);

  // `after` is where a walk continues; `from` is where a range begins. They are
  // one day apart because a listing skips *past* a key, and keeping them
  // separate is what lets `from` mean what a person means by it.
  const continuation = url.searchParams.get("after");
  if (continuation && !isDay(continuation)) return problem(400, "after must be a day");
  const after = continuation || (from ? dayBefore(from) : null);

  // Skipping in the store rather than filtering a fetched page is what lets a
  // long archive be walked at all: a filtered page runs out at the first page
  // and says so by returning nothing, which reads as "there is no more data".
  const page = await listPage(env, bucket, after, limit);
  const days = to ? page.days.filter((entry) => entry.day <= to) : page.days;
  const reachedEnd = days.length < page.days.length;

  return json({
    days,
    // Where to continue, or null at the end of the range. Following it until it
    // comes back null is how a reader walks an archive of any size.
    next: !reachedEnd && page.truncated && days.length > 0 ? days[days.length - 1].day : null,
  });
}

/** What is in here, without downloading it. Cheap enough for an agent to ask
 * before deciding whether it needs anything at all. */
async function describe(env: Env, bucket: string): Promise<Response> {
  let days = 0;
  let bytes = 0;
  let firstDay: string | null = null;
  let lastDay: string | null = null;
  let complete = true;
  let after: string | null = null;

  for (let page = 0; page < STATS_PAGE_LIMIT; page++) {
    const listing = await listPage(env, bucket, after, MAX_DAYS_PER_PAGE);
    for (const entry of listing.days) {
      days++;
      bytes += entry.bytes;
      firstDay ??= entry.day;
      lastDay = entry.day;
    }
    if (!listing.truncated || listing.days.length === 0) break;
    after = listing.days[listing.days.length - 1].day;
    if (page === STATS_PAGE_LIMIT - 1) complete = false;
  }

  const claimed = await env.BLOBS.head(signingKeyObject(bucket));
  return json({
    exists: claimed !== null || days > 0,
    days,
    bytes,
    firstDay,
    lastDay,
    // False when the archive is longer than this endpoint will walk; the
    // numbers are then a floor, not a total. Saying so beats quietly rounding
    // an archive down to the part that was convenient to count.
    complete,
  });
}

async function listPage(
  env: Env,
  bucket: string,
  after: string | null,
  limit: number,
): Promise<{ days: { day: string; bytes: number; uploaded: string }[]; truncated: boolean }> {
  const prefix = dayPrefix(bucket);
  const listing = await env.BLOBS.list({
    prefix,
    startAfter: after ? `${prefix}${after}` : undefined,
    limit,
  });

  const days = listing.objects
    .map((object) => {
      const day = object.key.slice(prefix.length);
      return isDay(day)
        ? { day, bytes: object.size, uploaded: object.uploaded.toISOString() }
        : null;
    })
    .filter((entry) => entry !== null);

  return { days, truncated: listing.truncated };
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

function problem(status: number, detail: string): Response {
  return json({ error: detail }, status);
}
