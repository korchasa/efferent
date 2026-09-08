import { assert, assertEquals, assertRejects } from "@std/assert";
import { bucketId } from "../protocol/ids.ts";
import { base64url } from "../protocol/signing.ts";

// A home of its own, set before the reading layer resolves it: the install
// tests below write real files, and none of them may land in a real reader.
const home = await Deno.makeTempDir({ prefix: "efferent-connection-" });
Deno.env.set("EFFERENT_HOME", home);
const { installConnectionHandoff, parseConnectionHandoff } = await import("./connection.ts");

async function fixture(
  options: { editor?: boolean } = {},
): Promise<{ text: string; bucket: string; editorPublic: string; readOnly: string }> {
  const pair = await crypto.subtle.generateKey({ name: "X25519" }, true, [
    "deriveBits",
  ]) as CryptoKeyPair;
  const privateJWK = await crypto.subtle.exportKey("jwk", pair.privateKey);
  const privateRaw = decode(privateJWK.d!);
  const publicRaw = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
  const bucket = await bucketId(publicRaw);
  const readingKey = `efferent-reading-v1.${base64url(privateRaw)}.${base64url(publicRaw)}`;

  const editor = await crypto.subtle.generateKey({ name: "Ed25519" }, true, [
    "sign",
    "verify",
  ]) as CryptoKeyPair;
  const editorJWK = await crypto.subtle.exportKey("jwk", editor.privateKey);
  const editorPrivate = decode(editorJWK.d!);
  const editorPublic = new Uint8Array(await crypto.subtle.exportKey("raw", editor.publicKey));
  const editorKey = `efferent-editor-v1.${base64url(editorPrivate)}.${base64url(editorPublic)}`;

  const lines = [
    "Instruction:",
    "Connect the supplied Efferent MCP and call setup_guide first. Keep the reading key and the editor key local and never pass either to a remote tool.",
    "",
    "MCP:",
    `https://efferent.example/mcp/b/${bucket}`,
    "",
    "Reading key:",
    readingKey,
  ];
  const readOnly = lines.join("\n");
  if (options.editor) lines.push("", "Editor key:", editorKey);
  return { bucket, editorPublic: base64url(editorPublic), text: lines.join("\n"), readOnly };
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
  // A handoff from before writing existed: the agent can read, not write, and
  // the record says so rather than guessing a key.
  assertEquals(connection.editor, undefined);
});

Deno.test("a fourth field carries the editor key, kept as a local signing key", async () => {
  const { text, editorPublic } = await fixture({ editor: true });

  const connection = await parseConnectionHandoff(text);

  assertEquals(connection.editor?.editorPublic, editorPublic);
  const imported = await crypto.subtle.importKey(
    "pkcs8",
    decode(connection.editor!.editorPrivate) as BufferSource,
    { name: "Ed25519" },
    false,
    ["sign"],
  );
  assertEquals(imported.type, "private");
});

Deno.test("an editor key whose halves do not match is refused", async () => {
  const { text } = await fixture({ editor: true });
  const other = await fixture({ editor: true });
  const wrong = text.replace(
    /(Editor key:\nefferent-editor-v1\.[A-Za-z0-9_-]{43}\.)[A-Za-z0-9_-]{43}/,
    `$1${other.editorPublic}`,
  );

  await assertRejects(() => parseConnectionHandoff(wrong), Error, "editor key");
});

Deno.test("a fresh handoff for the same archive adds the editor key to an existing reader", async () => {
  const { text, readOnly, editorPublic } = await fixture({ editor: true });
  await installConnectionHandoff(readOnly);
  const before = await Deno.readTextFile(`${home}/reading-key.json`);
  await assertRejects(() => Deno.lstat(`${home}/editor-key.json`), Deno.errors.NotFound);

  // The phone learnt to write and handed the same archive over again: the
  // reader keeps its key and its mirror, and gains the one thing it lacked.
  await installConnectionHandoff(text);

  const editor = JSON.parse(await Deno.readTextFile(`${home}/editor-key.json`));
  assertEquals(editor.editorPublic, editorPublic);
  assertEquals(await Deno.readTextFile(`${home}/reading-key.json`), before);

  // A handoff for another archive is still refused: two readers do not share a home.
  const other = await fixture({ editor: true });
  await assertRejects(() => installConnectionHandoff(other.text), Error, "already exists");
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

Deno.test("the phone instruction must bootstrap through setup_guide", async () => {
  const { text } = await fixture();
  const wrong = text.replace("call setup_guide first. ", "");

  await assertRejects(
    () => parseConnectionHandoff(wrong),
    Error,
    "must call setup_guide",
  );
});

function decode(value: string): Uint8Array {
  const binary = atob(value.replaceAll("-", "+").replaceAll("_", "/").padEnd(44, "="));
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}
