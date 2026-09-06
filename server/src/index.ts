/**
 * The bucket service: an archive of days that cannot read what it holds.
 *
 * It does three things — check that a writer is the one who claimed the bucket,
 * keep one object per day, and hand days back by range. It never sees a key
 * that decrypts anything, so there is deliberately no code here that could.
 *
 * There are no accounts and no registration. A bucket comes into existence
 * when the phone sends an empty signed claim, before any Health day exists.
 *
 * A day is written whole and replaced whole. That is the one property worth
 * being careful about: the device does not send a difference it worked out, it
 * re-reads the day from Health and puts the result here, so writing the same
 * day twice is not a conflict to resolve but the ordinary case. It also means
 * this service needs no notion of what changed, no acknowledgement to get
 * right, and no way for a reinstalled phone to collide with its own past.
 *
 * Days arrive several at a time, because a phone exporting a decade would
 * otherwise spend its whole waking life on round trips. Each one is still its
 * own sealed blob and its own object; the batch is a way of travelling, and
 * ends at the door.
 *
 * What it learns is which days exist and how big they are. Not what happened in
 * them, not at what time, not of what kind.
 */

/// <reference path="../worker-configuration.d.ts" />

import { McpServer } from "@modelcontextprotocol/server";
import { createMcpHandler } from "agents/mcp/server";
import { z } from "zod";

import {
  dayBefore,
  dayKey,
  dayPrefix,
  isBucketId,
  isDay,
  SERVICE_TAKEN_OBJECT,
  signingKeyObject,
  takenObject,
} from "../../protocol/ids.ts";
import { MAX_DAYS_PER_REQUEST, type SealedDay, unpackDays } from "../../protocol/batch.ts";
import {
  canonicalRequest,
  fromBase64url,
  hasSmallOrder,
  TIMESTAMP_TOLERANCE_SECONDS,
  type UploadHeader,
  verifyUpload,
} from "../../protocol/signing.ts";
import { AttestationError, verifyAttestation } from "../../protocol/attestation.ts";
import { SETUP_GUIDE } from "./setup-guide.ts";

declare global {
  interface Env {
    /**
     * `<team id>.<bundle id>`, which is what an attestation is bound to.
     *
     * A comma-separated list, because the copy installed straight onto a phone
     * for checking carries a bundle id of its own and would otherwise be told
     * it is another app — which is exactly what happened the first time a real
     * attestation reached this service. Every id belongs to the same team.
     *
     * Deliberately not in this repository: the team id names the account
     * rather than the app, and this repository is public. Set it with
     * `wrangler secret put APP_ID`. Without it no bucket can be claimed —
     * a service that cannot check is not allowed to guess.
     */
    APP_ID?: string;
  }
}

/** What one request may carry. The phone cuts a batch at four mebibytes of
 * sealed days and adds a few hundred bytes of framing, so this is its own
 * budget with room over it. It used to be sixteen, which was a number about
 * what a Worker can hold rather than about what a person's days weigh. */
export const MAX_BODY_BYTES = 5 * 1024 * 1024;
/** What an attestation may weigh. Apple's are about 5 KB — two certificates and
 * a receipt — so this is room over it rather than a measurement. */
export const MAX_ATTESTATION_BYTES = 32 * 1024;
/** What one day may weigh. Measured against the live archive on 2026-09-05:
 * eleven years of days, median 8.7 KB, ninety-ninth percentile 43.8 KB, the
 * heaviest of all 278 KB. A mebibyte is not a limit anybody meets; it is the
 * size at which a day has stopped being a day. */
export const MAX_DAY_BYTES = 1024 * 1024;
/** What one bucket may ever be handed. The whole eleven-year archive is 37 MB
 * and a year of rewriting recent days adds about 20 MB, so this is a couple of
 * decades for a person and an early stop for anything else. */
export const MAX_BUCKET_BYTES = 512 * 1024 * 1024;
/** What the service may be handed in total before it stops taking days and
 * says so. At R2's rate this is about a dollar and a half a month of storage,
 * and about two and a half thousand lifetime archives. It is a circuit
 * breaker, not a business plan: while anybody can claim a bucket, a per-bucket
 * ceiling on its own bounds nothing. */
