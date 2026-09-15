/**
 * What the archive store holds, and the one way to take an archive out of it.
 *
 * Never deployed — see the comment at the top of `wrangler.jsonc`. It is run
 * locally with `wrangler dev --remote`, which binds it to the live bucket, and
 * it answers on localhost to whoever started it.
 *
 * Three jobs:
 *
 * - **Answer a deletion request.** The privacy policy promises that an archive
 *   is removed within 30 days of its owner asking, and the service has no route
 *   that could do it. This does, behind a confirmation that has to name the
 *   archive being deleted.
 * - **Show the ceilings.** `MAX_SERVICE_BYTES` and `MAX_BUCKET_BYTES` count
 *   bytes ever handed over. They never come down, nothing watches them, and the
 *   end of one is a `507` the person on the other side can do nothing about.
 *   Looking is the only defence, so looking is one request.
 * - **Take a copy.** `/export` streams one archive out as it stands, sealed
 *   days included, so there is something to restore from. The days stay
 *   ciphertext: this tool holds no key and cannot read a single reading.
 *
 * The ceilings are imported from the service rather than repeated here. Two
 * copies of a number that decides when uploads stop is how a tool ends up
 * reassuring somebody about a limit that moved.
 */

import {
  BUCKET_ID_LENGTH,
  DATA_PREFIX,
  EDIT_PREFIX,
  isBucketId,
  OUTCOME_PREFIX,
  SERVICE_TAKEN_OBJECT,
  takenObject,
} from "../../protocol/ids.ts";
import { MAX_BUCKET_BYTES, MAX_SERVICE_BYTES, SERVICE_BYTES_ALREADY_TAKEN } from "../src/index.ts";

interface Store {
  BLOBS: R2Bucket;
}

/** One page of a listing; R2 hands back a thousand keys at a time. */
const PAGE = 1000;

/** How many delete passes one request may make. 1000 keys a pass, so this is
 * room for a million objects and a wall in front of a loop that deletes
 * nothing and lists the same page forever. */
const MAX_DELETE_PASSES = 1000;

const USAGE = `efferent maintenance — runs locally, never deployed

  GET  /ceilings                    what the two byte ceilings have been handed
  GET  /archives                    every archive, from its own tally (cheap)
  GET  /archives?deep               the same, counted by walking every object (slow)
  GET  /archive/<id>                one archive: days, edits, outcomes, dates, keys
  GET  /export/<id>                 every object as JSON lines, bodies in base64
  POST /delete/<id>                 what deleting it would remove — deletes nothing
  POST /delete/<id>?confirm=<id>    delete it, for good

An archive id is ${BUCKET_ID_LENGTH} characters of base32. Nothing else is accepted, which is
what keeps the service-wide tally and any other root object out of reach.
`;

export default {
  async fetch(request: Request, env: Store): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname.replace(/\/+$/, "") || "/";
    try {
      if (path === "/") return text(USAGE);
      if (path === "/ceilings") return json(await ceilings(env));
      if (path === "/archives") return json(await archives(env, url.searchParams.has("deep")));
      const one = path.match(/^\/archive\/([^/]+)$/);
      if (one) return json(await archive(env, named(one[1])));
      const dump = path.match(/^\/export\/([^/]+)$/);
      if (dump) return exportArchive(env, named(dump[1]));
      const gone = path.match(/^\/delete\/([^/]+)$/);
      if (gone && request.method === "POST") {
        return json(await remove(env, named(gone[1]), url.searchParams.get("confirm")));
      }
      return text(`no such path: ${path}\n\n${USAGE}`, 404);
    } catch (error) {
      return text(`${error instanceof Error ? error.message : String(error)}\n`, 400);
    }
  },
};

/** An id, or a clear refusal. A typo must never become a prefix to delete. */
function named(value: string): string {
  const id = decodeURIComponent(value);
  if (!isBucketId(id)) {
    throw new Error(`${id} is not an archive id: ${BUCKET_ID_LENGTH} characters of base32`);
  }
  return id;
}

