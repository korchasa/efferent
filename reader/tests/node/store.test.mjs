// The profile kept on this machine: importing a handoff, the files and their
// modes, and reading a profile the Python reader made. Ported from
// tests/test_connection.py and tests/test_permissions.py.

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createPrivateKey } from "node:crypto";
import { existsSync, mkdtempSync, readFileSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, beforeEach, describe, test } from "node:test";

import * as wire from "../../efferent.mjs";
import { editorPair, handoff, readingPair, remove, within } from "./helpers.mjs";

const READER = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const PYTHON = process.env.EFFERENT_PYTHON || join(READER, ".venv", "bin", "python");

let root;
let home;

beforeEach(() => {
  // A home of its own per test: these write real files, and none may land in
  // a real reader. A directory that does not exist yet, so its mode is ours.
  root = mkdtempSync(join(tmpdir(), "efferent-store-"));
  home = join(root, "reader");
});

afterEach(() => remove(root));

const mode = (path) => statSync(path).mode & 0o777;

function fixture(editor = false) {
  const reading = readingPair();
  const writing = editorPair();
  const text = handoff(reading, editor ? writing : null);
  return {
    reading,
    bucket: wire.bucketOf(reading.publicRaw),
    editorPublic: wire.toBase64url(writing.publicRaw),
    text,
    readOnly: handoff(reading, null),
  };
}

describe("Parsing a handoff", () => {
  test("a phone handoff becomes a local reader configuration", () => {
    const made = fixture();
    const connection = wire.parseConnectionHandoff(made.text);
    assert.equal(connection.bucket, made.bucket);
    assert.equal(connection.endpoint, "https://efferent.example");
    assert.equal(connection.mcpURL, `https://efferent.example/mcp/b/${made.bucket}`);
    assert.equal(connection.reading.readingPublic.length, 43);
    const imported = createPrivateKey({
      key: wire.fromBase64url(connection.reading.readingPrivate),
      format: "der",
      type: "pkcs8",
    });
    assert.equal(imported.asymmetricKeyType, "x25519");
    // A handoff from before writing existed: the record says so rather than
    // guessing a key.
    assert.equal("editor" in connection, false);
  });

  test("a fourth field carries the editor key", () => {
    const made = fixture(true);
    const connection = wire.parseConnectionHandoff(made.text);
    assert.equal(connection.editor.editorPublic, made.editorPublic);
    const imported = createPrivateKey({
      key: wire.fromBase64url(connection.editor.editorPrivate),
      format: "der",
      type: "pkcs8",
    });
    assert.equal(imported.asymmetricKeyType, "ed25519");
  });

  test("an editor key whose halves do not match is refused", () => {
    const made = fixture(true);
    const wrong = made.text.replace(made.editorPublic, fixture(true).editorPublic);
    assert.throws(() => wire.parseConnectionHandoff(wrong), /editor key/);
  });

  test("a key for another bucket is refused", () => {
    const made = fixture();
    assert.throws(
      () => wire.parseConnectionHandoff(made.text.replace(made.bucket, "a".repeat(26))),
      /different bucket/,
    );
  });

  test("a reading key cannot be smuggled into the MCP URL", () => {
    const made = fixture();
    const wrong = made.text.replace(
      `/mcp/b/${made.bucket}`,
      `/mcp/b/${made.bucket}?reading-key=secret`,
    );
    assert.throws(() => wire.parseConnectionHandoff(wrong), /without a query/);
  });

  test("the instruction must bootstrap through setup_guide", () => {
    const wrong = fixture().text.replaceAll("setup_guide", "some_tool");
    assert.throws(() => wire.parseConnectionHandoff(wrong), /must call setup_guide/);
  });
});

