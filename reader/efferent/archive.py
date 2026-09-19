"""Where days come from, for everything on the reading side.

This is the layer that holds the reading key, opens sealed days and keeps the
mirror. Both the command line tool and the MCP server sit on it, so there is
one implementation of "fetch a day and decrypt it" rather than two that drift.

The key never leaves this machine. The bucket service only ever handed over
ciphertext and only ever will.
"""

from __future__ import annotations

import json
import os
import re
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey

import efferent_hpke as wire

from .days import is_day, now_iso
from .phone import canonical_edit, decompress, sign, unix_now
from .sealed import associated_data, edit_associated_data, open_sealed

DAYS = "days"
STATE = "mirror.json"
READING = "reading-key.json"
EDITOR = "editor-key.json"
EDITS = "edits.json"
USER_AGENT = "efferent-local-reader/1.0"
FETCH_WINDOW = 8
RAW = (serialization.Encoding.Raw, serialization.PublicFormat.Raw)


class ArchiveError(Exception):
    """Something the reading side could not do, said in one sentence."""


def home() -> Path:
    """`EFFERENT_HOME`, read when asked rather than once: the tests keep several
    readers apart in one process, and nothing else pays for the lookup."""
    return Path(os.environ.get("EFFERENT_HOME") or ".efferent")


def resolve(path: Path) -> str:
    """An absolute path, for error messages. A relative one in a message about
    a missing directory tells the reader nothing about where it was looked for."""
    return str(path if path.is_absolute() else Path.cwd() / path)


# MARK: - Keys, as they are stored

# The stored reader key is bare base64url PKCS8; the phone handoff carries raw
# halves. Both are one DER prefix apart.


