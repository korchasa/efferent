// The MCP server, spoken to the way an agent speaks to it. Ported from
// tests/test_mcp.py.
//
// The fixture is a real mirror — a reading key, a `mirror.json` and day files —
// pointed at an address nothing answers on. That is deliberate: it exercises
// the path a laptop on a train takes, where the archive is unreachable and the
// answer has to come out of the mirror with a warning attached.

import assert from "node:assert/strict";
import { createPublicKey, verify } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, beforeEach, describe, test } from "node:test";
import { inflateRawSync } from "node:zlib";

import * as wire from "../../efferent.mjs";
import { cli, editorPair, makeHome, remove, within, writeMirroredDay } from "./helpers.mjs";

/** Nothing listens on port 9, so every call to the archive fails at once. */
const UNREACHABLE = "http://127.0.0.1:9";

const MEAL = {
  op: "put",
  id: "agent:meal:2026-01-01:lunch",
  metric: "dietaryEnergy",
  start: 1_767_268_800,
  end: 1_767_270_600,
  value: 640,
  unit: "kcal",
};
const NAP = {
  op: "put",
  id: "agent:sleep:2026-01-01:nap",
  metric: "sleep",
  start: 1_767_276_000,
  end: 1_767_279_600,
  stage: "asleepCore",
};

const total = (metric, on, value) => ({
  id: `agg:${metric}:${on}:d`,
  v: 1,
  metric,
  bucket: "day",
  value,
  unit: "count",
  start: `${on}T00:00:00Z`,
  end: `${on}T23:59:59Z`,
});
const reading = (metric, at, value, unit) => ({
  id: `hk:${metric}:${at}`,
  v: 1,
  metric,
  value,
  unit,
  start: at,
  end: at,
});
const asleep = (start, end) => ({
  id: `hk:sleep:${start}`,
  v: 1,
  metric: "sleep",
  stage: "asleepCore",
  start,
  end,
});

let home;
let keys;
let reader;
const realTransport = wire.io.transport;

function seed() {
  writeMirroredDay(home, "2026-01-01", [
    total("steps", "2026-01-01", 8000),
    total("flightsClimbed", "2026-01-01", 12),
    // An hourly bucket for the same day, which must never reach a daily table.
    {
      id: "agg:steps:h",
      v: 1,
      metric: "steps",
      bucket: "hour",
      value: 400,
      unit: "count",
      start: "2026-01-01T09:00:00Z",
      end: "2026-01-01T10:00:00Z",
    },
    reading("heartRate", "2026-01-01T09:00:00Z", 60, "count/min"),
    reading("heartRate", "2026-01-01T10:00:00Z", 80, "count/min"),
    asleep("2026-01-01T22:00:00Z", "2026-01-02T00:00:00Z"),
    // The same stretch again from a second source: merged, never added.
    asleep("2026-01-01T22:30:00Z", "2026-01-01T23:30:00Z"),
    {
      id: "hk:workout:1",
      v: 1,
      metric: "workout",
      activity: "52",
      duration: 1800,
      start: "2026-01-01T12:00:00Z",
      end: "2026-01-01T12:30:00Z",
    },
  ]);
  writeMirroredDay(home, "2026-01-02", [
    total("steps", "2026-01-02", 3000),
    // Two readings that do not agree on their fields: the second names no
    // device. A column list written by hand would drop it.
    {
      id: "hk:respiratoryRate:1",
      v: 1,
      metric: "respiratoryRate",
      value: 14,
      unit: "count/min",
      source: "a watch",
      start: "2026-01-02T03:00:00Z",
      end: "2026-01-02T03:00:00Z",
    },
    {
      id: "hk:respiratoryRate:2",
      v: 1,
      metric: "respiratoryRate",
      value: 16,
      unit: "count/min",
      start: "2026-01-02T04:00:00Z",
      end: "2026-01-02T04:00:00Z",
    },
    asleep("2026-01-02T00:00:00Z", "2026-01-02T06:00:00Z"),
    reading("heartRate", "2026-01-02T09:00:00Z", 70, "count/min"),
  ]);
}

beforeEach(() => {
  ({ home, ...keys } = makeHome({ endpoint: UNREACHABLE, editor: null }));
  seed();
  // The server keeps one reader across a session; each test gets its own.
  reader = new wire.Reader();
});

afterEach(() => {
  wire.io.transport = realTransport;
  remove(home);
});

const bucket = () => wire.bucketOf(keys.reading.publicRaw);

