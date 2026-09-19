"""The MCP server, spoken to the way an agent speaks to it.

The fixture is a real mirror — a reading key, a `mirror.json` and day files —
pointed at an address nothing answers on. That is deliberate: it exercises the
path a laptop on a train takes, where the archive is unreachable and the answer
has to come out of the mirror with a warning attached rather than not come out
at all.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey

import efferent_hpke as wire
from efferent import mcp
from efferent.archive import pkcs8, raw_private
from efferent.phone import canonical_edit, decompress
from efferent.sealed import edit_associated_data

ROOT = Path(__file__).resolve().parent.parent

#: Nothing listens on port 9, so every call to the archive fails at once.
UNREACHABLE = "http://127.0.0.1:9"

MEAL = {
    "op": "put",
    "id": "agent:meal:2026-01-01:lunch",
    "metric": "dietaryEnergy",
    "start": 1_767_268_800,
    "end": 1_767_270_600,
    "value": 640,
    "unit": "kcal",
}
NAP = {
    "op": "put",
    "id": "agent:sleep:2026-01-01:nap",
    "metric": "sleep",
    "start": 1_767_276_000,
    "end": 1_767_279_600,
    "stage": "asleepCore",
}


def total(metric: str, on: str, value: int) -> dict:
    return {
        "id": f"agg:{metric}:{on}:d",
        "v": 1,
        "metric": metric,
        "bucket": "day",
        "value": value,
        "unit": "count",
        "start": f"{on}T00:00:00Z",
        "end": f"{on}T23:59:59Z",
    }


def record(metric: str, at: str, value: float, unit: str) -> dict:
    return {
        "id": f"hk:{metric}:{at}",
        "v": 1,
        "metric": metric,
        "value": value,
        "unit": unit,
        "start": at,
        "end": at,
    }


def asleep(start: str, end: str) -> dict:
    return {
        "id": f"hk:sleep:{start}",
        "v": 1,
        "metric": "sleep",
        "stage": "asleepCore",
        "start": start,
        "end": end,
    }


class Served(unittest.TestCase):
    """A home of its own, seeded, with the server's own reader reset onto it."""

    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix="efferent-mcp-"))
        self.previous = os.environ.get("EFFERENT_HOME")
        os.environ["EFFERENT_HOME"] = str(self.home)

        private = X25519PrivateKey.generate()
        self.reading_public = private.public_key().public_bytes(*wire.RAW)
        self.reading_private = raw_private(pkcs8(private))
        self.bucket = wire.bucket_of(self.reading_public)
        (self.home / "reading-key.json").write_text(
            json.dumps(
                {
                    "readingPrivate": pkcs8(private),
                    "readingPublic": wire.to_base64url(self.reading_public),
                }
            )
        )
        (self.home / "mirror.json").write_text(
            json.dumps({"endpoint": UNREACHABLE, "days": {}, "syncedAt": ""})
        )
        (self.home / "days").mkdir()
        self.seed()
        # The server keeps one reader across a session; each test gets its own.
        mcp.reader = mcp.Reader()

    def tearDown(self):
        if self.previous is None:
            os.environ.pop("EFFERENT_HOME", None)
        else:
            os.environ["EFFERENT_HOME"] = self.previous
        shutil.rmtree(self.home, ignore_errors=True)

    def seed(self) -> None:
        self.day(
            "2026-01-01",
            [
                total("steps", "2026-01-01", 8000),
                total("flightsClimbed", "2026-01-01", 12),
                # An hourly bucket for the same day, which must never reach a
                # daily table.
                {
                    "id": "agg:steps:h",
                    "v": 1,
                    "metric": "steps",
                    "bucket": "hour",
                    "value": 400,
                    "unit": "count",
                    "start": "2026-01-01T09:00:00Z",
                    "end": "2026-01-01T10:00:00Z",
                },
                record("heartRate", "2026-01-01T09:00:00Z", 60, "count/min"),
                record("heartRate", "2026-01-01T10:00:00Z", 80, "count/min"),
                asleep("2026-01-01T22:00:00Z", "2026-01-02T00:00:00Z"),
                # The same stretch again from a second source: merged, never added.
                asleep("2026-01-01T22:30:00Z", "2026-01-01T23:30:00Z"),
                {
                    "id": "hk:workout:1",
                    "v": 1,
                    "metric": "workout",
                    "activity": "52",
                    "duration": 1800,
                    "start": "2026-01-01T12:00:00Z",
                    "end": "2026-01-01T12:30:00Z",
                },
            ],
        )
        self.day(
            "2026-01-02",
            [
                total("steps", "2026-01-02", 3000),
                # Two readings of one metric that do not agree on their fields:
                # the second names no device. A column list written by hand would
                # drop it and nothing would say so.
                {
                    "id": "hk:respiratoryRate:1",
                    "v": 1,
                    "metric": "respiratoryRate",
                    "value": 14,
                    "unit": "count/min",
                    "source": "a watch",
                    "start": "2026-01-02T03:00:00Z",
                    "end": "2026-01-02T03:00:00Z",
                },
                {
                    "id": "hk:respiratoryRate:2",
                    "v": 1,
                    "metric": "respiratoryRate",
                    "value": 16,
                    "unit": "count/min",
                    "start": "2026-01-02T04:00:00Z",
                    "end": "2026-01-02T04:00:00Z",
                },
                asleep("2026-01-02T00:00:00Z", "2026-01-02T06:00:00Z"),
                record("heartRate", "2026-01-02T09:00:00Z", 70, "count/min"),
            ],
        )

    def day(self, name: str, events: list[dict]) -> None:
        (self.home / "days" / f"{name}.ndjson").write_text(
            "".join(json.dumps(event, separators=(",", ":")) + "\n" for event in events)
        )

    def seed_editor(self) -> dict:
        """The editor key a four-field handoff would have installed."""
        private = Ed25519PrivateKey.generate()
        editor = {
            "editorPrivate": pkcs8(private),
            "editorPublic": wire.to_base64url(private.public_key().public_bytes(*wire.RAW)),
        }
        (self.home / "editor-key.json").write_text(json.dumps(editor))
        return editor

    # MARK: - Speaking to it

    def rpc(self, method: str, params: dict | None = None):
        return mcp.handle({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})

    def call(self, name: str, arguments: dict | None = None):
        answer = self.rpc("tools/call", {"name": name, "arguments": arguments or {}})
        text = answer["result"]["content"][0]["text"]
        try:
            body = json.loads(text)
        except ValueError:
            body = None
        return {"isError": answer["result"].get("isError") is True, "text": text, "body": body}


