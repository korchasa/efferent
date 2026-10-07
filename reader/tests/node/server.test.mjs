// The MCP server against an archive that answers. Ported from
// tests/test_server.py.
//
// The server meets the archive as a child process, because a session is what
// holds the freshness window and the mirror's record in memory. A test that
// wants a reader with no memory of the last question starts another one.

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { afterEach, beforeEach, describe, test } from "node:test";

import * as wire from "../../efferent.mjs";
import {
  cli,
  CLIENT,
  FakeArchive,
  makeHome,
  mirroredFiles,
  mirroredState,
  remove,
  total,
} from "./helpers.mjs";

const record = (metric, at, value) => ({
  metric,
  value,
  unit: "count/min",
  source: "a watch",
  start: at,
  end: at,
});

function seedRun(archive, from, count) {
  let day = from;
  for (let index = 0; index < count; index++) {
    archive.put(day, [total("steps", day, 1000 + index)]);
    day = wire.addDays(day, 1);
  }
}

/** The MCP server as the agent meets it: a process, spoken to over stdio. */
class Session {
  constructor(home) {
    this.child = spawn(process.execPath, [CLIENT, "mcp"], {
      env: { ...process.env, EFFERENT_HOME: home },
      stdio: ["pipe", "pipe", "ignore"],
    });
    this.lines = createInterface({ input: this.child.stdout })[Symbol.asyncIterator]();
    this.id = 0;
  }

