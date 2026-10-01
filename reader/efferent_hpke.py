#!/usr/bin/env python3
import argparse
import base64
import hashlib
import hmac
import json
import os
import re
import sys
import time
import zlib
from datetime import date, datetime, timezone
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import urlsplit, urlunsplit
from urllib.request import Request, urlopen

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305

INFO = b"efferent/v2 hpke"
SEALED_VERSION = 2
ENC_BYTES = 32
USER_AGENT = "efferent-local-reader/1.0"
RAW = (serialization.Encoding.Raw, serialization.PublicFormat.Raw)
# What one answer from the service may weigh before this reader stops reading
# it. A day is at most a mebibyte and a range answer at most eight.
MAX_ANSWER_BYTES = 16 * 1024 * 1024

# RFC 9180 HPKE, base mode, DHKEM(X25519, HKDF-SHA256), HKDF-SHA256 and
# ChaCha20-Poly1305, written out below rather than imported: the only
# dependency is then the cryptography library, and --self-test checks these
# lines against the vectors the RFC publishes for this exact suite (A.2.1).
# Every sealed object here is one message per context, so the sequence number
# is always 0 and the nonce is the base nonce itself.
KEM_SUITE = b"KEM" + (32).to_bytes(2, "big")
HPKE_SUITE = b"HPKE" + (32).to_bytes(2, "big") + (1).to_bytes(2, "big") + (3).to_bytes(2, "big")


def hkdf_extract(salt: bytes, ikm: bytes) -> bytes:
    return hmac.new(salt or bytes(32), ikm, hashlib.sha256).digest()


def hkdf_expand(prk: bytes, info: bytes, length: int) -> bytes:
    out, block, counter = b"", b"", 1
    while len(out) < length:
        block = hmac.new(prk, block + info + bytes([counter]), hashlib.sha256).digest()
        out, counter = out + block, counter + 1
    return out[:length]


def labeled_extract(suite: bytes, salt: bytes, label: bytes, ikm: bytes) -> bytes:
    return hkdf_extract(salt, b"HPKE-v1" + suite + label + ikm)


def labeled_expand(suite: bytes, prk: bytes, label: bytes, info: bytes, length: int) -> bytes:
    return hkdf_expand(prk, length.to_bytes(2, "big") + b"HPKE-v1" + suite + label + info, length)


def key_and_nonce(
    dh: bytes, enc: bytes, recipient_public: bytes, info: bytes
) -> tuple[bytes, bytes]:
    shared = labeled_expand(
        KEM_SUITE,
        labeled_extract(KEM_SUITE, b"", b"eae_prk", dh),
        b"shared_secret",
        enc + recipient_public,
        32,
    )
    context = (
        b"\x00"
        + labeled_extract(HPKE_SUITE, b"", b"psk_id_hash", b"")
        + labeled_extract(HPKE_SUITE, b"", b"info_hash", info)
    )
    secret = labeled_extract(HPKE_SUITE, shared, b"secret", b"")
    return (
        labeled_expand(HPKE_SUITE, secret, b"key", context, 32),
        labeled_expand(HPKE_SUITE, secret, b"base_nonce", context, 12),
    )


def hpke_seal(
    recipient_public: bytes,
    info: bytes,
    aad: bytes,
    plaintext: bytes,
    ephemeral: X25519PrivateKey | None = None,
) -> bytes:
    """Encapsulated key followed by ciphertext and tag. The ephemeral key is
    supplied only by the self-test; every real seal draws a fresh one."""
    ephemeral = ephemeral or X25519PrivateKey.generate()
    enc = ephemeral.public_key().public_bytes(*RAW)
    dh = ephemeral.exchange(X25519PublicKey.from_public_bytes(recipient_public))
    key, nonce = key_and_nonce(dh, enc, recipient_public, info)
    return enc + ChaCha20Poly1305(key).encrypt(nonce, plaintext, aad)


def hpke_open(recipient_private: bytes, info: bytes, aad: bytes, sealed: bytes) -> bytes:
    private = X25519PrivateKey.from_private_bytes(recipient_private)
    enc, ciphertext = sealed[:ENC_BYTES], sealed[ENC_BYTES:]
    dh = private.exchange(X25519PublicKey.from_public_bytes(enc))
    key, nonce = key_and_nonce(dh, enc, private.public_key().public_bytes(*RAW), info)
    return ChaCha20Poly1305(key).decrypt(nonce, ciphertext, aad)


