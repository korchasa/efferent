"""The MCP server against an archive that answers.

`test_mcp.py` points its fixture at an address nothing listens on, which is the
right shape for the questions it asks and leaves half the reader untested:
everything that happens when the archive *does* answer — the mirror being
brought up to date, the overview, and what is kept between questions.

The server meets the archive as a subprocess, because a session is what holds
the freshness window and the mirror's record in memory. A test that wants a
reader with no memory of the last question asks for another one.
"""

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
from efferent.days import add_days, today

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


def record(metric: str, at: str, value: float) -> dict:
    return {
        "metric": metric,
        "value": value,
        "unit": "count/min",
        "source": "a watch",
        "start": at,
        "end": at,
    }


def seed_run(archive: FakeArchive, frm: str, count: int) -> list[str]:
    days = []
    day = frm
    for index in range(count):
        archive.put(day, [total("steps", day, 1000 + index)])
        days.append(day)
        day = add_days(day, 1)
    return days


class Session:
    """The MCP server as the agent meets it: a process, spoken to over stdio."""

    def __init__(self, home: Path):
        self.child = subprocess.Popen(
            [sys.executable, "-m", "efferent.mcp"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env={**os.environ, "EFFERENT_HOME": str(home), "PYTHONPATH": str(ROOT)},
            cwd=ROOT,
            text=True,
            bufsize=1,
        )
        self.id = 0
        self.rpc("initialize", {"protocolVersion": "2025-06-18"})

    def rpc(self, method: str, params: dict | None = None) -> dict:
        self.id += 1
        request = {"jsonrpc": "2.0", "id": self.id, "method": method, "params": params}
        self.child.stdin.write(json.dumps(request) + "\n")
        self.child.stdin.flush()
        line = self.child.stdout.readline()
        if not line:
            raise RuntimeError("the server closed before answering")
        return json.loads(line)

    def call(self, name: str, arguments: dict | None = None) -> dict:
        answer = self.rpc("tools/call", {"name": name, "arguments": arguments or {}})
        text = answer["result"]["content"][0]["text"]
        return {
            "isError": answer["result"].get("isError") is True,
            "text": text,
            "body": json.loads(text),
        }

    def close(self) -> None:
        self.child.stdin.close()
        try:
            self.child.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.child.kill()
        self.child.stdout.close()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


class Served(unittest.TestCase):
    """A home holding the reading key, and an archive that answers."""

    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix="efferent-server-"))
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
        # A test may have stopped the archive itself, to see the reader meet one
        # that has gone away. Stopping it twice is not an error worth having.
        try:
            self.archive.stop()
        except Exception:  # noqa: BLE001, S110
            pass
        shutil.rmtree(self.home, ignore_errors=True)

    def session(self) -> Session:
        return Session(self.home)

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

    def kept_metrics(self) -> dict | None:
        """What the overview keeps between questions, or None when it kept none."""
        try:
            return json.loads((self.home / "metrics.json").read_text())
        except (OSError, ValueError):
            return None

    def cli(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, "-m", "efferent", *args],
            env={**os.environ, "EFFERENT_HOME": str(self.home), "PYTHONPATH": str(ROOT)},
            capture_output=True,
            text=True,
            cwd=ROOT,
        )


# MARK: - Bringing the mirror up to date


