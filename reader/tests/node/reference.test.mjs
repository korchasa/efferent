// The Python reference held to the Node client.
//
// `deno task interop` has the phone open an edit the Node client sealed. The
// Python reference seals edits too, and nothing else would notice it drifting,
// so the Node client opens one here: the Python sealing reaches the phone's
// rules through the client the phone already agrees with.

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createPublicKey, verify } from "node:crypto";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { inflateRawSync } from "node:zlib";

import * as wire from "../../efferent.mjs";
import { remove } from "./helpers.mjs";

const READER = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const PYTHON = process.env.EFFERENT_PYTHON || join(READER, ".venv", "bin", "python");

test("an edit the Python reference sealed opens and verifies in the client", () => {
  const scratch = mkdtempSync(join(tmpdir(), "efferent-reference-"));
  try {
    const state = join(scratch, "state.json");
    execFileSync(PYTHON, ["-m", "efferent.interop", "fixture", state], {
      cwd: READER,
      env: { ...process.env, PYTHONPATH: READER },
      stdio: ["ignore", "ignore", "inherit"],
    });
    const made = JSON.parse(
      wire.fromBase64url(JSON.parse(readFileSync(state, "utf8")).fixture).toString(),
    );
    const sealed = wire.fromBase64url(made.sealed);
    const readingPrivate = wire.fromBase64url(made.readingPrivate);
    assert.equal(made.bucket, wire.bucketOf(wire.publicOf("x25519", readingPrivate)));

    const editor = createPublicKey({
      key: Buffer.concat([
        Buffer.from("302a300506032b6570032100", "hex"),
        wire.fromBase64url(made.editor),
      ]),
      format: "der",
      type: "spki",
    });
    assert.ok(verify(
      null,
      Buffer.from(wire.canonicalEdit(made.bucket, made.timestamp, sealed)),
      editor,
      wire.fromBase64url(made.signature),
    ));

    assert.equal(sealed[0], wire.SEALED_VERSION);
    const opened = wire.hpkeOpen(
      readingPrivate,
      wire.INFO,
      wire.editAssociatedData(made.bucket),
      sealed.subarray(1),
    );
    const edit = JSON.parse(inflateRawSync(opened).toString());
    assert.equal(edit.v, wire.EDIT_FORMAT_VERSION);
    assert.deepEqual(wire.validateItems(edit.items), edit.items);
    // Both pack the same items to the same bytes before sealing.
    assert.deepEqual(inflateRawSync(wire.packEdit(edit.items)), inflateRawSync(opened));
  } finally {
    remove(scratch);
  }
});
