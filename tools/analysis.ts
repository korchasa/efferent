/**
 * Turning days into answers.
 *
 * Everything here is a pure function over events, so the awkward parts — which
 * night a stretch of sleep belongs to, whether two sources recorded the same
 * hour twice, what a workout number means — are decided in one place and can be
 * tested without a network or a key.
 *
 * The awkward parts are the point. An agent handed raw events gets them wrong in
 * ways that look plausible: it sums overlapping sleep and reports nine hours, it
 * adds hourly steps to daily steps and doubles the day, it prints a blood oxygen
 * of 0.97 as "0.97%". None of those fail loudly. So the tools answer in the
 * shapes people actually ask about, and the corrections happen below them.
 */

import type { Event } from "./archive.ts";

/**
 * Metrics whose numbers are already summed by Health, and must never be summed
 * again from records.
 *
 * iPhone, Watch and other apps all write steps for the same minutes, so adding
 * samples double-counts against what the Health app itself shows. These arrive
 * pre-bucketed and carry `bucket`.
 */
export const TOTALS = [
  "steps",
  "distanceWalkingRunning",
  "flightsClimbed",
  "activeEnergy",
  "basalEnergy",
  "exerciseTime",
  "standTime",
] as const;

/** Metrics that travel record by record, because a total of them says nothing. */
export const RECORDS = [
  "heartRate",
  "restingHeartRate",
  "heartRateVariability",
  "respiratoryRate",
  "oxygenSaturation",
  "sleep",
  "workout",
] as const;

/**
 * Where the unit written on an event would mislead a reader.
 *
 * HealthKit's percent unit is a fraction, so blood oxygen leaves the phone as
 * 0.97 with the unit "%". An agent reading that reports "0.97%" — a tenth of the
 * real figure and a number that would mean a medical emergency. The label is
 * corrected here rather than the value, because the value is what is in the
 * archive and rewriting it would put two meanings of the same field into one
 * history.
 */
export const UNIT_NOTES: Record<string, string> = {
  oxygenSaturation:
    "fraction of 1, not a percentage — 0.97 means 97%. The unit written on the event says '%' and is wrong.",
};

/**
 * `HKWorkoutActivityType` raw values, which is all the phone sends.
 *
 * Only the ones this archive contains plus the common neighbours; anything else
 * comes back as `activity-<n>` rather than as a bare number, so a reader is
 * never left guessing whether 52 is a code or a measurement.
 */
const ACTIVITIES: Record<string, string> = {
  "9": "climbing",
  "11": "crossTraining",
  "13": "cycling",
  "16": "elliptical",
  "20": "functionalStrengthTraining",
  "24": "hiking",
  "29": "mindAndBody",
  "35": "rowing",
  "37": "running",
  "44": "stairClimbing",
  "46": "swimming",
  "50": "traditionalStrengthTraining",
  "52": "walking",
  "57": "yoga",
  "3000": "other",
};

export function activityName(raw: unknown): string {
  const key = String(raw ?? "");
  return ACTIVITIES[key] ?? `activity-${key || "unknown"}`;
}

// MARK: - Days and ranges

export function addDays(day: string, count: number): string {
  const date = new Date(`${day}T00:00:00Z`);
  date.setUTCDate(date.getUTCDate() + count);
  return date.toISOString().slice(0, 10);
}

export function daysBetween(from: string, to: string): number {
  const a = Date.parse(`${from}T00:00:00Z`);
  const b = Date.parse(`${to}T00:00:00Z`);
  return Math.round((b - a) / 86_400_000);
}

/** Every day in an inclusive range, in order. */
export function dayRange(from: string, to: string): string[] {
  const days: string[] = [];
  for (let day = from; day <= to; day = addDays(day, 1)) days.push(day);
  return days;
}

// MARK: - What is in the archive at all

export interface MetricSummary {
  metric: string;
  kind: "total" | "record";
  unit: string | null;
  unitNote?: string;
  buckets: string[];
  firstDay: string;
  lastDay: string;
  daysCovered: number;
  events: number;
}