def self_test() -> None:
    """RFC 9180 appendix A.2.1, the published base-mode vectors for this suite:
    seal with the RFC's ephemeral key and expect its bytes, then open them."""
    info = bytes.fromhex("4f6465206f6e2061204772656369616e2055726e")
    ephemeral = X25519PrivateKey.from_private_bytes(
        bytes.fromhex("f4ec9b33b792c372c1d2c2063507b684ef925b8c75a42dbcbf57d63ccd381600")
    )
    recipient_private = bytes.fromhex(
        "8057991eef8f1f1af18f4a9491d16a1ce333f695d4db8e38da75975c4478e0fb"
    )
    recipient_public = bytes.fromhex(
        "4310ee97d88cc1f088a5576c77ab0cf5c3ac797f3d95139c6c84b5429c59662a"
    )
    plaintext = bytes.fromhex("4265617574792069732074727574682c20747275746820626561757479")
    aad = bytes.fromhex("436f756e742d30")
    expected = bytes.fromhex(
        "1afa08d3dec047a643885163f1180476fa7ddb54c6a8029ea33f95796bf2ac4a"
        "1c5250d8034ec2b784ba2cfd69dbdb8af406cfe3ff938e131f0def8c8b60b4db"
        "21993c62ce81883d2dd1b51a28"
    )
    sealed = hpke_seal(recipient_public, info, aad, plaintext, ephemeral)
    if sealed != expected:
        raise SystemExit("self-test failed: the sealed bytes differ from RFC 9180 A.2.1")
    if hpke_open(recipient_private, info, aad, sealed) != plaintext:
        raise SystemExit("self-test failed: the RFC 9180 A.2.1 ciphertext did not open")
    print("RFC 9180 A.2.1: sealed and opened exactly as published")


def base64url(value: str) -> bytes:
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def to_base64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode()


def bucket_of(reading_public_raw: bytes) -> str:
    """The bucket id, which is the reading public key hashed and written in
    base32. The service never learns the key; it is handed the name."""
    return base64.b32encode(hashlib.sha256(reading_public_raw).digest()).decode().lower()[:26]


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

    actual_public = (
        X25519PrivateKey.from_private_bytes(private_raw)
        .public_key()
        .public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    )
    if not hmac.compare_digest(actual_public, public_raw):
        raise ValueError("the private and public halves of the reading key do not match")

    if bucket_of(public_raw) != bucket:
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
        actual_editor = (
            Ed25519PrivateKey.from_private_bytes(editor_raw).public_key().public_bytes(*RAW)
        )
        if not hmac.compare_digest(actual_editor, editor_public):
            raise ValueError("the private and public halves of the editor key do not match")

    endpoint = urlunsplit((mcp.scheme, mcp.netloc, prefix, "", "")).rstrip("/")
    return endpoint, bucket, private_raw, editor_raw


def load_handoff(handoff_path: Path) -> tuple[str, str, bytes, bytes | None]:
    if os.name == "posix" and handoff_path.stat().st_mode & 0o077:
        raise PermissionError("the handoff file must be readable only by its owner: chmod 600")
    return connection(handoff_path.read_text())


def is_day(value: object) -> bool:
    """A calendar day, and one that exists: the 31st of February matches the
    pattern and is no day anybody can ask for."""
    if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
        return False
    try:
        date.fromisoformat(value)
    except ValueError:
        return False
    return True


# Every read is signed. The key is an Ed25519 key whose seed is
# HKDF-SHA256(reading private key, salt empty, info "efferent/v1 read", 32), so
# whoever holds the reading key holds this one too and the reading key itself
# never travels. The phone registers the public half with the service; from
# then on the bucket id alone opens nothing, and a read must name this bucket,
# the path and query it asks for, and a moment near the service's clock. Before
# the phone registers it the service ignores the signature, so signing always
# is what lets this script read both.

READ_INFO = b"efferent/v1 read"


def read_key(reading_private_raw: bytes) -> Ed25519PrivateKey:
    seed = hkdf_expand(hkdf_extract(b"", reading_private_raw), READ_INFO, 32)
    return Ed25519PrivateKey.from_private_bytes(seed)


def canonical_read(bucket: str, target: str, timestamp: int) -> str:
    return f"efferent/v1 read\n{bucket}\n{target}\n{timestamp}"