  async rpc(method, params = undefined) {
    this.id += 1;
    this.child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: this.id, method, params })}\n`);
    const { value, done } = await this.lines.next();
    if (done) throw new Error("the server closed before answering");
    return JSON.parse(value);
  }

  async call(name, args = {}) {
    const answer = await this.rpc("tools/call", { name, arguments: args });
    const text = answer.result.content[0].text;
    return { isError: answer.result.isError === true, text, body: JSON.parse(text) };
  }

  close() {
    this.child.stdin.end();
    return new Promise((resolve) => this.child.once("exit", resolve));
  }
}

let archive;
let home;

beforeEach(async () => {
  const made = makeHome({ editor: null });
  home = made.home;
  archive = await new FakeArchive(made.reading.publicRaw).start();
  writeFileSync(
    join(home, "mirror.json"),
    JSON.stringify({ endpoint: archive.url, days: {}, syncedAt: "" }),
  );
});

afterEach(async () => {
  await archive.stop();
  remove(home);
});

/** One session, opened, used and closed — even when the body throws. */
async function session(body) {
  const opened = new Session(home);
  await opened.rpc("initialize", { protocolVersion: "2025-06-18" });
  try {
    return await body(opened);
  } finally {
    await opened.close();
  }
}

function keptMetrics() {
  try {
    return JSON.parse(readFileSync(join(home, "metrics.json"), "utf8"));
  } catch {
    return null;
  }
}

describe("Freshness", () => {
  test("a first question copies the archive down and answers from it", async () => {
    archive.put("2026-03-01", [total("steps", "2026-03-01", 8000)]);
    archive.put("2026-03-02", [total("steps", "2026-03-02", 3000)]);
    const answer = await session((s) =>
      s.call("phone_data_daily", { since: "2026-03-01", until: "2026-03-02" })
    );
    assert.equal("warning" in answer.body, false, answer.text);
    assert.equal(answer.body.rows.length, 2);
    assert.equal(answer.body.rows[0][0], "2026-03-01");
    assert.deepEqual(mirroredFiles(home), ["2026-03-01", "2026-03-02"]);
  });

  test("a rewritten day inside the fortnight is copied by an ordinary question", async () => {
    const recent = wire.addDays(wire.today(), -3);
    archive.put(recent, [total("steps", recent, 1000)]);
    await session((s) => s.call("phone_data_sync"));
    archive.put(recent, [total("steps", recent, 99_999)]);
    const answer = await session((s) =>
      s.call("phone_data_daily", { since: recent, until: recent })
    );
    assert.equal(answer.body.rows[0][1], 99_999);
  });

  test("a day older than the fortnight rewritten is still copied by a sync", async () => {
    seedRun(archive, "2026-03-01", 5);
    await session(async (s) => {
      await s.call("phone_data_sync");
      assert.equal(mirroredFiles(home).length, 5);
      archive.put("2026-03-03", [total("steps", "2026-03-03", 99_999)]);
      archive.forget();
      await s.call("phone_data_sync");
      assert.deepEqual(
        archive.sent,
        ["2026-03-03"],
        "a sync fetched days whose stored version had not moved",
      );
      const answer = await s.call("phone_data_daily", { since: "2026-03-03", until: "2026-03-03" });
      assert.equal(answer.body.rows[0][1], 99_999);
    });
  });

  test("a mirror already level with the archive fetches nothing", async () => {
    seedRun(archive, "2026-03-01", 5);
    await session(async (s) => {
      await s.call("phone_data_sync");
      archive.forget();
      await s.call("phone_data_daily", { since: "2026-03-01", until: "2026-03-05" });
      assert.deepEqual(archive.sent, []);
      // Inside the freshness window a second question costs no round trip.
      assert.deepEqual(archive.asked, []);
    });
  });

  test("a sync asks the archive even inside the freshness window", async () => {
    archive.put("2026-03-01", [total("steps", "2026-03-01", 8000)]);
    await session(async (s) => {
      await s.call("phone_data_sync");
      archive.forget();
      await s.call("phone_data_sync");
      assert.ok(archive.asked.length > 0, "a sync answered from a window it exists to ignore");
    });
  });

  test("history arriving outside the recent fortnight is still noticed", async () => {
    const now = wire.today();
    archive.put(now, [total("steps", now, 8000)]);
    await session(async (s) => {
      await s.call("phone_data_sync");
      // Only the day count says the mirror is behind, which is the fall-through here.
      archive.put("2016-01-05", [total("steps", "2016-01-05", 4242)]);
      await s.call("phone_data_sync");
    });
    assert.ok(
      mirroredFiles(home).includes("2016-01-05"),
      "a day older than the recent listing never reached the mirror",
    );
  });

  test("a sync that breaks part way says so and records only what arrived", async () => {
    seedRun(archive, "2026-03-01", 12);
    archive.fault = { day: "2026-03-07" };
    const answer = await session((s) =>
      s.call("phone_data_daily", { since: "2026-03-01", until: "2026-03-12" })
    );
    assert.match(answer.body.warning, /could not be brought up to date/);
    assert.equal("2026-03-07" in mirroredState(home).days, false);
  });
});

describe("Overview", () => {
  test("the overview reports the archive, the readable part and every metric", async () => {
    archive.put("2026-03-01", [
      total("steps", "2026-03-01", 8000),
      record("heartRate", "2026-03-01T09:00:00Z", 60),
      record("heartRate", "2026-03-01T10:00:00Z", 80),
    ]);
    archive.put("2026-03-02", [total("steps", "2026-03-02", 3000)]);
    const answer = await session((s) => s.call("phone_data_overview"));
    assert.equal(answer.body.archive.days, 2);
    assert.equal(answer.body.archive.firstDay, "2026-03-01");
    assert.equal(answer.body.readable.days, 2);
    assert.match(answer.body.readable.note, /the whole archive is readable/);
    const metrics = Object.fromEntries(answer.body.metrics.map((entry) => [entry.metric, entry]));
    assert.equal(metrics.steps.kind, "total");
    assert.equal(metrics.steps.daysCovered, 2);
    assert.equal(metrics.heartRate.kind, "record");
    assert.equal(metrics.heartRate.events, 2);
    assert.equal(metrics.heartRate.firstDay, "2026-03-01");
  });

  test("the overview answers from the mirror when the archive has gone", async () => {
    archive.put("2026-03-01", [total("steps", "2026-03-01", 8000)]);
    await session((s) => s.call("phone_data_sync"));
    await archive.stop();
    const answer = await session((s) => s.call("phone_data_overview"));
    assert.match(answer.body.warning, /could not be reached/);
    assert.equal(answer.body.archive, "unreachable");
    assert.equal(answer.body.readable.days, 1);
    assert.equal(answer.body.metrics.length, 1);
  });

  test("the overview costs one round trip, not two", async () => {
    archive.put("2026-03-01", [total("steps", "2026-03-01", 8000)]);
    await session(async (s) => {
      archive.forget();
      const answer = await s.call("phone_data_overview");
      assert.equal(answer.body.archive.days, 1);
      assert.equal(
        archive.asked.filter((path) => path.includes("/stats")).length,
        1,
        "asked what it holds twice",
      );
      archive.forget();
      await s.call("phone_data_overview");
      assert.deepEqual(archive.asked, []);
    });
  });

  test("a sync reports what it copied and what is readable afterwards", async () => {
    seedRun(archive, "2026-03-01", 6);
    await session(async (s) => {
      const first = await s.call("phone_data_sync");
      assert.deepEqual(first.body, {
        copied: 6,
        readable: 6,
        firstDay: "2026-03-01",
        lastDay: "2026-03-06",
      });
      const again = await s.call("phone_data_sync");
      assert.equal(again.body.copied, 0, "a second sync copied days that had not changed");
      assert.equal(again.body.readable, 6);
    });
  });
});

describe("Records", () => {
  test("a day that left the archive stops being counted and its file is kept", async () => {
    seedRun(archive, "2026-03-01", 5);
    await session((s) => s.call("phone_data_sync"));
    assert.equal(Object.keys(mirroredState(home).days).length, 5);

    archive.drop("2026-03-03");
    await session((s) => s.call("phone_data_daily", { since: "2026-03-01", until: "2026-03-05" }));
    assert.equal(
      Object.keys(mirroredState(home).days).length,
      4,
      "the mirror still claims a day the archive lost",
    );
    // The record goes, the day does not: it may be the last copy left.
    assert.ok(
      mirroredFiles(home).includes("2026-03-03"),
      "the local copy of the lost day was deleted",
    );

    const overview = await session((s) => s.call("phone_data_overview"));
    assert.equal(overview.body.archive.days, 4);
    assert.equal(overview.body.readable.days, 5);
    assert.match(overview.body.readable.note, /the archive no longer holds/);

    // The count agrees again, so an ordinary question stops walking the archive.
    archive.forget();
    await session((s) => s.call("phone_data_daily", { since: "2026-03-01", until: "2026-03-05" }));
    assert.equal(archive.fullListings(), 0, "a lost day bought a full listing on every question");
  });

  test("a day count that is only a floor cannot say the mirror is level", async () => {
    seedRun(archive, "2026-03-01", 5);
    await session((s) => s.call("phone_data_sync"));
    archive.floor = 3;
    archive.forget();
    await session((s) => s.call("phone_data_daily", { since: "2026-03-01", until: "2026-03-05" }));
    assert.equal(
      archive.fullListings(),
      0,
      "a floor below the mirror's own count was read as a mismatch",
    );
  });

  test("a floor above the mirror's count still says it is behind", async () => {
    seedRun(archive, "2026-03-01", 5);
    archive.floor = 3;
    await session((s) => s.call("phone_data_daily", { since: "2026-03-01", until: "2026-03-05" }));
    assert.ok(archive.fullListings() > 0, "a mirror the archive said was behind never caught up");
    assert.equal(mirroredFiles(home).length, 5);
  });

  test("days another process already copied are not fetched again", async () => {
    seedRun(archive, "2026-03-01", 5);
    await session(async (s) => {
      await s.call("phone_data_sync");
      // The command line shares this mirror and copies new history down while
      // the server is running; the server's own record is now behind.
      seedRun(archive, "2026-02-20", 3);
      const run = await cli(home, ["sync"]);
      assert.equal(run.code, 0, run.stderr);
      assert.equal(Object.keys(mirroredState(home).days).length, 8);
      archive.forget();
      await s.call("phone_data_sync");
      assert.deepEqual(
        archive.sent,
        [],
        "the server re-fetched days another process had already copied",
      );
      assert.equal(Object.keys(mirroredState(home).days).length, 8);
    });
  });

  test("a mirror record that cannot be read does not stop an answer", async () => {
    seedRun(archive, "2026-03-01", 3);
    await session(async (s) => {
      await s.call("phone_data_sync");
      rmSync(join(home, "mirror.json"));
      const answer = await s.call("phone_data_sync");
      assert.match(answer.body.warning, /could not be read/);
      const daily = await s.call("phone_data_daily", { since: "2026-03-01", until: "2026-03-03" });
      assert.equal(daily.body.rows.length, 3);
    });
  });
});

describe("Remembered", () => {
  test("what a day holds is worked out once and kept", async () => {
    seedRun(archive, "2026-03-01", 5);
    await session((s) => s.call("phone_data_overview"));
    const kept = keptMetrics();
    assert.ok(kept, "nothing was kept, so every overview reads the mirror again");
    assert.equal(Object.keys(kept).length, 5);
    const answer = await session((s) => s.call("phone_data_overview"));
    assert.equal(answer.body.metrics.length, 1);
    assert.equal(answer.body.metrics[0].metric, "steps");
    assert.equal(answer.body.metrics[0].daysCovered, 5);
    assert.equal(answer.body.metrics[0].firstDay, "2026-03-01");
  });

  test("a kept day whose file has changed is read again, not believed", async () => {
    seedRun(archive, "2026-03-01", 3);
    await session((s) => s.call("phone_data_overview"));
    writeFileSync(
      join(home, "days", "2026-03-02.ndjson"),
      `${
        JSON.stringify({
          id: "hk:heartRate:2026-03-02T09:00:00Z",
          v: 1,
          metric: "heartRate",
          value: 61,
          unit: "count/min",
          start: "2026-03-02T09:00:00Z",
          end: "2026-03-02T09:00:00Z",
        })
      }\n`,
    );
    const answer = await session((s) => s.call("phone_data_overview"));
    const names = answer.body.metrics.map((entry) => entry.metric).sort();
    assert.deepEqual(names, ["heartRate", "steps"], "the overview answered from a stale record");
    assert.equal(answer.body.metrics.find((entry) => entry.metric === "steps").daysCovered, 2);
  });

  test("a record that was thrown away costs a read, never a wrong answer", async () => {
    seedRun(archive, "2026-03-01", 4);
    await session((s) => s.call("phone_data_overview"));
    const before = (await session((s) => s.call("phone_data_overview"))).body.metrics;
    rmSync(join(home, "metrics.json"));
    assert.deepEqual((await session((s) => s.call("phone_data_overview"))).body.metrics, before);
    assert.ok(keptMetrics(), "the record was not rebuilt");
    writeFileSync(join(home, "metrics.json"), "{ this is not json");
    assert.deepEqual((await session((s) => s.call("phone_data_overview"))).body.metrics, before);
  });

  test("a day that left the mirror leaves the record too", async () => {
    seedRun(archive, "2026-03-01", 4);
    await session((s) => s.call("phone_data_overview"));
    assert.equal(Object.keys(keptMetrics()).length, 4);
    rmSync(join(home, "days", "2026-03-02.ndjson"));
    const answer = await session((s) => s.call("phone_data_overview"));
    assert.equal(answer.body.readable.days, 3);
    assert.equal(answer.body.metrics[0].daysCovered, 3);
    assert.equal(Object.keys(keptMetrics()).length, 3);
  });
});