# MARK: - The handshake


class Handshake(Served):
    def test_initialize_answers_in_the_version_it_was_asked_for(self):
        answer = self.rpc("initialize", {"protocolVersion": "2024-11-05"})["result"]

        self.assertEqual(answer["protocolVersion"], "2024-11-05")
        self.assertEqual(answer["serverInfo"]["name"], "efferent")
        self.assertTrue(answer["capabilities"]["tools"] is not None, "tools were not offered")
        # The instructions are what an agent gets before it has read a single
        # day, so they have to name the tool that orients it.
        self.assertIn("phone_data_overview", answer["instructions"])

    def test_a_version_this_server_does_not_speak_falls_back(self):
        answer = self.rpc("initialize", {"protocolVersion": "1999-01-01"})["result"]

        self.assertEqual(answer["protocolVersion"], "2025-06-18")

    def test_a_notification_is_not_answered(self):
        # Replying to one is a protocol error, not a harmless extra, and clients
        # differ in how loudly they complain.
        answer = mcp.handle({"jsonrpc": "2.0", "method": "notifications/initialized"})

        self.assertIsNone(answer)

    def test_every_tool_arrives_with_a_schema_and_a_description(self):
        tools = self.rpc("tools/list")["result"]["tools"]

        self.assertEqual(len(tools), 9)
        for tool in tools:
            self.assertGreater(
                len(tool["description"]),
                100,
                f"{tool['name']} is described too thinly to use unprompted",
            )
            self.assertTrue(tool["inputSchema"], f"{tool['name']} has no schema")
        self.assertEqual(
            sorted(tool["name"] for tool in tools),
            [
                "phone_data_daily",
                "phone_data_edits",
                "phone_data_overview",
                "phone_data_samples",
                "phone_data_sleep",
                "phone_data_statistics",
                "phone_data_sync",
                "phone_data_workouts",
                "phone_data_write",
            ],
        )

    def test_an_unknown_tool_is_a_failed_call_not_a_broken_connection(self):
        answer = self.call("phone_data_horoscope")

        self.assertTrue(answer["isError"])
        self.assertIn("no such tool", answer["text"])