export const MAX_SERVICE_BYTES = 100 * 1024 * 1024 * 1024;
/** Where the service's own tally starts when there is none to read. Measured
 * with `wrangler r2 bucket info efferent` on 2026-09-05: 17,585 objects,
 * 153 MB. Deleting the tally object is how it is re-seeded from here. */
export const SERVICE_BYTES_ALREADY_TAKEN = 153 * 1000 * 1000;
/** The oldest day anybody may write. Health cannot know about a day before the
 * person, and an archive reaching back to the year 1 is somebody filling the
 * key space rather than exporting a life. */
export const EARLIEST_DAY = "1900-01-01";

/// How many times a tally will re-read and write again when another request
/// changed it first. Three covers the handful of uploads a phone runs at once
/// and costs at most five extra subrequests per tally, which the free plan's
/// fifty per request leaves room for beside a batch of days.
export const TALLY_ATTEMPTS = 3;

/// A tally, and the version of the object it was read from.
type Tally = { value: number; version?: string };
/** Days per listing page — R2's own ceiling for one listing, so asking for more
 * would page underneath anyway. Nearly three years in one answer: an ordinary
 * question never pages, and a device checking a decade against the archive does
 * it in three round trips. */
const MAX_DAYS_PER_PAGE = 1000;
/** How far `stats` will walk inside one year before it answers "at least this
 * much". A year holds 366 days at the outside and a page holds hundreds, so
 * this is slack rather than a limit anybody meets. */
const STATS_PAGES_PER_YEAR = 4;
/** How many pages of rolled-up years `stats` will read. A page of them covered
 * about two thousand days of the real archive, so this reaches a century. */
const STATS_YEAR_PAGES = 50;

export default {
  async fetch(request: Request, env: Env, ctx?: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    const segments = url.pathname.split("/").filter(Boolean);

    if (segments.length === 1 && segments[0] === "health") {
      return json({ ok: true });
    }
    if (segments.length === 3 && segments[0] === "mcp" && segments[1] === "b") {
      const bucket = segments[2];
      if (!isBucketId(bucket)) return problem(400, "malformed bucket id");
      if (!ctx) return problem(500, "execution context is unavailable");
      return await remoteMcp(request, env, ctx, bucket, url.origin);
    }
    if (segments[0] !== "b" || !segments[1]) {
      return problem(404, "unknown path");
    }

    const bucket = segments[1];
    if (!isBucketId(bucket)) return problem(400, "malformed bucket id");

    if (segments.length === 2 && request.method === "PUT") {
      if (!await allowed(env.CLAIMS, request)) {
        return problem(429, "too many bucket claims from here just now");
      }
      return await createBucket(request, env, bucket);
    }
    if (segments.length === 3 && segments[2] === "days") {
      if (request.method === "GET") return await listDays(env, bucket, url);
      if (request.method === "PUT") {
        if (!await allowed(env.WRITES, request)) {
          return problem(429, "too many uploads from here just now");
        }
        return await putDays(request, env, bucket);
      }
    }
    if (segments.length === 3 && segments[2] === "stats" && request.method === "GET") {
      return await describe(env, bucket);
    }
    if (segments.length === 4 && segments[2] === "d" && request.method === "GET") {
      const day = segments[3];
      if (!isDay(day)) return problem(400, "day must be YYYY-MM-DD and a date that exists");
      return await getDay(env, bucket, day);
    }
    return problem(405, `${request.method} is not allowed here`);
  },
} satisfies ExportedHandler<Env>;