describe("Installing a handoff", () => {
  test("a fresh handoff for the same archive adds the editor key", async () => {
    await within(home, () => {
      const made = fixture(true);
      wire.installConnectionHandoff(made.readOnly);
      const before = readFileSync(join(home, "reading-key.json"), "utf8");
      assert.equal(existsSync(join(home, "editor-key.json")), false);

      // The phone learnt to write and handed the same archive over again: the
      // reader keeps its key and its mirror, and gains the one thing it lacked.
      wire.installConnectionHandoff(made.text);
      const editor = JSON.parse(readFileSync(join(home, "editor-key.json"), "utf8"));
      assert.equal(editor.editorPublic, made.editorPublic);
      assert.equal(readFileSync(join(home, "reading-key.json"), "utf8"), before);

      // A handoff for another archive is still refused: two readers do not
      // share a home.
      assert.throws(() => wire.installConnectionHandoff(fixture(true).text), /already exists/);
    });
  });

  test("an installed handoff records the endpoint and an empty mirror", async () => {
    await within(home, () => {
      const made = fixture();
      wire.installConnectionHandoff(made.text);
      assert.deepEqual(JSON.parse(readFileSync(join(home, "mirror.json"), "utf8")), {
        endpoint: "https://efferent.example",
        days: {},
        syncedAt: "",
      });
    });
  });
});

describe("Permissions", () => {
  test("the reader keeps its directory and plaintext private", async () => {
    await within(home, () => {
      wire.write("mirror.json", { endpoint: "https://efferent.example", days: {} });
      // The kept metric record goes down the same path but compactly, and it
      // holds the same kind of thing: which metrics this person records.
      wire.write("metrics.json", { "2026-08-27": { v: "1:2" } }, true);
      wire.writeDay("2026-08-27", [{ id: "sample", v: 1 }]);
      wire.write("editor-key.json", { editorPrivate: "x", editorPublic: "y" });
      wire.write("edits.json", [{ name: "1757228400000-abcdefgh", at: "", items: [] }]);
    });
    assert.equal(mode(home), 0o700);
    assert.equal(mode(join(home, "mirror.json")), 0o600);
    assert.equal(mode(join(home, "metrics.json")), 0o600);
    assert.equal(mode(join(home, "days")), 0o700);
    assert.equal(mode(join(home, "days", "2026-08-27.ndjson")), 0o600);
    assert.equal(mode(join(home, "editor-key.json")), 0o600);
    assert.equal(mode(join(home, "edits.json")), 0o600);
  });

  test("nothing is left behind half written", async () => {
    await within(home, () => {
      wire.write("mirror.json", { endpoint: "x", days: {} });
      wire.writeDay("2026-08-27", []);
    });
    assert.equal(existsSync(join(home, "mirror.json.partial")), false);
    assert.equal(existsSync(join(home, "days", "2026-08-27.partial")), false);
  });
});

describe("A profile the Python reader made", () => {
  test("its reading key opens what was sealed to its public half", async () => {
    // The Python reader writes the key; Node reads it back without migration.
    execFileSync(PYTHON, ["-m", "efferent", "keygen"], {
      cwd: READER,
      env: { ...process.env, EFFERENT_HOME: home },
      stdio: ["ignore", "ignore", "inherit"],
    });
    await within(home, () => {
      const stored = wire.load("reading-key.json");
      const secret = wire.rawPrivate(stored.readingPrivate);
      const publicRaw = wire.fromBase64url(stored.readingPublic);
      assert.deepEqual(wire.publicOf("x25519", secret), publicRaw);
      const sealed = wire.hpkeSeal(
        publicRaw,
        wire.INFO,
        Buffer.from("aad"),
        Buffer.from("the day"),
      );
      assert.equal(
        wire.hpkeOpen(secret, wire.INFO, Buffer.from("aad"), sealed).toString(),
        "the day",
      );
      // And Node's own encoding of the key is the very string Python wrote.
      assert.equal(wire.pkcs8("x25519", secret), stored.readingPrivate);
    });
  });

  test("a day's fingerprint is the one Python computes for the same file", async () => {
    await within(home, () => wire.writeDay("2026-08-27", [{ id: "sample", v: 1, value: 3 }]));
    const path = join(home, "days", "2026-08-27.ndjson");
    const python = execFileSync(
      PYTHON,
      [
        "-c",
        "import os,sys; s=os.stat(sys.argv[1]); print(f'{s.st_size}:{s.st_mtime_ns // 1_000_000}')",
        path,
      ],
      { encoding: "utf8" },
    ).trim();
    await within(home, () => assert.equal(wire.mirrorVersions()["2026-08-27"], python));
  });
});