/**
 * What each metric is, when it starts, and how much of it there is.
 *
 * The start dates are the most useful thing in here and are not obvious: a
 * metric begins on the day the device that measures it arrived, so asking for
 * heart rate before that day is not a gap in the data, it is a question about a
 * time when nothing was measuring.
 */
export function summarise(days: { day: string; events: Event[] }[]): MetricSummary[] {
  const found = new Map<string, {
    kind: "total" | "record";
    unit: string | null;
    buckets: Set<string>;
    first: string;
    last: string;
    days: Set<string>;
    events: number;
  }>();

  for (const { day, events } of days) {
    for (const event of events) {
      const metric = event.metric;
      if (!metric) continue;
      const existing = found.get(metric);
      if (!existing) {
        found.set(metric, {
          kind: event.bucket ? "total" : "record",
          unit: typeof event.unit === "string" ? event.unit : null,
          buckets: new Set(event.bucket ? [event.bucket] : []),
          first: day,
          last: day,
          days: new Set([day]),
          events: 1,
        });
        continue;
      }
      if (event.bucket) existing.buckets.add(event.bucket);
      if (day < existing.first) existing.first = day;
      if (day > existing.last) existing.last = day;
      existing.days.add(day);
      existing.events++;
    }
  }

  return [...found.entries()]
    .map(([metric, value]) => ({
      metric,
      kind: value.kind,
      unit: value.unit,
      ...(UNIT_NOTES[metric] ? { unitNote: UNIT_NOTES[metric] } : {}),
      buckets: [...value.buckets].sort(),
      firstDay: value.first,
      lastDay: value.last,
      daysCovered: value.days.size,
      events: value.events,
    }))
    .sort((left, right) => left.firstDay.localeCompare(right.firstDay));
}

// MARK: - Numbers

export interface Distribution {
  n: number;
  min: number;
  p10: number;
  median: number;
  mean: number;
  p90: number;
  max: number;
  sum: number;
}

export function distribution(values: number[]): Distribution | null {
  if (values.length === 0) return null;
  const sorted = [...values].sort((left, right) => left - right);
  const sum = sorted.reduce((total, value) => total + value, 0);
  return {
    n: sorted.length,
    min: round(sorted[0]),
    p10: round(percentile(sorted, 0.1)),
    median: round(percentile(sorted, 0.5)),
    mean: round(sum / sorted.length),
    p90: round(percentile(sorted, 0.9)),
    max: round(sorted[sorted.length - 1]),
    sum: round(sum),
  };
}

/** Linear interpolation between the neighbouring ranks, on an already sorted
 * list. */
function percentile(sorted: number[], fraction: number): number {
  if (sorted.length === 1) return sorted[0];
  const position = (sorted.length - 1) * fraction;
  const lower = Math.floor(position);
  const upper = Math.ceil(position);
  if (lower === upper) return sorted[lower];
  return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - lower);
}

/** Three decimals is past the precision of every measurement here and keeps the
 * answers readable; a step count is an integer either way. */
function round(value: number): number {
  return Math.round(value * 1000) / 1000;
}

// MARK: - Daily totals

/**
 * One row per day, one column per metric, from the day buckets only.
 *
 * Day buckets only, and this is the whole reason the function exists: the same
 * archive carries hourly buckets for recent days, and a reader that took both
 * would count those days twice.
 */
export function dailyTotals(
  days: { day: string; events: Event[] }[],
  metrics: string[],
): { day: string; values: Record<string, number | null> }[] {
  return days.map(({ day, events }) => {
    const values: Record<string, number | null> = {};
    for (const metric of metrics) values[metric] = null;
    for (const event of events) {
      if (event.bucket !== "day") continue;
      const metric = event.metric;
      if (!metric || !(metric in values)) continue;
      if (typeof event.value === "number") values[metric] = round(event.value);
    }
    return { day, values };
  });
}

// MARK: - Grouping

export type Grouping = "day" | "week" | "month" | "year";

/** The label a day falls under. Weeks are ISO weeks, so they start on Monday
 * and a week is named by the Monday itself rather than by a number nobody can
 * place in a year. */
