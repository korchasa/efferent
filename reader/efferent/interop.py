"""Do the two implementations still agree?

The Swift under `src/Core` and this reader describe the same bytes twice, in two
languages, and nothing but a check keeps them in step. A Swift test packs, seals
and signs a real request of two days; this unpacks it, opens each day with the
matching private key and checks the signature. Drift between the two shows up
here rather than on a phone.

Two days rather than one on purpose: a batch of one would never exercise the
boundary between them, which is where a framing disagreement would live.

This is the reading half. `deno task interop` runs the Swift half around it:
`fixture` first, so the phone has an edit to open, then `check` with what the
Swift test printed.

The reading key below is a fixture. Its public half is in `WireTests.swift`, its
private half is right here in the open — it guards nothing.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey

import efferent_hpke as wire

from .archive import events_of, transport
from .phone import (
    canonical_edit,
    canonical_request,
    decompress,
    pack_day,
    unpack_days,
    verify_upload,
)
from .sealed import associated_data, edit_associated_data, open_sealed

# A throwaway key pair, generated once for this check and used nowhere else.
#
# It is committed on purpose: the check has to open what Swift sealed, so both
# halves must be identical on every machine, and a key that must be identical
# everywhere cannot be a secret. It guards nothing — the bucket it addresses
# holds two days of made-up steps.
#
# The scanner flags keys of exactly this shape, and `.gitleaks.toml` excuses
# this one by naming both the file and the value, so pasting a different key
# here still fails the check. That narrowness is the point: the risk is not the
# fixture, it is the day somebody replaces it with a real reading key — which
# would be published the moment it was committed, and decrypts everything the
# archive has ever held.
READING_PRIVATE = "MC4CAQAwBQYDK2VuBCIEIB-BUIZTXqbNIR0MFd8VXE2BPlP2ohi2pcpCd_FksGD6"
READING_PUBLIC = "YAvPaXBsGTnyrLF6FcE1oI2EjHmIeKAg07zRX51nI2w"
DAY = "2026-08-07"
SECOND_DAY = "2026-08-08"

ITEMS = [
    {
        "op": "put",
        "id": "agent:meal:2026-08-07:lunch",
        "metric": "dietaryEnergy",
        "start": 1_754_568_000,
        "end": 1_754_569_800,
        "value": 640,
        "unit": "kcal",
    },
    {
        "op": "put",
        "id": "agent:sleep:2026-08-06:core",
        "metric": "sleep",
        "start": 1_754_517_600,
        "end": 1_754_542_800,
        "stage": "asleepCore",
    },
    {"op": "delete", "id": "agent:meal:2026-08-01:dinner"},
]


def section(title: str) -> None:
    print(f"\n==> {title}")


def expect(condition: bool, message: str) -> None:
    if not condition:
        print(f"error: {message}", file=sys.stderr)
        raise SystemExit(1)


def raw(private) -> bytes:
    return private.private_bytes(
        serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption()
    )


# MARK: - The edit the phone will open


def make_fixture(state_path: Path) -> None:
    """An edit the way the reader makes one: the items packed, sealed to the
    reading key with the bucket in the tag, and signed by the editor over the
    canonical message.

    Writing goes the other way round from a day, so this side seals and the
    phone opens. Both keys are made here for this run and never leave: the
    reading key travels to the test as its raw private half, the editor key as
    its public half beside the signature."""
    reading = X25519PrivateKey.generate()
    reading_public = reading.public_key().public_bytes(*wire.RAW)
    bucket = wire.bucket_of(reading_public)

    editor = Ed25519PrivateKey.generate()
    editor_public = editor.public_key().public_bytes(*wire.RAW)

    sealed = bytes([wire.SEALED_VERSION]) + wire.hpke_seal(
        reading_public, wire.INFO, edit_associated_data(bucket), wire.pack_edit(ITEMS)
    )
    timestamp = 1_700_000_000
    signature = editor.sign(canonical_edit(bucket, timestamp, sealed).encode())

    fixture = wire.to_base64url(
        json.dumps(
            {
                "bucket": bucket,
                "readingPrivate": wire.to_base64url(raw(reading)),
                "editor": wire.to_base64url(editor_public),
                "timestamp": timestamp,
                "signature": wire.to_base64url(signature),
                "sealed": wire.to_base64url(sealed),
            },
            separators=(",", ":"),
        ).encode()
    )
    state_path.write_text(json.dumps({"fixture": fixture}))
    print(fixture)


# MARK: - What the phone produced


def read_day(blob: bytes, day: str, private_raw: bytes, public_raw: bytes, bucket: str) -> list:
    """Open one sealed day and read its lines back.

    The strongest thing this check can say: the two implementations do not
    merely agree about what a day means, they write the same bytes for it. A day
    whose bytes differ between them is a day the phone would re-upload for ever,
    because the fingerprint it compares is over exactly these bytes."""
    plaintext = decompress(open_sealed(private_raw, public_raw, blob, associated_data(bucket, day)))
    text = plaintext.decode()
    events = events_of(plaintext)
    repacked = pack_day([{k: v for k, v in event.items() if k != "id"} for event in events])
    expect(
        repacked == text,
        f"Swift and Python packed {day} differently:\n  swift {text}\n  python {repacked}",
    )
    return events


def check(state_path: Path, emitted: dict, post_to: str | None) -> None:
    public_raw = wire.base64url(READING_PUBLIC)
    bucket = wire.bucket_of(public_raw)
    private_raw = X25519PrivateKey.from_private_bytes(
        serialization.load_der_private_key(
            wire.base64url(READING_PRIVATE), password=None
        ).private_bytes(
            serialization.Encoding.Raw,
            serialization.PrivateFormat.Raw,
            serialization.NoEncryption(),
        )
    )
    private_raw = raw(private_raw)

    section("Importing the phone-owned reading key locally")
    from .connection import parse_connection_handoff  # noqa: PLC0415 — only this path needs it

    handoff = wire.base64url(emitted["handoff"]).decode()
    imported = parse_connection_handoff(handoff)
    expect(
        imported["mcpURL"] == f"https://efferent.example/mcp/b/{imported['bucket']}",
        "the local importer did not keep the bucket embedded in the phone's MCP URL",
    )
    expect(
        len(imported["reading"]["readingPrivate"]) > 40,
        "the phone's raw private key did not become a local PKCS8 reading key",
    )

    section("Unpacking the request the phone built")
    frame = wire.base64url(emitted["frame"])
    packed = unpack_days(frame)
    expect(len(packed) == 2, f"expected 2 days in the frame, got {len(packed)}")
    named = ",".join(day for day, _ in packed)
    expect(named == f"{DAY},{SECOND_DAY}", f"the frame named {named}")

    section("Opening each day with the reading key")
    lines = read_day(packed[0][1], DAY, private_raw, public_raw, bucket)
    expect(len(lines) == 2, f"expected 2 events, got {len(lines)}")
    # Totals before records, which is what makes an unchanged day the same bytes
    # twice — and the id below is rebuilt here, not carried on the wire.
    expect(lines[0]["id"] == "agg:steps:2025-08-07T09:00:00Z:h", f"first id was {lines[0]['id']}")
    expect(lines[0]["metric"] == "steps" and lines[0]["value"] == 842, "the fields did not survive")
    expect(lines[0].get("bucket") == "hour", "a total has to say which bucket it is")
    expect(lines[1]["id"] == "hk:sleep:2025-08-06T22:00:00Z", f"second id was {lines[1]['id']}")
    expect(
        lines[1]["metric"] == "sleep" and lines[1]["stage"] == "asleepCore",
        "the sleep stage was lost",
    )
    expect("bucket" not in lines[1], "a record must not look like a total")

    second = read_day(packed[1][1], SECOND_DAY, private_raw, public_raw, bucket)
    expect(len(second) == 1, f"expected 1 event on the second day, got {len(second)}")
    expect(second[0]["value"] == 1201, f"the second day's total was {second[0]['value']}")

    # Each day is sealed to its own date, so the one cannot be opened as the
    # other. Without that, a service could hand back Friday for Thursday and
    # nothing would notice — the day is only in the tag, never in the ciphertext.
    moved = False
    try:
        open_sealed(private_raw, public_raw, packed[1][1], associated_data(bucket, DAY))
        moved = True
    except Exception:  # noqa: BLE001 — what should happen
        pass
    expect(not moved, "a day opened under another date — the date is not bound into the tag")

    section("Checking the signature the phone produced")
    writer = wire.base64url(emitted["writer"])
    signature = wire.base64url(emitted["signature"])
    timestamp = int(emitted["timestamp"])
    days = [DAY, SECOND_DAY]
    expect(
        verify_upload(writer, signature, bucket, days, timestamp, frame),
        "the reader could not verify a signature the phone made",
    )

    # A signature that verifies against the wrong body would mean the body hash
    # is not really in the canonical string — the failure that lets anyone swap
    # a day.
    tampered = bytearray(frame)
    tampered[-1] ^= 0x01
    expect(
        not verify_upload(writer, signature, bucket, days, timestamp, bytes(tampered)),
        "a changed body still verified — the body is not covered by the signature",
    )
    expect(
        not verify_upload(writer, signature, bucket, [DAY], timestamp, frame),
        "dropping a day from the batch still verified — the days are not in the canonical string",
    )

    if post_to:
        post(post_to, bucket, frame, emitted, private_raw, public_raw)

    section("Checking what the phone made of the edit")
    expect(
        emitted["editItems"] == str(len(ITEMS)),
        f"the phone unpacked {emitted['editItems']} items out of {len(ITEMS)}",
    )
    expect(
        emitted["editIds"] == ",".join(item["id"] for item in ITEMS),
        f"the phone read the ids as {emitted['editIds']}",
    )
    expect(
        emitted["editMetrics"] == ",".join(item.get("metric", "delete") for item in ITEMS),
        f"the phone read the metrics as {emitted['editMetrics']}",
    )

    section(
        f"Both sides agree: bucket {bucket}, {len(packed)} days, {len(frame)} bytes on the wire, "
        f"and an edit of {len(ITEMS)} items opened on the phone"
    )
    rebuilt = canonical_request(bucket, days, timestamp, frame)
    print("  canonical request the reader rebuilt:")
    for part in rebuilt.split("\n"):
        print(f"    {part}")
    state_path.unlink(missing_ok=True)


def post(
    post_to: str, bucket: str, frame: bytes, emitted: dict, private_raw: bytes, public_raw: bytes
) -> None:
    """The bytes agree; whether a real service accepts them is a separate
    question, and the only way to answer it is to ask one."""
    section(f"Posting the Swift request to {post_to}")
    status, answer = transport(
        "PUT",
        f"{post_to}/b/{bucket}/days",
        {
            "Content-Type": "application/octet-stream",
            "X-Efferent-Timestamp": emitted["liveTimestamp"],
            "X-Efferent-Writer": emitted["writer"],
            "X-Efferent-Signature": emitted["liveSignature"],
        },
        frame,
    )
    text = answer.decode("utf-8", "replace")
    expect(status < 400, f"the service refused a request the phone made: {status} {text}")
    expect(
        ",".join(json.loads(text)["stored"]) == f"{DAY},{SECOND_DAY}",
        f"expected both days back, got {text}",
    )

    section("Reading them back out of the service")
    # Each day has to come back on its own: a batch is a way of travelling, and
    # an archive that kept it as one object would answer a date with a frame.
    for day, expected in (
        (DAY, "agg:steps:2026-08-07T09:00:00Z:h"),
        (SECOND_DAY, "agg:steps:2026-08-08T09:00:00Z:h"),
    ):
        _, stored = transport("GET", f"{post_to}/b/{bucket}/d/{day}")
        read_back = decompress(
            open_sealed(private_raw, public_raw, stored, associated_data(bucket, day))
        ).decode()
        expect(expected in read_back, f"what came back for {day} is not what went in")
        print(f"  {day}: {len(read_back.strip().splitlines())} lines back, {len(stored)} bytes")

    _, listed = transport("GET", f"{post_to}/b/{bucket}/days")
    days = json.loads(listed)["days"]
    expect(len(days) >= 2, f"the service listed {len(days)} days back")


def main(argv: list[str] | None = None) -> None:
    args = sys.argv[1:] if argv is None else argv
    if len(args) < 2:
        raise SystemExit("usage: python -m efferent.interop fixture|check <state.json>")
    what, state_path = args[0], Path(args[1])
    if what == "fixture":
        return make_fixture(state_path)
    if what == "check":
        emitted = json.loads(state_path.read_text())["emitted"]
        return check(state_path, emitted, args[2] if len(args) > 2 else None)
    raise SystemExit(f"no such step: {what}")


if __name__ == "__main__":
    main()