function createRemoteServer(env: Env, bucket: string, origin: string): McpServer {
  const server = new McpServer(
    { name: "efferent-sealed-archive", version: "1.0.0" },
    {
      instructions:
        "Call setup_guide first. Keep the reading key local and never pass it to this server, " +
        "a remote tool, an HTTP request, a URL or a log. This server returns ciphertext only.",
    },
  );

  server.registerTool(
    "setup_guide",
    {
      title: "Set up local Efferent reading",
      description:
        "Call this first. Return the complete local-only setup procedure and reference Python " +
        "reader. It takes no arguments and never receives the reading key.",
      inputSchema: z.object({}),
    },
    () => ({ content: [{ type: "text" as const, text: SETUP_GUIDE }] }),
  );

  server.registerTool(
    "archive_status",
    {
      title: "Describe the sealed archive",
      description:
        "Return only ciphertext metadata: whether this bucket exists, its day count, byte count, " +
        "and first and last dates. This server never receives a reading key and cannot answer a " +
        "health question. Decrypt selected days with the reference code from setup_guide.",
      inputSchema: z.object({}),
    },
    async () => textTool(await describeData(env, bucket)),
  );

  server.registerTool(
    "list_sealed_days",
    {
      title: "List sealed days",
      description:
        "List ciphertext objects by date, size and upload time. Both date bounds are inclusive. " +
        "Follow next until it is null. No argument accepts a key and no returned value contains " +
        "plaintext; decrypt selected objects only with local code on the agent machine.",
      inputSchema: z.object({
        from: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(),
        to: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(),
        after: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(),
        limit: z.number().int().min(1).max(MAX_DAYS_PER_PAGE).optional(),
      }),
    },
    async (arguments_) => {
      const url = new URL(`/b/${bucket}/days`, origin);
      for (const [name, value] of Object.entries(arguments_)) {
        if (value !== undefined) url.searchParams.set(name, String(value));
      }
      const response = await listDays(env, bucket, url);
      return responseTool(response);
    },
  );

  server.registerTool(
    "get_sealed_day",
    {
      title: "Get a sealed day",
      description:
        "Return a link to one encrypted day object. The link carries only the bucket id and date. " +
        "Download the bytes and pass them to the local reference code; never pass the reading key " +
        "back to this tool or attach it to the download request.",
      inputSchema: z.object({
        day: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
      }),
    },
    async ({ day }) => {
      if (!isDay(day)) return failedTool("day must be YYYY-MM-DD and a date that exists");
      const object = await env.BLOBS.head(dayKey(bucket, day));
      if (!object) return failedTool("no such day");
      const uri = new URL(`/b/${bucket}/d/${day}`, origin).toString();
      return {
        content: [{
          type: "resource_link" as const,
          uri,
          name: `sealed-day-${day}`,
          description: "End-to-end encrypted Efferent day; decrypt only on the agent machine.",
          mimeType: "application/octet-stream",
        }],
      };
    },
  );

  return server;
}

function remoteMcp(
  request: Request,
  env: Env,
  ctx: ExecutionContext,
  bucket: string,
  origin: string,
): Promise<Response> {
  const route = new URL(request.url).pathname;
  return createMcpHandler(() => createRemoteServer(env, bucket, origin), {
    route,
  })(request, env, ctx);
}

function textTool(value: unknown) {
  return {
    content: [{ type: "text" as const, text: JSON.stringify(value) }],
    structuredContent: value as Record<string, unknown>,
  };
}

async function responseTool(response: Response) {
  const value = await response.json() as Record<string, unknown>;
  return response.ok ? textTool(value) : failedTool(String(value.error ?? "request failed"));
}

function failedTool(message: string) {
  return { content: [{ type: "text" as const, text: message }], isError: true };
}

/**
 * Claim an empty logical bucket before the phone has a day to send.
 *
 * It is the same proof used for an upload, signed over an empty body and an
 * empty day list. The reading key is absent: the service learns only the
 * independent public signing key.
 */
async function createBucket(request: Request, env: Env, bucket: string): Promise<Response> {
  const body = new Uint8Array(await request.arrayBuffer());
  if (body.length !== 0) return problem(400, "bucket creation must have an empty body");

  const authorization = await authorizeWriter(request, env, bucket, [], body);
  if (authorization instanceof Response) return authorization;
  if (!authorization.registered) {
    const refusal = await attestedClaim(request, env, authorization.header, body);
    if (refusal) return refusal;
    await env.BLOBS.put(signingKeyObject(bucket), authorization.claimed);
  }
  return json({ bucket, created: !authorization.registered }, authorization.registered ? 200 : 201);
}

