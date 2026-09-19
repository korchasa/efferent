"""What a phone does on the wire, proved on this side of it.

The Swift phone and the TypeScript service each have their own tests for these
bytes. These are the Python ones: the reading side stands in for a phone when it
sends a development day, and a packing that drifted would be discovered against
a real service rather than here.
"""

import json
import unittest

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey

import efferent_hpke as wire
from efferent.phone import (
    canonical_request,
    compress,
    decompress,
    pack_day,
    pack_days,
    unpack_days,
)
from efferent.sealed import associated_data, open_sealed, seal_legacy


def beat(at: str, value: int) -> dict:
    return {
        "metric": "heartRate",
        "unit": "count/min",
        "source": "Watch",
        "start": at,
        "end": at,
        "value": value,
    }


class Packing(unittest.TestCase):
    def test_a_day_says_what_it_holds_once_and_counts_instants_from_there(self):
        events = [
            beat("2026-08-07T09:00:00Z", 60),
            beat("2026-08-07T09:01:00Z", 61),
            beat("2026-08-07T09:03:00Z", 62),
        ]

        series = json.loads(pack_day(events))["series"]

        self.assertEqual(len(series), 1)
        self.assertEqual(series[0]["source"], "Watch")
        self.assertEqual(series[0]["t"], [0, 60, 120])
        self.assertEqual(series[0]["value"], [60, 61, 62])

    def test_the_order_events_arrive_in_does_not_change_a_days_bytes(self):
        events = [
            beat("2026-08-07T09:03:00Z", 62),
            beat("2026-08-07T09:00:00Z", 60),
            beat("2026-08-07T09:01:00Z", 61),
        ]

        self.assertEqual(pack_day(events), pack_day(list(reversed(events))))
        self.assertEqual(pack_day(events), pack_day([events[1], events[2], events[0]]))

    def test_a_field_with_no_column_is_refused_rather_than_dropped(self):
        with self.assertRaisesRegex(ValueError, "no column for mood"):
            pack_day([{**beat("2026-08-07T09:00:00Z", 60), "mood": "fine"}])

    def test_a_packed_day_expands_back_to_what_went_in(self):
        events = [beat("2026-08-07T09:00:00Z", 60), beat("2026-08-07T09:01:00Z", 61)]

        expanded = wire.expand(pack_day(events).encode()).strip().split("\n")

        self.assertEqual(len(expanded), 2)
        self.assertEqual([json.loads(line)["value"] for line in expanded], [60, 61])


class Frames(unittest.TestCase):
    """The one thing framing has to get right: what came out is what went in,
    byte for byte and under the right date."""

    def test_days_survive_a_round_trip_through_a_frame(self):
        batch = [
            ("2025-12-31", bytes([1, 2, 3])),
            ("2026-01-01", bytes([9]) * 300),
            ("2026-01-02", bytes([7])),
        ]

        self.assertEqual(unpack_days(pack_days(batch)), batch)

    def test_the_same_days_always_pack_to_the_same_bytes(self):
        # The body's hash is what the signature covers.
        batch = [("2026-08-06", bytes([1])), ("2026-08-07", bytes([2, 2]))]

        self.assertEqual(pack_days(batch), pack_days(batch))

    def test_a_batch_refuses_repeated_or_out_of_order_days(self):
        # Two copies of a day in one batch would ask which one wins — a question
        # with no answer the sender could predict. Ordering removes it.
        blob = bytes([1])
        for batch in (
            [("2026-08-07", blob), ("2026-08-07", blob)],
            [("2026-08-07", blob), ("2026-08-06", blob)],
            [("not a day", blob)],
            [],
        ):
            with self.assertRaises(ValueError):
                pack_days(batch)

    def test_a_truncated_frame_is_refused_rather_than_salvaged(self):
        # A frame that unpacked to whatever parsed before it went wrong would
        # have the service store part of a batch and answer as though it stored
        # all of it. The sender would then stop marking the days that never came.
        whole = pack_days([("2026-08-06", bytes([1, 2])), ("2026-08-07", bytes([3, 4, 5, 6]))])

        with self.assertRaisesRegex(ValueError, "and only"):
            unpack_days(whole[:-1])
        # Cut inside the second day's header, where there is not even a date.
        with self.assertRaisesRegex(ValueError, "left over"):
            unpack_days(whole[: 16 + 4])
        with self.assertRaises(ValueError):
            unpack_days(b"")


class Signing(unittest.TestCase):
    def test_the_canonical_request_names_every_field_the_server_acts_on(self):
        line = canonical_request("b" * 26, ["2026-08-06", "2026-08-07"], 1_700_000_000, b"x")

        self.assertEqual(
            line.split("\n")[:4],
            ["efferent/v1", "b" * 26, "2026-08-06,2026-08-07", "1700000000"],
        )

    def test_a_signature_covers_the_body_not_just_the_headers(self):
        self.assertNotEqual(
            canonical_request("b" * 26, ["2026-08-06"], 1, b"one"),
            canonical_request("b" * 26, ["2026-08-06"], 1, b"two"),
        )


class Envelopes(unittest.TestCase):
    def setUp(self):
        private = X25519PrivateKey.generate()
        self.private_raw = private.private_bytes(
            serialization.Encoding.Raw,
            serialization.PrivateFormat.Raw,
            serialization.NoEncryption(),
        )
        self.public_raw = private.public_key().public_bytes(*wire.RAW)

    def test_what_the_phone_seals_the_reading_key_opens(self):
        aad = associated_data("c" * 26, "2026-08-07")
        blob = bytes([wire.SEALED_VERSION]) + wire.hpke_seal(
            self.public_raw, wire.INFO, aad, compress(b"a day")
        )

        self.assertEqual(
            decompress(open_sealed(self.private_raw, self.public_raw, blob, aad)), b"a day"
        )

    def test_a_day_cannot_be_passed_off_as_another_day(self):
        aad = associated_data("c" * 26, "2026-08-07")
        blob = bytes([wire.SEALED_VERSION]) + wire.hpke_seal(self.public_raw, wire.INFO, aad, b"x")

        with self.assertRaises(InvalidTag):
            open_sealed(
                self.private_raw, self.public_raw, blob, associated_data("c" * 26, "2026-08-08")
            )

    def test_the_reader_still_opens_a_sealed_version_1_day_during_migration(self):
        # The phone replaces its days with version 2 as it re-reads them. Until
        # the last one has been replaced, a reader that refused version 1 would
        # report an old day as unreadable rather than as old.
        aad = associated_data("c" * 26, "2026-08-07")

        blob = seal_legacy(self.public_raw, b"legacy day", aad)

        self.assertEqual(blob[0], 1)
        self.assertEqual(open_sealed(self.private_raw, self.public_raw, blob, aad), b"legacy day")

    def test_an_envelope_this_reader_does_not_speak_is_refused(self):
        with self.assertRaisesRegex(ValueError, "unsupported sealed version 9"):
            open_sealed(self.private_raw, self.public_raw, bytes([9, 0, 0]), b"")
        with self.assertRaisesRegex(ValueError, "no version byte"):
            open_sealed(self.private_raw, self.public_raw, b"", b"")


if __name__ == "__main__":
    unittest.main()