def pkcs8(private: X25519PrivateKey | Ed25519PrivateKey) -> str:
    return wire.to_base64url(
        private.private_bytes(
            serialization.Encoding.DER,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
    )


def raw_private(stored: str) -> bytes:
    """The raw 32 bytes of a stored PKCS8 key, X25519 or Ed25519 alike."""
    key = serialization.load_der_private_key(wire.base64url(stored), password=None)
    return key.private_bytes(
        serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption()
    )


# MARK: - Files


def load(name: str):
    return json.loads((home() / name).read_text())


def private_directory(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    # mkdir's mode applies only when it creates the last component. Tighten an
    # existing reader too, because an older release created these directories
    # through the process umask and commonly left them at 0755.
    path.chmod(0o700)


def write(name: str, value: object, compact: bool = False) -> None:
    """Through a temporary file: two processes keep this mirror, and a rename
    is the one write nobody can catch half of. Laid out unless asked otherwise,
    because these are the files somebody opens when the reader is behaving
    strangely; `compact` is for the one that is not read by people."""
    private_directory(home())
    temporary = home() / f"{name}.partial"
    text = json.dumps(value, separators=(",", ":")) if compact else json.dumps(value, indent=2)
    temporary.write_text(text + "\n")
    temporary.chmod(0o600)
    temporary.rename(home() / name)


def load_state(url: str | None = None) -> dict:
    try:
        stored = load(STATE)
    except (OSError, ValueError):
        stored = None
    endpoint = url or (stored or {}).get("endpoint")
    if not endpoint:
        # Named in full, because the commonest way to see this is a server
        # started by an agent from some other directory: the default home is
        # relative, so it resolved somewhere with no archive in it.
        raise ArchiveError(
            f"no archive is configured in {resolve(home())} — point EFFERENT_HOME at the "
            "directory holding reading-key.json, or run `efferent status --url <endpoint>` "
            "there once"
        )
    state = {
        "endpoint": endpoint,
        "days": (stored or {}).get("days") or {},
        "syncedAt": (stored or {}).get("syncedAt") or "",
    }
    # Written here rather than by whichever command happens to save afterwards:
    # "after that it is remembered" has to be true of the first command a
    # person runs, not only of the ones that keep a mirror.
    if endpoint != (stored or {}).get("endpoint"):
        write(STATE, state)
    return state


def save_state(state: dict) -> None:
    write(STATE, {**state, "syncedAt": now_iso()})


# MARK: - The editor key and the record of edits


def load_editor() -> dict:
    """The key that signs edits, or a sentence saying why there is none."""
    try:
        return load(EDITOR)
    except (OSError, ValueError):
        raise ArchiveError(
            f"no editor key in {resolve(home())} — the handoff this reader was connected with "
            "predates writing; ask the phone for a fresh one and run `efferent connect` with it"
        ) from None


def submitted_edits() -> list[dict]:
    """Every edit this profile submitted, oldest first."""
    try:
        return load(EDITS)
    except (OSError, ValueError):
        return []


def record_submitted(edit: dict) -> None:
    write(EDITS, [*submitted_edits(), edit])


def summarize(item: dict) -> dict:
    """What one item was about, kept locally so a later session can find the
    id it needs to replace or delete a sample it wrote. Never a value."""
    if item["op"] == "delete":
        return {"op": "delete", "id": item["id"]}
    day = datetime.fromtimestamp(item["start"], timezone.utc).date().isoformat()
    return {"op": "put", "id": item["id"], "metric": item["metric"], "day": day}


# MARK: - The mirror, one file per day


def write_day(day: str, events: list[dict]) -> None:
    private_directory(home() / DAYS)
    # Through a temporary file: a day truncated by an interrupted write would
    # look like a day on which almost nothing happened.
    temporary = home() / DAYS / f"{day}.partial"
    temporary.write_text(
        "".join(json.dumps(event, separators=(",", ":")) + "\n" for event in events)
    )
    temporary.chmod(0o600)
    temporary.rename(home() / DAYS / f"{day}.ndjson")


def read_day(day: str) -> list[dict]:
    try:
        text = (home() / DAYS / f"{day}.ndjson").read_bytes()
    except OSError:
        return []
    return events_of(text)


def events_of(plaintext: bytes) -> list[dict]:
    """A day's events, whichever layout it is stored in."""
    return [json.loads(line) for line in wire.expand(plaintext).splitlines() if line]


def _day_files() -> list[tuple[str, Path]]:
    found = []
    try:
        entries = list((home() / DAYS).iterdir())
    except OSError:
        return []
    for entry in entries:
        day = re.sub(r"\.ndjson$", "", entry.name)
        if day == entry.name or not is_day(day) or not entry.is_file():
            continue
        found.append((day, entry))
    return sorted(found)


def mirror_versions() -> dict[str, str]:
    """Every mirrored day with a fingerprint of the file it is in, in order.
    Size and modification time, which is the ordinary way to ask whether a
    file has changed, and deliberately not the archive's upload time."""
    versions = {}
    for day, path in _day_files():
        stat = path.stat()
        versions[day] = f"{stat.st_size}:{stat.st_mtime_ns // 1_000_000}"
    return versions


def mirrored_days(start: str | None = None, end: str | None = None) -> list[str]:
    """The mirrored days inside a range, in order."""
    return [
        day for day, _ in _day_files() if (not start or day >= start) and (not end or day <= end)
    ]


# MARK: - Talking to the service


def transport(method: str, url: str, headers: dict | None = None, body: bytes | None = None):
    """One place every request goes through, so a test can stand in for the
    service. Answers `(status, body)`; a refusal is a status, not an exception."""
    request = Request(
        url, data=body, method=method, headers={"User-Agent": USER_AGENT, **(headers or {})}
    )
    try:
        with urlopen(request, timeout=30) as response:
            return response.status, response.read()
    except HTTPError as error:
        return error.code, error.read()


def fetch_json(url: str):
    status, body = transport("GET", url)
    if status >= 400:
        raise ArchiveError(f"{url}: {status} {body.decode('utf-8', 'replace')}")
    return json.loads(body)


def refusal(body: bytes, status: int) -> str:
    """The one sentence a refusal carries, or the status when it carries none."""
    text = body.decode("utf-8", "replace")
    try:
        parsed = json.loads(text)
        if isinstance(parsed, dict) and isinstance(parsed.get("error"), str):
            return parsed["error"]
    except ValueError:
        pass
    return text or str(status)


# MARK: - The archive, as something to read from


class Archive:
    """The archive behind an endpoint, opened with the reading key in `home()`."""

    def __init__(self, endpoint: str):
        reading = load(READING)
        self.endpoint = endpoint
        self.reading_public = wire.base64url(reading["readingPublic"])
        self.private_raw = raw_private(reading["readingPrivate"])
        self.bucket = wire.bucket_of(self.reading_public)

    def day(self, name: str) -> dict:
        status, blob = transport(
            "GET",
            f"{self.endpoint}/b/{self.bucket}/d/{name}",
            {"Accept": "application/octet-stream"},
        )
        if status >= 400:
            raise ArchiveError(f"{name}: {status} {blob.decode('utf-8', 'replace')}")
        sealed = open_sealed(
            self.private_raw, self.reading_public, blob, associated_data(self.bucket, name)
        )
        return {"day": name, "events": events_of(decompress(sealed))}

    def list(self, start: str | None = None, end: str | None = None) -> list[dict]:
        """Which days the archive has in a range. Following `next` until it
        comes back null is not optional: a listing that stopped at its first
        page would report the rest of a decade as nothing at all."""
        entries: list[dict] = []
        after = None
        while True:
            parameters = {}
            if after:
                parameters["after"] = after
            elif start:
                parameters["from"] = start
            if end:
                parameters["to"] = end
            page = fetch_json(f"{self.endpoint}/b/{self.bucket}/days?{urlencode(parameters)}")
            entries.extend(page["days"])
            if page.get("next") is None:
                return entries
            after = page["next"]

    def several(self, names: list[str], width: int = FETCH_WINDOW):
        """Named days, several at a time, in the order they were asked for. The
        window is small on purpose — enough to fill the link, not enough to
        look like an attack on it."""
        with ThreadPoolExecutor(max_workers=width) as pool:
            for start in range(0, len(names), width):
                yield from pool.map(self.day, names[start : start + width])

    def stats(self) -> dict:
        return fetch_json(f"{self.endpoint}/b/{self.bucket}/stats")

    def submit_edits(self, items: list) -> dict:
        """An edit, the way the phone will check it: sealed to the reading key
        with the bucket in the tag, signed by the editor key over the canonical
        message. Validated before anything is sealed, and written down locally
        afterwards, because the service knows an edit by a name and a count."""
        wire.validate_items(items)
        editor = load_editor()
        sealed = bytes([wire.SEALED_VERSION]) + wire.hpke_seal(
            self.reading_public,
            wire.INFO,
            edit_associated_data(self.bucket),
            wire.pack_edit(items),
        )
        timestamp = unix_now()
        signature = sign(
            raw_private(editor["editorPrivate"]), canonical_edit(self.bucket, timestamp, sealed)
        )
        status, body = transport(
            "POST",
            f"{self.endpoint}/b/{self.bucket}/edits",
            {
                "Content-Type": "application/octet-stream",
                "X-Efferent-Timestamp": str(timestamp),
                "X-Efferent-Editor": editor["editorPublic"],
                "X-Efferent-Signature": wire.to_base64url(signature),
            },
            sealed,
        )
        if status >= 400:
            raise ArchiveError(f"the service refused the edit: {status} {refusal(body, status)}")
        answer = json.loads(body)
        record_submitted(
            {"name": answer["name"], "at": answer["at"], "items": [summarize(i) for i in items]}
        )
        return answer

    def edits(
        self, after: str | None = None, status: str | None = None, limit: int | None = None
    ) -> dict:
        """The service's listing, with this profile's own record laid over it."""
        parameters = {}
        if after:
            parameters["after"] = after
        if status:
            parameters["status"] = status
        if limit:
            parameters["limit"] = str(limit)
        page = fetch_json(f"{self.endpoint}/b/{self.bucket}/edits?{urlencode(parameters)}")
        known = {edit["name"]: edit["items"] for edit in submitted_edits()}
        entries = []
        for entry in page["edits"]:
            items = known.get(entry["name"])
            laid = {**entry, "items": items} if items is not None else {**entry}
            if (entry.get("refused") or 0) > 0:
                outcome = fetch_json(f"{self.endpoint}/b/{self.bucket}/o/{entry['name']}")
                laid["refusals"] = [
                    {
                        **refused,
                        **(
                            {"id": items[refused["item"]]["id"]}
                            if items and refused["item"] < len(items)
                            else {}
                        ),
                    }
                    for refused in outcome["refused"]
                ]
            entries.append(laid)
        return {"edits": entries, "next": page.get("next")}


def open_archive(endpoint: str) -> Archive:
    return Archive(endpoint)