/**
 * Store the days a request carries, each replacing whatever was there.
 *
 * Replacing is the point rather than a compromise. A day's body is the whole of
 * that day as Health has it now, so a second write is a correction — a workout
 * deleted, a watch that synced late — and keeping the older version would mean
 * keeping something the person has already changed.
 *
 * Several days share a request only to save round trips. They are unpacked and
 * stored as they came, still sealed, still one object each, so nothing further
 * down knows a batch happened.
 *
 * The answer names every day that landed. It is the sender's licence to stop
 * marking them, and there is no partial success to interpret: if a write fails
 * the request fails, and days already written are simply written again next
 * time. That is what idempotence is for.
 */
async function putDays(request: Request, env: Env, bucket: string): Promise<Response> {
  const body = new Uint8Array(await request.arrayBuffer());
  if (body.length === 0) return problem(400, "empty body");
  if (body.length > MAX_BODY_BYTES) return problem(413, `a request over ${MAX_BODY_BYTES} bytes`);

  let entries: SealedDay[];
  try {
    entries = unpackDays(body);
  } catch (error) {
    return problem(400, `malformed batch: ${(error as Error).message}`);
  }
  if (entries.length > MAX_DAYS_PER_REQUEST) {
    return problem(
      413,
      `${entries.length} days in one request, and ${MAX_DAYS_PER_REQUEST} is all`,
    );
  }

  const heavy = entries.find((entry) => entry.blob.length > MAX_DAY_BYTES);
  if (heavy) {
    return problem(
      413,
      `${heavy.day} weighs ${heavy.blob.length} bytes, and ${MAX_DAY_BYTES} is all one day may`,
    );
  }
  // A day is a date somebody lived through. Refusing the rest keeps the key
  // space of a bucket to the days a person can have rather than to every date
  // the calendar can spell.
  // Tomorrow, because a phone far enough east is already on a day this server
  // has not reached.
  const latest = new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString().slice(0, 10);
  const outside = entries.find((entry) => entry.day < EARLIEST_DAY || entry.day > latest);
  if (outside) {
    return problem(400, `${outside.day} is outside ${EARLIEST_DAY} … ${latest}`);
  }

  const authorization = await authorizeWriter(
    request,
    env,
    bucket,
    entries.map((entry) => entry.day),
    body,
  );
  if (authorization instanceof Response) return authorization;

  // An upload no longer brings a bucket into existence. It used to, and a
  // signature was enough — which would have left the whole attestation check
  // standing beside an open door. Claiming is the one way in, and it is the
  // one place Apple is asked to vouch for the caller.
  if (!authorization.registered) {
    return problem(403, "this bucket has not been claimed");
  }

  // Both ceilings are read before anything is written, because a refusal after
  // the writes would have cost exactly what it was meant to prevent.
  const bucketTaken = await taken(env, takenObject(bucket), 0);
  if (bucketTaken.value + body.length > MAX_BUCKET_BYTES) {
    return problem(
      507,
      `this bucket has been handed ${bucketTaken.value} bytes, and ${MAX_BUCKET_BYTES} is all one bucket may take`,
    );
  }
  const serviceTaken = await taken(env, SERVICE_TAKEN_OBJECT, SERVICE_BYTES_ALREADY_TAKEN);
  if (serviceTaken.value + body.length > MAX_SERVICE_BYTES) {
    return problem(507, "this service has been handed as much as it may take");
  }

  // Settled, not all: a batch where one write failed still stored the others,
  // and the sender marks a day as delivered only when this answer names it. An
  // exception here would answer nothing about days that are in fact in the
  // archive, and the phone would build and send every one of them again.
  const writes = await Promise.allSettled(
    entries.map((entry) => env.BLOBS.put(dayKey(bucket, entry.day), entry.blob)),
  );
  const stored = entries
    .filter((_, index) => writes[index].status === "fulfilled")
    .map((entry) => entry.day);
  if (stored.length === 0) {
    return problem(502, "the store took none of these days");
  }

  // Counted after the fact and by the whole request, not by the days that
  // landed: what a ceiling is protecting against is the work of taking a
  // request, and that work was done either way.
  await Promise.all([
    add(env, takenObject(bucket), bucketTaken, body.length),
    add(env, SERVICE_TAKEN_OBJECT, serviceTaken, body.length),
  ]);
  return json({ stored, bytes: body.length });
}

