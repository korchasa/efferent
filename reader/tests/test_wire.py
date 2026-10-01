"""The wire module, which is also the script an agent receives from setup_guide."""

import base64
import hashlib
import json
import unittest
import zlib

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey

import efferent_hpke as wire

RAW = (serialization.Encoding.Raw, serialization.PublicFormat.Raw)


def raw_pair(private: X25519PrivateKey | Ed25519PrivateKey) -> tuple[bytes, bytes]:
    secret = private.private_bytes(
        serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption()
    )
    return secret, private.public_key().public_bytes(*RAW)


def bucket_of(public: bytes) -> str:
    return base64.b32encode(hashlib.sha256(public).digest()).decode().lower()[:26]


def handoff(reading: X25519PrivateKey, editor: Ed25519PrivateKey | None, bucket: str | None = None):
    secret, public = raw_pair(reading)
    lines = [
        "Instruction:",
        "Connect the supplied Efferent MCP and call setup_guide first. Keep the reading key local.",
        "",
        "MCP:",
        f"https://efferent.example/mcp/b/{bucket or bucket_of(public)}",
        "",
        "Reading key:",
        f"efferent-reading-v1.{wire.to_base64url(secret)}.{wire.to_base64url(public)}",
    ]
    if editor is not None:
        editor_secret, editor_public = raw_pair(editor)
        lines += [
            "",
            "Editor key:",
            f"efferent-editor-v1.{wire.to_base64url(editor_secret)}.{wire.to_base64url(editor_public)}",
        ]
    return "\n".join(lines)


class HPKE(unittest.TestCase):
    def test_rfc_9180_vectors_seal_and_open_as_published(self):
        wire.self_test()

    def test_a_fresh_key_opens_what_was_sealed_to_it(self):
        secret, public = raw_pair(X25519PrivateKey.generate())
        sealed = wire.hpke_seal(public, wire.INFO, b"aad", b"the day")
        self.assertEqual(wire.hpke_open(secret, wire.INFO, b"aad", sealed), b"the day")

    def test_sealing_twice_differs_and_both_open(self):
        secret, public = raw_pair(X25519PrivateKey.generate())
        first = wire.hpke_seal(public, wire.INFO, b"aad", b"x")
        second = wire.hpke_seal(public, wire.INFO, b"aad", b"x")
        self.assertNotEqual(first, second)
        self.assertEqual(wire.hpke_open(secret, wire.INFO, b"aad", second), b"x")

    def test_another_day_another_bucket_or_another_key_is_refused(self):
        secret, public = raw_pair(X25519PrivateKey.generate())
        other, _ = raw_pair(X25519PrivateKey.generate())
        sealed = wire.hpke_seal(public, wire.INFO, b"efferent/v1\nb\n2026-01-01", b"x")
        with self.assertRaises(InvalidTag):
            wire.hpke_open(secret, wire.INFO, b"efferent/v1\nb\n2026-01-02", sealed)
        with self.assertRaises(InvalidTag):
            wire.hpke_open(secret, wire.INFO, b"efferent/v1\nc\n2026-01-01", sealed)
        with self.assertRaises(InvalidTag):
            wire.hpke_open(other, wire.INFO, b"efferent/v1\nb\n2026-01-01", sealed)

    def test_a_flipped_byte_is_refused_not_returned(self):
        secret, public = raw_pair(X25519PrivateKey.generate())
        sealed = bytearray(wire.hpke_seal(public, wire.INFO, b"aad", b"x" * 40))
        sealed[-1] ^= 1
        with self.assertRaises(InvalidTag):
            wire.hpke_open(secret, wire.INFO, b"aad", bytes(sealed))


class Handoff(unittest.TestCase):
    def test_four_fields_give_endpoint_bucket_and_both_keys(self):
        reading, editor = X25519PrivateKey.generate(), Ed25519PrivateKey.generate()
        endpoint, bucket, private_raw, editor_raw = wire.connection(handoff(reading, editor))
        self.assertEqual(endpoint, "https://efferent.example")
        self.assertEqual(bucket, bucket_of(raw_pair(reading)[1]))
        self.assertEqual(private_raw, raw_pair(reading)[0])
        self.assertEqual(editor_raw, raw_pair(editor)[0])

    def test_three_fields_read_and_cannot_write(self):
        _, _, _, editor_raw = wire.connection(handoff(X25519PrivateKey.generate(), None))
        self.assertIsNone(editor_raw)

    def test_a_key_that_belongs_to_another_bucket_is_refused(self):
        text = handoff(X25519PrivateKey.generate(), None, bucket="a" * 26)
        with self.assertRaisesRegex(ValueError, "different bucket"):
            wire.connection(text)

    def test_mismatched_halves_are_refused(self):
        reading = X25519PrivateKey.generate()
        text = handoff(reading, None)
        _, other_public = raw_pair(X25519PrivateKey.generate())
        secret, _ = raw_pair(reading)
        # The public half of another key in place of the real one: the private
        # half no longer derives it, and the importer says so before it looks at
        # the bucket.
        forged = text.rsplit(".", 1)[0] + "." + wire.to_base64url(other_public)
        with self.assertRaisesRegex(ValueError, "do not match"):
            wire.connection(forged)

    def test_a_query_on_the_mcp_url_is_refused(self):
        text = handoff(X25519PrivateKey.generate(), None).replace(
            "\n\nReading key", "?x=1\n\nReading key"
        )
        with self.assertRaisesRegex(ValueError, "query"):
            wire.connection(text)

    def test_a_missing_field_is_named(self):
        with self.assertRaisesRegex(ValueError, "no MCP field"):
            wire.connection("Instruction:\nx\n\nReading key:\ny\n")


