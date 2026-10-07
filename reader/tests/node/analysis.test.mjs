// The corrections that keep an answer from being plausibly wrong. Ported from
// tests/test_analysis.py, plus the arithmetic that has to round and add the way
// the Python reader did.

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, test } from "node:test";

import * as wire from "../../efferent.mjs";

const READER = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const PYTHON = process.env.EFFERENT_PYTHON || join(READER, ".venv", "bin", "python");

function sleep(start, end, stage = "asleepCore", source = "Watch") {
  return { id: `hk:sleep:${start}:${source}`, v: 1, metric: "sleep", stage, start, end, source };
}

describe("Sleep", () => {
  test("overlapping stretches are merged rather than added", () => {
    // The same hour described twice. Adding the lengths would give six hours of
    // sleep to someone who slept four, and it reads as good news.
    const [night] = wire.nights([
      sleep("2026-01-01T22:00:00Z", "2026-01-02T00:00:00Z"),
      sleep("2026-01-01T23:00:00Z", "2026-01-02T02:00:00Z", "asleepDeep", "Phone"),
    ]);
    assert.equal(night.asleepHours, 4, "the overlap was counted twice");
  });

  test("a night across midnight is one night named by the evening", () => {
    const found = wire.nights([
      sleep("2026-01-01T23:30:00Z", "2026-01-02T00:00:00Z"),
      sleep("2026-01-02T00:00:00Z", "2026-01-02T06:00:00Z"),
    ]);
    assert.equal(found.length, 1);
    assert.equal(found[0].night, "2026-01-01");
    assert.equal(found[0].asleepHours, 6.5);
  });

  test("stages are broken out and time in bed kept apart", () => {
    const [night] = wire.nights([
      sleep("2026-01-01T23:00:00Z", "2026-01-02T01:00:00Z", "asleepCore"),
      sleep("2026-01-02T01:00:00Z", "2026-01-02T02:00:00Z", "asleepREM"),
      sleep("2026-01-01T22:30:00Z", "2026-01-02T02:30:00Z", "inBed"),
    ]);
    assert.equal(night.asleepHours, 3);
    assert.equal(night.inBedHours, 4);
    assert.deepEqual(night.stages, { asleepCore: 2, asleepREM: 1 });
    assert.equal(night.start, "2026-01-01T23:00:00Z");
    assert.equal(night.end, "2026-01-02T02:00:00Z");
    assert.equal(night.segments, 2);
  });
});

describe("Totals", () => {
  test("hourly totals never reach a daily table", () => {
    const day = [
      { id: "d", v: 1, metric: "steps", bucket: "day", value: 12000 },
      { id: "h1", v: 1, metric: "steps", bucket: "hour", value: 400 },
      { id: "h2", v: 1, metric: "steps", bucket: "hour", value: 400 },
    ];
    const rows = wire.dailyTotals([{ day: "2026-01-01", events: day }], [
      "steps",
      "flightsClimbed",
    ]);
    assert.equal(rows[0].values.steps, 12000);
    assert.equal(rows[0].values.flightsClimbed, null, "a day with no total must not read as zero");
  });
});

describe("Workouts", () => {
  test("a workout comes back as an activity rather than a number", () => {
    assert.equal(wire.activityName("52"), "walking");
    assert.equal(wire.activityName(13), "cycling");
    assert.equal(wire.activityName("99"), "activity-99");
    assert.equal(wire.activityName(null), "activity-unknown");
  });

  test("workouts are listed in order with their length in minutes", () => {
    const found = wire.workouts([{
      day: "2026-01-02",
      events: [
        {
          id: "w2",
          v: 1,
          metric: "workout",
          activity: "13",
          duration: 1800,
          start: "2026-01-02T10:00:00Z",
          end: "2026-01-02T10:30:00Z",
        },
        {
          id: "w1",
          v: 1,
          metric: "workout",
          activity: "52",
          duration: 600,
          start: "2026-01-02T08:00:00Z",
          end: "2026-01-02T08:10:00Z",
        },
      ],
    }]);
    assert.deepEqual(found.map((workout) => workout.activity), ["walking", "cycling"]);
    assert.deepEqual(found.map((workout) => workout.minutes), [10, 30]);
  });
});