function seedEditor() {
  const pair = editorPair();
  const editor = {
    editorPrivate: wire.pkcs8("ed25519", pair.secret),
    editorPublic: wire.toBase64url(pair.publicRaw),
  };
  writeFileSync(join(home, "editor-key.json"), JSON.stringify(editor));
  return editor;
}

const rpc = (method, params = undefined) =>
  within(home, () => wire.handle({ jsonrpc: "2.0", id: 1, method, params }, reader));

async function call(name, args = {}) {
  const answer = await rpc("tools/call", { name, arguments: args });
  const text = answer.result.content[0].text;
  let body = null;
  try {
    body = JSON.parse(text);
  } catch {
    body = null;
  }
  return { isError: answer.result.isError === true, text, body };
}

const reply = (status, body) => ({ status, body: Buffer.from(JSON.stringify(body)), headers: {} });

describe("Handshake", () => {
  test("initialize answers in the version it was asked for", async () => {
    const { result } = await rpc("initialize", { protocolVersion: "2024-11-05" });
    assert.equal(result.protocolVersion, "2024-11-05");
    assert.equal(result.serverInfo.name, "efferent");
    assert.ok(result.capabilities.tools, "tools were not offered");
    assert.match(result.instructions, /phone_data_overview/);
  });

  test("a version this server does not speak falls back", async () => {
    assert.equal(
      (await rpc("initialize", { protocolVersion: "1999-01-01" })).result.protocolVersion,
      "2025-06-18",
    );
  });

  test("a notification is not answered", async () => {
    assert.equal(
      await wire.handle({ jsonrpc: "2.0", method: "notifications/initialized" }, reader),
      null,
    );
  });

  test("every tool arrives with a schema and a description", async () => {
    const { tools } = (await rpc("tools/list")).result;
    assert.equal(tools.length, 9);
    for (const tool of tools) {
      assert.ok(
        tool.description.length > 100,
        `${tool.name} is described too thinly to use unprompted`,
      );
      assert.ok(tool.inputSchema, `${tool.name} has no schema`);
    }
  });

  test("the tool list is the public contract, byte for byte", async () => {
    // tests/node/tools.json is what the Python server listed: names,
    // descriptions and schemas are what every registered agent already reads.
    const contract = JSON.parse(readFileSync(new URL("./tools.json", import.meta.url), "utf8"));
    assert.deepEqual((await rpc("tools/list")).result.tools, contract.tools);
    assert.equal((await rpc("initialize")).result.instructions, contract.instructions);
  });

  test("an unknown tool is a failed call, not a broken connection", async () => {
    const answer = await call("phone_data_horoscope");
    assert.equal(answer.isError, true);
    assert.match(answer.text, /no such tool/);
  });

  test("an unknown method is an error, and a ping is answered", async () => {
    assert.equal((await rpc("resources/list")).error.code, -32601);
    assert.deepEqual((await rpc("ping")).result, {});
  });
});

describe("Answers", () => {
  test("a daily table takes the daily buckets and leaves the hourly ones", async () => {
    const answer = await call("phone_data_daily", { since: "2026-01-01", until: "2026-01-02" });
    assert.equal(answer.body.columns[0], "day");
    assert.deepEqual(answer.body.rows.map((row) => [row[0], row[1]]), [["2026-01-01", 8000], [
      "2026-01-02",
      3000,
    ]]);
  });

  test("a night is whole, merged and named by the evening", async () => {
    const answer = await call("phone_data_sleep", { since: "2026-01-01", until: "2026-01-01" });
    assert.equal(answer.body.rows.length, 1);
    assert.equal(answer.body.rows[0].night, "2026-01-01");
    // 22:00 to 06:00 across two day files, with an overlap inside it.
    assert.equal(answer.body.rows[0].asleepHours, 8);
  });

  test("statistics describe readings without handing any over", async () => {
    const answer = await call("phone_data_statistics", {
      metric: "heartRate",
      since: "2026-01-01",
      until: "2026-01-02",
      group_by: "day",
    });
    assert.equal(answer.body.rows.length, 2);
    assert.deepEqual(answer.body.rows[0], {
      group: "2026-01-01",
      n: 2,
      min: 60,
      p10: 62,
      median: 70,
      mean: 70,
      p90: 78,
      max: 80,
      sum: 140,
    });
    assert.deepEqual(Object.keys(answer.body), [
      "warning",
      "metric",
      "unit",
      "over",
      "groupBy",
      "rows",
    ]);
  });

  test("a workout is reported by its activity and summed by it", async () => {
    const answer = await call("phone_data_workouts", { since: "2026-01-01", until: "2026-01-02" });
    assert.equal(answer.body.total, 1);
    assert.deepEqual(answer.body.byActivity, { walking: { count: 1, minutes: 30 } });
  });

  test("blood oxygen answers carry the warning about its unit", async () => {
    const answer = await call("phone_data_samples", {
      metric: "oxygenSaturation",
      since: "2026-01-01",
      until: "2026-01-02",
    });
    assert.match(answer.body.unitNote, /0\.97 means 97%/);
  });

  test("a daily table answers the metrics an agent can write", async () => {
    const answer = await call("phone_data_daily", {
      metrics: ["dietaryEnergy", "dietaryProtein"],
      since: "2026-01-01",
      until: "2026-01-01",
    });
    assert.equal(answer.isError, false, answer.text);
    assert.deepEqual(answer.body.columns, ["day", "dietaryEnergy", "dietaryProtein"]);
  });

  test("the overview reads the mirror and says it could not ask the archive", async () => {
    const answer = await call("phone_data_overview");
    assert.equal(answer.body.archive, "unreachable");
    assert.equal(answer.body.readable.days, 2);
    assert.equal(answer.body.readable.note, "the archive could not be asked what it holds");
    assert.ok(answer.body.metrics.some((entry) => entry.metric === "heartRate"));
  });
});