def read_headers(url: str, bucket: str, reading_private_raw: bytes, timestamp: int) -> dict:
    """The three headers that sign a read of this URL. What is signed is the path
    and query exactly as they are sent, so a signature for one day opens no
    other day and one page of a listing no other page."""
    parts = urlsplit(url)
    target = parts.path + (f"?{parts.query}" if parts.query else "")
    key = read_key(reading_private_raw)
    return {
        "X-Efferent-Timestamp": str(timestamp),
        "X-Efferent-Reader": to_base64url(key.public_key().public_bytes(*RAW)),
        "X-Efferent-Signature": to_base64url(
            key.sign(canonical_read(bucket, target, timestamp).encode())
        ),
    }


def get(url: str, bucket: str, reading_private_raw: bytes, accept: str):
    """One signed read: the body and the headers, or the service's refusal."""
    request = Request(
        url,
        headers={
            "Accept": accept,
            "User-Agent": USER_AGENT,
            **read_headers(url, bucket, reading_private_raw, int(time.time())),
        },
    )
    try:
        with urlopen(request, timeout=30) as response:
            body = response.read(MAX_ANSWER_BYTES + 1)
            headers = response.headers
    except HTTPError as error:
        raise SystemExit(
            f"the service refused {urlsplit(url).path}: {error.code} "
            f"{error.read().decode('utf-8', 'replace')}"
        ) from None
    if len(body) > MAX_ANSWER_BYTES:
        raise ValueError("the answer exceeds the 16 MiB this reader will hold")
    return body, headers


def open_day(bucket: str, reading_private_raw: bytes, day: str, blob: bytes) -> bytes:
    """A sealed day, opened. The day is bound into the tag, so a blob handed
    back under another date does not open at all."""
    if not blob or blob[0] != SEALED_VERSION:
        version = blob[0] if blob else "missing"
        raise ValueError(f"expected HPKE sealed version 2, got {version}")
    aad = f"efferent/v1\n{bucket}\n{day}".encode()
    compressed = hpke_open(reading_private_raw, INFO, aad, blob[1:])
    return zlib.decompress(compressed, -zlib.MAX_WBITS)


FRAME_HEADER_BYTES = 14


def unpack_frame(body: bytes) -> list[tuple[str, bytes]]:
    """A range answer, which is the frame an upload uses travelling back: ten
    bytes of ASCII day, four of big-endian length, the sealed day, repeated to
    the end. Days ascend and never repeat. An empty body is a range with no days
    in it; anything left over is a truncated frame, refused whole rather than
    read as far as it goes."""
    days: list[tuple[str, bytes]] = []
    offset = 0
    previous = ""
    while offset < len(body):
        left = len(body) - offset
        if left < FRAME_HEADER_BYTES:
            raise ValueError(f"{left} bytes left over where a day was expected")
        day = body[offset : offset + 10].decode("ascii", "replace")
        length = int.from_bytes(body[offset + 10 : offset + FRAME_HEADER_BYTES], "big")
        if not is_day(day):
            raise ValueError(f"{json.dumps(day)} is not a day")
        if day <= previous:
            raise ValueError(f"days must ascend without repeats: {previous} then {day}")
        if length == 0:
            raise ValueError(f"{day} carries no body")
        if left - FRAME_HEADER_BYTES < length:
            raise ValueError(
                f"{day} says {length} bytes and only {left - FRAME_HEADER_BYTES} are there"
            )
        start = offset + FRAME_HEADER_BYTES
        days.append((day, body[start : start + length]))
        previous = day
        offset = start + length
    return days


def read_day(handoff_path: Path, day: str) -> bytes:
    endpoint, bucket, private_raw, _ = load_handoff(handoff_path)
    blob, _ = get(f"{endpoint}/b/{bucket}/d/{day}", bucket, private_raw, "application/octet-stream")
    return open_day(bucket, private_raw, day, blob)


def read_range(handoff_path: Path, first: str, last: str):
    """Every day from first to last, both included, as NDJSON lines with the
    day on each. The service answers a quarter of days, or eight mebibytes, per
    request and names the last day it sent while more remain."""
    endpoint, bucket, private_raw, _ = load_handoff(handoff_path)
    after = ""
    while True:
        query = f"from={first}&to={last}" + (f"&after={after}" if after else "")
        body, headers = get(
            f"{endpoint}/b/{bucket}/d?{query}", bucket, private_raw, "application/octet-stream"
        )
        for day, blob in unpack_frame(body):
            if day < first or day > last or day <= after:
                raise ValueError(f"the service answered {first} to {last} with {day}")
            for line in expand(open_day(bucket, private_raw, day, blob)).splitlines():
                event = json.loads(line)
                event["day"] = day
                yield json.dumps(event, sort_keys=True) + "\n"
        following = headers.get("X-Efferent-Next")
        if not following:
            return
        if following <= after:
            raise ValueError(f"the service asked to go on from {following} after {after}")
        after = following