async function authorizeWriter(
  request: Request,
  env: Env,
  bucket: string,
  days: string[],
  body: Uint8Array,
): Promise<{ claimed: Uint8Array; registered: boolean; header: UploadHeader } | Response> {
  const signature = request.headers.get("x-efferent-signature");
  const writerKey = request.headers.get("x-efferent-writer");
  if (!signature || !writerKey) return problem(400, "missing writer key or signature");

  const timestamp = Number(request.headers.get("x-efferent-timestamp"));
  if (!Number.isSafeInteger(timestamp) || timestamp < 0) {
    return problem(400, "x-efferent-timestamp must be a whole number");
  }
  // The refusal carries this server's own clock. A phone cannot tell that its
  // clock is wrong — every request it signs is refused for the same reason, and
  // nothing it can measure says why — so the one place the answer exists is
  // here. With it, the phone corrects itself and the next request goes through.
  const now = Math.floor(Date.now() / 1000);
  const drift = Math.abs(now - timestamp);
  if (drift > TIMESTAMP_TOLERANCE_SECONDS) {
    return json({
      error: `timestamp is ${drift}s away from this server's clock`,
      now,
    }, 400);
  }

  let claimed: Uint8Array;
  let decodedSignature: Uint8Array;
  try {
    claimed = fromBase64url(writerKey);
    decodedSignature = fromBase64url(signature);
  } catch {
    return problem(400, "writer key and signature must be base64url");
  }
  if (claimed.length !== 32 || decodedSignature.length !== 64) {
    return problem(400, "writer key or signature has the wrong length");
  }
  // Said plainly here, because the answer "that signature does not match" would
  // send whoever reads it looking for a bug in their signing.
  if (hasSmallOrder(claimed)) {
    return problem(400, "that writer key is not a key anybody holds");
  }

  const registered = await env.BLOBS.get(signingKeyObject(bucket));
  if (registered) {
    const known = new Uint8Array(await registered.arrayBuffer());
    if (!sameBytes(known, claimed)) {
      return problem(403, "this bucket already belongs to another writer");
    }
  }

  // For an upload, `days` came from the unpacked frame. This proves the service
  // parsed exactly what the phone signed. For creation it is deliberately empty.
  const header: UploadHeader = { bucket, days, timestamp };
  if (!await verifyUpload(claimed, decodedSignature, header, body)) {
    return problem(403, "signature does not match the request");
  }
  return { claimed, registered: registered !== null, header };
}

/**
 * Apple's word that a bucket is being claimed by this app on a real iPhone.
 *
 * Only a claim is checked, and only a claim that creates a bucket: a phone that
 * claims one it already owns has proved as much with the signature above, and
 * an attested key can be attested once. Uploads are not checked at all — they
 * are already bound to the bucket by the key the claim registered.
 *
 * What the attestation covers is the canonical bytes of this very claim, which
 * carry the bucket and a timestamp this service refuses when it is far from its
 * own clock. That is why there is no challenge endpoint and nothing is kept
 * between two requests.
 */