describe("Refusals", () => {
  test("a malformed day is refused with the correction", async () => {
    const answer = await call("phone_data_daily", { since: "last tuesday" });
    assert.equal(answer.isError, true);
    assert.match(answer.text, /YYYY-MM-DD/);
  });

  test("a range too long for a daily table is refused, not truncated", async () => {
    const answer = await call("phone_data_daily", { since: "2020-01-01", until: "2026-01-01" });
    assert.equal(answer.isError, true);
    assert.match(answer.text, /phone_data_statistics/);
  });

  test("a range that runs backwards is refused", async () => {
    const answer = await call("phone_data_daily", { since: "2026-02-01", until: "2026-01-01" });
    assert.equal(answer.isError, true);
    assert.match(answer.text, /after/);
  });

  test("an unreachable archive still answers and says it is behind", async () => {
    const answer = await call("phone_data_daily", { since: "2026-01-01", until: "2026-01-02" });
    assert.match(answer.body.warning, /could not be reached/);
  });
});

describe("Shape", () => {
  test("readings come as a table with what they agree on said once", async () => {
    const answer = await call("phone_data_samples", {
      metric: "heartRate",
      since: "2026-01-01",
      until: "2026-01-02",
    });
    assert.deepEqual(answer.body.sameOnEveryRow, { unit: "count/min", v: 1 });
    assert.deepEqual(answer.body.columns, ["start", "end", "value"]);
    assert.deepEqual(answer.body.rows, [
      ["2026-01-01T09:00:00Z", "2026-01-01T09:00:00Z", 60],
      ["2026-01-01T10:00:00Z", "2026-01-01T10:00:00Z", 80],
      ["2026-01-02T09:00:00Z", "2026-01-02T09:00:00Z", 70],
    ]);
  });

  test("a field only some readings carry becomes a column", async () => {
    const answer = await call("phone_data_samples", {
      metric: "respiratoryRate",
      since: "2026-01-02",
      until: "2026-01-02",
    });
    assert.ok(answer.body.columns.includes("source"), "a field one reading carried was lost");
    assert.equal("source" in answer.body.sameOnEveryRow, false);
    const at = answer.body.columns.indexOf("source");
    assert.deepEqual(answer.body.rows.map((row) => row[at]), ["a watch", null]);
  });

  test("the derived identifier is not carried and nothing else is lost", async () => {
    const answer = await call("phone_data_samples", {
      metric: "heartRate",
      since: "2026-01-01",
      until: "2026-01-01",
    });
    const carried = new Set([...answer.body.columns, ...Object.keys(answer.body.sameOnEveryRow)]);
    assert.equal(carried.has("id"), false, "the identifier came back after all");
    for (const field of ["v", "start", "end", "value", "unit"]) {
      assert.ok(carried.has(field), field);
    }
  });

  test("workouts come as a table too and the counts are over all of them", async () => {
    const answer = await call("phone_data_workouts", { since: "2026-01-01", until: "2026-01-02" });
    assert.deepEqual(answer.body.sameOnEveryRow, {});
    const at = answer.body.columns.indexOf("activity");
    assert.equal(answer.body.rows.length, 1);
    assert.equal(answer.body.rows[0][at], "walking");
    assert.deepEqual(answer.body.byActivity, { walking: { count: 1, minutes: 30 } });
  });

  test("an answer is written without indentation", async () => {
    const answer = await call("phone_data_daily", { since: "2026-01-01", until: "2026-01-02" });
    assert.equal(answer.text.includes("\n"), false, "the answer came back laid out");
  });
});

