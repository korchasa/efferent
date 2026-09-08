/**
 * The edit queue, against an R2 that lives in memory.
 *
 * The service holds an agent's sealed edits until the phone has applied them,
 * and it holds them for exactly one caller: the editor key the phone registered.
 * What is worth testing is who is refused — a stranger, a stale clock, an
 * editor for another bucket — and what the queue does at its edges: when it is
 * full, when the phone answers, when somebody who is not the phone tries to
 * read an edit back. Nothing here opens an edit; nothing here can.
 */

import { assert, assertEquals } from "@std/assert";
import worker, {
  MAX_EDIT_BYTES,
  MAX_EDITS_PER_PAGE,
  MAX_OUTCOME_BYTES,
  MAX_PENDING_EDITS,
} from "./src/index.ts";
import {
  editKey,
  editorKeyObject,
  isEditName,
  outcomeKey,
  SERVICE_TAKEN_OBJECT,
  takenObject,
} from "../protocol/ids.ts";
import {
  base64url,
  canonicalEdit,
  canonicalEditorRegistration,
  canonicalFetch,
  canonicalOutcome,
  signMessage,
} from "../protocol/signing.ts";
import {
  bindings,
  BUCKET,
  type Environment,
  environment,
  owned,
  type Writer,
  writerKey,
} from "./support.ts";

type Editor = { privateKey: CryptoKey; publicRaw: Uint8Array; publicKey: string };

async function editorKey(): Promise<Editor> {
  const pair = await crypto.subtle.generateKey({ name: "Ed25519" }, true, [
    "sign",
    "verify",
  ]) as CryptoKeyPair;
  const publicRaw = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
  return { privateKey: pair.privateKey, publicRaw, publicKey: base64url(publicRaw) };
}

function now(): number {
  return Math.floor(Date.now() / 1000);
}

/** Stand-in for a sealed edit: the HPKE version byte and whatever follows. The
 * service never opens one, so its contents only ever need to be recognisable. */
function sealedEdit(...rest: number[]): Uint8Array {
  return new Uint8Array([2, ...rest]);
}

async function writerHeaders(
  writer: Writer,
  message: string,
  timestamp: number,
): Promise<Record<string, string>> {
  return {
    "x-efferent-timestamp": String(timestamp),
    "x-efferent-writer": writer.publicKey,
    "x-efferent-signature": base64url(await signMessage(writer.privateKey, message)),
  };
}

async function register(
  env: Environment,
  writer: Writer,
  editorPublic: Uint8Array,
  options: { timestamp?: number } = {},
): Promise<Response> {
  const timestamp = options.timestamp ?? now();
  const message = await canonicalEditorRegistration(BUCKET, timestamp, editorPublic);
  return await worker.fetch(
    new Request(`https://example.invalid/b/${BUCKET}/editor`, {
      method: "PUT",
      headers: await writerHeaders(writer, message, timestamp),
      body: editorPublic as BodyInit,
    }),
    bindings(env),
  );
}

async function submit(
  env: Environment,
  editor: Editor,
  body: Uint8Array = sealedEdit(7, 7, 7),
  options: { timestamp?: number; signed?: Uint8Array; bucket?: string; key?: string } = {},
): Promise<Response> {
  const timestamp = options.timestamp ?? now();
  const bucket = options.bucket ?? BUCKET;
  const message = await canonicalEdit(bucket, timestamp, options.signed ?? body);
  return await worker.fetch(
    new Request(`https://example.invalid/b/${BUCKET}/edits`, {
      method: "POST",
      headers: {
        "x-efferent-timestamp": String(timestamp),
        "x-efferent-editor": options.key ?? editor.publicKey,
        "x-efferent-signature": base64url(await signMessage(editor.privateKey, message)),
      },
      body: body as BodyInit,
    }),
    bindings(env),
  );
}

/** Submit and take the name — in a later millisecond than the last one, because
 * two edits taken in the same millisecond share a moment and are ordered by
 * their random tails, which is not an order a test can lean on. */