function json(body: unknown, status = 200): Response {
  return new Response(`${JSON.stringify(body, null, 1)}\n`, {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

function text(body: string, status = 200): Response {
  return new Response(body, { status, headers: { "content-type": "text/plain; charset=utf-8" } });
}

/** A tally is a number written as text, and an absent one is not zero. */
async function tally(env: Store, key: string, whenAbsent: number): Promise<number> {
  const object = await env.BLOBS.get(key);
  if (!object) return whenAbsent;
  const counted = Number(await object.text());
  return Number.isSafeInteger(counted) && counted >= 0 ? counted : whenAbsent;
}

function share(taken: number, ceiling: number): string {
  return `${((taken / ceiling) * 100).toFixed(2)}%`;
}

/** The top-level names, which are the archives and nothing else. */
async function ids(env: Store): Promise<string[]> {
  const found: string[] = [];
  let cursor: string | undefined;
  do {
    const page = await env.BLOBS.list({ delimiter: "/", limit: PAGE, cursor });
    for (const prefix of page.delimitedPrefixes) {
      const id = prefix.replace(/\/$/, "");
      if (isBucketId(id)) found.push(id);
    }
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
  return found.sort();
}

async function ceilings(env: Store) {
  const service = await tally(env, SERVICE_TAKEN_OBJECT, SERVICE_BYTES_ALREADY_TAKEN);
  const found = await ids(env);
  const buckets = [];
  for (const id of found) {
    const taken = await tally(env, takenObject(id), 0);
    buckets.push({
      archive: id,
      taken,
      used: share(taken, MAX_BUCKET_BYTES),
      left: MAX_BUCKET_BYTES - taken,
    });
  }
  buckets.sort((a, b) => b.taken - a.taken);
  return {
    service: {
      taken: service,
      ceiling: MAX_SERVICE_BYTES,
      used: share(service, MAX_SERVICE_BYTES),
      left: MAX_SERVICE_BYTES - service,
      // Bytes handed over, never bytes held, so deleting an archive frees
      // nothing here. Re-seeding means deleting the `taken` object and letting
      // the service start again from its measured floor.
      note: "bytes ever handed over; a deletion gives none of it back",
    },
    bucketCeiling: MAX_BUCKET_BYTES,
    archives: buckets,
  };
}

/** Everything under one prefix, in one walk. */
async function walk(env: Store, prefix: string) {
  let objects = 0;
  let bytes = 0;
  let first: string | undefined;
  let last: string | undefined;
  let written: string | undefined;
  let cursor: string | undefined;
  do {
    const page = await env.BLOBS.list({ prefix, limit: PAGE, cursor });
    for (const object of page.objects) {
      objects += 1;
      bytes += object.size;
      const name = object.key.slice(prefix.length);
      if (first === undefined || name < first) first = name;
      if (last === undefined || name > last) last = name;
      const at = object.uploaded.toISOString();
      if (written === undefined || at > written) written = at;
    }
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
  return { objects, bytes, first, last, written };
}

async function archives(env: Store, deep: boolean) {
  const found = await ids(env);
  const rows = [];
  for (const id of found) {
    const taken = await tally(env, takenObject(id), 0);
    const claimed = (await env.BLOBS.head(`${id}/key`)) !== null;
    const editor = (await env.BLOBS.head(`${id}/editor`)) !== null;
    if (!deep) {
      rows.push({ archive: id, taken, claimed, editor });
      continue;
    }
    const days = await walk(env, `${id}/${DATA_PREFIX}`);
    rows.push({
      archive: id,
      taken,
      claimed,
      editor,
      days: days.objects,
      bytes: days.bytes,
      firstDay: days.first,
      lastDay: days.last,
      lastWritten: days.written,
    });
  }
  return { count: rows.length, deep, archives: rows };
}

async function archive(env: Store, id: string) {
  const [days, edits, outcomes, taken, key, editor] = await Promise.all([
    walk(env, `${id}/${DATA_PREFIX}`),
    walk(env, `${id}/${EDIT_PREFIX}`),
    walk(env, `${id}/${OUTCOME_PREFIX}`),
    tally(env, takenObject(id), 0),
    env.BLOBS.head(`${id}/key`),
    env.BLOBS.head(`${id}/editor`),
  ]);
  return {
    archive: id,
    exists: days.objects > 0 || key !== null,
    claimed: key !== null,
    claimedAt: key?.uploaded.toISOString(),
    editorRegistered: editor !== null,
    taken,
    used: share(taken, MAX_BUCKET_BYTES),
    days: {
      count: days.objects,
      bytes: days.bytes,
      first: days.first,
      last: days.last,
      lastWritten: days.written,
    },
    editsPending: edits.objects,
    outcomes: outcomes.objects,
  };
}

/**
 * One archive, object by object, as JSON lines.
 *
 * Streamed rather than gathered, because a decade of days is four thousand
 * objects and holding them all at once is how a Worker runs out of memory
 * halfway through the job it was started for. Bodies are base64: a sealed day
 * is not text, and a copy that mangles it is not a copy.
 */
function exportArchive(env: Store, id: string): Response {
  const stream = new ReadableStream({
    async start(controller) {
      const encoder = new TextEncoder();
      const line = (value: unknown) => {
        controller.enqueue(encoder.encode(`${JSON.stringify(value)}\n`));
      };
      try {
        let cursor: string | undefined;
        let objects = 0;
        do {
          const page = await env.BLOBS.list({ prefix: `${id}/`, limit: PAGE, cursor });
          for (const listed of page.objects) {
            const object = await env.BLOBS.get(listed.key);
            if (!object) continue;
            const bytes = new Uint8Array(await object.arrayBuffer());
            let binary = "";
            for (const byte of bytes) binary += String.fromCharCode(byte);
            line({
              key: listed.key,
              size: listed.size,
              uploaded: listed.uploaded.toISOString(),
              body: btoa(binary),
            });
            objects += 1;
          }
          cursor = page.truncated ? page.cursor : undefined;
        } while (cursor);
        line({ done: true, archive: id, objects });
      } catch (error) {
        line({ error: error instanceof Error ? error.message : String(error) });
      }
      controller.close();
    },
  });
  return new Response(stream, {
    headers: { "content-type": "application/x-ndjson; charset=utf-8" },
  });
}

/**
 * Take one archive out of the store.
 *
 * Without `confirm` nothing is deleted and the answer says what would go. That
 * is the form to use first: a deletion request names an archive, and the thing
 * to check before acting on it is that the archive named is the one that
 * exists. `confirm` has to repeat the id, so a deletion cannot be one paste of
 * the wrong line.
 *
 * Each pass lists from the beginning rather than following a cursor: the keys
 * of the previous pass are gone, so the listing starts at what is left. A
 * cursor would point past everything just deleted.
 */
async function remove(env: Store, id: string, confirm: string | null) {
  const before = await archive(env, id);
  if (!before.exists) return { archive: id, deleted: 0, note: "no such archive in this store" };
  if (confirm !== id) {
    return {
      archive: id,
      wouldDelete: before,
      deleted: 0,
      note: `nothing was deleted; repeat the id as ?confirm=${id} to go through with it`,
    };
  }
  let deleted = 0;
  let passes = 0;
  for (; passes < MAX_DELETE_PASSES; passes += 1) {
    const page = await env.BLOBS.list({ prefix: `${id}/`, limit: PAGE });
    if (page.objects.length === 0) break;
    await env.BLOBS.delete(page.objects.map((object) => object.key));
    deleted += page.objects.length;
  }
  const after = await archive(env, id);
  return {
    archive: id,
    deleted,
    passes,
    stillThere: after.exists,
    // The service-wide tally counts bytes handed over, so it does not move.
    note: "the service tally counts bytes handed over and is unchanged by this",
  };
}