describe("Writing", () => {
  test("the overview names what an agent may write, with the unit", async () => {
    const { writable } = (await call("phone_data_overview")).body;
    assert.deepEqual(writable.dietaryEnergy, { kind: "quantity", unit: "kcal" });
    assert.deepEqual(writable.bodyMass, { kind: "quantity", unit: "kg" });
    assert.equal(writable.sleep.kind, "category");
    assert.ok(writable.sleep.stages.includes("asleepREM"));
  });

  test("a handoff from before writing cannot write and says so", async () => {
    const answer = await call("phone_data_write", { items: [MEAL] });
    assert.equal(answer.isError, true);
    assert.match(answer.text, /editor key/);
  });

  test("an item that is wrong is refused before anything is sealed", async () => {
    seedEditor();
    let posted = 0;
    wire.io.transport = () => {
      posted += 1;
      return reply(500, {});
    };
    const answer = await call("phone_data_write", { items: [{ ...MEAL, unit: "kJ" }] });
    assert.equal(answer.isError, true);
    assert.match(answer.text, /item 0/);
    assert.match(answer.text, /kcal/);
    assert.equal(posted, 0);
  });

  test("an edit is sealed, signed and posted", async () => {
    const editor = seedEditor();
    const taken = {};
    wire.io.transport = (method, url, headers, body) => {
      Object.assign(taken, { method, url, headers, body });
      return reply(201, {
        name: "1767300000000-abcdefgh",
        at: "2026-01-01T20:00:00.000Z",
        bytes: body.length,
      });
    };
    const answer = await call("phone_data_write", { items: [MEAL, NAP] });

    assert.equal(answer.isError, false, answer.text);
    assert.equal(answer.body.name, "1767300000000-abcdefgh");
    assert.equal(answer.body.items, 2);
    assert.match(answer.body.note, /phone/);
    assert.equal(taken.method, "POST");
    assert.equal(taken.url, `${UNREACHABLE}/b/${bucket()}/edits`);

    // Signed by the editor key over the canonical message the service and the
    // phone both check.
    assert.equal(taken.headers["X-Efferent-Editor"], editor.editorPublic);
    const timestamp = Number(taken.headers["X-Efferent-Timestamp"]);
    assert.ok(Math.abs(timestamp - Date.now() / 1000) < 60, "the timestamp is not now");
    const publicKey = createPublicKey({
      key: Buffer.concat([
        Buffer.from("302a300506032b6570032100", "hex"),
        wire.fromBase64url(editor.editorPublic),
      ]),
      format: "der",
      type: "spki",
    });
    assert.ok(verify(
      null,
      Buffer.from(wire.canonicalEdit(bucket(), timestamp, taken.body)),
      publicKey,
      wire.fromBase64url(taken.headers["X-Efferent-Signature"]),
    ));

    // Sealed to the reading key and bound to the bucket.
    assert.equal(taken.body[0], 2);
    const opened = wire.hpkeOpen(
      keys.reading.secret,
      wire.INFO,
      wire.editAssociatedData(bucket()),
      taken.body.subarray(1),
    );
    assert.deepEqual(JSON.parse(inflateRawSync(opened).toString()).items, [MEAL, NAP]);

    // And written down locally, so a later session can find the ids.
    const kept = JSON.parse(readFileSync(join(home, "edits.json"), "utf8"));
    assert.equal(kept.length, 1);
    assert.equal(kept[0].name, "1767300000000-abcdefgh");
    assert.deepEqual(kept[0].items, [
      { op: "put", id: MEAL.id, metric: "dietaryEnergy", day: "2026-01-01" },
      { op: "put", id: NAP.id, metric: "sleep", day: "2026-01-01" },
    ]);
  });

  test("the service refusing an edit is a failed call with its sentence", async () => {
    seedEditor();
    wire.io.transport = () => reply(403, { error: "no editor is registered for this bucket" });
    const answer = await call("phone_data_write", { items: [MEAL] });
    assert.equal(answer.isError, true);
    assert.match(answer.text, /403/);
    assert.match(answer.text, /no editor is registered/);
  });

  test("edits are listed with the status and the local record", async () => {
    seedEditor();
    writeFileSync(
      join(home, "edits.json"),
      JSON.stringify([{
        name: "1767300000000-abcdefgh",
        at: "2026-01-01T20:00:00.000Z",
        items: [
          { op: "put", id: MEAL.id, metric: "dietaryEnergy", day: "2026-01-01" },
          { op: "put", id: NAP.id, metric: "sleep", day: "2026-01-01" },
        ],
      }]),
    );
    const readerKey = wire.toBase64url(wire.publicOf("ed25519", wire.readKey(keys.reading.secret)));
    wire.io.transport = (_method, url, headers) => {
      // Every read is signed with the key made from the reading key.
      assert.equal(headers["X-Efferent-Reader"], readerKey);
      // The first outcome was stored before the word changed and still says
      // `refused`; it is a real answer and is read as one.
      if (url.includes("/o/1767300000000-abcdefgh")) {
        return reply(200, { applied: 1, refused: [{ item: 1, code: "badRange" }], bytes: 300 });
      }
      if (url.includes("/o/1767300002000-yyyyyyyy")) {
        return reply(200, { applied: 0, failed: [{ item: 0, code: "replayed" }], bytes: 90 });
      }
      assert.ok(url.includes(`/b/${bucket()}/edits`));
      assert.ok(url.includes("status=all"));
      return reply(200, {
        edits: [
          {
            name: "1767300000000-abcdefgh",
            bytes: 300,
            at: "2026-01-01T20:00:00.000Z",
            status: "partial",
            applied: 1,
            failed: 1,
          },
          {
            name: "1767300001000-zzzzzzzz",
            bytes: 200,
            at: "2026-01-01T20:00:01.000Z",
            status: "pending",
          },
          {
            name: "1767300002000-yyyyyyyy",
            bytes: 90,
            at: "2026-01-01T20:00:02.000Z",
            status: "failed",
            applied: 0,
            failed: 1,
          },
        ],
        next: null,
      });
    };
    const answer = await call("phone_data_edits", { status: "all" });

    assert.equal(answer.isError, false, answer.text);
    assert.equal(answer.body.next, null);
    assert.deepEqual(answer.body.codes, wire.OUTCOME_CODES);
    const [known, unknown, replayed] = answer.body.edits;
    assert.equal(known.status, "partial");
    assert.equal(known.applied, 1);
    assert.deepEqual(known.items.map((item) => item.id), [MEAL.id, NAP.id]);
    assert.deepEqual(known.refusals, [{ item: 1, code: "badRange", id: NAP.id }]);
    assert.equal(unknown.status, "pending");
    assert.equal("items" in unknown, false);
    assert.deepEqual(replayed.refusals, [{ item: 0, code: "replayed" }]);
  });

  test("the command line writes from a file and answers in the tool's shape", async () => {
    seedEditor();
    const path = join(home, "items.json");
    writeFileSync(path, JSON.stringify({ items: [{ ...MEAL, unit: "g" }] }));
    // Refused before anything is sealed, so the unreachable archive is never asked.
    const run = await cli(home, ["write", "--items", path]);
    assert.equal(run.code, 2);
    assert.match(run.stderr, /^error: item 0: unit must be kcal/);
  });
});

