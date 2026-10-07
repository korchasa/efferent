// The reading side against an archive that answers, through the command line.
// Ported from tests/test_reader.py.

import assert from "node:assert/strict";
import { readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { afterEach, beforeEach, describe, test } from "node:test";

import * as wire from "../../efferent.mjs";
import {
  cli,
  FakeArchive,
  handoff as handoffText,
  makeHome,
  mirroredFiles,
  mirroredState,
  readingPair,
  remove,
  total,
} from "./helpers.mjs";

/** Days named from a start, one total each, so a day is identifiable by its value alone. */
function seedRun(archive, from, count) {
  const days = [];
  let day = from;
  for (let index = 0; index < count; index++) {
    archive.put(day, [total("steps", day, 1000 + index)]);
    days.push(day);
    day = wire.addDays(day, 1);
  }
  return days;
}

let archive;
let home;
let reading;

beforeEach(async () => {
  ({ home, reading } = makeHome());
  archive = await new FakeArchive(reading.publicRaw).start();
  // Pointed at by `--url` the first time, the way the Python tests did, so the
  // first command is what records the endpoint.
});

afterEach(async () => {
  await archive.stop();
  remove(home);
});

const registered = () => {
  archive.reader = wire.publicOf("ed25519", wire.readKey(reading.secret));
};

describe("Listing", () => {
  test("a listing is walked past its own page size", async () => {
    seedRun(archive, "2026-03-01", 7);
    const run = await cli(home, ["sync", "--url", archive.url]);
    assert.equal(run.code, 0, run.stderr);
    // Seven days at two per page is four requests: three full and the last.
    assert.ok(archive.listings() >= 4, `walked only ${archive.listings()} pages`);
    assert.equal(mirroredFiles(home).length, 7);
  });

  test("a listing that breaks part way through answers short for nobody", async () => {
    seedRun(archive, "2026-03-01", 7);
    archive.fault = { page: 1 };
    const run = await cli(home, ["sync", "--url", archive.url]);
    assert.notEqual(run.code, 0, "a broken listing was reported as a finished sync");
    assert.match(run.stderr, /500/);
    assert.deepEqual(mirroredState(home).days, {});
  });
});

describe("Windowed fetch", () => {
  test("days come back in the order they were asked for", async () => {
    seedRun(archive, "2026-03-01", 20);
    const run = await cli(home, ["read", "--url", archive.url]);
    assert.equal(run.code, 0, run.stderr);
    const days = run.stdout.trim().split("\n").map((line) => JSON.parse(line).start.slice(0, 10));
    assert.equal(days.length, 20);
    assert.deepEqual(days, [...days].sort(), "the stream of days came back out of order");
  });

  test("a refused day stops the fetch instead of being skipped", async () => {
    seedRun(archive, "2026-03-01", 20);
    archive.fault = { day: "2026-03-11" };
    const run = await cli(home, ["sync", "--url", archive.url]);
    assert.notEqual(run.code, 0, "a refused day was reported as a finished sync");
    assert.match(run.stderr, /2026-03-11/);
    assert.equal("2026-03-11" in mirroredState(home).days, false);
  });

  test("a day the listing named and the range left out stops the fetch", async () => {
    seedRun(archive, "2026-03-01", 5);
    archive.fault = { omit: "2026-03-03" };
    const run = await cli(home, ["sync", "--url", archive.url]);
    assert.notEqual(run.code, 0, "a day that never arrived was passed over");
    assert.match(run.stderr, /2026-03-03: the archive no longer holds this day/);
    // A mirror that recorded a day it never received would never ask again.
    assert.equal("2026-03-03" in mirroredState(home).days, false);
  });

  test("a run of days is asked for as a range, not a day at a time", async () => {
    seedRun(archive, "2026-03-01", 40);
    const run = await cli(home, ["sync", "--url", archive.url]);
    assert.equal(run.code, 0, run.stderr);
    assert.equal(mirroredFiles(home).length, 40);
    // Forty days in a row are one range, which this archive answers three days
    // at a time: fourteen answers, each following the last.
    assert.equal(archive.ranges().length, 14);
    assert.deepEqual(
      archive.asked.filter((path) => path.includes("/d/")),
      [],
      "a day was asked for alone",
    );
  });

  test("no more than one window of ranges is ever in the air", async () => {
    // A day a fortnight: too far apart to share a range, so only the window
    // holds them back.
    let day = "2026-01-01";
    for (let index = 0; index < 16; index++) {
      archive.put(day, [total("steps", day, 1000 + index)]);
      day = wire.addDays(day, 14);
    }
    const run = await cli(home, ["sync", "--url", archive.url]);
    assert.equal(run.code, 0, run.stderr);
    assert.equal(mirroredFiles(home).length, 16);
    assert.equal(archive.ranges().length, 16);
    assert.ok(archive.maxInFlight > 1, "the ranges were asked for one at a time");
    assert.ok(
      archive.maxInFlight <= wire.FETCH_WINDOW,
      `${archive.maxInFlight} ranges were open at once`,
    );
  });

  test("days close together share a range and the ones between are dropped", async () => {
    seedRun(archive, "2026-03-01", 10);
    await cli(home, ["sync", "--url", archive.url]);
    archive.put("2026-03-03", [total("steps", "2026-03-03", 7777)]);
    archive.put("2026-03-07", [total("steps", "2026-03-07", 8888)]);
    const before = statSync(join(home, "days", "2026-03-05.ndjson"), { bigint: true }).mtimeNs;
    archive.forget();

    const run = await cli(home, ["sync"]);

    assert.equal(run.code, 0, run.stderr);
    assert.equal(archive.ranges().length, 2, "five days of range is two answers");
    assert.equal(
      statSync(join(home, "days", "2026-03-05.ndjson"), { bigint: true }).mtimeNs,
      before,
      "a day nobody asked for was written again because it came along in a range",
    );
    const line = readFileSync(join(home, "days", "2026-03-07.ndjson"), "utf8").trim();
    assert.equal(JSON.parse(line).value, 8888);
  });
});

describe("Signed reads", () => {
  // Once the phone registers a read key, the bucket id opens nothing and every
  // read has to be signed with that key. The reader makes it from the reading
  // key each time, the same way the phone does.
  test("every read is signed with the key made from the reading key", async () => {
    seedRun(archive, "2026-03-01", 5);
    registered();
    const run = await cli(home, ["sync", "--url", archive.url]);
    assert.equal(run.code, 0, run.stderr);
    assert.equal(mirroredFiles(home).length, 5);
    assert.match((await cli(home, ["status"])).stdout, /archive {2}5 days/);
  });

  test("a read key this reader does not hold is refused by name", async () => {
    seedRun(archive, "2026-03-01", 3);
    archive.reader = wire.publicOf(
      "ed25519",
      wire.readKey(Buffer.from(Array.from({ length: 32 }, (_, index) => index + 1))),
    );
    const run = await cli(home, ["sync", "--url", archive.url]);
    assert.notEqual(run.code, 0, "a read under somebody else's key looked fine");
    assert.match(run.stderr, /403/);
    assert.match(run.stderr, /not this archive's read key/);
    assert.deepEqual(mirroredFiles(home), []);
  });
});

describe("Mirror", () => {
  test("a mirror already level with the archive fetches nothing", async () => {
    seedRun(archive, "2026-03-01", 3);
    assert.equal((await cli(home, ["sync", "--url", archive.url])).code, 0);
    archive.forget();
    const run = await cli(home, ["sync"]);
    assert.equal(run.code, 0, run.stderr);
    assert.match(run.stdout, /already up to date/);
    assert.deepEqual(archive.sent, []);
  });

  test("a rewritten day is copied again", async () => {
    seedRun(archive, "2026-03-01", 3);
    await cli(home, ["sync", "--url", archive.url]);
    archive.put("2026-03-02", [total("steps", "2026-03-02", 9999)]);
    archive.forget();
    const run = await cli(home, ["sync"]);
    assert.equal(run.code, 0, run.stderr);
    assert.deepEqual(archive.sent, ["2026-03-02"]);
    const line = readFileSync(join(home, "days", "2026-03-02.ndjson"), "utf8").trim();
    assert.equal(JSON.parse(line).value, 9999);
  });

  test("a query answers from the mirror with the archive gone", async () => {
    seedRun(archive, "2026-03-01", 3);
    await cli(home, ["sync", "--url", archive.url]);
    await archive.stop();
    const run = await cli(home, ["query", "--metric", "steps", "--format", "summary"]);
    assert.equal(run.code, 0, run.stderr);
    assert.match(run.stdout, /3 events/);
    assert.match(run.stdout, /steps\/day/);
  });
});

describe("Status", () => {
  test("status says what the archive holds and what the mirror has", async () => {
    seedRun(archive, "2026-03-01", 4);
    const run = await cli(home, ["status", "--url", archive.url]);
    assert.equal(run.code, 0, run.stderr);
    assert.ok(run.stdout.includes(`bucket   ${archive.bucket}`));
    assert.ok(run.stdout.includes("archive  4 days"));
    assert.ok(run.stdout.includes("mirror   nothing yet — run sync"));

    await cli(home, ["sync"]);
    const after = await cli(home, ["status"]);
    assert.ok(
      after.stdout.includes("mirror   4 days, 2026-03-01 … 2026-03-04  — up to date"),
      after.stdout,
    );
  });
});

describe("Questions", () => {
  test("a range fetches the day before it so a night is not lost", async () => {
    seedRun(archive, "2026-03-01", 5);
    await cli(home, ["status", "--url", archive.url]);
    archive.forget();
    const run = await cli(home, ["ask", "--since", "2026-03-03", "--until", "2026-03-04"]);
    assert.equal(run.code, 0, run.stderr);
    // The 2nd is fetched as well: a night that began before midnight belongs to
    // the evening's day. It is then filtered out, because nothing in it
    // overlaps the question.
    assert.deepEqual([...archive.sent].sort(), ["2026-03-02", "2026-03-03", "2026-03-04"]);
    const kept = run.stdout.trim().split("\n").map((line) => JSON.parse(line).start.slice(0, 10));
    assert.deepEqual(kept, ["2026-03-03", "2026-03-04"]);
  });

  test("a bound that is not a day is refused by name", async () => {
    const run = await cli(home, ["query", "--since", "March"]);
    assert.equal(run.code, 2);
    assert.match(run.stderr, /--since must be a day/);
  });
});

describe("Connecting and asking for help", () => {
  test("connect imports a handoff from stdin, and a second archive is refused", async () => {
    const fresh = makeHome({ editor: null });
    const target = join(fresh.home, "profile");
    try {
      const text = handoffText(fresh.reading);
      const run = await cli(target, ["connect", "--handoff", "-"], text);
      assert.equal(run.code, 0, run.stderr);
      assert.match(run.stdout, /connected: /);
      assert.match(run.stdout, /predates writing/);
      assert.equal(mirroredState(target).endpoint, "https://efferent.example");
      const other = await cli(target, ["connect", "--handoff", "-"], handoffText(readingPair()));
      assert.equal(other.code, 2);
      assert.match(other.stderr, /already exists/);
    } finally {
      remove(fresh.home);
    }
  });

  test("tools lists every description, and one tool on request", async () => {
    const all = JSON.parse((await cli(home, ["tools"])).stdout);
    assert.equal(all.length, 9);
    const one = JSON.parse((await cli(home, ["tools", "phone_data_write"])).stdout);
    assert.deepEqual(one.map((tool) => tool.name), ["phone_data_write"]);
    assert.equal((await cli(home, ["tools", "phone_data_horoscope"])).code, 2);
  });

  test("a misspelt option is refused rather than ignored", async () => {
    // Ignored, `--metirc` would answer for every metric: a smaller question
    // quietly replaced by a bigger one, with nothing in the answer to say so.
    for (const args of [["daily", "--metirc", "steps"], ["ask", "--sinse", "2026-01-01"]]) {
      const run = await cli(home, args);
      assert.equal(run.code, 2, args.join(" "));
      assert.match(run.stderr, new RegExp(`unknown option ${args[1]} for ${args[0]}`));
      assert.equal(run.stdout, "");
    }
  });

  test("an unknown command prints the usage and fails", async () => {
    const run = await cli(home, ["horoscope"]);
    assert.equal(run.code, 2);
    assert.match(run.stderr, /^usage: node efferent.mjs/);
  });
});

describe("No archive", () => {
  test("a home with no archive says where it looked", async () => {
    const empty = makeHome({ editor: null }).home;
    try {
      const run = await cli(empty, ["status"]);
      assert.equal(run.code, 2);
      assert.match(run.stderr, /no archive is configured/);
      assert.ok(run.stderr.includes(empty), run.stderr);
    } finally {
      remove(empty);
    }
  });
});
