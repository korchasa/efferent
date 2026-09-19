"""The reading side against an archive that answers."""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey

import efferent_hpke as wire
from efferent.archive import pkcs8
from efferent.days import add_days

from .fake_archive import FakeArchive

ROOT = Path(__file__).resolve().parent.parent


def total(metric: str, on: str, value: int) -> dict:
    return {
        "metric": metric,
        "bucket": "day",
        "value": value,
        "unit": "count",
        "start": f"{on}T00:00:00Z",
        "end": f"{on}T23:59:59Z",
    }


def seed_run(archive: FakeArchive, frm: str, count: int) -> list[str]:
    """Days named from a start, one total each, so a day is identifiable by its
    value alone."""
    days = []
    day = frm
    for index in range(count):
        archive.put(day, [total("steps", day, 1000 + index)])
        days.append(day)
        day = add_days(day, 1)
    return days


class Reader(unittest.TestCase):
    """A home holding the reading key, and an archive to point it at."""

    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix="efferent-reader-"))
        private = X25519PrivateKey.generate()
        reading_public = private.public_key().public_bytes(*wire.RAW)
        (self.home / "reading-key.json").write_text(
            json.dumps(
                {
                    "readingPrivate": pkcs8(private),
                    "readingPublic": wire.to_base64url(reading_public),
                }
            )
        )
        self.archive = FakeArchive(reading_public)
        (self.home / "mirror.json").write_text(
            json.dumps({"endpoint": self.archive.url, "days": {}, "syncedAt": ""})
        )

    def tearDown(self):
        self.archive.stop()
        shutil.rmtree(self.home, ignore_errors=True)

    # MARK: - Helpers

    def cli(self, *args: str) -> subprocess.CompletedProcess:
        """The command line tool, run to completion in a process of its own: the
        reading layer takes its home from the environment, and a test that ran
        it in this one would answer about this one."""
        return subprocess.run(
            [sys.executable, "-m", "efferent", *args],
            env={**os.environ, "EFFERENT_HOME": str(self.home), "PYTHONPATH": str(ROOT)},
            capture_output=True,
            text=True,
            cwd=ROOT,
        )

    def mirrored_state(self) -> dict:
        return json.loads((self.home / "mirror.json").read_text())

    def mirrored_files(self) -> list[str]:
        try:
            return sorted(
                path.name[: -len(".ndjson")]
                for path in (self.home / "days").iterdir()
                if path.name.endswith(".ndjson")
            )
        except OSError:
            return []


class Listing(Reader):
    def test_a_listing_is_walked_past_its_own_page_size(self):
        seed_run(self.archive, "2026-03-01", 7)

        run = self.cli("sync", "--url", self.archive.url)

        self.assertEqual(run.returncode, 0, run.stderr)
        # Seven days at two per page is four requests: three full and the last.
        self.assertGreaterEqual(
            self.archive.listings(), 4, f"walked only {self.archive.listings()} pages"
        )
        self.assertEqual(len(self.mirrored_files()), 7)

    def test_a_listing_that_breaks_part_way_through_answers_short_for_nobody(self):
        seed_run(self.archive, "2026-03-01", 7)
        # The stats call comes first and is not a listing, so page 1 is the
        # second page of the walk — far enough in that a short answer would look
        # plausible.
        self.archive.fault = {"page": 1}

        run = self.cli("sync", "--url", self.archive.url)

        self.assertNotEqual(run.returncode, 0, "a broken listing was reported as a finished sync")
        self.assertIn("500", run.stderr)
        # The whole point: nothing was recorded as mirrored on the strength of a
        # walk that never finished.
        self.assertEqual(self.mirrored_state()["days"], {})


class WindowedFetch(Reader):
    def test_days_come_back_in_the_order_they_were_asked_for(self):
        seed_run(self.archive, "2026-03-01", 20)

        run = self.cli("read", "--url", self.archive.url)

        self.assertEqual(run.returncode, 0, run.stderr)
        days = [json.loads(line)["start"][:10] for line in run.stdout.strip().split("\n")]
        self.assertEqual(len(days), 20)
        self.assertEqual(
            days,
            sorted(days),
            "the stream of days came back out of order; a reader of it cannot tell",
        )

    def test_a_refused_day_stops_the_fetch_instead_of_being_skipped(self):
        seed_run(self.archive, "2026-03-01", 20)
        self.archive.fault = {"day": "2026-03-11"}

        run = self.cli("sync", "--url", self.archive.url)

        self.assertNotEqual(run.returncode, 0, "a refused day was reported as a finished sync")
        self.assertIn("2026-03-11", run.stderr)
        # A day that never arrived must not be recorded as mirrored: nothing
        # would ever ask for it again.
        self.assertNotIn("2026-03-11", self.mirrored_state()["days"])

    def test_no_more_than_one_window_of_days_is_ever_in_the_air(self):
        seed_run(self.archive, "2026-03-01", 40)

        run = self.cli("sync", "--url", self.archive.url)

        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertGreater(self.archive.max_in_flight, 1, "the days were fetched one at a time")
        self.assertLessEqual(
            self.archive.max_in_flight,
            8,
            f"{self.archive.max_in_flight} days were open at once, more than the window",
        )
        self.assertEqual(len(self.mirrored_files()), 40)


