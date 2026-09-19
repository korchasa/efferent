"""Turning days into answers.

Everything here is a pure function over events, so the awkward parts — which
night a stretch of sleep belongs to, whether two sources recorded the same
hour twice, what a workout number means — are decided in one place and can be
tested without a network or a key.

The awkward parts are the point. An agent handed raw events gets them wrong in
ways that look plausible: it sums overlapping sleep and reports nine hours, it
adds hourly steps to daily steps and doubles the day, it prints a blood oxygen
of 0.97 as "0.97%". None of those fail loudly. So the tools answer in the
shapes people actually ask about, and the corrections happen below them.
"""

from datetime import datetime, timedelta, timezone

from .days import add_days

Event = dict

# Metrics whose numbers are already summed by Health, and must never be summed
# again from records. iPhone, Watch and other apps all write steps for the same
# minutes, so adding samples double-counts against what the Health app itself
# shows. These arrive pre-bucketed and carry `bucket`.
TOTALS = (
    "steps",
    "distanceWalkingRunning",
    "flightsClimbed",
    "activeEnergy",
    "basalEnergy",
    "exerciseTime",
    "standTime",
    # What an agent may write, summed by Health like everything else here: a
    # day of meals is one number per nutrient, however many entries made it.
    "dietaryEnergy",
    "dietaryProtein",
    "dietaryCarbohydrates",
    "dietaryFat",
    "dietaryWater",
)

# Metrics that travel record by record, because a total of them says nothing.
RECORDS = (
    "heartRate",
    "restingHeartRate",
    "heartRateVariability",
    "respiratoryRate",
    "oxygenSaturation",
    "bodyMass",
    "sleep",
    "workout",
)

# Where the unit written on an event would mislead a reader. HealthKit's percent
# unit is a fraction, so blood oxygen leaves the phone as 0.97 with the unit
# "%". The label is corrected here rather than the value, because the value is
# what is in the archive and rewriting it would put two meanings of the same
# field into one history.
UNIT_NOTES = {
    "oxygenSaturation": (
        "fraction of 1, not a percentage — 0.97 means 97%. "
        "The unit written on the event says '%' and is wrong."
    ),
}

# HKWorkoutActivityType raw values, which is all the phone sends. Anything else
# comes back as `activity-<n>` rather than as a bare number, so a reader is
# never left guessing whether 52 is a code or a measurement.
ACTIVITIES = {
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
}


def activity_name(raw: object) -> str:
    key = "" if raw is None else str(raw)
    return ACTIVITIES.get(key, f"activity-{key or 'unknown'}")


def round3(value: float) -> float | int:
    """Three decimals is past the precision of every measurement here and keeps
    the answers readable; a whole number stays whole, as it did in JSON."""
    rounded = round(value, 3)
    return int(rounded) if rounded == int(rounded) else rounded


# MARK: - What is in the archive at all


def what_a_day_holds(events: list[Event]) -> dict:
    """What one day holds, per metric, and nothing about any other day.

    Split out because it is the expensive half and the half that does not
    change: a day is written once and then answers the same question forever,
    so this can be worked out once and kept."""
    held: dict = {}
    for event in events:
        metric = event.get("metric")
        if not metric:
            continue
        bucket = event.get("bucket") if isinstance(event.get("bucket"), str) else None
        existing = held.get(metric)
        if existing is None:
            unit = event.get("unit")
            held[metric] = {
                "buckets": [bucket] if bucket else [],
                "unit": unit if isinstance(unit, str) else None,
                "events": 1,
            }
            continue
        if bucket and bucket not in existing["buckets"]:
            existing["buckets"].append(bucket)
        existing["events"] += 1
    return held


def fold(days: list[dict]) -> list[dict]:
    """Day summaries into one summary of the archive.

    Every part combines: the buckets are a union, the first and last days a
    minimum and a maximum, the counts sums. The two fields that are *not*
    combined — what kind of thing a metric is and what unit it carries — come
    from the first day that holds it, so the days must arrive in order."""
    found: dict = {}
    for entry in days:
        day = entry["day"]
        for metric, holding in entry["held"].items():
            existing = found.get(metric)
            if existing is None:
                found[metric] = {
                    "kind": "total" if holding["buckets"] else "record",
                    "unit": holding["unit"],
                    "buckets": set(holding["buckets"]),
                    "first": day,
                    "last": day,
                    "days": {day},
                    "events": holding["events"],
                }
                continue
            existing["buckets"].update(holding["buckets"])
            existing["first"] = min(existing["first"], day)
            existing["last"] = max(existing["last"], day)
            existing["days"].add(day)
            existing["events"] += holding["events"]

    summaries = []
    for metric, value in found.items():
        summary = {"metric": metric, "kind": value["kind"], "unit": value["unit"]}
        if metric in UNIT_NOTES:
            summary["unitNote"] = UNIT_NOTES[metric]
        summary.update(
            buckets=sorted(value["buckets"]),
            firstDay=value["first"],
            lastDay=value["last"],
            daysCovered=len(value["days"]),
            events=value["events"],
        )
        summaries.append(summary)
    return sorted(summaries, key=lambda summary: summary["firstDay"])


def summarise(days: list[dict]) -> list[dict]:
    """What each metric is, when it starts, and how much of it there is."""
    return fold([{"day": d["day"], "held": what_a_day_holds(d["events"])} for d in days])


