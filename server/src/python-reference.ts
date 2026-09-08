/** The local-only RFC 9180 reader embedded in the remote MCP setup guide. */
export const PYTHON_HPKE_REFERENCE = String.raw`#!/usr/bin/env python3
import argparse
import base64
from datetime import date, datetime, timezone
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import sys
import time
from urllib.error import HTTPError
from urllib.parse import urlsplit, urlunsplit
from urllib.request import Request, urlopen
import zlib

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from pyhpke import AEADId, CipherSuite, KDFId, KEMId

INFO = b"efferent/v2 hpke"
SEALED_VERSION = 2
ENC_BYTES = 32
SUITE = CipherSuite.new(
    KEMId.DHKEM_X25519_HKDF_SHA256,
    KDFId.HKDF_SHA256,
    AEADId.CHACHA20_POLY1305,
)
USER_AGENT = "efferent-local-reader/1.0"
RAW = (serialization.Encoding.Raw, serialization.PublicFormat.Raw)


def base64url(value: str) -> bytes:
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def to_base64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode()


def optional_field(handoff: str, name: str) -> str | None:
    match = re.search(rf"(?:^|\n){re.escape(name)}:\s*\r?\n([^\r\n]+)", handoff)
    return match.group(1).strip() if match else None


def field(handoff: str, name: str) -> str:
    value = optional_field(handoff, name)
    if not value:
        raise ValueError(f"the handoff has no {name} field")
    return value


def connection(handoff: str) -> tuple[str, str, bytes, bytes | None]:
    """The endpoint, the bucket, the raw reading private key, and the raw editor
    private key when the handoff carries one. A handoff from before writing
    existed has three fields; such a connection reads and cannot write."""
    mcp = urlsplit(field(handoff, "MCP"))
    if mcp.scheme not in ("http", "https") or mcp.query or mcp.fragment:
        raise ValueError("MCP must be an HTTP URL without a query or fragment")
    match = re.fullmatch(r"(.*)/mcp/b/([a-z2-7]{26})", mcp.path)
    if not match:
        raise ValueError("MCP must end in /mcp/b/<bucket-id>")
    prefix, bucket = match.groups()

    key_parts = field(handoff, "Reading key").split(".")
    if len(key_parts) != 3 or key_parts[0] != "efferent-reading-v1":
        raise ValueError("the reading key is not an Efferent reading key version 1")
    private_raw, public_raw = map(base64url, key_parts[1:])
    if len(private_raw) != 32 or len(public_raw) != 32:
        raise ValueError("the reading key must contain two 32-byte X25519 keys")

    actual_public = X25519PrivateKey.from_private_bytes(private_raw).public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw
    )
    if not hmac.compare_digest(actual_public, public_raw):
        raise ValueError("the private and public halves of the reading key do not match")

    derived = base64.b32encode(hashlib.sha256(public_raw).digest()).decode().lower()[:26]
    if derived != bucket:
        raise ValueError("the reading key belongs to a different bucket than the MCP URL")

    editor_raw = None
    editor_field = optional_field(handoff, "Editor key")
    if editor_field:
        editor_parts = editor_field.split(".")
        if len(editor_parts) != 3 or editor_parts[0] != "efferent-editor-v1":
            raise ValueError("the editor key is not an Efferent editor key version 1")
        editor_raw, editor_public = map(base64url, editor_parts[1:])
        if len(editor_raw) != 32 or len(editor_public) != 32:
            raise ValueError("the editor key must contain two 32-byte Ed25519 keys")
        actual_editor = Ed25519PrivateKey.from_private_bytes(editor_raw).public_key().public_bytes(*RAW)
        if not hmac.compare_digest(actual_editor, editor_public):
            raise ValueError("the private and public halves of the editor key do not match")

    endpoint = urlunsplit((mcp.scheme, mcp.netloc, prefix, "", "")).rstrip("/")
    return endpoint, bucket, private_raw, editor_raw


def load_handoff(handoff_path: Path) -> tuple[str, str, bytes, bytes | None]:
    if os.name == "posix" and handoff_path.stat().st_mode & 0o077:
        raise PermissionError("the handoff file must be readable only by its owner: chmod 600")
    return connection(handoff_path.read_text())


def read_day(handoff_path: Path, day: str) -> bytes:
    endpoint, bucket, private_raw, _ = load_handoff(handoff_path)
    aad = f"efferent/v1\n{bucket}\n{day}".encode()

    # This request contains only the bucket and date. The reading key remains local.
    request = Request(
        f"{endpoint}/b/{bucket}/d/{day}",
        headers={
            "Accept": "application/octet-stream",
            "User-Agent": USER_AGENT,
        },
    )
    with urlopen(request, timeout=30) as response:
        blob = response.read(16 * 1024 * 1024 + 1)
    if len(blob) > 16 * 1024 * 1024:
        raise ValueError("the sealed day exceeds the 16 MiB protocol limit")
    if not blob or blob[0] != SEALED_VERSION:
        version = blob[0] if blob else "missing"
        raise ValueError(f"expected HPKE sealed version 2, got {version}")

    recipient = SUITE.kem.deserialize_private_key(private_raw)
    context = SUITE.create_recipient_context(
        blob[1 : 1 + ENC_BYTES], recipient, info=INFO
    )
    compressed = context.open(blob[1 + ENC_BYTES :], aad=aad)
    return zlib.decompress(compressed, -zlib.MAX_WBITS)


DAY_FORMAT_VERSION = 2
SHARED = ("metric", "bucket", "unit", "source")
COLUMNS = ("value", "stage", "activity", "duration")


def expand(plaintext: bytes) -> str:
    """Turn a stored day into NDJSON: one JSON object per line.

    A day is stored as columns. Rows that agree on kind, metric, bucket, unit and
    source share a series and name all of that once; instants travel as whole
    seconds counted from the first row. That is an eighth of the size of a line
    per reading, and the reason there is no record id on the wire: it was 58% of
    the bytes and nothing read it.

    An identity is rebuilt here from the kind, the metric and the instant. Two
    sleep stages can begin in the same second, so rows that land on one identity
    are numbered #1, #2 in the order the series holds them, which the writer
    fixes. Days written before this layout are lines already and pass through.
    """
    text = plaintext.decode("utf-8").strip()
    if not text or "\n" in text or not text.startswith("{"):
        return text + "\n" if text else ""

    document = json.loads(text)
    if "series" not in document:
        return text + "\n"
    if document.get("v") != DAY_FORMAT_VERSION:
        raise SystemExit(
            f"this day is written in layout {document.get('v')}, "
            f"and this reader speaks {DAY_FORMAT_VERSION}"
        )

    events = []
    for series in document["series"]:
        moment = series["t0"]
        for row, step in enumerate(series["t"]):
            moment += step
            event = {"v": 1, "start": instant(moment), "end": instant(moment + series["d"][row])}
            for name in SHARED:
                if name in series:
                    event[name] = series[name]
            for name in COLUMNS:
                if name in series and series[name][row] is not None:
                    event[name] = series[name][row]
            tail = ":" + event["bucket"][0] if "bucket" in event else ""
            event["id"] = f"{series['k']}:{event.get('metric')}:{event['start']}{tail}"
            events.append(event)

    repeated = {}
    for event in events:
        repeated[event["id"]] = repeated.get(event["id"], 0) + 1
    running = {}
    for event in events:
        if repeated[event["id"]] > 1:
            running[event["id"]] = seen = running.get(event["id"], 0) + 1
            event["id"] = f"{event['id']}#{seen}"

    return "".join(json.dumps(event, sort_keys=True) + "\n" for event in events)


def instant(seconds: int) -> str:
    return datetime.fromtimestamp(seconds, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# Writing into Health goes the other way: an edit is sealed to the phone's own
# reading key, signed with the editor key, and handed to the service, which
# stores it unopened. The phone opens it, checks the signature itself and puts
# the samples into Health. Nothing here, and nothing on the service, can put a
# number into Health directly.

EDIT_FORMAT_VERSION = 1
MAX_ITEMS_PER_EDIT = 500
SLEEP_STAGES = ("inBed", "awake", "asleepUnspecified", "asleepCore", "asleepDeep", "asleepREM")
WRITABLE = {
    "sleep": None,
    "dietaryEnergy": "kcal",
    "dietaryProtein": "g",
    "dietaryCarbohydrates": "g",
    "dietaryFat": "g",
    "dietaryWater": "mL",
    "bodyMass": "kg",
}
PUT_KEYS = ("op", "id", "metric", "start", "end", "value", "unit", "stage")
DELETE_KEYS = ("op", "id")
ID = re.compile(r"[A-Za-z0-9._:-]{1,120}")


def validate_items(items: object) -> list[dict]:
    """Every way an item can be wrong is said here, before anything is sealed."""
    if not isinstance(items, list) or not items:
        raise ValueError("items must be a list with at least one item")
    if len(items) > MAX_ITEMS_PER_EDIT:
        raise ValueError(f"an edit may carry {MAX_ITEMS_PER_EDIT} items, not {len(items)}")
    for index, item in enumerate(items):
        try:
            validate_item(item)
        except ValueError as error:
            raise ValueError(f"item {index}: {error}") from None
    return items


def validate_item(item: object) -> None:
    if not isinstance(item, dict):
        raise ValueError("an item must be an object")
    if item.get("op") not in ("put", "delete"):
        raise ValueError("op must be put or delete")
    if not isinstance(item.get("id"), str) or not ID.fullmatch(item["id"]):
        raise ValueError("id must be 1 to 120 characters of letters, digits, . _ : -")
    allowed = PUT_KEYS if item["op"] == "put" else DELETE_KEYS
    for key in item:
        if key not in allowed:
            raise ValueError(f"{key} is not a field of a {item['op']} item")
    if item["op"] == "delete":
        return
    if item.get("metric") not in WRITABLE:
        raise ValueError(f"metric {item.get('metric')!r} cannot be written")
    for name in ("start", "end"):
        value = item.get(name)
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            raise ValueError(f"{name} must be whole seconds since 1970")
    if item["end"] < item["start"]:
        raise ValueError("end must not be before start")
    unit = WRITABLE[item["metric"]]
    if unit is not None:
        if "stage" in item:
            raise ValueError("stage belongs to sleep, not to a quantity")
        value = item.get("value")
        if isinstance(value, bool) or not isinstance(value, (int, float)) or value < 0 or value != value:
            raise ValueError("value must be a finite number, zero or more")
        if item.get("unit") != unit:
            raise ValueError(f"unit must be {unit} for {item['metric']}")
    else:
        if "value" in item or "unit" in item:
            raise ValueError("value and unit belong to a quantity, not to sleep")
        if item.get("stage") not in SLEEP_STAGES:
            raise ValueError(f"stage must be one of {', '.join(SLEEP_STAGES)}")


def pack_edit(items: list[dict]) -> bytes:
    """Raw-deflate-compressed {"v":1,"items":[...]}, keys in a fixed order."""
    ordered = [
        {key: item[key] for key in (PUT_KEYS if item["op"] == "put" else DELETE_KEYS) if key in item}
        for item in items
    ]
    text = json.dumps({"v": EDIT_FORMAT_VERSION, "items": ordered}, separators=(",", ":"))
    compressor = zlib.compressobj(wbits=-zlib.MAX_WBITS)
    return compressor.compress(text.encode()) + compressor.flush()


def write_edit(handoff_path: Path, items_path: Path) -> str:
    endpoint, bucket, private_raw, editor_raw = load_handoff(handoff_path)
    if editor_raw is None:
        raise ValueError(
            "this handoff has no Editor key field, so it predates writing: "
            "the agent can read the archive and cannot write into Health"
        )
    loaded = json.loads(items_path.read_text())
    items = validate_items(loaded["items"] if isinstance(loaded, dict) else loaded)

    # Sealed to the phone's reading key, with the bucket in the tag; the service
    # names the edit afterwards and never sees inside it.
    public_raw = X25519PrivateKey.from_private_bytes(private_raw).public_key().public_bytes(*RAW)
    enc, context = SUITE.create_sender_context(
        SUITE.kem.deserialize_public_key(public_raw), info=INFO
    )
    sealed = bytes([SEALED_VERSION]) + enc + context.seal(
        pack_edit(items), aad=f"efferent/v1 edit\n{bucket}".encode()
    )

    # Signed by the editor key over the canonical message the service and the
    # phone both check: the purpose, the bucket, the time and a digest of the bytes.
    timestamp = int(time.time())
    digest = to_base64url(hashlib.sha256(sealed).digest())
    message = f"efferent/v1 edit\n{bucket}\n{timestamp}\n{digest}".encode()
    editor = Ed25519PrivateKey.from_private_bytes(editor_raw)

    request = Request(
        f"{endpoint}/b/{bucket}/edits",
        data=sealed,
        method="POST",
        headers={
            "Content-Type": "application/octet-stream",
            "User-Agent": USER_AGENT,
            "X-Efferent-Timestamp": str(timestamp),
            "X-Efferent-Editor": to_base64url(editor.public_key().public_bytes(*RAW)),
            "X-Efferent-Signature": to_base64url(editor.sign(message)),
        },
    )
    try:
        with urlopen(request, timeout=30) as response:
            return response.read().decode()
    except HTTPError as error:
        raise SystemExit(f"the service refused the edit: {error.code} {error.read().decode()}")


def list_edits(handoff_path: Path) -> str:
    """Every edit and what the phone said about it, one JSON object per line.
    The listing is keyless: it names edits and counts, never their contents."""
    endpoint, bucket, _, _ = load_handoff(handoff_path)
    lines = []
    after = ""
    while True:
        query = f"?status=all&after={after}" if after else "?status=all"
        request = Request(
            f"{endpoint}/b/{bucket}/edits{query}", headers={"User-Agent": USER_AGENT}
        )
        with urlopen(request, timeout=30) as response:
            page = json.loads(response.read())
        lines.extend(json.dumps(entry, sort_keys=True) for entry in page["edits"])
        if not page.get("next"):
            return "".join(line + "\n" for line in lines)
        after = page["next"]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--handoff", required=True, type=Path)
    what = parser.add_mutually_exclusive_group(required=True)
    what.add_argument("--day", help="YYYY-MM-DD: fetch and decrypt that day")
    what.add_argument("--write", type=Path, help="a JSON file of items to write into Health")
    what.add_argument("--edits", action="store_true", help="list the edits and their outcomes")
    args = parser.parse_args()
    if args.write:
        sys.stdout.write(write_edit(args.handoff, args.write) + "\n")
        return
    if args.edits:
        sys.stdout.write(list_edits(args.handoff))
        return
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", args.day):
        parser.error("--day must be YYYY-MM-DD")
    try:
        date.fromisoformat(args.day)
    except ValueError:
        parser.error("--day must be YYYY-MM-DD")
    sys.stdout.write(expand(read_day(args.handoff, args.day)))


if __name__ == "__main__":
    main()
`;
