import { assertEquals, assertNotEquals } from "@std/assert";
import {
  activityName,
  addDays,
  dailyTotals,
  dayRange,
  distribution,
  groupOf,
  nights,
  summarise,
  workouts,
} from "./analysis.ts";
import type { Event } from "./archive.ts";

function sleep(start: string, end: string, stage = "asleepCore", source = "Watch"): Event {
  return { id: `hk:sleep:${start}:${source}`, v: 1, metric: "sleep", stage, start, end, source };
}

Deno.test("overlapping stretches of sleep are merged rather than added", () => {
  // The same hour described twice — a watch and an app, or one stretch split by
  // a stage change that overlaps its neighbour. Adding the lengths would give
  // six hours of sleep to someone who slept four, and it reads as good news.
  const [night] = nights([
    sleep("2026-01-01T22:00:00Z", "2026-01-02T00:00:00Z"),
    sleep("2026-01-01T23:00:00Z", "2026-01-02T02:00:00Z", "asleepDeep", "Phone"),
  ]);

  assertEquals(night.asleepHours, 4, "the overlap was counted twice");
});

Deno.test("a night that crosses midnight is one night, named by the evening", () => {
  // The evening half is stored in one day file and the small hours in the next,
  // because a record belongs to the day it started on. Grouping by that day
  // would report two short nights where there was one long one.
  const found = nights([
    sleep("2026-01-01T23:30:00Z", "2026-01-02T00:00:00Z"),
    sleep("2026-01-02T00:00:00Z", "2026-01-02T06:00:00Z"),
  ]);

  assertEquals(found.length, 1);
  assertEquals(found[0].night, "2026-01-01");
  assertEquals(found[0].asleepHours, 6.5);
});

Deno.test("stages are broken out and time in bed is kept apart from time asleep", () => {
  const [night] = nights([
    sleep("2026-01-01T23:00:00Z", "2026-01-02T01:00:00Z", "asleepCore"),
    sleep("2026-01-02T01:00:00Z", "2026-01-02T02:00:00Z", "asleepREM"),
    sleep("2026-01-01T22:30:00Z", "2026-01-02T02:30:00Z", "inBed"),
  ]);

  assertEquals(night.asleepHours, 3);
  assertEquals(night.inBedHours, 4);
  assertEquals(night.stages, { asleepCore: 2, asleepREM: 1 });
});

Deno.test("hourly totals never reach a daily table", () => {
  // Both buckets live in the same day, so a reader that took whichever came
  // first would report a day of eight hundred steps as one of twelve thousand.
  const day: Event[] = [
    { id: "d", v: 1, metric: "steps", bucket: "day", value: 12000, unit: "count" },
    { id: "h1", v: 1, metric: "steps", bucket: "hour", value: 400, unit: "count" },
    { id: "h2", v: 1, metric: "steps", bucket: "hour", value: 400, unit: "count" },
  ];

  const rows = dailyTotals([{ day: "2026-01-01", events: day }], ["steps", "flightsClimbed"]);

  assertEquals(rows[0].values.steps, 12000);
  assertEquals(rows[0].values.flightsClimbed, null, "a day with no total must not read as zero");
});

Deno.test("a workout comes back as an activity rather than as a number", () => {
  assertEquals(activityName("52"), "walking");
  assertEquals(activityName("13"), "cycling");
  // Unknown codes stay legible as codes. A bare 99 in an answer would be read
  // as a measurement.
  assertEquals(activityName("99"), "activity-99");
  assertEquals(activityName(undefined), "activity-unknown");
});

Deno.test("workouts are listed in order with their length in minutes", () => {
  const found = workouts([{
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

  assertEquals(found.map((workout) => workout.activity), ["walking", "cycling"]);
  assertEquals(found.map((workout) => workout.minutes), [10, 30]);
});

Deno.test("a distribution describes the spread, not just the middle", () => {
  const spread = distribution([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])!;

  assertEquals(spread.n, 10);
  assertEquals(spread.median, 5.5);
  assertEquals(spread.min, 1);
  assertEquals(spread.max, 10);
  assertEquals(spread.sum, 55);
  assertEquals(distribution([]), null, "an empty range must not answer with zeros");
});

Deno.test("weeks are named by their Monday", () => {
  // 2026-01-01 is a Thursday.
  assertEquals(groupOf("2026-01-01", "week"), "2025-12-29");
  assertEquals(groupOf("2026-01-01", "month"), "2026-01");
  assertEquals(groupOf("2026-01-01", "year"), "2026");
  assertEquals(groupOf("2026-01-01", "day"), "2026-01-01");
});

Deno.test("days are counted across month and year ends", () => {
  assertEquals(addDays("2026-02-28", 1), "2026-03-01");
  assertEquals(addDays("2026-01-01", -1), "2025-12-31");
  assertEquals(dayRange("2025-12-30", "2026-01-02").length, 4);
});

Deno.test("the summary says when a metric starts, which is when its device arrived", () => {
  const summary = summarise([
    {
      day: "2020-01-01",
      events: [{ id: "a", v: 1, metric: "steps", bucket: "day", value: 1, unit: "count" }],
    },
    {
      day: "2022-06-01",
      events: [
        { id: "b", v: 1, metric: "steps", bucket: "day", value: 2, unit: "count" },
        { id: "c", v: 1, metric: "heartRate", value: 60, unit: "count/min" },
      ],
    },
  ]);

  const steps = summary.find((entry) => entry.metric === "steps")!;
  const heart = summary.find((entry) => entry.metric === "heartRate")!;
  assertEquals(steps.firstDay, "2020-01-01");
  assertEquals(steps.kind, "total");
  assertEquals(heart.firstDay, "2022-06-01");
  assertEquals(heart.kind, "record");
  assertEquals(heart.daysCovered, 1);
});

Deno.test("blood oxygen carries the correction that its own unit is wrong", () => {
  const summary = summarise([{
    day: "2026-01-01",
    events: [{ id: "o", v: 1, metric: "oxygenSaturation", value: 0.97, unit: "%" }],
  }]);

  // The event says "%" and holds 0.97. An agent reporting that as 0.97% would
  // be describing an emergency, so the note travels with every answer.
  assertNotEquals(summary[0].unitNote, undefined);
});