class AsAProcess(unittest.TestCase):
    """The one test that runs the server the way a client does: as a process,
    over its own stdin and stdout. Calling `handle` directly cannot see a fault
    in how the module starts up, and such a fault shipped once."""

    def test_the_server_answers_as_a_process_past_the_handshake(self):
        home = Path(tempfile.mkdtemp(prefix="efferent-process-"))
        try:
            # Its own empty home: this test must never touch a real archive, and
            # none of what it asks for needs one.
            child = subprocess.run(
                [sys.executable, "-m", "efferent.mcp"],
                input='{"jsonrpc":"2.0","id":1,"method":"initialize"}\n'
                '{"jsonrpc":"2.0","id":2,"method":"tools/list"}\n',
                env={**os.environ, "EFFERENT_HOME": str(home), "PYTHONPATH": str(ROOT)},
                capture_output=True,
                text=True,
                cwd=ROOT,
                timeout=30,
            )
            lines = [json.loads(line) for line in child.stdout.strip().split("\n")]
            self.assertEqual(lines[0]["result"]["serverInfo"]["name"], "efferent")
            # The second request is the one that matters — the first would pass
            # either way.
            self.assertNotIn("error", lines[1])
            self.assertEqual(len(lines[1]["result"]["tools"]), 9)
        finally:
            shutil.rmtree(home, ignore_errors=True)


# MARK: - Answers


class Answers(Served):
    def test_a_daily_table_takes_the_daily_buckets_and_leaves_the_hourly_ones(self):
        answer = self.call("phone_data_daily", {"since": "2026-01-01", "until": "2026-01-02"})

        self.assertEqual(answer["body"]["columns"][0], "day")
        steps = [[row[0], row[1]] for row in answer["body"]["rows"]]
        self.assertEqual(steps, [["2026-01-01", 8000], ["2026-01-02", 3000]])

    def test_a_night_is_whole_merged_and_named_by_the_evening(self):
        answer = self.call("phone_data_sleep", {"since": "2026-01-01", "until": "2026-01-01"})

        self.assertEqual(len(answer["body"]["rows"]), 1)
        self.assertEqual(answer["body"]["rows"][0]["night"], "2026-01-01")
        # 22:00 to 06:00 across two day files, with an overlap inside it.
        self.assertEqual(answer["body"]["rows"][0]["asleepHours"], 8)

    def test_statistics_describe_readings_without_handing_any_over(self):
        answer = self.call(
            "phone_data_statistics",
            {
                "metric": "heartRate",
                "since": "2026-01-01",
                "until": "2026-01-02",
                "group_by": "day",
            },
        )

        self.assertEqual(len(answer["body"]["rows"]), 2)
        self.assertEqual(
            answer["body"]["rows"][0],
            {
                "group": "2026-01-01",
                "n": 2,
                "min": 60,
                "p10": 62,
                "median": 70,
                "mean": 70,
                "p90": 78,
                "max": 80,
                "sum": 140,
            },
        )

    def test_a_workout_is_reported_by_its_activity_and_summed_by_it(self):
        answer = self.call("phone_data_workouts", {"since": "2026-01-01", "until": "2026-01-02"})

        self.assertEqual(answer["body"]["total"], 1)
        self.assertEqual(answer["body"]["byActivity"], {"walking": {"count": 1, "minutes": 30}})

    def test_blood_oxygen_answers_carry_the_warning_about_its_unit(self):
        answer = self.call(
            "phone_data_samples",
            {"metric": "oxygenSaturation", "since": "2026-01-01", "until": "2026-01-02"},
        )

        self.assertIn("0.97 means 97%", answer["body"]["unitNote"])

    def test_a_daily_table_answers_the_metrics_an_agent_can_write(self):
        # What was written must be readable back through the same tool, or the
        # agent has no way to see that a meal landed.
        answer = self.call(
            "phone_data_daily",
            {
                "metrics": ["dietaryEnergy", "dietaryProtein"],
                "since": "2026-01-01",
                "until": "2026-01-01",
            },
        )

        self.assertFalse(answer["isError"], answer["text"])
        self.assertEqual(answer["body"]["columns"], ["day", "dietaryEnergy", "dietaryProtein"])


