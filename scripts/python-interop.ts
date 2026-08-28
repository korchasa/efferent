/** Prove that the exact Python source in setup_guide opens a TypeScript HPKE day. */

import { bucketId } from "../protocol/ids.ts";
import { compress } from "../protocol/framing.ts";
import { base64url } from "../protocol/signing.ts";
import { associatedData, seal } from "../protocol/sealedbox.ts";
import { PYTHON_HPKE_REFERENCE } from "../server/src/python-reference.ts";

const DAY = "2026-08-28";
const plaintext = new TextEncoder().encode(
  '{"id":"agg:steps:2026-08-28:d","v":1,"metric":"steps","value":1234}\n',
);
const pair = await crypto.subtle.generateKey({ name: "X25519" }, true, [
  "deriveBits",
]) as CryptoKeyPair;
const privateJWK = await crypto.subtle.exportKey("jwk", pair.privateKey);
if (!privateJWK.d) throw new Error("WebCrypto did not export the private X25519 fixture");
const privateRaw = Uint8Array.fromBase64(privateJWK.d, { alphabet: "base64url" });
const publicRaw = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
const bucket = await bucketId(publicRaw);
const blob = await seal(publicRaw, await compress(plaintext), associatedData(bucket, DAY));

const server = Deno.serve({ hostname: "127.0.0.1", port: 0, onListen() {} }, (request) => {
  const path = new URL(request.url).pathname;
  if (path !== `/b/${bucket}/d/${DAY}`) return new Response("not found", { status: 404 });
  if (request.headers.get("user-agent") !== "efferent-local-reader/1.0") {
    return new Response("reader user agent required", { status: 403 });
  }
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
    ].join("\n"),
  );
  await Deno.chmod(source, 0o600);
  await Deno.chmod(handoff, 0o600);

  const python = Deno.env.get("EFFERENT_PYTHON") ?? "python3";
  const output = await new Deno.Command(python, {
    args: [source, "--handoff", handoff, "--day", DAY],
    stdout: "piped",
    stderr: "piped",
  }).output();
  if (!output.success) {
    throw new Error(
      `Python reference failed: ${new TextDecoder().decode(output.stderr).trim()}`,
    );
  }
  const opened = output.stdout;
  if (
    !opened.every((byte, index) => byte === plaintext[index]) || opened.length !== plaintext.length
  ) {
    throw new Error("Python reference changed the plaintext");
  }
  console.log(`Python opened the exact HPKE setup-guide fixture: ${plaintext.length} bytes`);
} finally {
  await server.shutdown();
  await Deno.remove(root, { recursive: true });
}