async function submitted(env: Environment, editor: Editor, body?: Uint8Array): Promise<string> {
  const moment = Date.now();
  while (Date.now() === moment) { /* the next millisecond */ }
  const response = await submit(env, editor, body);
  const text = await response.text();
  assertEquals(response.status, 201, text);
  return (JSON.parse(text) as { name: string }).name;
}

async function fetchEdit(
  env: Environment,
  writer: Writer | null,
  name: string,
): Promise<Response> {
  const timestamp = now();
  return await worker.fetch(
    new Request(`https://example.invalid/b/${BUCKET}/e/${name}`, {
      headers: writer
        ? await writerHeaders(writer, canonicalFetch(BUCKET, name, timestamp), timestamp)
        : {},
    }),
    bindings(env),
  );
}

async function report(
  env: Environment,
  writer: Writer,
  name: string,
  outcome: unknown,
): Promise<Response> {
  const timestamp = now();
  const body = new TextEncoder().encode(
    typeof outcome === "string" ? outcome : JSON.stringify(outcome),
  );
  const message = await canonicalOutcome(BUCKET, name, timestamp, body);
  return await worker.fetch(
    new Request(`https://example.invalid/b/${BUCKET}/e/${name}/outcome`, {
      method: "PUT",
      headers: await writerHeaders(writer, message, timestamp),
      body: body as BodyInit,
    }),
    bindings(env),
  );
}

type Listed = {
  edits: {
    name: string;
    bytes: number;
    at: string;
    status: string;
    applied?: number;
    refused?: number;
  }[];
  next: string | null;
};

async function list(env: Environment, query = ""): Promise<Listed> {
  const response = await worker.fetch(
    new Request(`https://example.invalid/b/${BUCKET}/edits?${query}`),
    bindings(env),
  );
  const text = await response.text();
  assertEquals(response.status, 200, text);
  return JSON.parse(text) as Listed;
}

/** A claimed bucket with an editor registered: where every ordinary test starts. */
async function paired(): Promise<{ env: Environment; writer: Writer; editor: Editor }> {
  const env = environment();
  const writer = await writerKey();
  owned(env, writer);
  const editor = await editorKey();
  assertEquals((await register(env, writer, editor.publicRaw)).status, 201);
  return { env, writer, editor };
}

function tally(env: Environment, key: string): number {
  return Number(new TextDecoder().decode(env.BLOBS.store.get(key)!.body));
}

// MARK: - Registering the editor

Deno.test("the phone registers its editor key, and only after claiming the bucket", async () => {
  const env = environment();
  const writer = await writerKey();
  const editor = await editorKey();

  const early = await register(env, writer, editor.publicRaw);
  assertEquals(early.status, 403);
  assert(((await early.json()) as { error: string }).error.includes("claim"));
  assertEquals(env.BLOBS.store.has(editorKeyObject(BUCKET)), false);

  owned(env, writer);
  assertEquals((await register(env, writer, editor.publicRaw)).status, 201);
  assertEquals([...env.BLOBS.store.get(editorKeyObject(BUCKET))!.body], [...editor.publicRaw]);
  // Again, from a phone that forgot it had: the same answer, one status down.
  assertEquals((await register(env, writer, editor.publicRaw)).status, 200);
});

Deno.test("an editor key is refused when it is not a key", async () => {
  const env = environment();
  const writer = await writerKey();
  owned(env, writer);
  assertEquals((await register(env, writer, new Uint8Array(32))).status, 400);
  assertEquals((await register(env, writer, new Uint8Array(31))).status, 400);
  assertEquals(env.BLOBS.store.has(editorKeyObject(BUCKET)), false);
});

Deno.test("another writer cannot register an editor for this bucket", async () => {
  const env = environment();
  const writer = await writerKey();
  owned(env, writer);
  const stranger = await writerKey();
  assertEquals((await register(env, stranger, (await editorKey()).publicRaw)).status, 403);
});

// MARK: - Submitting an edit

