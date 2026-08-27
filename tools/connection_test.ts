import { assert, assertEquals, assertRejects } from "@std/assert";
import { bucketId } from "../protocol/ids.ts";
import { base64url } from "../protocol/signing.ts";
import { parseConnectionHandoff } from "./connection.ts";

async function fixture(): Promise<{ text: string; bucket: string }> {
  const pair = await crypto.subtle.generateKey({ name: "X25519" }, true, [
    "deriveBits",
  ]) as CryptoKeyPair;
  const privateJWK = await crypto.subtle.exportKey("jwk", pair.privateKey);
  const privateRaw = decode(privateJWK.d!);
  const publicRaw = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
  const bucket = await bucketId(publicRaw);
  const readingKey = `efferent-reading-v1.${base64url(privateRaw)}.${base64url(publicRaw)}`;
  return {
    bucket,
    text: [
      "Instruction:",
      "Connect Efferent. Keep the reading key local and never pass it to a remote tool.",
      "",
      "Prompt:",
      "https://efferent.example/prompts/connect/v1",
      "",
      "MCP:",
      `https://efferent.example/mcp/b/${bucket}`,
      "",
      "Reading key:",
      readingKey,
    ].join("\n"),
  };
}

Deno.test("a phone handoff becomes a local reader configuration", async () => {
  const { text, bucket } = await fixture();

  const connection = await parseConnectionHandoff(text);

  assertEquals(connection.bucket, bucket);
  assertEquals(connection.endpoint, "https://efferent.example");
  assertEquals(connection.mcpURL, `https://efferent.example/mcp/b/${bucket}`);
  assertEquals(connection.reading.readingPublic.length, 43);
  assert(connection.reading.readingPrivate.length > 40);
  const imported = await crypto.subtle.importKey(
    "pkcs8",
    decode(connection.reading.readingPrivate) as BufferSource,
    { name: "X25519" },
    false,
    ["deriveBits"],
  );
  assertEquals(imported.type, "private");
});

Deno.test("a key for another bucket is refused before local state is written", async () => {
  const { text } = await fixture();
  const wrong = text.replace(/\/mcp\/b\/[a-z2-7]{26}/, "/mcp/b/aaaaaaaaaaaaaaaaaaaaaaaaaa");

  await assertRejects(
    () => parseConnectionHandoff(wrong),
    Error,
    "different bucket",
  );
});

Deno.test("a reading key cannot be smuggled into the MCP URL", async () => {
  const { text } = await fixture();
  const wrong = text.replace(/(MCP:\n[^\n]+)/, "$1?reading-key=secret");

  await assertRejects(
    () => parseConnectionHandoff(wrong),
    Error,
    "without a query",
  );
});

function decode(value: string): Uint8Array {
  const binary = atob(value.replaceAll("-", "+").replaceAll("_", "/").padEnd(44, "="));
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}