class Freshness(Served):
    def test_a_first_question_copies_the_archive_down_and_answers_from_it(self):
        self.archive.put("2026-03-01", [total("steps", "2026-03-01", 8000)])
        self.archive.put("2026-03-02", [total("steps", "2026-03-02", 3000)])

        with self.session() as session:
            answer = session.call(
                "phone_data_daily", {"since": "2026-03-01", "until": "2026-03-02"}
            )

        self.assertNotIn("warning", answer["body"])
        self.assertEqual(len(answer["body"]["rows"]), 2)
        self.assertEqual(answer["body"]["rows"][0][0], "2026-03-01")
        self.assertEqual(self.mirrored_files(), ["2026-03-01", "2026-03-02"])

    def test_a_rewritten_day_inside_the_fortnight_is_copied_by_an_ordinary_question(self):
        recent = add_days(today(), -3)
        self.archive.put(recent, [total("steps", recent, 1000)])
        with self.session() as first:
            first.call("phone_data_sync")

        # The ordinary case in this design: the phone re-read a day and put it
        # up again, under a later upload time. Inside the fortnight the recent
        # listing is what notices, so no sync is needed — but the freshness
        # window is, so a second process is what asks.
        self.archive.put(recent, [total("steps", recent, 99_999)])

        with self.session() as later:
            answer = later.call("phone_data_daily", {"since": recent, "until": recent})

        self.assertEqual(answer["body"]["rows"][0][1], 99_999)

    def test_a_day_older_than_the_fortnight_rewritten_is_still_copied_by_a_sync(self):
        # Neither cheap check reaches this day: the recent listing does not
        # cover it and the archive's day count has not moved. Before the forced
        # check read the whole listing, the mirror answered from its old copy
        # for good.
        seed_run(self.archive, "2026-03-01", 5)
        with self.session() as session:
            session.call("phone_data_sync")
            self.assertEqual(len(self.mirrored_files()), 5)

            self.archive.put("2026-03-03", [total("steps", "2026-03-03", 99_999)])
            self.archive.forget()
            session.call("phone_data_sync")

            self.assertEqual(
                self.archive.fetched_days(),
                ["2026-03-03"],
                "a sync fetched days whose stored version had not moved",
            )
            answer = session.call(
                "phone_data_daily", {"since": "2026-03-03", "until": "2026-03-03"}
            )
            self.assertEqual(answer["body"]["rows"][0][1], 99_999)

    def test_a_mirror_already_level_with_the_archive_fetches_nothing(self):
        seed_run(self.archive, "2026-03-01", 5)
        with self.session() as session:
            session.call("phone_data_sync")
            self.archive.forget()

            session.call("phone_data_daily", {"since": "2026-03-01", "until": "2026-03-05"})

            self.assertEqual(self.archive.fetched_days(), [])
            # Inside the freshness window a second question costs no round trip.
            self.assertEqual(self.archive.asked, [])

    def test_a_sync_asks_the_archive_even_inside_the_freshness_window(self):
        self.archive.put("2026-03-01", [total("steps", "2026-03-01", 8000)])
        with self.session() as session:
            session.call("phone_data_sync")
            self.archive.forget()

            session.call("phone_data_sync")

            self.assertGreater(
                len(self.archive.asked), 0, "a sync answered from a window it exists to ignore"
            )

    def test_history_arriving_outside_the_recent_fortnight_is_still_noticed(self):
        now = today()
        self.archive.put(now, [total("steps", now, 8000)])
        with self.session() as session:
            session.call("phone_data_sync")

            # A decade-old day the fortnight listing cannot see. Only the day
            # count says the mirror is behind, which is the fall-through here.
            self.archive.put("2016-01-05", [total("steps", "2016-01-05", 4242)])
            session.call("phone_data_sync")

        self.assertIn(
            "2016-01-05",
            self.mirrored_files(),
            "a day older than the recent listing never reached the mirror",
        )

    def test_a_sync_that_breaks_part_way_says_so_and_records_only_what_arrived(self):
        seed_run(self.archive, "2026-03-01", 12)
        self.archive.fault = {"day": "2026-03-07"}

        with self.session() as session:
            answer = session.call(
                "phone_data_daily", {"since": "2026-03-01", "until": "2026-03-12"}
            )

        self.assertIn("could not be brought up to date", answer["body"]["warning"])
        self.assertNotIn(
            "2026-03-07",
            self.mirrored_state()["days"],
            "a day that never arrived was recorded as mirrored, so nothing will ask again",
        )


# MARK: - The two tools that had none


