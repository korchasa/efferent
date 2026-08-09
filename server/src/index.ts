/**
 * The bucket service: an append-only store that cannot read what it holds.
 *
 * It does three things — check that a writer is the one who claimed the bucket,
 * keep blobs in sequence order, and hand them back. It never sees a key that
 * decrypts anything, so there is deliberately no code here that could.
 *
 * There are no accounts and no registration. A bucket comes into existence on
 * its first write, and its name already proves who it belongs to.
 */

import {
  DATA_PREFIX,
  isBucketId,
  objectKey,
  parseObjectName,
  signingKeyObject,
} from "../../protocol/ids.ts";
import {
  fromBase64url,
  TIMESTAMP_TOLERANCE_SECONDS,
  type UploadHeader,
  verifyUpload,
} from "../../protocol/signing.ts";

/** Room for a large batch; well under what a Worker can hold in memory. */
const MAX_BODY_BYTES = 4 * 1024 * 1024;
const MAX_OBJECTS_PER_PAGE = 200;

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

    if (request.method === "POST" && segments.length === 2) {
      return await append(request, env, bucket);
    }
    if (request.method === "GET" && segments.length === 3 && segments[2] === "objects") {
      return await listObjects(env, bucket, url);
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

  await env.BLOBS.put(objectKey(bucket, header.seqFrom, header.seqTo), body);
  return json({ ack: header.seqTo });
}

async function listObjects(env: Env, bucket: string, url: URL): Promise<Response> {
  const after = Number(url.searchParams.get("after") ?? "0");
  if (!Number.isSafeInteger(after) || after < 0) {
    return problem(400, "after must be a sequence number");
  }

  const prefix = `${bucket}/${DATA_PREFIX}`;
  const listing = await env.BLOBS.list({ prefix, limit: MAX_OBJECTS_PER_PAGE });

  const objects = listing.objects
    .map((object) => {
      const name = object.key.slice(prefix.length);
      const range = parseObjectName(name);
      return range ? { name, size: object.size, ...range } : null;
    })
    .filter((entry) => entry !== null)
    .filter((entry) => entry.seqTo > after);

  return json({ objects, truncated: listing.truncated });
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