# MARK: - Refusals


class Refusals(Served):
    def test_a_malformed_day_is_refused_with_the_correction(self):
        answer = self.call("phone_data_daily", {"since": "last tuesday"})

        self.assertTrue(answer["isError"])
        self.assertIn("YYYY-MM-DD", answer["text"])

    def test_a_range_too_long_for_a_daily_table_is_refused_not_truncated(self):
        # Truncating would answer a question about five years with one about
        # one, and nothing in the answer would say so.
        answer = self.call("phone_data_daily", {"since": "2020-01-01", "until": "2026-01-01"})

        self.assertTrue(answer["isError"])
        self.assertIn("phone_data_statistics", answer["text"])

    def test_a_range_that_runs_backwards_is_refused(self):
        answer = self.call("phone_data_daily", {"since": "2026-02-01", "until": "2026-01-01"})

        self.assertTrue(answer["isError"])
        self.assertIn("after", answer["text"])

    def test_an_unreachable_archive_still_answers_and_says_it_is_behind(self):
        # The mirror holds the days; only the check failed. An answer that came
        # back silently would be a stale answer about health data with nothing
        # to mark it.
        answer = self.call("phone_data_daily", {"since": "2026-01-01", "until": "2026-01-02"})

        self.assertIn("could not be reached", answer["body"]["warning"])


# MARK: - The shape an answer travels in


class Shape(Served):
    def test_readings_come_as_a_table_with_what_they_agree_on_said_once(self):
        answer = self.call(
            "phone_data_samples",
            {"metric": "heartRate", "since": "2026-01-01", "until": "2026-01-02"},
        )

        self.assertEqual(answer["body"]["sameOnEveryRow"], {"unit": "count/min", "v": 1})
        self.assertEqual(answer["body"]["columns"], ["start", "end", "value"])
        self.assertEqual(
            answer["body"]["rows"],
            [
                ["2026-01-01T09:00:00Z", "2026-01-01T09:00:00Z", 60],
                ["2026-01-01T10:00:00Z", "2026-01-01T10:00:00Z", 80],
                ["2026-01-02T09:00:00Z", "2026-01-02T09:00:00Z", 70],
            ],
        )

    def test_a_field_only_some_readings_carry_becomes_a_column(self):
        answer = self.call(
            "phone_data_samples",
            {"metric": "respiratoryRate", "since": "2026-01-02", "until": "2026-01-02"},
        )

        # The whole point: `source` is on one reading and not the other, so it
        # cannot be said once — and it must not vanish either. A null is the
        # reading that named no device, not a device called nothing.
        self.assertIn("source", answer["body"]["columns"], "a field one reading carried was lost")
        self.assertNotIn("source", answer["body"]["sameOnEveryRow"])
        at = answer["body"]["columns"].index("source")
        self.assertEqual([row[at] for row in answer["body"]["rows"]], ["a watch", None])

    def test_the_derived_identifier_is_not_carried_and_nothing_else_is_lost(self):
        answer = self.call(
            "phone_data_samples",
            {"metric": "heartRate", "since": "2026-01-01", "until": "2026-01-01"},
        )

        carried = {*answer["body"]["columns"], *answer["body"]["sameOnEveryRow"]}
        self.assertNotIn("id", carried, "the identifier came back after all")
        # Everything the event held apart from the id and the metric named above.
        for field in ("v", "start", "end", "value", "unit"):
            self.assertIn(field, carried, f"{field} left the answer with the identifier")

    def test_workouts_come_as_a_table_too_and_the_counts_are_over_all_of_them(self):
        answer = self.call("phone_data_workouts", {"since": "2026-01-01", "until": "2026-01-02"})

        # One workout is one row, and a single row keeps every field in its
        # columns: there is nothing to say once, and an answer whose only row
        # came back empty would be a worse trade than the repetition it saved.
        self.assertEqual(answer["body"]["sameOnEveryRow"], {})
        at = answer["body"]["columns"].index("activity")
        self.assertEqual(len(answer["body"]["rows"]), 1)
        self.assertEqual(answer["body"]["rows"][0][at], "walking")
        self.assertEqual(answer["body"]["byActivity"], {"walking": {"count": 1, "minutes": 30}})

    def test_an_answer_is_written_without_indentation(self):
        answer = self.call("phone_data_daily", {"since": "2026-01-01", "until": "2026-01-02"})

        # Nothing but a model reads this, and it pays for every character. The
        # spaces were a fifth of every answer this server sent.
        self.assertNotIn("\n", answer["text"], "the answer came back laid out")