describe("Numbers", () => {
  test("a distribution describes the spread, not just the middle", () => {
    const spread = wire.distribution([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
    assert.equal(spread.n, 10);
    assert.equal(spread.median, 5.5);
    assert.equal(spread.min, 1);
    assert.equal(spread.max, 10);
    assert.equal(spread.sum, 55);
    assert.equal(wire.distribution([]), null, "an empty range must not answer with zeros");
  });

  test("a tie rounds to the even digit, as Python's round() does", () => {
    // A 225-second stage is exactly 0.0625 hours.
    assert.equal(wire.round3(0.0625), 0.062);
    assert.equal(wire.roundTo(0.375, 2), 0.38);
    assert.equal(wire.roundTo(0.125, 2), 0.12);
    assert.equal(wire.roundTo(-0.125, 2), -0.12);
    assert.equal(wire.roundTo(2.5, 0), 2);
    assert.equal(wire.roundTo(3.5, 0), 4);
    // Not a tie in binary, whatever it looks like in decimal.
    assert.equal(wire.roundTo(2.675, 2), 2.67);
    assert.equal(wire.roundTo(1.0005, 3), 1);
  });

  test("rounding and summing agree with Python on a spread of values", () => {
    const values = [];
    for (let index = 0; index < 400; index++) {
      values.push(index / 16, index / 1000 + 0.0005, index * 0.1 + 0.05);
    }
    for (let index = 0; index < 400; index++) values.push(Math.sin(index) * 1000);
    const script = [
      "import json,sys",
      "values=json.load(sys.stdin)",
      "print(json.dumps({'r3':[round(v,3) for v in values],'r1':[round(v,1) for v in values],",
      "'sum':sum(values),'mean':sum(values)/len(values)}))",
    ].join("\n");
    const python = JSON.parse(
      execFileSync(PYTHON, ["-c", script], { input: JSON.stringify(values), encoding: "utf8" }),
    );
    assert.deepEqual(values.map(wire.round3), python.r3);
    assert.deepEqual(values.map((value) => wire.roundTo(value, 1)), python.r1);
    const spread = wire.distribution(values);
    assert.equal(spread.sum, wire.round3(python.sum));
    assert.equal(spread.mean, wire.round3(python.mean));
  });
});

describe("Days", () => {
  test("weeks are named by their Monday", () => {
    // 2026-01-01 is a Thursday.
    assert.equal(wire.groupOf("2026-01-01", "week"), "2025-12-29");
    assert.equal(wire.groupOf("2026-01-01", "month"), "2026-01");
    assert.equal(wire.groupOf("2026-01-01", "year"), "2026");
    assert.equal(wire.groupOf("2026-01-01", "day"), "2026-01-01");
  });

  test("days are counted across month and year ends", () => {
    assert.equal(wire.addDays("2026-02-28", 1), "2026-03-01");
    assert.equal(wire.addDays("2026-01-01", -1), "2025-12-31");
    assert.equal(wire.daysBetween("2025-12-30", "2026-01-02") + 1, 4);
  });
});

describe("Summary", () => {
  test("the summary says when a metric starts", () => {
    const summary = wire.summarise([
      {
        day: "2020-01-01",
        events: [{ id: "a", v: 1, metric: "steps", bucket: "day", unit: "count" }],
      },
      {
        day: "2022-06-01",
        events: [
          { id: "b", v: 1, metric: "steps", bucket: "day", unit: "count" },
          { id: "c", v: 1, metric: "heartRate", unit: "count/min" },
        ],
      },
    ]);
    const steps = summary.find((entry) => entry.metric === "steps");
    const heart = summary.find((entry) => entry.metric === "heartRate");
    assert.equal(steps.firstDay, "2020-01-01");
    assert.equal(steps.kind, "total");
    assert.equal(steps.daysCovered, 2);
    assert.equal(heart.firstDay, "2022-06-01");
    assert.equal(heart.kind, "record");
    assert.equal(heart.daysCovered, 1);
  });

  test("blood oxygen carries the correction that its unit is wrong", () => {
    const summary = wire.summarise([
      {
        day: "2026-01-01",
        events: [{ id: "o", v: 1, metric: "oxygenSaturation", value: 0.97, unit: "%" }],
      },
    ]);
    assert.ok("unitNote" in summary[0]);
  });
});

describe("Table", () => {
  test("what every row agrees on is said once, and a lone row keeps everything", () => {
    const rows = [
      { start: "a", end: "b", source: "Watch", value: 1 },
      { start: "c", end: "d", source: "Watch", value: 2 },
    ];
    assert.deepEqual(wire.table(rows), {
      sameOnEveryRow: { source: "Watch" },
      columns: ["start", "end", "value"],
      rows: [["a", "b", 1], ["c", "d", 2]],
    });
    assert.deepEqual(wire.table([rows[0]]).columns, ["start", "end", "source", "value"]);
  });
});