# MARK: - Numbers


def percentile(sorted_values: list[float], fraction: float) -> float:
    """Linear interpolation between the neighbouring ranks."""
    if len(sorted_values) == 1:
        return sorted_values[0]
    position = (len(sorted_values) - 1) * fraction
    lower = int(position // 1)
    upper = lower + (1 if position != lower else 0)
    if lower == upper:
        return sorted_values[lower]
    return sorted_values[lower] + (sorted_values[upper] - sorted_values[lower]) * (position - lower)


def distribution(values: list[float]) -> dict | None:
    if not values:
        return None
    ordered = sorted(values)
    total = sum(ordered)
    return {
        "n": len(ordered),
        "min": round3(ordered[0]),
        "p10": round3(percentile(ordered, 0.1)),
        "median": round3(percentile(ordered, 0.5)),
        "mean": round3(total / len(ordered)),
        "p90": round3(percentile(ordered, 0.9)),
        "max": round3(ordered[-1]),
        "sum": round3(total),
    }


def empty_distribution() -> dict:
    return {"n": 0, "min": 0, "p10": 0, "median": 0, "mean": 0, "p90": 0, "max": 0, "sum": 0}


# MARK: - Daily totals


def daily_totals(days: list[dict], metrics: list[str]) -> list[dict]:
    """One row per day, one column per metric, from the day buckets only. The
    same archive carries hourly buckets for recent days, and a reader that
    took both would count those days twice."""
    rows = []
    for entry in days:
        values: dict = {metric: None for metric in metrics}
        for event in entry["events"]:
            if event.get("bucket") != "day":
                continue
            metric = event.get("metric")
            if metric not in values:
                continue
            value = event.get("value")
            if isinstance(value, (int, float)) and not isinstance(value, bool):
                values[metric] = round3(value)
        rows.append({"day": entry["day"], "values": values})
    return rows


# MARK: - Grouping


def group_of(day: str, grouping: str) -> str:
    """The label a day falls under. Weeks are ISO weeks, so they start on Monday
    and a week is named by the Monday itself."""
    if grouping == "day":
        return day
    if grouping == "month":
        return day[:7]
    if grouping == "year":
        return day[:4]
    weekday = datetime.fromisoformat(day).weekday()
    return add_days(day, -weekday)


# MARK: - Sleep


def parse_instant(value: object) -> float | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def merged(events: list[Event]) -> float:
    """The length of the union of a set of intervals, in seconds."""
    spans = []
    for event in events:
        start, end = parse_instant(event.get("start")), parse_instant(event.get("end"))
        if start is not None and end is not None and end > start:
            spans.append((start, end))
    spans.sort()
    total = 0.0
    frm, to = 0.0, -1.0
    for start, end in spans:
        if start > to:
            if to > frm:
                total += to - frm
            frm, to = start, end
        elif end > to:
            to = end
    if to > frm:
        total += to - frm
    return total


def nights(events: list[Event]) -> list[dict]:
    """Nights, assembled out of the stretches the watch recorded.

    Overlaps are merged, never added: more than one source can describe the
    same minutes, and adding their lengths gives nine hours of sleep to someone
    who slept six. A night is noon to noon, named by the evening it began in,
    so grouping by the calendar day does not cut every night in half."""
    by_night: dict[str, list[Event]] = {}
    for event in events:
        if event.get("metric") != "sleep" or not event.get("start") or not event.get("end"):
            continue
        started = parse_instant(event["start"])
        if started is None:
            continue
        label = (
            (datetime.fromtimestamp(started, timezone.utc) - timedelta(hours=12)).date().isoformat()
        )
        by_night.setdefault(label, []).append(event)

    result = []
    for night in sorted(by_night):
        stretches = by_night[night]
        asleep = [e for e in stretches if str(e.get("stage") or "").startswith("asleep")]
        in_bed = [e for e in stretches if e.get("stage") == "inBed"]

        stages = {}
        for stage in sorted({str(e.get("stage")) for e in asleep}):
            stages[stage] = round3(merged([e for e in asleep if e.get("stage") == stage]) / 3600)

        spans = asleep if asleep else stretches
        starts = sorted(str(e.get("start")) for e in spans)
        ends = sorted(str(e.get("end")) for e in spans)
        result.append(
            {
                "night": night,
                "asleepHours": round3(merged(asleep) / 3600),
                "inBedHours": round3(merged(in_bed) / 3600) if in_bed else None,
                "stages": stages,
                "start": starts[0] if starts else None,
                "end": ends[-1] if ends else None,
                "segments": len(asleep),
            }
        )
    return result


# MARK: - Workouts


def workouts(days: list[dict]) -> list[dict]:
    found = []
    for entry in days:
        for event in entry["events"]:
            if event.get("metric") != "workout":
                continue
            duration = event.get("duration")
            source = event.get("source")
            found.append(
                {
                    "day": entry["day"],
                    "activity": activity_name(event.get("activity")),
                    "start": str(event.get("start") or ""),
                    "end": str(event.get("end") or ""),
                    "minutes": round3(float(duration or 0) / 60),
                    "source": source if isinstance(source, str) else None,
                }
            )
    return sorted(found, key=lambda workout: workout["start"])