async function attestedClaim(
  request: Request,
  env: Env,
  header: UploadHeader,
  body: Uint8Array,
): Promise<Response | null> {
  if (!env.APP_ID) return problem(500, "this service cannot check attestations");

  const object = request.headers.get("x-efferent-attestation");
  const keyId = request.headers.get("x-efferent-attestation-key");
  if (!object || !keyId) return problem(400, "claiming a bucket needs an App Attest attestation");

  let attestation: Uint8Array;
  let named: Uint8Array;
  try {
    attestation = fromBase64url(object);
    named = fromBase64url(keyId);
  } catch {
    return problem(400, "the attestation and its key id must be base64url");
  }
  if (attestation.length > MAX_ATTESTATION_BYTES) {
    return problem(400, "that attestation is too long");
  }

  try {
    await verifyAttestation({
      attestation,
      keyId: named,
      appIds: env.APP_ID.split(",").map((id) => id.trim()).filter((id) => id !== ""),
      challenge: new TextEncoder().encode(await canonicalRequest(header, body)),
    });
  } catch (error) {
    if (error instanceof AttestationError) return problem(403, error.message);
    throw error;
  }
  return null;
}

async function getDay(env: Env, bucket: string, day: string): Promise<Response> {
  const object = await env.BLOBS.get(dayKey(bucket, day));
  if (!object) return problem(404, "no such day");

  return new Response(object.body, {
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
  return json(await describeData(env, bucket));
}

/**
 * Counting the archive, a year at a time and every year at once.
 *
 * There is no cheaper answer than the listing itself — R2 knows how many
 * objects a prefix holds only by walking them — so the saving is in not
 * waiting. A single walk is sequential by construction, because each page
 * starts where the last one ended, and a decade spent 1.4 seconds going four
 * pages one after another. Days are named by date, so the archive splits along
 * a boundary the keys already have: one listing says which years exist, and the
 * years are then counted side by side. The same objects are read, and the
 * answer is the same answer.
 */
async function describeData(env: Env, bucket: string) {
  const years = await listYears(env, bucket);
  const counted = await Promise.all(years.years.map((year) => countYear(env, bucket, year)));

  let days = 0;
  let bytes = 0;
  let firstDay: string | null = null;
  let lastDay: string | null = null;
  let complete = years.complete;

  // In order, because the first and last day of the archive are the first day
  // of its earliest year and the last day of its latest.
  for (const year of counted) {
    days += year.days;
    bytes += year.bytes;
    firstDay ??= year.firstDay;
    lastDay = year.lastDay ?? lastDay;
    if (!year.complete) complete = false;
  }

  const claimed = await env.BLOBS.head(signingKeyObject(bucket));
  return {
    exists: claimed !== null || days > 0,
    days,
    bytes,
    firstDay,
    lastDay,
    // False when the archive is longer than this endpoint will walk; the
    // numbers are then a floor, not a total. Saying so beats quietly rounding
    // an archive down to the part that was convenient to count.
    complete,
  };
}

/**
 * Which years this archive has days in, without reading the days.
 *
 * A day key ends in `YYYY-MM-DD`, so asking R2 to stop at the first dash hands
 * back one entry per year rather than one per day — twelve answers where a walk
 * would have read four thousand objects. Anything under the prefix not shaped
 * like a year is left out; only `isDay` decides what counts, and it decides it
 * below, on the keys themselves.
 *
 * **A rolled-up listing pages like any other, and for the same reason.** R2
 * gathers the prefixes from the objects it scanned, not from the whole bucket,
 * so it answers twelve years as two pages and says so. Taking the first page
 * for the answer cost the real archive its last three years — 2 942 days out of
 * 3 914, `lastDay` two and a half years early, and no error anywhere. Follow the
 * cursor.
 */
async function listYears(
  env: Env,
  bucket: string,
): Promise<{ years: string[]; complete: boolean }> {
  const prefix = dayPrefix(bucket);
  const found = new Set<string>();
  let cursor: string | undefined;

  for (let page = 0; page < STATS_YEAR_PAGES; page++) {
    const listing = await env.BLOBS.list({
      prefix,
      delimiter: "-",
      limit: MAX_DAYS_PER_PAGE,
      cursor,
    });
    for (const delimited of listing.delimitedPrefixes) {
      found.add(delimited.slice(prefix.length));
    }
    if (!listing.truncated) return { years: years(found), complete: true };
    cursor = listing.cursor;
  }
  // Only an archive longer than every page of this walk together, which is
  // decades of days. Saying so beats answering about the part that fitted.
  return { years: years(found), complete: false };
}

function years(found: Set<string>): string[] {
  return [...found].filter((year) => /^\d{4}-$/.test(year)).sort();
}

/** One year, walked to its end. It cannot need more than one page in practice;
 * it pages anyway, because a listing that stopped at its page size would report
 * the rest of the year as nothing at all. */
async function countYear(env: Env, bucket: string, year: string) {
  let days = 0;
  let bytes = 0;
  let firstDay: string | null = null;
  let lastDay: string | null = null;
  let after: string | null = null;

  for (let page = 0; page < STATS_PAGES_PER_YEAR; page++) {
    const listing = await listPage(env, bucket, after, MAX_DAYS_PER_PAGE, year);
    for (const entry of listing.days) {
      days++;
      bytes += entry.bytes;
      firstDay ??= entry.day;
      lastDay = entry.day;
    }
    if (!listing.truncated || listing.days.length === 0) {
      return { days, bytes, firstDay, lastDay, complete: true };
    }
    after = listing.days[listing.days.length - 1].day;
  }
  return { days, bytes, firstDay, lastDay, complete: false };
}

async function listPage(
  env: Env,
  bucket: string,
  after: string | null,
  limit: number,
  within = "",
): Promise<{ days: { day: string; bytes: number; uploaded: string }[]; truncated: boolean }> {
  const prefix = dayPrefix(bucket);
  const listing = await env.BLOBS.list({
    // `within` narrows the listing to part of the key space — a year, for the
    // count above. The day is still cut from the whole prefix, so a narrowed
    // page and a full one describe days the same way.
    prefix: `${prefix}${within}`,
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

/**
 * Whether this caller may make this request at all.
 *
 * Keyed by the address the request came from, because at the point this is
 * asked nothing else about the caller has been established — the signature is
 * checked later, and checking it first would mean doing the expensive thing to
 * find out whether the cheap one was allowed.
 *
 * Cloudflare counts within one of its locations, so a caller spread over the
 * world gets this many in each. That is a reason to hold a service-wide
 * ceiling as well, not a reason to skip the count.
 */
async function allowed(limiter: RateLimit, request: Request): Promise<boolean> {
  // A request with no address reaches here in local development only; there is
  // one such caller, and it shares one count.
  const key = request.headers.get("cf-connecting-ip") ?? "no address";
  const { success } = await limiter.limit({ key });
  return success;
}

/** What this name has been handed so far. An unreadable tally is treated as an
 * absent one: it is a budget, and losing count of it must not lock a person out
 * of their own archive. */
async function taken(env: Env, key: string, whenAbsent: number): Promise<Tally> {
  const object = await env.BLOBS.get(key);
  if (!object) return { value: whenAbsent };
  const counted = Number(await object.text());
  const value = Number.isSafeInteger(counted) && counted >= 0 ? counted : whenAbsent;
  return { value, version: object.httpEtag };
}

/// Add to a tally without losing what another request added at the same time.
///
/// R2 has no addition, so a tally is read, added to and written back — and two
/// uploads that overlap read the same number, with the second write erasing the
/// first. The phone sends several at once, so that is the ordinary case rather
/// than a rare one: measured on 2026-09-06, a bucket's tally said 838 906 bytes
/// where 944 043 had been accepted. The write therefore carries the version it
/// read, and R2 refuses it if that is no longer the version — which turns the
/// race into a `null` answer and one more read.
async function add(env: Env, key: string, read: Tally, bytes: number): Promise<void> {
  let known = read;
  for (let attempt = 1; attempt <= TALLY_ATTEMPTS; attempt++) {
    const written = await env.BLOBS.put(key, `${known.value + bytes}`, {
      onlyIf: known.version
        ? new Headers({ "if-match": known.version })
        : new Headers({ "if-none-match": "*" }),
    });
    if (written) return;
    known = await taken(env, key, known.value);
  }
  // Giving up undercounts; it never refuses a request that should be taken and
  // never loses a day. A ceiling that stopped the archive because its own
  // bookkeeping was busy would cost more than the bookkeeping is worth.
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