class Overview(Served):
    def test_the_overview_reports_the_archive_the_readable_part_and_every_metric(self):
        self.archive.put(
            "2026-03-01",
            [
                total("steps", "2026-03-01", 8000),
                record("heartRate", "2026-03-01T09:00:00Z", 60),
                record("heartRate", "2026-03-01T10:00:00Z", 80),
            ],
        )
        self.archive.put("2026-03-02", [total("steps", "2026-03-02", 3000)])

        with self.session() as session:
            answer = session.call("phone_data_overview")

        self.assertEqual(answer["body"]["archive"]["days"], 2)
        self.assertEqual(answer["body"]["archive"]["firstDay"], "2026-03-01")
        self.assertEqual(answer["body"]["readable"]["days"], 2)
        self.assertIn("the whole archive is readable", answer["body"]["readable"]["note"])

        metrics = {entry["metric"]: entry for entry in answer["body"]["metrics"]}
        self.assertEqual(metrics["steps"]["kind"], "total")
        self.assertEqual(metrics["steps"]["daysCovered"], 2)
        self.assertEqual(metrics["heartRate"]["kind"], "record")
        self.assertEqual(metrics["heartRate"]["events"], 2)
        self.assertEqual(metrics["heartRate"]["firstDay"], "2026-03-01")

    def test_the_overview_answers_from_the_mirror_when_the_archive_has_gone(self):
        self.archive.put("2026-03-01", [total("steps", "2026-03-01", 8000)])
        with self.session() as first:
            first.call("phone_data_sync")
        self.archive.stop()

        # A second process, so the question is asked outside any window a
        # previous answer opened: the archive is unreachable now, and the
        # overview has to say so rather than fail.
        with self.session() as later:
            answer = later.call("phone_data_overview")

        self.assertIn("could not be reached", answer["body"]["warning"])
        self.assertEqual(answer["body"]["archive"], "unreachable")
        self.assertEqual(answer["body"]["readable"]["days"], 1)
        self.assertEqual(len(answer["body"]["metrics"]), 1)

    def test_the_overview_costs_one_round_trip_not_two(self):
        self.archive.put("2026-03-01", [total("steps", "2026-03-01", 8000)])
        with self.session() as only:
            self.archive.forget()
            answer = only.call("phone_data_overview")
            self.assertEqual(answer["body"]["archive"]["days"], 1)

            # The check the overview runs already asks the archive what it
            # holds. Asking a second time for the same answer is another walk of
            # the whole listing on the service, and it was most of what made
            # this tool slow.
            self.assertEqual(
                len([path for path in self.archive.asked if "/stats" in path]),
                1,
                "the overview asked the archive what it holds twice",
            )

            # And inside the freshness window a second overview asks nothing.
            self.archive.forget()
            only.call("phone_data_overview")
            self.assertEqual(self.archive.asked, [])

    def test_a_sync_reports_what_it_copied_and_what_is_readable_afterwards(self):
        seed_run(self.archive, "2026-03-01", 6)
        with self.session() as session:
            first = session.call("phone_data_sync")

            self.assertEqual(first["body"]["copied"], 6)
            self.assertEqual(first["body"]["readable"], 6)
            self.assertEqual(first["body"]["firstDay"], "2026-03-01")
            self.assertEqual(first["body"]["lastDay"], "2026-03-06")

            again = session.call("phone_data_sync")
            self.assertEqual(
                again["body"]["copied"], 0, "a second sync copied days that had not changed"
            )
            self.assertEqual(again["body"]["readable"], 6)


# MARK: - What the mirror records, and who else writes it