Deno.test("a registered editor's edit is taken, named and counted", async () => {
  const { env, editor } = await paired();
  const response = await submit(env, editor, sealedEdit(1, 2, 3));
  assertEquals(response.status, 201);
  const answer = await response.json() as { name: string; at: string; bytes: number };
  assert(isEditName(answer.name), answer.name);
  assertEquals(answer.bytes, 4);
  const stored = env.BLOBS.store.get(editKey(BUCKET, answer.name))!;
  assertEquals(answer.at, stored.uploaded.toISOString());
  assertEquals([...stored.body], [2, 1, 2, 3]);
  assertEquals(stored.customMetadata!.editor, editor.publicKey);
  assert(stored.customMetadata!.signature.length === 86);
  assert(/^\d+$/.test(stored.customMetadata!.timestamp));
  assertEquals(tally(env, takenObject(BUCKET)), 4);
  assert(tally(env, SERVICE_TAKEN_OBJECT) > 4);
});

Deno.test("edits are refused from anybody but the registered editor", async () => {
  const { env, editor } = await paired();
  const stranger = await editorKey();

  assertEquals((await submit(env, stranger)).status, 403);
  // The right key named, the wrong key signing.
  assertEquals((await submit(env, stranger, undefined, { key: editor.publicKey })).status, 403);
  // The right key signing over other bytes.
  assertEquals(
    (await submit(env, editor, sealedEdit(1), { signed: sealedEdit(2) })).status,
    403,
  );
  // The right key signing for another bucket.
  assertEquals(
    (await submit(env, editor, undefined, { bucket: "anotherbucketidforthistest" })).status,
    403,
  );
  assertEquals(
    [...env.BLOBS.store.keys()].filter((key) => key.includes("/e/")),
    [],
    "nothing was stored",
  );
});

Deno.test("an edit with no editor registered has nowhere to go", async () => {
  const env = environment();
  const writer = await writerKey();
  owned(env, writer);
  assertEquals((await submit(env, await editorKey())).status, 403);
});

Deno.test("a stale edit is refused with the service's clock in the answer", async () => {
  const { env, editor } = await paired();
  const response = await submit(env, editor, undefined, { timestamp: now() - 3600 });
  assertEquals(response.status, 400);
  const answer = await response.json() as { now: number };
  assert(Math.abs(answer.now - now()) < 5);
});

Deno.test("an edit has a weight and a shape", async () => {
  const { env, editor } = await paired();
  assertEquals((await submit(env, editor, new Uint8Array(0))).status, 400);
  assertEquals((await submit(env, editor, new Uint8Array([1, 9, 9]))).status, 400, "version 1");
  const heavy = new Uint8Array(MAX_EDIT_BYTES + 1);
  heavy[0] = 2;
  assertEquals((await submit(env, editor, heavy)).status, 413);
  const heaviest = new Uint8Array(MAX_EDIT_BYTES);
  heaviest[0] = 2;
  assertEquals((await submit(env, editor, heaviest)).status, 201);
});

Deno.test("a full queue takes nothing more until the phone empties it", async () => {
  const { env, writer, editor } = await paired();
  // Written straight into the store: the cap is what is under test, not the
  // road to it.
  for (let index = 0; index < MAX_PENDING_EDITS; index++) {
    env.BLOBS.store.set(
      editKey(BUCKET, `${String(1757228400000 + index).padStart(13, "0")}-aaaaaaaa`),
      {
        body: sealedEdit(1),
        uploaded: new Date(),
        version: 1,
        customMetadata: { editor: editor.publicKey, signature: "x", timestamp: "1" },
      },
    );
  }
  const refused = await submit(env, editor);
  assertEquals(refused.status, 429);
  assert(((await refused.json()) as { error: string }).error.includes(String(MAX_PENDING_EDITS)));

  const first = "1757228400000-aaaaaaaa";
  assertEquals((await report(env, writer, first, { applied: 1, refused: [] })).status, 200);
  assertEquals((await submit(env, editor)).status, 201);
});

Deno.test("an edit counts against the bucket's ceiling like a day does", async () => {
  const { env, editor } = await paired();
  env.BLOBS.store.set(takenObject(BUCKET), {
    body: new TextEncoder().encode(String(512 * 1024 * 1024 - 2)),
    uploaded: new Date(),
    version: 1,
  });
  assertEquals((await submit(env, editor, sealedEdit(1, 2))).status, 507);
  assertEquals((await submit(env, editor, sealedEdit(1))).status, 201);
});