export function groupOf(day: string, grouping: Grouping): string {
  if (grouping === "day") return day;
  if (grouping === "month") return day.slice(0, 7);
  if (grouping === "year") return day.slice(0, 4);
  const date = new Date(`${day}T00:00:00Z`);
  const weekday = (date.getUTCDay() + 6) % 7;
  return addDays(day, -weekday);
}

// MARK: - Sleep

export interface Night {
  night: string;
  asleepHours: number;
  inBedHours: number | null;
  stages: Record<string, number>;
  start: string | null;
  end: string | null;
  segments: number;
}

/**
 * Nights, assembled out of the stretches the watch recorded.
 *
 * Two corrections live here and both change the answer:
 *
 * **Overlaps are merged, never added.** Sleep arrives as overlapping stretches
 * with stages, and more than one source can describe the same minutes. Adding
 * their lengths gives nine hours of sleep to someone who slept six, and it is
 * the kind of wrong that reads as good news.
 *
 * **A night is noon to noon.** A night that began before midnight is in the
 * evening's day and the rest of it is in the next, so grouping by the calendar
 * day would cut every night in half and report two short ones. Naps fall into
 * the night of the day they happened on, which is the price of a rule simple
 * enough to be predictable.
 */
export function nights(events: Event[]): Night[] {
  const byNight = new Map<string, Event[]>();
  for (const event of events) {
    if (event.metric !== "sleep" || !event.start || !event.end) continue;
    const label = new Date(Date.parse(event.start) - 12 * 3600_000).toISOString().slice(0, 10);
    const bucket = byNight.get(label);
    if (bucket) bucket.push(event);
    else byNight.set(label, [event]);
  }

  return [...byNight.entries()].sort((left, right) => left[0].localeCompare(right[0])).map(
    ([night, stretches]) => {
      const asleep = stretches.filter((event) => String(event.stage ?? "").startsWith("asleep"));
      const inBed = stretches.filter((event) => event.stage === "inBed");

      const stages: Record<string, number> = {};
      for (const stage of new Set(asleep.map((event) => String(event.stage)))) {
        stages[stage] = round(
          merged(asleep.filter((event) => event.stage === stage)) / 3600,
        );
      }

      const spans = asleep.length > 0 ? asleep : stretches;
      const starts = spans.map((event) => String(event.start)).sort();
      const ends = spans.map((event) => String(event.end)).sort();

      return {
        night,
        asleepHours: round(merged(asleep) / 3600),
        inBedHours: inBed.length > 0 ? round(merged(inBed) / 3600) : null,
        stages,
        start: starts[0] ?? null,
        end: ends[ends.length - 1] ?? null,
        segments: asleep.length,
      };
    },
  );
}

/** The length of the union of a set of intervals, in seconds. */
function merged(events: Event[]): number {
  const spans = events
    .map((event) => [Date.parse(String(event.start)), Date.parse(String(event.end))] as const)
    .filter(([from, to]) => Number.isFinite(from) && Number.isFinite(to) && to > from)
    .sort((left, right) => left[0] - right[0]);

  let total = 0;
  let from = 0;
  let to = -1;
  for (const [start, end] of spans) {
    if (start > to) {
      if (to > from) total += to - from;
      from = start;
      to = end;
    } else if (end > to) to = end;
  }
  if (to > from) total += to - from;
  return total / 1000;
}

// MARK: - Workouts

export interface Workout {
  day: string;
  activity: string;
  start: string;
  end: string;
  minutes: number;
  source: string | null;
}

export function workouts(days: { day: string; events: Event[] }[]): Workout[] {
  const found: Workout[] = [];
  for (const { day, events } of days) {
    for (const event of events) {
      if (event.metric !== "workout") continue;
      found.push({
        day,
        activity: activityName(event.activity),
        start: String(event.start ?? ""),
        end: String(event.end ?? ""),
        minutes: round(Number(event.duration ?? 0) / 60),
        source: typeof event.source === "string" ? event.source : null,
      });
    }
  }
  return found.sort((left, right) => left.start.localeCompare(right.start));
}
