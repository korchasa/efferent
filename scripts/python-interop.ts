/**
 * Prove that the exact Python source in setup_guide agrees with `protocol/`
 * both ways: it opens a TypeScript-sealed day, and the edit it seals and signs
 * is one TypeScript opens and verifies.
 */

import { bucketId } from "../protocol/ids.ts";
import { compress } from "../protocol/framing.ts";
import { base64url, canonicalEdit, verifyMessage } from "../protocol/signing.ts";
import { associatedData, open, rawPrivateKey, seal } from "../protocol/sealedbox.ts";
import { editAssociatedData, type EditItem, unpackEdits } from "../protocol/edits.ts";
import { PYTHON_HPKE_REFERENCE } from "../server/src/python-reference.ts";

const DAY = "2026-08-28";
const EDIT_NAME = "1767300000000-abcdefgh";
const ITEMS: EditItem[] = [
  {
    op: "put",
    id: "agent:meal:2026-08-28:lunch",
    metric: "dietaryEnergy",
    start: 1_756_382_400,
    end: 1_756_384_200,
    value: 640,
    unit: "kcal",
  },
  {
    op: "put",
    id: "agent:sleep:2026-08-27:core",
    metric: "sleep",
    start: 1_756_332_000,
    end: 1_756_357_200,
    stage: "asleepCore",
  },
  { op: "delete", id: "agent:meal:2026-08-20:dinner" },
];
const plaintext = new TextEncoder().encode(
  '{"id":"agg:steps:2026-08-28:d","v":1,"metric":"steps","value":1234}\n',
);
const pair = await crypto.subtle.generateKey({ name: "X25519" }, true, [
  "deriveBits",
]) as CryptoKeyPair;
const privateJWK = await crypto.subtle.exportKey("jwk", pair.privateKey);
if (!privateJWK.d) throw new Error("WebCrypto did not export the private X25519 fixture");
const privateRaw = Uint8Array.fromBase64(privateJWK.d, { alphabet: "base64url" });
const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
const publicRaw = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
const bucket = await bucketId(publicRaw);
const blob = await seal(publicRaw, await compress(plaintext), associatedData(bucket, DAY));

// The editor key the phone would have handed over beside the reading key.
const editor = await crypto.subtle.generateKey({ name: "Ed25519" }, true, [
  "sign",
  "verify",
]) as CryptoKeyPair;
const editorJWK = await crypto.subtle.exportKey("jwk", editor.privateKey);
if (!editorJWK.d) throw new Error("WebCrypto did not export the private Ed25519 fixture");
const editorPrivate = Uint8Array.fromBase64(editorJWK.d, { alphabet: "base64url" });
const editorPublic = new Uint8Array(await crypto.subtle.exportKey("raw", editor.publicKey));

/** What the Python side handed the stand-in service, kept for the check below. */
let taken: { headers: Headers; body: Uint8Array } | null = null;

const server = Deno.serve({ hostname: "127.0.0.1", port: 0, onListen() {} }, async (request) => {
  const path = new URL(request.url).pathname;
  if (request.headers.get("user-agent") !== "efferent-local-reader/1.0") {
    return new Response("reader user agent required", { status: 403 });
  }
  if (path === `/b/${bucket}/edits` && request.method === "POST") {
    taken = { headers: request.headers, body: new Uint8Array(await request.arrayBuffer()) };
    return Response.json(
      { name: EDIT_NAME, at: "2026-08-28T12:00:00.000Z", bytes: taken.body.length },
      { status: 201 },
    );
  }
  if (path === `/b/${bucket}/edits` && request.method === "GET") {
    return Response.json({
      edits: [{
        name: EDIT_NAME,
        bytes: taken?.body.length ?? 0,
        at: "2026-08-28T12:00:00.000Z",
        status: "pending",
      }],
      next: null,
    });
  }
  if (path !== `/b/${bucket}/d/${DAY}`) return new Response("not found", { status: 404 });
  if (request.headers.get("accept") !== "application/octet-stream") {
    return new Response("sealed-day media type required", { status: 406 });
  }
  return new Response(blob.slice().buffer, {
    headers: { "content-type": "application/octet-stream" },
  });
});
const address = server.addr as Deno.NetAddr;
const root = await Deno.makeTempDir({ prefix: "efferent-python-interop-" });