def list_days(handoff_path: Path, first: str | None, last: str | None):
    """Which days the archive holds, how big each is and when it was last
    uploaded, one JSON object per line. Nothing is decrypted, because nothing
    here is sealed: it is what the service itself knows."""
    endpoint, bucket, private_raw, _ = load_handoff(handoff_path)
    after = ""
    while True:
        parameters = [f"after={after}"] if after else [f"from={first}"] if first else []
        parameters += [f"to={last}"] if last else []
        query = f"?{'&'.join(parameters)}" if parameters else ""
        body, _ = get(f"{endpoint}/b/{bucket}/days{query}", bucket, private_raw, "application/json")
        page = json.loads(body)
        for entry in page["days"]:
            yield json.dumps(entry, sort_keys=True) + "\n"
        if not page.get("next"):
            return
        after = page["next"]


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
        if (
            isinstance(value, bool)
            or not isinstance(value, (int, float))
            or value < 0
            or value != value
        ):
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
        {
            key: item[key]
            for key in (PUT_KEYS if item["op"] == "put" else DELETE_KEYS)
            if key in item
        }
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
    sealed = bytes([SEALED_VERSION]) + hpke_seal(
        public_raw, INFO, f"efferent/v1 edit\n{bucket}".encode(), pack_edit(items)
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
        raise SystemExit(
            f"the service refused the edit: {error.code} {error.read().decode()}"
        ) from None


def list_edits(handoff_path: Path):
    """Every edit and what the phone said about it, one JSON object per line.
    The listing names edits and counts, never their contents."""
    endpoint, bucket, private_raw, _ = load_handoff(handoff_path)
    after = ""
    while True:
        query = f"?status=all&after={after}" if after else "?status=all"
        body, _ = get(
            f"{endpoint}/b/{bucket}/edits{query}", bucket, private_raw, "application/json"
        )
        page = json.loads(body)
        for entry in page["edits"]:
            yield json.dumps(entry, sort_keys=True) + "\n"
        if not page.get("next"):
            return
        after = page["next"]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--handoff", type=Path, help="the file holding the phone's handoff")
    what = parser.add_mutually_exclusive_group()
    what.add_argument("--self-test", action="store_true", help="check HPKE against RFC 9180 A.2.1")
    what.add_argument("--day", help="YYYY-MM-DD: fetch and decrypt that day")
    what.add_argument("--list", action="store_true", help="list the days held, without decrypting")
    what.add_argument("--write", type=Path, help="a JSON file of items to write into Health")
    what.add_argument("--edits", action="store_true", help="list the edits and their outcomes")
    parser.add_argument("--from", dest="first", help="YYYY-MM-DD: the first day of a range")
    parser.add_argument("--to", dest="last", help="YYYY-MM-DD: the last day of a range")
    args = parser.parse_args()
    for flag, value in (("--day", args.day), ("--from", args.first), ("--to", args.last)):
        if value is not None and not is_day(value):
            parser.error(f"{flag} must be YYYY-MM-DD and a date that exists")
    ranged = args.first is not None or args.last is not None
    if ranged and not args.list and (args.first is None or args.last is None):
        parser.error("a range of days takes both --from and --to")
    if ranged and args.first is not None and args.last is not None and args.first > args.last:
        parser.error("--from must not be after --to")
    if ranged and (args.self_test or args.day or args.write or args.edits):
        parser.error("--from and --to go with --list or alone")
    if args.self_test:
        self_test()
        return
    if not (args.day or args.list or args.write or args.edits or ranged):
        parser.error(
            "say what to do: --from and --to, --day, --list, --edits, --write, --self-test"
        )
    if args.handoff is None:
        parser.error("--handoff is required")
    if args.write:
        sys.stdout.write(write_edit(args.handoff, args.write) + "\n")
    elif args.edits:
        sys.stdout.writelines(list_edits(args.handoff))
    elif args.list:
        sys.stdout.writelines(list_days(args.handoff, args.first, args.last))
    elif args.day:
        sys.stdout.write(expand(read_day(args.handoff, args.day)))
    else:
        sys.stdout.writelines(read_range(args.handoff, args.first, args.last))


if __name__ == "__main__":
    main()