# MARK: - Writing


class Writing(Served):
    def test_the_overview_names_what_an_agent_may_write_with_the_unit(self):
        answer = self.call("phone_data_overview")

        writable = answer["body"]["writable"]
        self.assertEqual(writable["dietaryEnergy"], {"kind": "quantity", "unit": "kcal"})
        self.assertEqual(writable["bodyMass"], {"kind": "quantity", "unit": "kg"})
        self.assertEqual(writable["sleep"]["kind"], "category")
        self.assertIn("asleepREM", writable["sleep"]["stages"])

    def test_a_handoff_from_before_writing_cannot_write_and_says_so(self):
        answer = self.call("phone_data_write", {"items": [MEAL]})

        self.assertTrue(answer["isError"])
        self.assertIn("editor key", answer["text"])

    def test_an_item_that_is_wrong_is_refused_before_anything_is_sealed(self):
        self.seed_editor()
        with (
            mock.patch.object(mcp, "reader", mcp.Reader()),
            mock.patch("efferent.archive.transport") as posted,
        ):
            answer = self.call("phone_data_write", {"items": [{**MEAL, "unit": "kJ"}]})

            self.assertTrue(answer["isError"])
            self.assertIn("item 0", answer["text"])
            self.assertIn("kcal", answer["text"])
            posted.assert_not_called()

    def test_an_edit_is_sealed_signed_and_posted(self):
        editor = self.seed_editor()
        taken = {}

        def service(method, url, headers=None, body=None):
            taken.update(method=method, url=url, headers=headers, body=body)
            return 201, json.dumps(
                {
                    "name": "1767300000000-abcdefgh",
                    "at": "2026-01-01T20:00:00.000Z",
                    "bytes": len(body),
                }
            ).encode()

        with mock.patch("efferent.archive.transport", service):
            answer = self.call("phone_data_write", {"items": [MEAL, NAP]})

        self.assertFalse(answer["isError"], answer["text"])
        self.assertEqual(answer["body"]["name"], "1767300000000-abcdefgh")
        self.assertEqual(answer["body"]["items"], 2)
        self.assertIn("phone", answer["body"]["note"])

        self.assertEqual(taken["url"], f"{UNREACHABLE}/b/{self.bucket}/edits")

        # Signed by the editor key from the handoff, over the canonical message
        # the service and the phone both check.
        body = taken["body"]
        self.assertEqual(taken["headers"]["X-Efferent-Editor"], editor["editorPublic"])
        timestamp = int(taken["headers"]["X-Efferent-Timestamp"])
        self.assertLess(abs(timestamp - time.time()), 60, "the timestamp is not now")
        Ed25519PublicKey.from_public_bytes(wire.base64url(editor["editorPublic"])).verify(
            wire.base64url(taken["headers"]["X-Efferent-Signature"]),
            canonical_edit(self.bucket, timestamp, body).encode(),
        )

        # Sealed to the reading key and bound to the bucket, so the phone and
        # only the phone can open it.
        self.assertEqual(body[0], 2)
        opened = wire.hpke_open(
            self.reading_private, wire.INFO, edit_associated_data(self.bucket), body[1:]
        )
        self.assertEqual(json.loads(decompress(opened))["items"], [MEAL, NAP])

        # And written down locally, so a later session can find the ids.
        kept = json.loads((self.home / "edits.json").read_text())
        self.assertEqual(len(kept), 1)
        self.assertEqual(kept[0]["name"], "1767300000000-abcdefgh")
        self.assertEqual(
            kept[0]["items"],
            [
                {"op": "put", "id": MEAL["id"], "metric": "dietaryEnergy", "day": "2026-01-01"},
                {"op": "put", "id": NAP["id"], "metric": "sleep", "day": "2026-01-01"},
            ],
        )

    def test_the_service_refusing_an_edit_is_a_failed_call_with_its_sentence(self):
        self.seed_editor()

        def service(*_, **__):
            return 403, json.dumps({"error": "no editor is registered for this bucket"}).encode()

        with mock.patch("efferent.archive.transport", service):
            answer = self.call("phone_data_write", {"items": [MEAL]})

        self.assertTrue(answer["isError"])
        self.assertIn("403", answer["text"])
        self.assertIn("no editor is registered", answer["text"])

    def test_edits_are_listed_with_the_status_and_the_local_record(self):
        self.seed_editor()
        (self.home / "edits.json").write_text(
            json.dumps(
                [
                    {
                        "name": "1767300000000-abcdefgh",
                        "at": "2026-01-01T20:00:00.000Z",
                        "items": [
                            {
                                "op": "put",
                                "id": MEAL["id"],
                                "metric": "dietaryEnergy",
                                "day": "2026-01-01",
                            },
                            {
                                "op": "put",
                                "id": NAP["id"],
                                "metric": "sleep",
                                "day": "2026-01-01",
                            },
                        ],
                    }
                ]
            )
        )

        def service(method, url, headers=None, body=None):
            # The listing carries counts; the outcome is asked for only where
            # something was refused, and it says which item and why.
            if "/o/1767300000000-abcdefgh" in url:
                return 200, json.dumps(
                    {
                        "applied": 1,
                        "refused": [{"item": 1, "code": "badRange"}],
                        "bytes": 300,
                        "at": "2026-01-01T20:00:00.000Z",
                    }
                ).encode()
            self.assertIn(f"/b/{self.bucket}/edits", url)
            self.assertIn("status=all", url)
            return 200, json.dumps(
                {
                    "edits": [
                        {
                            "name": "1767300000000-abcdefgh",
                            "bytes": 300,
                            "at": "2026-01-01T20:00:00.000Z",
                            "status": "partial",
                            "applied": 1,
                            "refused": 1,
                        },
                        {
                            "name": "1767300001000-zzzzzzzz",
                            "bytes": 200,
                            "at": "2026-01-01T20:00:01.000Z",
                            "status": "pending",
                        },
                    ],
                    "next": None,
                }
            ).encode()

        with mock.patch("efferent.archive.transport", service):
            answer = self.call("phone_data_edits", {"status": "all"})

        self.assertFalse(answer["isError"], answer["text"])
        self.assertIsNone(answer["body"]["next"])
        self.assertEqual(len(answer["body"]["edits"]), 2)
        known, unknown = answer["body"]["edits"]
        self.assertEqual(known["status"], "partial")
        self.assertEqual(known["applied"], 1)
        self.assertEqual([item["id"] for item in known["items"]], [MEAL["id"], NAP["id"]])
        # The index the phone answered with, turned back into the agent's id.
        self.assertEqual(known["refusals"], [{"item": 1, "code": "badRange", "id": NAP["id"]}])
        # An edit this profile did not submit — another machine's, or one from
        # before the record existed — is listed as the service knows it.
        self.assertEqual(unknown["status"], "pending")
        self.assertNotIn("items", unknown)


if __name__ == "__main__":
    unittest.main()