Deno.test("too many edits from one place are turned away before anything is checked", async () => {
  const { env, editor } = await paired();
  env.EDITS.answer = false;
  assertEquals((await submit(env, editor)).status, 429);
  assertEquals(env.EDITS.keys.length, 1);
});

// MARK: - Listing

Deno.test("the queue lists in the order edits were taken, and pages", async () => {
  const { env, editor } = await paired();
  const names: string[] = [];
  for (let index = 0; index < 5; index++) {
    names.push(await submitted(env, editor, sealedEdit(index)));
  }
  assertEquals([...names].sort(), names, "names are made in order");

  const whole = await list(env);
  assertEquals(whole.edits.map((entry) => entry.name), names);
  assertEquals(whole.edits.map((entry) => entry.status), new Array(5).fill("pending"));
  assertEquals(whole.edits[3].bytes, 2);
  assertEquals(whole.next, null);

  const page = await list(env, "limit=2");
  assertEquals(page.edits.map((entry) => entry.name), names.slice(0, 2));
  assertEquals(page.next, names[1]);
  const rest = await list(env, `limit=3&after=${page.next}`);
  assertEquals(rest.edits.map((entry) => entry.name), names.slice(2));
  assertEquals(rest.next, null);
});

Deno.test("a listing refuses a limit and a cursor it cannot mean", async () => {
  const { env } = await paired();
  const bad = async (query: string) => {
    const response = await worker.fetch(
      new Request(`https://example.invalid/b/${BUCKET}/edits?${query}`),
      bindings(env),
    );
    return response.status;
  };
  assertEquals(await bad("limit=0"), 400);
  assertEquals(await bad("limit=x"), 400);
  assertEquals(await bad("after=../key"), 400);
  assertEquals(await bad("status=done"), 400);
  assertEquals((await list(env, `limit=${MAX_EDITS_PER_PAGE * 10}`)).edits, []);
});

// MARK: - The phone reads an edit

Deno.test("only the phone can read an edit back, and it gets the editor's proof with it", async () => {
  const { env, writer, editor } = await paired();
  const name = await submitted(env, editor, sealedEdit(4, 5));

  // Unsigned is malformed, like an unsigned upload; signed by somebody else is refused.
  const unsigned = await fetchEdit(env, null, name);
  assertEquals(unsigned.status, 400);
  const stranger = await fetchEdit(env, await writerKey(), name);
  assertEquals(stranger.status, 403);

  const response = await fetchEdit(env, writer, name);
  assertEquals(response.status, 200);
  assertEquals([...new Uint8Array(await response.arrayBuffer())], [2, 4, 5]);
  assertEquals(response.headers.get("x-efferent-editor"), editor.publicKey);
  assertEquals(response.headers.get("x-efferent-signature")!.length, 86);
  assert(/^\d+$/.test(response.headers.get("x-efferent-timestamp")!));
  assertEquals(response.headers.get("content-type"), "application/octet-stream");

  assertEquals((await fetchEdit(env, writer, "1757228400000-zzzzzzzz")).status, 404);
  assertEquals(
    (await worker.fetch(
      new Request(`https://example.invalid/b/${BUCKET}/e/not-a-name`),
      bindings(env),
    )).status,
    400,
  );
});

// MARK: - The phone answers

Deno.test("an outcome replaces the edit, and the edit is then gone for good", async () => {
  const { env, writer, editor } = await paired();
  const name = await submitted(env, editor, sealedEdit(1, 2, 3));

  const answer = await report(env, writer, name, {
    applied: 2,
    refused: [{ item: 1, code: "badRange" }],
  });
  assertEquals(answer.status, 200, await answer.text());
  assertEquals(env.BLOBS.store.has(editKey(BUCKET, name)), false);
  const outcome = JSON.parse(
    new TextDecoder().decode(env.BLOBS.store.get(outcomeKey(BUCKET, name))!.body),
  );
  assertEquals(outcome.applied, 2);
  assertEquals(outcome.refused, [{ item: 1, code: "badRange" }]);
  assertEquals(outcome.bytes, 4);
  assert(typeof outcome.at === "string");

  assertEquals((await fetchEdit(env, writer, name)).status, 410);
  assertEquals((await list(env)).edits, []);

  // The phone answering twice — a crash after the store took the outcome and
  // before the phone heard — is the ordinary case, not an error.
  const again = await report(env, writer, name, { applied: 3, refused: [] });
  assertEquals(again.status, 200);
  assertEquals((await fetchEdit(env, writer, name)).status, 410);
});

