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
from efferent.archive import FETCH_WINDOW, pkcs8
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
        self.reading_private = private.private_bytes_raw()
        self.reading_public = reading_public
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

    def test_a_run_of_days_is_asked_for_as_a_range_not_a_day_at_a_time(self):
        seed_run(self.archive, "2026-03-01", 40)

        run = self.cli("sync", "--url", self.archive.url)

        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(len(self.mirrored_files()), 40)
        # Forty days in a row are one range. The archive here answers three days
        # at a time, so that is fourteen answers followed one from the next —
        # where a request per day was forty.
        self.assertEqual(len(self.archive.ranges()), 14)
        self.assertEqual(
            [path for path in self.archive.asked if "/d/" in path], [], "a day was asked for alone"
        )

    def test_no_more_than_one_window_of_ranges_is_ever_in_the_air(self):
        # A day a fortnight: too far apart to share a range, so each is a
        # request of its own and only the window holds them back.
        day = "2026-01-01"
        for index in range(16):
            self.archive.put(day, [total("steps", day, 1000 + index)])
            day = add_days(day, 14)

        run = self.cli("sync", "--url", self.archive.url)

        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(len(self.mirrored_files()), 16)
        self.assertEqual(len(self.archive.ranges()), 16)
        self.assertGreater(self.archive.max_in_flight, 1, "the ranges were asked for one at a time")
        self.assertLessEqual(
            self.archive.max_in_flight,
            FETCH_WINDOW,
            f"{self.archive.max_in_flight} ranges were open at once, more than the window",
        )

    def test_days_close_together_share_a_range_and_the_ones_between_are_dropped(self):
        seed_run(self.archive, "2026-03-01", 10)
        self.cli("sync", "--url", self.archive.url)
        # Two rewritten days four apart: one range is cheaper than two, and the
        # days between come along without being written down a second time.
        self.archive.put("2026-03-03", [total("steps", "2026-03-03", 7777)])
        self.archive.put("2026-03-07", [total("steps", "2026-03-07", 8888)])
        before = (self.home / "days" / "2026-03-05.ndjson").stat().st_mtime_ns
        self.archive.forget()

        run = self.cli("sync")

        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(len(self.archive.ranges()), 2, "five days of range is two answers")
        self.assertEqual(
            (self.home / "days" / "2026-03-05.ndjson").stat().st_mtime_ns,
            before,
            "a day nobody asked for was written again because it came along in a range",
        )
        line = (self.home / "days" / "2026-03-07.ndjson").read_text().strip()
        self.assertEqual(json.loads(line)["value"], 8888)


class SignedReads(Reader):
    """Once the phone registers a read key, the bucket id opens nothing and every
    read has to be signed with that key. The reader never stores it: it is made
    from the reading key each time, the same way the phone makes it."""

    def registered(self) -> None:
        self.archive.reader = (
            wire.read_key(self.reading_private).public_key().public_bytes(*wire.RAW)
        )

    def test_every_read_is_signed_with_the_key_made_from_the_reading_key(self):
        seed_run(self.archive, "2026-03-01", 5)
        self.registered()

        run = self.cli("sync", "--url", self.archive.url)

        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(len(self.mirrored_files()), 5)
        self.assertIn("archive  5 days", self.cli("status").stdout)

    def test_a_read_key_this_reader_does_not_hold_is_refused_by_name(self):
        seed_run(self.archive, "2026-03-01", 3)
        self.archive.reader = (
            wire.read_key(bytes(range(1, 33))).public_key().public_bytes(*wire.RAW)
        )

        run = self.cli("sync", "--url", self.archive.url)

        self.assertNotEqual(run.returncode, 0, "a read under somebody else's key looked fine")
        self.assertIn("403", run.stderr)
        self.assertIn("not this archive's read key", run.stderr)
        self.assertEqual(self.mirrored_files(), [])


class ReferenceScript(Reader):
    """The script the setup guide hands an agent, against an archive that
    answers. It reads with the same key and the same frames as the package."""

    def handoff(self) -> Path:
        path = self.home / "handoff.txt"
        key = ".".join(
            [
                "efferent-reading-v1",
                wire.to_base64url(self.reading_private),
                wire.to_base64url(self.reading_public),
            ]
        )
        path.write_text(
            f"MCP:\n{self.archive.url}/mcp/b/{self.archive.bucket}\n\nReading key:\n{key}\n"
        )
        path.chmod(0o600)
        return path

    def script(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [
                sys.executable,
                str(ROOT / "efferent_hpke.py"),
                "--handoff",
                str(self.handoff()),
                *args,
            ],
            capture_output=True,
            text=True,
            cwd=ROOT,
        )

    def test_a_range_comes_back_as_lines_that_each_name_their_day(self):
        seed_run(self.archive, "2026-03-01", 10)
        self.archive.reader = (
            wire.read_key(self.reading_private).public_key().public_bytes(*wire.RAW)
        )

        run = self.script("--from", "2026-03-02", "--to", "2026-03-08")

        self.assertEqual(run.returncode, 0, run.stderr)
        lines = [json.loads(line) for line in run.stdout.strip().split("\n")]
        self.assertEqual(
            [line["day"] for line in lines], [add_days("2026-03-02", n) for n in range(7)]
        )
        self.assertEqual(lines[0]["value"], 1001)
        # Seven days at three an answer, followed from one answer to the next.
        self.assertEqual(len(self.archive.ranges()), 3)

    def test_a_listing_can_be_narrowed_to_a_range(self):
        seed_run(self.archive, "2026-03-01", 10)

        run = self.script("--list", "--from", "2026-03-04", "--to", "2026-03-06")

        self.assertEqual(run.returncode, 0, run.stderr)
        days = [json.loads(line)["day"] for line in run.stdout.strip().split("\n")]
        self.assertEqual(days, ["2026-03-04", "2026-03-05", "2026-03-06"])

    def test_a_range_needs_both_ends_in_order(self):
        one_end = self.script("--from", "2026-03-04")
        backwards = self.script("--from", "2026-03-04", "--to", "2026-03-01")

        self.assertEqual(one_end.returncode, 2)
        self.assertIn("takes both --from and --to", one_end.stderr)
        self.assertEqual(backwards.returncode, 2)
        self.assertIn("--from must not be after --to", backwards.stderr)
        self.assertEqual(self.archive.asked, [], "a malformed range still reached the archive")


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