class Days(unittest.TestCase):
    def test_a_columnar_day_expands_to_one_line_per_row(self):
        day = {
            "v": 2,
            "series": [
                {
                    "k": "agg",
                    "metric": "steps",
                    "bucket": "hour",
                    "unit": "count",
                    "source": "Watch",
                    "t0": 1_754_557_200,
                    "t": [0, 3600],
                    "d": [3600, 3600],
                    "value": [842, 120],
                }
            ],
        }
        lines = wire.expand(json.dumps(day).encode()).splitlines()
        self.assertEqual(len(lines), 2)
        first = json.loads(lines[0])
        self.assertEqual(first["id"], "agg:steps:2025-08-07T09:00:00Z:h")
        self.assertEqual(first["value"], 842)
        self.assertEqual(first["end"], "2025-08-07T10:00:00Z")
        self.assertEqual(first["bucket"], "hour")
        self.assertEqual(json.loads(lines[1])["value"], 120)

    def test_rows_that_land_on_one_instant_are_numbered(self):
        day = {
            "v": 2,
            "series": [
                {
                    "k": "hk",
                    "metric": "sleep",
                    "t0": 1_754_517_600,
                    "t": [0, 0],
                    "d": [600, 1200],
                    "stage": ["asleepCore", "asleepDeep"],
                }
            ],
        }
        ids = [
            json.loads(line)["id"] for line in wire.expand(json.dumps(day).encode()).splitlines()
        ]
        self.assertEqual(
            ids, ["hk:sleep:2025-08-06T22:00:00Z#1", "hk:sleep:2025-08-06T22:00:00Z#2"]
        )

    def test_a_day_written_as_lines_passes_through(self):
        lines = b'{"id":"a","v":1}\n{"id":"b","v":1}\n'
        self.assertEqual(wire.expand(lines), lines.decode())
        self.assertEqual(wire.expand(b""), "")

    def test_a_layout_this_reader_does_not_speak_is_refused(self):
        with self.assertRaises(SystemExit):
            wire.expand(b'{"v":3,"series":[]}')


class ReadKey(unittest.TestCase):
    """The key a read is signed with. Nobody stores it: the phone and every
    reader make it from the reading key, so the derivation itself is the
    contract, and these vectors are what the Swift side is held to as well."""

    READING_PRIVATE = bytes(range(1, 33))
    BUCKET = "abucketidmadeupforthistest"
    TARGET = f"/b/{BUCKET}/d?from=2026-08-01&to=2026-08-31"

    def test_the_read_key_matches_the_published_vector(self):
        key = wire.read_key(self.READING_PRIVATE)
        seed = key.private_bytes(
            serialization.Encoding.Raw,
            serialization.PrivateFormat.Raw,
            serialization.NoEncryption(),
        )
        self.assertEqual(
            seed.hex(), "39e7d153a3e583b4036f36b661bf06e3714d6c29d969c347d2bbe45e6bdc87be"
        )
        self.assertEqual(
            key.public_key().public_bytes(*RAW).hex(),
            "434172a1e4cbfe85eb1097bdc785a22e5a293a0c05ddee75ff146822f9ee53b5",
        )

    def test_a_read_signature_matches_the_published_vector(self):
        # Ed25519 here is deterministic, so the signature is a vector too. The
        # phone's CryptoKit signs with fresh randomness, so the Swift test
        # verifies this signature rather than reproducing it.
        message = wire.canonical_read(self.BUCKET, self.TARGET, 1_700_000_000)
        self.assertEqual(
            message,
            "efferent/v1 read\n"
            "abucketidmadeupforthistest\n"
            "/b/abucketidmadeupforthistest/d?from=2026-08-01&to=2026-08-31\n"
            "1700000000",
        )
        self.assertEqual(
            wire.read_key(self.READING_PRIVATE).sign(message.encode()).hex(),
            "babf8af472d036155a4cbb7bb5385cb0dc360aa18e27c825660609b5d28937f9"
            "502366c466fbfb9fc724e8d0d3615e47f77b6f9fe62c312b80f3a8267d037900",
        )

    def test_the_headers_sign_the_path_and_query_exactly_as_sent(self):
        url = f"https://efferent.example{self.TARGET}"
        headers = wire.read_headers(url, self.BUCKET, self.READING_PRIVATE, 1_700_000_000)

        self.assertEqual(headers["X-Efferent-Timestamp"], "1700000000")
        public = wire.read_key(self.READING_PRIVATE).public_key()
        self.assertEqual(headers["X-Efferent-Reader"], wire.to_base64url(public.public_bytes(*RAW)))
        public.verify(
            wire.base64url(headers["X-Efferent-Signature"]),
            wire.canonical_read(self.BUCKET, self.TARGET, 1_700_000_000).encode(),
        )

        # No query, no question mark: the service signs what the URL parser
        # leaves of it, and an empty query leaves nothing.
        bare = wire.read_headers(
            f"https://efferent.example/b/{self.BUCKET}/stats", self.BUCKET, self.READING_PRIVATE, 1
        )
        public.verify(
            wire.base64url(bare["X-Efferent-Signature"]),
            wire.canonical_read(self.BUCKET, f"/b/{self.BUCKET}/stats", 1).encode(),
        )

    def test_another_reading_key_makes_another_read_key(self):
        one = wire.read_key(self.READING_PRIVATE).public_key().public_bytes(*RAW)
        other = wire.read_key(bytes(range(2, 34))).public_key().public_bytes(*RAW)
        self.assertNotEqual(one, other)


