"""The corrections that keep an answer from being plausibly wrong."""

import unittest

from efferent.analysis import (
    activity_name,
    daily_totals,
    distribution,
    group_of,
    nights,
    summarise,
    workouts,
)
from efferent.days import add_days, day_range


def sleep(start, end, stage="asleepCore", source="Watch"):
    return {
        "id": f"hk:sleep:{start}:{source}",
        "v": 1,
        "metric": "sleep",
        "stage": stage,
        "start": start,
        "end": end,
        "source": source,
    }


class Sleep(unittest.TestCase):
    def test_overlapping_stretches_are_merged_rather_than_added(self):
        # The same hour described twice — a watch and an app, or one stretch
        # split by a stage change that overlaps its neighbour. Adding the
        # lengths would give six hours of sleep to someone who slept four, and
        # it reads as good news.
        night = nights(
            [
                sleep("2026-01-01T22:00:00Z", "2026-01-02T00:00:00Z"),
                sleep("2026-01-01T23:00:00Z", "2026-01-02T02:00:00Z", "asleepDeep", "Phone"),
            ]
        )[0]

        self.assertEqual(night["asleepHours"], 4, "the overlap was counted twice")

    def test_a_night_across_midnight_is_one_night_named_by_the_evening(self):
        # The evening half is stored in one day file and the small hours in the
        # next, because a record belongs to the day it started on. Grouping by
        # that day would report two short nights where there was one long one.
        found = nights(
            [
                sleep("2026-01-01T23:30:00Z", "2026-01-02T00:00:00Z"),
                sleep("2026-01-02T00:00:00Z", "2026-01-02T06:00:00Z"),
            ]
        )

        self.assertEqual(len(found), 1)
        self.assertEqual(found[0]["night"], "2026-01-01")
        self.assertEqual(found[0]["asleepHours"], 6.5)

    def test_stages_are_broken_out_and_time_in_bed_kept_apart(self):
        night = nights(
            [
                sleep("2026-01-01T23:00:00Z", "2026-01-02T01:00:00Z", "asleepCore"),
                sleep("2026-01-02T01:00:00Z", "2026-01-02T02:00:00Z", "asleepREM"),
                sleep("2026-01-01T22:30:00Z", "2026-01-02T02:30:00Z", "inBed"),
            ]
        )[0]

        self.assertEqual(night["asleepHours"], 3)
        self.assertEqual(night["inBedHours"], 4)
        self.assertEqual(night["stages"], {"asleepCore": 2, "asleepREM": 1})


class Totals(unittest.TestCase):
    def test_hourly_totals_never_reach_a_daily_table(self):
        # Both buckets live in the same day, so a reader that took whichever
        # came first would report a day of eight hundred steps as one of twelve
        # thousand.
        day = [
            {"id": "d", "v": 1, "metric": "steps", "bucket": "day", "value": 12000},
            {"id": "h1", "v": 1, "metric": "steps", "bucket": "hour", "value": 400},
            {"id": "h2", "v": 1, "metric": "steps", "bucket": "hour", "value": 400},
        ]

        rows = daily_totals([{"day": "2026-01-01", "events": day}], ["steps", "flightsClimbed"])

        self.assertEqual(rows[0]["values"]["steps"], 12000)
        self.assertIsNone(
            rows[0]["values"]["flightsClimbed"], "a day with no total must not read as zero"
        )


class Workouts(unittest.TestCase):
    def test_a_workout_comes_back_as_an_activity_rather_than_a_number(self):
        self.assertEqual(activity_name("52"), "walking")
        self.assertEqual(activity_name("13"), "cycling")
        # Unknown codes stay legible as codes. A bare 99 in an answer would be
        # read as a measurement.
        self.assertEqual(activity_name("99"), "activity-99")
        self.assertEqual(activity_name(None), "activity-unknown")

    def test_workouts_are_listed_in_order_with_their_length_in_minutes(self):
        found = workouts(
            [
                {
                    "day": "2026-01-02",
                    "events": [
                        {
                            "id": "w2",
                            "v": 1,
                            "metric": "workout",
                            "activity": "13",
                            "duration": 1800,
                            "start": "2026-01-02T10:00:00Z",
                            "end": "2026-01-02T10:30:00Z",
                        },
                        {
                            "id": "w1",
                            "v": 1,
                            "metric": "workout",
                            "activity": "52",
                            "duration": 600,
                            "start": "2026-01-02T08:00:00Z",
                            "end": "2026-01-02T08:10:00Z",
                        },
                    ],
                }
            ]
        )

        self.assertEqual([w["activity"] for w in found], ["walking", "cycling"])
        self.assertEqual([w["minutes"] for w in found], [10, 30])


class Numbers(unittest.TestCase):
    def test_a_distribution_describes_the_spread_not_just_the_middle(self):
        spread = distribution([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])

        self.assertEqual(spread["n"], 10)
        self.assertEqual(spread["median"], 5.5)
        self.assertEqual(spread["min"], 1)
        self.assertEqual(spread["max"], 10)
        self.assertEqual(spread["sum"], 55)
        self.assertIsNone(distribution([]), "an empty range must not answer with zeros")


class Days(unittest.TestCase):
    def test_weeks_are_named_by_their_monday(self):
        # 2026-01-01 is a Thursday.
        self.assertEqual(group_of("2026-01-01", "week"), "2025-12-29")
        self.assertEqual(group_of("2026-01-01", "month"), "2026-01")
        self.assertEqual(group_of("2026-01-01", "year"), "2026")
        self.assertEqual(group_of("2026-01-01", "day"), "2026-01-01")

    def test_days_are_counted_across_month_and_year_ends(self):
        self.assertEqual(add_days("2026-02-28", 1), "2026-03-01")
        self.assertEqual(add_days("2026-01-01", -1), "2025-12-31")
        self.assertEqual(len(day_range("2025-12-30", "2026-01-02")), 4)


class Summary(unittest.TestCase):
    def test_the_summary_says_when_a_metric_starts(self):
        summary = summarise(
            [
                {
                    "day": "2020-01-01",
                    "events": [
                        {"id": "a", "v": 1, "metric": "steps", "bucket": "day", "unit": "count"}
                    ],
                },
                {
                    "day": "2022-06-01",
                    "events": [
                        {"id": "b", "v": 1, "metric": "steps", "bucket": "day", "unit": "count"},
                        {"id": "c", "v": 1, "metric": "heartRate", "unit": "count/min"},
                    ],
                },
            ]
        )

        steps = next(entry for entry in summary if entry["metric"] == "steps")
        heart = next(entry for entry in summary if entry["metric"] == "heartRate")
        self.assertEqual(steps["firstDay"], "2020-01-01")
        self.assertEqual(steps["kind"], "total")
        self.assertEqual(heart["firstDay"], "2022-06-01")
        self.assertEqual(heart["kind"], "record")
        self.assertEqual(heart["daysCovered"], 1)

    def test_blood_oxygen_carries_the_correction_that_its_unit_is_wrong(self):
        summary = summarise(
            [
                {
                    "day": "2026-01-01",
                    "events": [
                        {
                            "id": "o",
                            "v": 1,
                            "metric": "oxygenSaturation",
                            "value": 0.97,
                            "unit": "%",
                        }
                    ],
                }
            ]
        )

        # The event says "%" and holds 0.97. An agent reporting that as 0.97%
        # would be describing an emergency, so the note travels with the answer.
        self.assertIn("unitNote", summary[0])


if __name__ == "__main__":
    unittest.main()
