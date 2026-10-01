"""An archive that answers, for testing the reading side against one.

The reader's own tests point at an address nothing listens on, which is the
right shape for the questions they ask and leaves half the reader untested:
everything that happens when the archive *does* answer — the listing walk, the
windowed fetch, the mirror being brought up to date. All of it is where a change
goes wrong quietly: a walk that returns the pages that arrived reports the rest
of an archive as nothing at all, a fetch that loses its order hands a stream of
days back shuffled, and a mirror that records a day it failed to fetch never
asks for it again.

So this fixture is a real archive: an HTTP service that seals days with the
reading key the way the phone does, pages its listing the way R2 forces the real
one to, hands a range of days back in frames the way the Worker does, and can be
told to fail a named day or a named page. Given a read key, it refuses every
read not signed with it, as the service does once the phone has registered one.
"""

import json
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

import efferent_hpke as wire
from efferent.days import day_before
from efferent.phone import compress, pack_day
from efferent.sealed import associated_data

# Days per listing page. Small on purpose: the walk past a page boundary is the
# part being tested, and the real ceiling of 1000 would never reach it.
PAGE = 2
# Days per range answer, for the same reason: the real ninety-two would never
# make a reader follow the archive on to the next answer.
FRAME = 3
# How long the archive holds a day open. Long enough that a window of fetches
# overlaps in the request log, which is what makes the count of them mean
# something.
DAY_DELAY = 0.025