describe("As a process", () => {
  // The server run the way a client runs it: as a process, over its own stdin
  // and stdout. Calling `handle` directly cannot see a fault in how the module
  // starts up, and such a fault shipped once in the Python server.
  test("the server answers past the handshake, and a bad line is an error, not an exit", async () => {
    const empty = makeHome({ editor: null }).home;
    try {
      const run = await cli(
        empty,
        ["mcp"],
        '{"jsonrpc":"2.0","id":1,"method":"initialize"}\n' +
          '{"jsonrpc":"2.0","method":"notifications/initialized"}\n' +
          "not json\n" +
          '{"jsonrpc":"2.0","id":2,"method":"tools/list"}\n' +
          '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"phone_data_overview"}}\n',
      );
      assert.equal(run.code, 0, run.stderr);
      const lines = run.stdout.trim().split("\n").map((line) => JSON.parse(line));
      assert.equal(lines.length, 4, run.stdout);
      assert.equal(lines[0].result.serverInfo.name, "efferent");
      assert.equal(lines[1].error.code, -32700);
      assert.equal(lines[2].result.tools.length, 9);
      // No archive in this home: the overview still answers, from an empty
      // mirror, and its warning says where it looked — as the Python did.
      assert.equal(lines[3].result.isError, undefined);
      const overview = JSON.parse(lines[3].result.content[0].text);
      assert.match(overview.warning, /no archive is configured/);
      assert.equal(overview.readable.days, 0);
    } finally {
      remove(empty);
    }
  });
});