class Records(Served):
    def test_a_day_that_left_the_archive_stops_being_counted_and_its_file_is_kept(self):
        seed_run(self.archive, "2026-03-01", 5)
        with self.session() as first:
            first.call("phone_data_sync")
            self.assertEqual(len(self.mirrored_state()["days"]), 5)

        # What clearing objects from a bucket does. The mirror's record of that
        # day says "the archive holds this version", and that has stopped being
        # true.
        self.archive.drop("2026-03-03")

        with self.session() as second:
            second.call("phone_data_daily", {"since": "2026-03-01", "until": "2026-03-05"})
        self.assertEqual(
            len(self.mirrored_state()["days"]),
            4,
            "the mirror still claims the archive holds a day it has lost",
        )
        # The record goes, the day does not: the archive losing a day does not
        # make the local copy worthless, and it may be the last one left.
        self.assertIn(
            "2026-03-03", self.mirrored_files(), "the local copy of the lost day was deleted"
        )

        # Dropping the record must not make the loss silent: the overview is
        # where a reader finds out that the only copy of a day is this one.
        with self.session() as third:
            overview = third.call("phone_data_overview")
        self.assertEqual(overview["body"]["archive"]["days"], 4)
        self.assertEqual(overview["body"]["readable"]["days"], 5)
        self.assertIn("the archive no longer holds", overview["body"]["readable"]["note"])

        # The point of dropping the record: the count now agrees again, so an
        # ordinary question stops walking the whole archive on every refresh.
        self.archive.forget()
        with self.session() as fourth:
            fourth.call("phone_data_daily", {"since": "2026-03-01", "until": "2026-03-05"})
        self.assertEqual(
            self.archive.full_listings(),
            0,
            "a lost day bought a full listing on every question, for the life of the mirror",
        )

    def test_a_day_count_that_is_only_a_floor_cannot_say_the_mirror_is_level(self):
        seed_run(self.archive, "2026-03-01", 5)
        with self.session() as first:
            first.call("phone_data_sync")

        # An archive longer than the service will walk answers with a floor. It
        # is below the truth by construction, so it can never mean "behind".
        self.archive.floor = 3
        self.archive.forget()
        with self.session() as second:
            second.call("phone_data_daily", {"since": "2026-03-01", "until": "2026-03-05"})

        self.assertEqual(
            self.archive.full_listings(),
            0,
            "a floor below the mirror's own count was read as a mismatch",
        )

    def test_a_floor_above_the_mirrors_count_still_says_it_is_behind(self):
        seed_run(self.archive, "2026-03-01", 5)
        # Nothing mirrored yet, and the archive admits to at least three days.
        # That is a mismatch a floor can prove, so the whole listing follows.
        self.archive.floor = 3

        with self.session() as only:
            only.call("phone_data_daily", {"since": "2026-03-01", "until": "2026-03-05"})

        self.assertGreater(
            self.archive.full_listings(), 0, "a mirror the archive said was behind never caught up"
        )
        self.assertEqual(len(self.mirrored_files()), 5)

    def test_days_another_process_already_copied_are_not_fetched_again(self):
        seed_run(self.archive, "2026-03-01", 5)
        with self.session() as held:
            held.call("phone_data_sync")

            # History arriving while a server is already running. The command
            # line tool shares this mirror and copies it down; the server's own
            # record of what is mirrored is now behind the file it will write.
            seed_run(self.archive, "2026-02-20", 3)
            run = self.cli("sync")
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertEqual(len(self.mirrored_state()["days"]), 8)

            self.archive.forget()
            held.call("phone_data_sync")

            self.assertEqual(
                self.archive.fetched_days(),
                [],
                "the server re-fetched days another process had already copied",
            )
            self.assertEqual(len(self.mirrored_state()["days"]), 8)

    def test_a_mirror_record_that_cannot_be_read_does_not_stop_an_answer(self):
        seed_run(self.archive, "2026-03-01", 3)
        with self.session() as held:
            held.call("phone_data_sync")

            # The record of what is mirrored goes; the days themselves stay.
            # Reading it fresh on every pass is what makes this reachable at
            # all, so it has to degrade the way an unreachable archive does
            # rather than fail the question.
            (self.home / "mirror.json").unlink()

            answer = held.call("phone_data_sync")
            self.assertIn("could not be read", answer["body"]["warning"])
            daily = held.call("phone_data_daily", {"since": "2026-03-01", "until": "2026-03-03"})
            self.assertEqual(len(daily["body"]["rows"]), 3)


