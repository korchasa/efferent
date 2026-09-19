"""What a phone does on the wire, for standing in for one.

The reader never uploads a real day: the phone builds days, seals them to its
own date, packs them into one request and signs the whole. This module is the
same bytes for the `send` command that pretends to be a phone against a
development service, and for the interop check that opens what a real phone's
tests produced. It is a port of the TypeScript `protocol/day.ts`,
`protocol/batch.ts` and `protocol/signing.ts`, byte for byte.
"""

import hashlib
import json
import zlib
from datetime import datetime, timezone

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from efferent_hpke import to_base64url

from .days import is_day

PROTOCOL = "efferent/v1"
DAY_FORMAT_VERSION = 2
SHARED = ("metric", "bucket", "unit", "source")
COLUMNS = ("value", "stage", "activity", "duration")
KNOWN = {"id", "v", "start", "end", *SHARED, *COLUMNS}
MAX_DAYS_PER_REQUEST = 31
DAY_BYTES = 10
HEADER_BYTES = DAY_BYTES + 4


# MARK: - Framing


def compress(data: bytes) -> bytes:
    """Raw deflate, the way every reader and the phone expect it."""
    compressor = zlib.compressobj(wbits=-zlib.MAX_WBITS)
    return compressor.compress(data) + compressor.flush()


def decompress(data: bytes) -> bytes:
    return zlib.decompress(data, -zlib.MAX_WBITS)


# MARK: - A day, packed the way the phone packs it


def epoch(instant: object) -> int:
    if not isinstance(instant, str) or not instant:
        raise ValueError("an event with no instant cannot be placed in a day")
    return int(datetime.fromisoformat(instant.replace("Z", "+00:00")).timestamp())


def kind_of(event: dict) -> str:
    return "hk" if event.get("bucket") is None else "agg"


def _compare(left: object, right: object) -> int:
    if left is None and right is None:
        return 0
    if left is None:
        return -1
    if right is None:
        return 1
    if isinstance(left, (int, float)) and isinstance(right, (int, float)):
        return (left > right) - (left < right)
    return (str(left) > str(right)) - (str(left) < str(right))


def _row_key(event: dict):
    from functools import cmp_to_key  # noqa: PLC0415

    return cmp_to_key(_precedes)(event)


def _precedes(left: dict, right: dict) -> int:
    by_start = epoch(left.get("start")) - epoch(right.get("start"))
    if by_start:
        return by_start
    by_end = epoch(left.get("end")) - epoch(right.get("end"))
    if by_end:
        return by_end
    for name in COLUMNS:
        order = _compare(left.get(name), right.get(name))
        if order:
            return order
    return 0


def pack_day(events: list[dict]) -> str:
    """Pack events into a day, byte for byte the way the phone does. The order
    events arrive in must not change the bytes: series by their shared fields,
    rows by their instants and then their values."""
    groups: dict[str, list[dict]] = {}
    for event in events:
        strangers = sorted(name for name in event if name not in KNOWN)
        if strangers:
            raise ValueError(f"no column for {', '.join(strangers)}")
        key = json.dumps(
            [kind_of(event), *(event.get(name) for name in SHARED)],
            separators=(",", ":"),
            ensure_ascii=False,
        )
        groups.setdefault(key, []).append(event)

    series = []
    for key in sorted(groups):
        rows = sorted(groups[key], key=_row_key)
        first = epoch(rows[0].get("start"))
        previous = first
        starts, lengths = [], []
        for row in rows:
            moment = epoch(row.get("start"))
            starts.append(moment - previous)
            previous = moment
            lengths.append(epoch(row.get("end")) - moment)
        entry: dict = {"k": kind_of(rows[0])}
        for name in SHARED:
            if rows[0].get(name) is not None:
                entry[name] = rows[0][name]
        entry["t0"] = first
        entry["t"] = starts
        entry["d"] = lengths
        for name in COLUMNS:
            if any(row.get(name) is not None for row in rows):
                entry[name] = [row.get(name) for row in rows]
        series.append(dict(sorted(entry.items())))

    return json.dumps(
        {"series": series, "v": DAY_FORMAT_VERSION}, separators=(",", ":"), ensure_ascii=False
    )


# MARK: - Several sealed days in one request


def _check(day: str, previous: str, length: int) -> None:
    if not is_day(day):
        raise ValueError(f"{json.dumps(day)} is not a day")
    if day <= previous:
        raise ValueError(f"days must ascend without repeats: {previous} then {day}")
    if length == 0:
        raise ValueError(f"{day} carries no body")


def pack_days(days: list[tuple[str, bytes]]) -> bytes:
    """`(day, sealed blob)` pairs into one frame: ten bytes of day, four of
    length, the blob, repeated to the end."""
    if not days:
        raise ValueError("a batch with no days in it")
    body = bytearray()
    previous = ""
    for day, blob in days:
        _check(day, previous, len(blob))
        previous = day
        body += day.encode("ascii") + len(blob).to_bytes(4, "big") + blob
    return bytes(body)


def unpack_days(body: bytes) -> list[tuple[str, bytes]]:
    """Read a frame back, or refuse it whole: a batch that unpacked to the days
    it happened to parse would store some of what was sent and answer as though
    it stored all of it."""
    days = []
    offset = 0
    previous = ""
    while offset < len(body):
        left = len(body) - offset
        if left < HEADER_BYTES:
            raise ValueError(f"{left} bytes left over where a day was expected")
        day = body[offset : offset + DAY_BYTES].decode("ascii", "replace")
        length = int.from_bytes(body[offset + DAY_BYTES : offset + HEADER_BYTES], "big")
        _check(day, previous, length)
        if left - HEADER_BYTES < length:
            raise ValueError(f"{day} says {length} bytes and only {left - HEADER_BYTES} are there")
        days.append((day, body[offset + HEADER_BYTES : offset + HEADER_BYTES + length]))
        previous = day
        offset += HEADER_BYTES + length
    if not days:
        raise ValueError("a batch with no days in it")
    return days


# MARK: - Who may write


def canonical_request(bucket: str, days: list[str], timestamp: int, body: bytes) -> str:
    """The exact bytes an upload signs: every field the server acts on, the hash
    of the body included, and the days named as well as hashed so the server
    has to prove its own reading of the frame."""
    digest = to_base64url(hashlib.sha256(body).digest())
    return "\n".join([PROTOCOL, bucket, ",".join(days), str(timestamp), digest])


def canonical_edit(bucket: str, timestamp: int, sealed: bytes) -> str:
    digest = to_base64url(hashlib.sha256(sealed).digest())
    return "\n".join([f"{PROTOCOL} edit", bucket, str(timestamp), digest])


def sign(private_raw: bytes, message: str) -> bytes:
    return Ed25519PrivateKey.from_private_bytes(private_raw).sign(message.encode())


def sign_upload(
    private_raw: bytes, bucket: str, days: list[str], timestamp: int, body: bytes
) -> bytes:
    return sign(private_raw, canonical_request(bucket, days, timestamp, body))


def unix_now() -> int:
    return int(datetime.now(timezone.utc).timestamp())