class FakeArchive:
    def __init__(self, reading_public: bytes):
        self.reading_public = reading_public
        self.bucket = wire.bucket_of(reading_public)
        self.days: dict[str, dict] = {}
        #: Every path asked for, in the order it was asked.
        self.asked: list[str] = []
        #: Every day handed back, alone or inside a range, in the order sent.
        self.sent: list[str] = []
        #: The public half of the read key, once "the phone" registered one.
        #: Until then a read is answered on the bucket id alone.
        self.reader: bytes | None = None
        #: The most days ever open at once, which is the fetch window observed.
        self.max_in_flight = 0
        self.fault: dict = {}
        #: What `stats` reports instead of the truth, as the real service does
        #: once an archive is longer than it will walk: a floor, `complete` false.
        self.floor: int | None = None
        self._in_flight = 0
        self._lock = threading.Lock()

        archive = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def do_GET(self):  # noqa: N802
                archive.answer(self)

            def log_message(self, *_):
                pass

        class Server(ThreadingHTTPServer):
            # The reader fetches a window of days at once, and the default
            # backlog of 5 is smaller than that window: the connections past it
            # are refused by the kernel and arrive as "connection reset by
            # peer", which reads as an archive that dropped the request. macOS
            # 27 enforces it where earlier versions were forgiving, so two tests
            # that had passed for months began failing overnight, in the reader
            # rather than in the stub that caused it.
            request_queue_size = 128

        self.server = Server(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    # MARK: - Putting days in

    def put(self, day: str, events: list[dict]) -> None:
        """Put a day in, or replace one. A replacement gets a later upload time,
        which is the only thing that tells a mirror its copy is old."""
        blob = bytes([wire.SEALED_VERSION]) + wire.hpke_seal(
            self.reading_public,
            wire.INFO,
            associated_data(self.bucket, day),
            compress(pack_day(events).encode()),
        )
        previous = self.days.get(day)
        uploaded = _plus_a_second(previous["uploaded"]) if previous else "2026-01-01T00:00:00.000Z"
        self.days[day] = {"blob": blob, "uploaded": uploaded}

    def drop(self, day: str) -> None:
        """Take a day out, the way clearing objects from a bucket does."""
        self.days.pop(day, None)

    # MARK: - What the reader asked for

    def forget(self) -> None:
        """Called between the halves of a test so a count means "since then"."""
        with self._lock:
            self.asked.clear()
            self.sent.clear()
            self.max_in_flight = 0

    def fetched_days(self) -> list[str]:
        return list(self.sent)

    def ranges(self) -> list[str]:
        """The range reads asked for: one per answer, a long range being
        several."""
        return [path for path in self.asked if urlsplit(path).path.endswith("/d")]

    def listings(self) -> int:
        return len([path for path in self.asked if "/days" in path])

    def full_listings(self) -> int:
        """Listings that walk the archive from its first day: the expensive one,
        and the only one that can say a day has gone."""
        return len(
            [
                path
                for path in self.asked
                if "/days" in path and "from=" not in path and "after=" not in path
            ]
        )

    def stop(self) -> None:
        self.server.shutdown()
        self.server.server_close()

    # MARK: - Answering

    def answer(self, handler: BaseHTTPRequestHandler) -> None:
        split = urlsplit(handler.path)
        with self._lock:
            self.asked.append(handler.path)
        parts = [part for part in split.path.split("/") if part]
        if len(parts) < 3 or parts[0] != "b" or parts[1] != self.bucket:
            return _json(handler, {"error": "unknown"}, 404)
        refused = self.refusal(handler)
        if refused:
            return _json(handler, {"error": refused[1]}, refused[0])
        if parts[2] == "stats":
            return _json(handler, self.stats())
        if parts[2] == "days":
            return self.list(handler, parse_qs(split.query))
        if parts[2] == "d" and len(parts) == 3:
            return self.frame(handler, parse_qs(split.query))
        if parts[2] == "d":
            return self.day(handler, parts[3])
        return _json(handler, {"error": "unknown"}, 405)

    def refusal(self, handler: BaseHTTPRequestHandler) -> tuple[int, str] | None:
        """What the service says to a read it will not answer, or nothing. The
        signature covers the path and query exactly as sent."""
        if self.reader is None:
            return None
        reader = handler.headers.get("X-Efferent-Reader")
        signature = handler.headers.get("X-Efferent-Signature")
        timestamp = handler.headers.get("X-Efferent-Timestamp") or ""
        if not reader or not signature:
            return 401, "this archive answers only reads signed with its read key"
        if wire.base64url(reader) != self.reader:
            return 403, "that is not this archive's read key"
        message = wire.canonical_read(self.bucket, handler.path, int(timestamp or 0))
        try:
            Ed25519PublicKey.from_public_bytes(self.reader).verify(
                wire.base64url(signature), message.encode()
            )
        except InvalidSignature:
            return 403, "signature does not match the request"
        return None

    def stats(self) -> dict:
        names = sorted(self.days)
        return {
            "exists": True,
            "days": self.floor if self.floor is not None else len(names),
            "bytes": sum(len(day["blob"]) for day in self.days.values()),
            "firstDay": names[0] if names else None,
            "lastDay": names[-1] if names else None,
            "complete": self.floor is None,
        }

    def list(self, handler: BaseHTTPRequestHandler, query: dict) -> None:
        """Paged the way R2 forces the real one to be: `after` skips past a key,
        and `next` is null only at the end."""
        after = (query.get("after") or [None])[0]
        frm = (query.get("from") or [None])[0]
        to = (query.get("to") or [None])[0]

        start = after or (day_before(frm) if frm else None)
        names = [day for day in sorted(self.days) if not start or day > start]
        truncated = len(names) > PAGE
        names = names[:PAGE]
        within = [day for day in names if day <= to] if to else names
        reached_end = len(within) < len(names)

        # The page number the reader is on, counted by how many it has already
        # walked. It cannot send one, so the fault is matched on the count.
        if self.fault.get("page") is not None and self.listings() - 1 == self.fault["page"]:
            return _json(handler, {"error": "the listing broke"}, 500)

        _json(
            handler,
            {
                "days": [
                    {
                        "day": day,
                        "bytes": len(self.days[day]["blob"]),
                        "uploaded": self.days[day]["uploaded"],
                    }
                    for day in within
                ],
                "next": within[-1] if (not reached_end and truncated and within) else None,
            },
        )

    def frame(self, handler: BaseHTTPRequestHandler, query: dict) -> None:
        """A range, both ends included, as one frame of at most `FRAME` days.
        While more remain the answer names the last day it carried, and the
        reader asks again with that as `after` — the Worker's own contract."""
        frm = (query.get("from") or [None])[0]
        to = (query.get("to") or [None])[0]
        after = (query.get("after") or [None])[0]
        if not frm or not to:
            return _json(handler, {"error": "a range takes both from and to"}, 400)
        start = after or day_before(frm)
        names = [day for day in sorted(self.days) if start < day <= to]
        chosen = names[:FRAME]
        with self._lock:
            self._in_flight += 1
            self.max_in_flight = max(self.max_in_flight, self._in_flight)
        try:
            time.sleep(DAY_DELAY)
            if self.fault.get("day") in chosen:
                return _json(handler, {"error": f"{self.fault['day']} is refused"}, 500)
            body = b"".join(
                day.encode("ascii")
                + len(self.days[day]["blob"]).to_bytes(4, "big")
                + self.days[day]["blob"]
                for day in chosen
            )
            with self._lock:
                self.sent.extend(chosen)
            handler.send_response(200)
            handler.send_header("Content-Type", "application/octet-stream")
            handler.send_header("Content-Length", str(len(body)))
            if len(names) > FRAME:
                handler.send_header("X-Efferent-Next", chosen[-1])
            handler.end_headers()
            handler.wfile.write(body)
        finally:
            with self._lock:
                self._in_flight -= 1

    def day(self, handler: BaseHTTPRequestHandler, name: str) -> None:
        with self._lock:
            self._in_flight += 1
            self.max_in_flight = max(self.max_in_flight, self._in_flight)
        try:
            time.sleep(DAY_DELAY)
            if self.fault.get("day") == name:
                return _json(handler, {"error": f"{name} is refused"}, 500)
            stored = self.days.get(name)
            if not stored:
                return _json(handler, {"error": "no such day"}, 404)
            with self._lock:
                self.sent.append(name)
            handler.send_response(200)
            handler.send_header("Content-Type", "application/octet-stream")
            handler.send_header("Content-Length", str(len(stored["blob"])))
            handler.end_headers()
            handler.wfile.write(stored["blob"])
        finally:
            with self._lock:
                self._in_flight -= 1


def _plus_a_second(stamp: str) -> str:
    moment = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
    later = moment.timestamp() + 1
    return (
        datetime.fromtimestamp(later, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.")
        + f"{int(later % 1 * 1000):03d}Z"
    )


def _json(handler: BaseHTTPRequestHandler, body: object, status: int = 200) -> None:
    encoded = json.dumps(body).encode()
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(encoded)))
    handler.end_headers()
    handler.wfile.write(encoded)