class Frames(unittest.TestCase):
    """A range answer: the upload frame travelling back."""

    @staticmethod
    def frame(*days: tuple[str, bytes]) -> bytes:
        return b"".join(day.encode() + len(blob).to_bytes(4, "big") + blob for day, blob in days)

    def test_days_come_back_in_order_with_their_bytes(self):
        body = self.frame(("2026-08-01", b"one"), ("2026-08-03", b"three"))
        self.assertEqual(
            wire.unpack_frame(body), [("2026-08-01", b"one"), ("2026-08-03", b"three")]
        )

    def test_an_empty_answer_is_a_range_with_no_days(self):
        self.assertEqual(wire.unpack_frame(b""), [])

    def test_every_way_a_frame_is_wrong_is_refused_whole(self):
        good = self.frame(("2026-08-01", b"one"))
        cases = [
            (good[:-1], "only 2 are there"),
            (good + b"2026-08", "left over"),
            (self.frame(("2026-08-01", b"one"), ("2026-08-01", b"again")), "ascend"),
            (self.frame(("2026-02-30", b"one")), "not a day"),
            (self.frame(("2026-08-01", b"")), "no body"),
        ]
        for body, pattern in cases:
            with self.subTest(pattern=pattern):
                with self.assertRaisesRegex(ValueError, pattern):
                    wire.unpack_frame(body)


class Edits(unittest.TestCase):
    PUT = {
        "op": "put",
        "id": "agent:meal:2026-08-28:lunch",
        "metric": "dietaryEnergy",
        "start": 1_756_382_400,
        "end": 1_756_384_200,
        "value": 640,
        "unit": "kcal",
    }

    def test_valid_items_pass_and_pack_deterministically(self):
        items = [self.PUT, {"op": "delete", "id": "agent:meal:2026-08-20:dinner"}]
        self.assertEqual(wire.validate_items(items), items)
        packed = wire.pack_edit(items)
        text = zlib.decompress(packed, -zlib.MAX_WBITS).decode()
        self.assertEqual(json.loads(text)["v"], wire.EDIT_FORMAT_VERSION)
        self.assertEqual(
            json.loads(text)["items"][1], {"op": "delete", "id": "agent:meal:2026-08-20:dinner"}
        )
        self.assertEqual(packed, wire.pack_edit(items))

    def test_every_way_an_item_is_wrong_names_the_item(self):
        cases = [
            ({**self.PUT, "unit": "g"}, "unit"),
            ({**self.PUT, "metric": "steps"}, "metric"),
            ({**self.PUT, "end": self.PUT["start"] - 1}, "before start"),
            ({**self.PUT, "id": "bad id"}, "id"),
            ({**self.PUT, "extra": 1}, "extra"),
            ({"op": "delete"}, "id"),
            ({"op": "move", "id": "x"}, "op"),
        ]
        for item, pattern in cases:
            with self.subTest(item=item):
                with self.assertRaisesRegex(ValueError, "item 0: .*(" + pattern + ")"):
                    wire.validate_items([item])

    def test_an_empty_or_oversized_edit_is_refused(self):
        with self.assertRaises(ValueError):
            wire.validate_items([])
        with self.assertRaisesRegex(ValueError, str(wire.MAX_ITEMS_PER_EDIT)):
            wire.validate_items([self.PUT] * (wire.MAX_ITEMS_PER_EDIT + 1))


if __name__ == "__main__":
    unittest.main()