Deno.test("an outcome is refused when it is not one", async () => {
  const { env, writer, editor } = await paired();
  const name = await submitted(env, editor);
  assertEquals((await report(env, writer, name, { applied: 1 })).status, 400);
  assertEquals(
    (await report(env, writer, name, { applied: 1, refused: [{ item: 0, code: "steps" }] })).status,
    400,
  );
  assertEquals((await report(env, writer, name, "not json")).status, 400);
  assertEquals(
    (await report(env, writer, name, {
      applied: 1,
      refused: [],
      note: "x".repeat(MAX_OUTCOME_BYTES),
    }))
      .status,
    413,
  );
  assertEquals(
    (await report(env, await writerKey(), name, { applied: 1, refused: [] })).status,
    403,
  );
  assertEquals(
    (await report(env, writer, "1757228400000-zzzzzzzz", { applied: 1, refused: [] })).status,
    404,
  );
  assert(env.BLOBS.store.has(editKey(BUCKET, name)), "the edit is still waiting");
});

Deno.test("a listing of everything tells applied from failed from pending", async () => {
  const { env, writer, editor } = await paired();
  const done = await submitted(env, editor, sealedEdit(1));
  const failed = await submitted(env, editor, sealedEdit(2));
  const partial = await submitted(env, editor, sealedEdit(3));
  const waiting = await submitted(env, editor, sealedEdit(4));
  assertEquals((await report(env, writer, done, { applied: 2, refused: [] })).status, 200);
  assertEquals(
    (await report(env, writer, failed, {
      applied: 0,
      refused: [{ item: 0, code: "unknownMetric" }],
    }))
      .status,
    200,
  );
  assertEquals(
    (await report(env, writer, partial, { applied: 1, refused: [{ item: 1, code: "badUnit" }] }))
      .status,
    200,
  );

  const pending = await list(env);
  assertEquals(pending.edits.map((entry) => entry.name), [waiting]);

  const all = await list(env, "status=all");
  assertEquals(
    all.edits.map((entry) => [entry.name, entry.status, entry.applied, entry.refused]),
    [
      [done, "applied", 2, 0],
      [failed, "failed", 0, 1],
      [partial, "partial", 1, 1],
      [waiting, "pending", undefined, undefined],
    ],
  );
  assertEquals(all.edits[0].bytes, 2);
  assertEquals(all.next, null);

  // Paging over both kinds at once loses nothing.
  const first = await list(env, "status=all&limit=3");
  assertEquals(first.edits.map((entry) => entry.name), [done, failed, partial]);
  assertEquals(first.next, partial);
  const second = await list(env, `status=all&limit=3&after=${first.next}`);
  assertEquals(second.edits.map((entry) => entry.name), [waiting]);
  assertEquals(second.next, null);
});

Deno.test("the whole of an outcome can be read back by name", async () => {
  const { env, writer, editor } = await paired();
  const name = await submitted(env, editor);
  assertEquals(
    (await report(env, writer, name, { applied: 0, refused: [{ item: 0, code: "unauthorized" }] }))
      .status,
    200,
  );
  const response = await worker.fetch(
    new Request(`https://example.invalid/b/${BUCKET}/o/${name}`),
    bindings(env),
  );
  assertEquals(response.status, 200);
  const outcome = await response.json() as { applied: number; refused: { code: string }[] };
  assertEquals(outcome.applied, 0);
  assertEquals(outcome.refused[0].code, "unauthorized");
  assertEquals(
    (await worker.fetch(
      new Request(`https://example.invalid/b/${BUCKET}/o/1757228400000-zzzzzzzz`),
      bindings(env),
    )).status,
    404,
  );
});