try {
  const source = `${root}/efferent_hpke.py`;
  const handoff = `${root}/handoff.txt`;
  await Deno.writeTextFile(source, PYTHON_HPKE_REFERENCE);
  await Deno.writeTextFile(
    handoff,
    [
      "Instruction:",
      "Connect the supplied Efferent MCP and call setup_guide first. Keep the reading key local and never pass it to a remote tool.",
      "",
      "MCP:",
      `http://127.0.0.1:${address.port}/mcp/b/${bucket}`,
      "",
      "Reading key:",
      `efferent-reading-v1.${base64url(privateRaw)}.${base64url(publicRaw)}`,
      "",
      "Editor key:",
      `efferent-editor-v1.${base64url(editorPrivate)}.${base64url(editorPublic)}`,
    ].join("\n"),
  );
  await Deno.chmod(source, 0o600);
  await Deno.chmod(handoff, 0o600);

  const python = Deno.env.get("EFFERENT_PYTHON") ?? "python3";
  const reference = async (...args: string[]): Promise<Uint8Array> => {
    const output = await new Deno.Command(python, {
      args: [source, "--handoff", handoff, ...args],
      stdout: "piped",
      stderr: "piped",
    }).output();
    if (!output.success) {
      throw new Error(
        `Python reference failed on ${args[0]}: ${new TextDecoder().decode(output.stderr).trim()}`,
      );
    }
    return output.stdout;
  };

  const opened = await reference("--day", DAY);
  if (
    !opened.every((byte, index) => byte === plaintext[index]) || opened.length !== plaintext.length
  ) {
    throw new Error("Python reference changed the plaintext");
  }
  console.log(`Python opened the exact HPKE setup-guide fixture: ${plaintext.length} bytes`);

  // The other direction: Python seals and signs an edit, and TypeScript — which
  // is what the phone's checks are tested against — verifies and opens it.
  const items = `${root}/items.json`;
  await Deno.writeTextFile(items, JSON.stringify(ITEMS));
  const answer = JSON.parse(new TextDecoder().decode(await reference("--write", items)));
  if (answer.name !== EDIT_NAME) throw new Error(`Python printed ${JSON.stringify(answer)}`);
  if (!taken) throw new Error("the Python reference posted nothing");
  const { headers, body } = taken as { headers: Headers; body: Uint8Array };

  if (headers.get("x-efferent-editor") !== base64url(editorPublic)) {
    throw new Error("the edit names an editor other than the handoff's");
  }
  const timestamp = Number(headers.get("x-efferent-timestamp"));
  if (Math.abs(timestamp - Date.now() / 1000) > 60) throw new Error("the timestamp is not now");
  const signature = Uint8Array.fromBase64(headers.get("x-efferent-signature") ?? "", {
    alphabet: "base64url",
  });
  if (!await verifyMessage(editorPublic, signature, await canonicalEdit(bucket, timestamp, body))) {
    throw new Error("Python's editor signature does not verify over the canonical message");
  }
  const unpacked = await unpackEdits(
    await open(await rawPrivateKey(pkcs8), publicRaw, body, editAssociatedData(bucket)),
  );
  if (JSON.stringify(unpacked) !== JSON.stringify(ITEMS)) {
    throw new Error(
      `the items came out different:\n  in  ${JSON.stringify(ITEMS)}\n  out ${
        JSON.stringify(unpacked)
      }`,
    );
  }
  console.log(`TypeScript opened and verified the edit Python sealed: ${body.length} bytes`);

  const listed = new TextDecoder().decode(await reference("--edits"));
  if (!listed.includes(EDIT_NAME) || !listed.includes("pending")) {
    throw new Error(`the Python listing did not name the edit: ${listed}`);
  }
  console.log("Python listed it back");
} finally {
  await server.shutdown();
  await Deno.remove(root, { recursive: true });
}