# MARK: - What each day holds, remembered


class Remembered(Served):
    def test_what_a_day_holds_is_worked_out_once_and_kept(self):
        seed_run(self.archive, "2026-03-01", 5)
        with self.session() as first:
            first.call("phone_data_overview")

        kept = self.kept_metrics()
        self.assertIsNotNone(kept, "nothing was kept, so every overview reads the mirror again")
        self.assertEqual(len(kept), 5)

        # The second overview must answer the same, out of what was kept.
        with self.session() as second:
            answer = second.call("phone_data_overview")
        self.assertEqual(len(answer["body"]["metrics"]), 1)
        self.assertEqual(answer["body"]["metrics"][0]["metric"], "steps")
        self.assertEqual(answer["body"]["metrics"][0]["daysCovered"], 5)
        self.assertEqual(answer["body"]["metrics"][0]["firstDay"], "2026-03-01")

    def test_a_kept_day_whose_file_has_changed_is_read_again_not_believed(self):
        seed_run(self.archive, "2026-03-01", 3)
        with self.session() as first:
            first.call("phone_data_overview")

        # A day rewritten underneath the record — which is what the phone does
        # all day. What is kept is a claim about a file, so the file has to be
        # what tests it: a fingerprint that no longer matches is thrown away.
        (self.home / "days" / "2026-03-02.ndjson").write_text(
            json.dumps(
                {
                    "id": "hk:heartRate:2026-03-02T09:00:00Z",
                    "v": 1,
                    "metric": "heartRate",
                    "value": 61,
                    "unit": "count/min",
                    "start": "2026-03-02T09:00:00Z",
                    "end": "2026-03-02T09:00:00Z",
                }
            )
            + "\n"
        )

        with self.session() as second:
            answer = second.call("phone_data_overview")

        names = sorted(entry["metric"] for entry in answer["body"]["metrics"])
        self.assertEqual(names, ["heartRate", "steps"], "the overview answered from a stale record")
        steps = next(e for e in answer["body"]["metrics"] if e["metric"] == "steps")
        self.assertEqual(steps["daysCovered"], 2)

    def test_a_record_that_was_thrown_away_costs_a_read_never_a_wrong_answer(self):
        seed_run(self.archive, "2026-03-01", 4)
        with self.session() as first:
            first.call("phone_data_overview")
        with self.session() as asked:
            before = asked.call("phone_data_overview")["body"]["metrics"]

        # Deleting it is always safe, and so is having none: the days are the
        # truth and this only ever saved a read of them.
        (self.home / "metrics.json").unlink()
        with self.session() as second:
            self.assertEqual(second.call("phone_data_overview")["body"]["metrics"], before)
        self.assertIsNotNone(self.kept_metrics(), "the record was not rebuilt")

        # The same for a record that is nonsense rather than missing.
        (self.home / "metrics.json").write_text("{ this is not json")
        with self.session() as third:
            self.assertEqual(third.call("phone_data_overview")["body"]["metrics"], before)

    def test_a_day_that_left_the_mirror_leaves_the_record_too(self):
        seed_run(self.archive, "2026-03-01", 4)
        with self.session() as first:
            first.call("phone_data_overview")
        self.assertEqual(len(self.kept_metrics()), 4)

        (self.home / "days" / "2026-03-02.ndjson").unlink()
        with self.session() as second:
            answer = second.call("phone_data_overview")
        self.assertEqual(answer["body"]["readable"]["days"], 3)
        self.assertEqual(answer["body"]["metrics"][0]["daysCovered"], 3)
        self.assertEqual(len(self.kept_metrics()), 3)


if __name__ == "__main__":
    unittest.main()