class Mirror(Reader):
    def test_a_mirror_already_level_with_the_archive_fetches_nothing(self):
        seed_run(self.archive, "2026-03-01", 3)
        self.assertEqual(self.cli("sync", "--url", self.archive.url).returncode, 0)
        self.archive.forget()

        run = self.cli("sync")

        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("already up to date", run.stdout)
        self.assertEqual(self.archive.fetched_days(), [])

    def test_a_rewritten_day_is_copied_again(self):
        seed_run(self.archive, "2026-03-01", 3)
        self.cli("sync", "--url", self.archive.url)
        self.archive.put("2026-03-02", [total("steps", "2026-03-02", 9999)])
        self.archive.forget()

        run = self.cli("sync")

        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(self.archive.fetched_days(), ["2026-03-02"])
        line = (self.home / "days" / "2026-03-02.ndjson").read_text().strip()
        self.assertEqual(json.loads(line)["value"], 9999)

    def test_a_query_answers_from_the_mirror_with_the_archive_gone(self):
        seed_run(self.archive, "2026-03-01", 3)
        self.cli("sync", "--url", self.archive.url)
        self.archive.stop()

        run = self.cli("query", "--metric", "steps", "--format", "summary")

        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("3 events", run.stdout)
        self.assertIn("steps/day", run.stdout)


class Status(Reader):
    def test_status_says_what_the_archive_holds_and_what_the_mirror_has(self):
        seed_run(self.archive, "2026-03-01", 4)

        run = self.cli("status", "--url", self.archive.url)

        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn(f"bucket   {self.archive.bucket}", run.stdout)
        self.assertIn("archive  4 days", run.stdout)
        self.assertIn("mirror   nothing yet — run sync", run.stdout)

        self.cli("sync")
        after = self.cli("status")
        self.assertIn("mirror   4 days, 2026-03-01 … 2026-03-04  — up to date", after.stdout)


class Questions(Reader):
    def test_a_range_fetches_the_day_before_it_so_a_night_is_not_lost(self):
        seed_run(self.archive, "2026-03-01", 5)
        self.archive.forget()

        run = self.cli("ask", "--since", "2026-03-03", "--until", "2026-03-04")

        self.assertEqual(run.returncode, 0, run.stderr)
        # The 2nd is fetched as well: a night that began before midnight belongs
        # to the evening's day, and asking only for the 3rd would lose it. The
        # days are asked for together, so it is the set that is the claim here;
        # the order they come back in is the test above.
        self.assertEqual(
            sorted(self.archive.fetched_days()), ["2026-03-02", "2026-03-03", "2026-03-04"]
        )
        # It is then filtered out, because nothing in it overlaps the question.
        kept = [json.loads(line)["start"][:10] for line in run.stdout.strip().split("\n")]
        self.assertEqual(kept, ["2026-03-03", "2026-03-04"])

    def test_a_bound_that_is_not_a_day_is_refused_by_name(self):
        run = self.cli("query", "--since", "March")

        self.assertEqual(run.returncode, 2)
        self.assertIn("--since must be a day", run.stderr)


class NoArchive(unittest.TestCase):
    def test_a_home_with_no_archive_says_where_it_looked(self):
        home = Path(tempfile.mkdtemp(prefix="efferent-empty-"))
        try:
            run = subprocess.run(
                [sys.executable, "-m", "efferent", "status"],
                env={**os.environ, "EFFERENT_HOME": str(home), "PYTHONPATH": str(ROOT)},
                capture_output=True,
                text=True,
                cwd=ROOT,
            )
            self.assertEqual(run.returncode, 2)
            self.assertIn("no archive is configured", run.stderr)
            self.assertIn(str(home), run.stderr)
        finally:
            shutil.rmtree(home, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
