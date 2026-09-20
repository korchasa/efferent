"""The reading side, as a command line tool.

This is where the reading key lives. It never leaves this machine: the phone
only ever gets the public half, and the bucket service only gets ciphertext.

Everything is addressed by day, which is what makes both commands cheap. `ask`
goes to the service and downloads only the days a question covers. `sync` keeps
a local copy — one file per day — so `query` can answer with the network
switched off. Neither has a position to keep track of: a day in the mirror is
either the one the archive holds or an older version of it, and the archive says
which by when it was last written.
"""

from __future__ import annotations

import json
import sys

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey

import efferent_hpke as wire

from .archive import (
    READING,
    ArchiveError,
    home,
    load,
    load_state,
    mirrored_days,
    open_archive,
    pkcs8,
    raw_private,
    read_day,
    save_state,
    transport,
    write,
    write_day,
)
from .connection import install_connection_handoff
from .days import day_before, is_day, today
from .phone import compress, pack_day, pack_days, sign_upload, unix_now
from .sealed import associated_data

USAGE = """usage:
  efferent connect --handoff <file>    import the phone handoff locally
  efferent keygen                       create the reading key pair
  efferent send --url <endpoint>        pretend to be a phone, write days
                [--day <d>[,<d>…]]      one request, however many days
  efferent read --url <endpoint>        fetch and decrypt, straight to stdout
  efferent sync [--url <endpoint>]      copy every day that changed since last time
  efferent status [--url <endpoint>]    what the archive holds, and what the mirror does
  efferent query [filters]              answer from the mirror, offline
  efferent ask [filters]                answer from the archive, fetching only those days
  efferent edits [--all] [--after <n>]  what became of the edits; pending only by default

filters (query, ask and read):
  --metric <steps|sleep|…>             --bucket <hour|day>
  --since <YYYY-MM-DD>                 --until <YYYY-MM-DD>
  --limit <n>                          --format <ndjson|summary>"""


class Failure(Exception):
    """Something a person can act on, printed as one line."""


# MARK: - Commands


def connect(path: str) -> None:
    text = sys.stdin.read() if path == "-" else open(path).read()
    connection = install_connection_handoff(text)
    print(f"connected: {connection['bucket']}")
    print(f"saved:     {home()}/reading-key.json")
    if "editor" in connection:
        print(f"saved:     {home()}/editor-key.json")
    print(f"archive:   {connection['endpoint']}")
    print("the reading key stayed on this machine")
    if "editor" not in connection:
        print(
            "this handoff predates writing: the agent can read the archive and cannot write "
            "into Health — a fresh handoff from the phone adds the editor key"
        )


def keygen() -> None:
    private = X25519PrivateKey.generate()
    public_raw = private.public_key().public_bytes(*wire.RAW)
    write(
        READING,
        {"readingPrivate": pkcs8(private), "readingPublic": wire.to_base64url(public_raw)},
    )
    print(f"bucket: {wire.bucket_of(public_raw)}")
    print(f"saved:  {home()}/{READING} — this file is the only way to read the data")


def send(url: str, day_list: str) -> None:
    """Stand in for a phone: build some days and write them exactly as a device
    would — sealed one by one, packed into a single request, signed as a whole.

    `--day` takes a list so the batching path can be reached by hand. A phone
    sends a month at a time and this is the only other thing that ever writes."""
    wanted = sorted(part.strip() for part in day_list.split(",") if part.strip())
    for day in wanted:
        if not is_day(day):
            raise Failure(f"--day must be YYYY-MM-DD, got {day}")

    reading = load(READING)
    writer = load_or_create_writer()
    public_raw = wire.base64url(reading["readingPublic"])
    bucket = wire.bucket_of(public_raw)

    batch = []
    for day in wanted:
        events = [
            {
                "id": "",
                "v": 1,
                "metric": "steps",
                "bucket": "hour",
                "start": f"{day}T{9 + hour:02d}:00:00Z",
                "end": f"{day}T{10 + hour:02d}:00:00Z",
                "value": 100 + hour,
                "unit": "count",
            }
            for hour in range(3)
        ]
        # Each day is sealed to its own date, so a day cannot be moved or handed
        # back as another one. The batch around them binds nothing.
        blob = bytes([wire.SEALED_VERSION]) + wire.hpke_seal(
            public_raw,
            wire.INFO,
            associated_data(bucket, day),
            compress(pack_day(events).encode()),
        )
        batch.append((day, blob))

    try:
        body = pack_days(batch)
    except ValueError as error:
        raise Failure(f"those days do not make a request: {error}") from None

    timestamp = unix_now()
    signature = sign_upload(raw_private(writer["writerPrivate"]), bucket, wanted, timestamp, body)
    status, answer = transport(
        "PUT",
        f"{url}/b/{bucket}/days",
        {
            "Content-Type": "application/octet-stream",
            "X-Efferent-Timestamp": str(timestamp),
            "X-Efferent-Writer": writer["writerPublic"],
            "X-Efferent-Signature": wire.to_base64url(signature),
        },
        body,
    )
    print(f"{status} {answer.decode('utf-8', 'replace')}")
    if status >= 400:
        raise SystemExit(1)


def read(options: dict) -> None:
    state = load_state(options.get("url"))
    archive = open_archive(state["endpoint"])
    listing = archive.list(**bounds(filter_from(options)))
    for fetched in archive.several([entry["day"] for entry in listing]):
        out = "\n".join(json.dumps(event, separators=(",", ":")) for event in fetched["events"])
        if out:
            sys.stdout.write(out + "\n")


def sync(options: dict) -> None:
    """Copy every day the archive has that this mirror does not, or has an older
    version of. Interrupting it costs the days it had not reached and nothing
    else: each day is its own file, and the record is written as it goes."""
    state = load_state(options.get("url"))
    archive = open_archive(state["endpoint"])

    listing = archive.list(**bounds(filter_from(options)))
    stale = {
        e["day"]: e["uploaded"] for e in listing if state["days"].get(e["day"]) != e["uploaded"]
    }
    if not stale:
        print(f"already up to date: {len(state['days'])} days mirrored")
        return

    taken = 0
    for fetched in archive.several(sorted(stale)):
        write_day(fetched["day"], fetched["events"])
        state["days"][fetched["day"]] = stale[fetched["day"]]
        taken += 1
        # Every eight, which is one window of fetches. Often enough that an
        # interrupted sync loses almost nothing, rarely enough that a long run
        # is not mostly writing a file about itself.
        if taken % 8 == 0:
            save_state(state)
    save_state(state)

    print(f"{taken} day{'' if taken == 1 else 's'} copied, {len(state['days'])} mirrored")


def status(url: str | None) -> None:
    """What the archive holds and what the mirror has of it."""
    state = load_state(url)
    archive = open_archive(state["endpoint"])
    remote = archive.stats()

    mirrored = sorted(state["days"])
    print(f"bucket   {archive.bucket}")
    span = f", {remote['firstDay']} … {remote['lastDay']}" if remote.get("firstDay") else ""
    more = "" if remote.get("complete") else "+"
    print(f"archive  {remote['days']}{more} days, {remote['bytes'] / 1024 / 1024:.1f} MiB{span}")
    if not mirrored:
        print("mirror   nothing yet — run sync")
        return
    behind = remote["days"] - len(mirrored)
    tail = f"  — {behind} behind, run sync" if behind > 0 else "  — up to date"
    print(f"mirror   {len(mirrored)} days, {mirrored[0]} … {mirrored[-1]}{tail}")


def edits(options: dict) -> None:
    """What the service holds for the phone, and what the phone said about it."""
    state = load_state(options.get("url"))
    archive = open_archive(state["endpoint"])
    page = archive.edits(
        status="all" if options.get("all") else "pending", after=options.get("after") or None
    )
    if not page["edits"]:
        print(
            "no edits" if options.get("all") else "nothing pending — --all shows what was applied"
        )
        return
    for entry in page["edits"]:
        # A refusal is not one thing, so the line says which kind. An edit
        # "0 applied, 1 refused" where the refusal is a question reads as a
        # failure, and that is exactly what it is not.
        parts = []
        if entry.get("applied"):
            parts.append(f"{entry['applied']} applied")
        if entry.get("waiting"):
            parts.append(f"{entry['waiting']} waiting for you")
        if entry.get("declined"):
            parts.append(f"{entry['declined']} declined")
        could_not = (
            (entry.get("refused") or 0) - (entry.get("waiting") or 0) - (entry.get("declined") or 0)
        )
        if could_not > 0:
            parts.append(f"{could_not} refused")
        counts = "" if entry["status"] == "pending" or not parts else "  " + ", ".join(parts)
        print(f"{entry['name']}  {entry['status']:<8}  {entry['at']}{counts}")
        for item in entry.get("items") or []:
            named = f"  {item['metric']} {item['day']}" if item.get("metric") else ""
            print(f"    {item['op']:<6} {item['id']}{named}")
        for refused in entry.get("refusals") or []:
            named = f" ({refused['id']})" if refused.get("id") else ""
            print(f"    refused item {refused['item']}{named}: {refused['code']}")
    if page.get("next"):
        print(f"more: --after {page['next']}")


def query(options: dict) -> None:
    """Answer from the mirror. No network, so it works on a plane and it is fast
    enough to call in a loop."""
    wanted = filter_from(options)
    events = []
    for day in mirrored_days(**bounds(wanted)):
        events.extend(event for event in read_day(day) if matches(event, wanted))
    report(events, options)


def ask(options: dict) -> None:
    """Answer from the archive, without a mirror.

    A question about one August costs that August: the days it covers are named
    by their dates, so the service hands over thirty-one objects and nothing
    else. It is still the exact filtering that happens here, after decryption —
    a day holds everything that happened in it, and the service cannot see in."""
    state = load_state(options.get("url"))
    archive = open_archive(state["endpoint"])

    wanted = filter_from(options)
    listing = archive.list(**bounds(wanted))
    collected = []
    for fetched in archive.several([entry["day"] for entry in listing]):
        collected.extend(event for event in fetched["events"] if matches(event, wanted))
    print(f"{len(listing)} days fetched, {len(collected)} events kept", file=sys.stderr)
    report(collected, options)


# MARK: - What a question asks for


def filter_from(options: dict) -> dict:
    """Both bounds are days and are inclusive. Anything finer would be a promise
    this tool cannot keep: the archive is cut into days, so an hour is something
    to filter with `jq` afterwards rather than something to ask for."""
    return {
        "metric": options.get("metric") or None,
        "bucket": options.get("bucket") or None,
        "since": day_of(options["since"], "--since") if options.get("since") else None,
        "until": day_of(options["until"], "--until") if options.get("until") else None,
    }


def bounds(wanted: dict) -> dict:
    """The days a question covers.

    One day earlier than asked for, always. A night of sleep that began before
    midnight is in the evening's day, so a question about the 11th that fetched
    only the 11th would miss the night it is asking about — and would do it
    silently, which is the worst way for a query to be wrong."""
    return {
        "start": day_before(wanted["since"]) if wanted["since"] else None,
        "end": wanted["until"],
    }


def day_of(value: str, option: str) -> str:
    day = value[:10]
    if not is_day(day):
        raise Failure(f"{option} must be a day, YYYY-MM-DD, got {value}")
    return day


def matches(event: dict, wanted: dict) -> bool:
    """Whether an event belongs in the answer.

    Time is compared by overlap, not by the start alone. An interval that began
    the evening before still happened during the day being asked about, and
    dropping it would quietly lose exactly the nights a sleep question is about.

    Compared day against day. An event's times are instants and a bound is a
    date, so comparing the two as strings would put every reading of the 6th
    after the 6th — a whole day dropped from a query that named it."""
    if wanted["metric"] and event.get("metric") != wanted["metric"]:
        return False
    if wanted["bucket"] and event.get("bucket") != wanted["bucket"]:
        return False
    start = (event.get("start") or "")[:10]
    if wanted["since"] and (event.get("end") or event.get("start") or "")[:10] < wanted["since"]:
        return False
    if wanted["until"] and start > wanted["until"]:
        return False
    return True


def report(events: list[dict], options: dict) -> None:
    ordered = sorted(events, key=lambda e: (e.get("start") or "", e.get("id") or ""))

    if options.get("format") == "summary":
        counts: dict[str, int] = {}
        for event in ordered:
            key = f"{event.get('metric') or '?'}"
            if event.get("bucket"):
                key += f"/{event['bucket']}"
            counts[key] = counts.get(key, 0) + 1
        print(f"{len(ordered)} events")
        for key, count in sorted(counts.items(), key=lambda pair: -pair[1]):
            print(f"  {count:>7}  {key}")
        return

    limited = ordered[: int(options["limit"])] if options.get("limit") else ordered
    out = "\n".join(json.dumps(event, separators=(",", ":")) for event in limited)
    if out:
        print(out)


# MARK: - The stand-in phone's own key


def load_or_create_writer() -> dict:
    try:
        return load("writer-key.json")
    except (OSError, ValueError):
        private = Ed25519PrivateKey.generate()
        key = {
            "writerPrivate": pkcs8(private),
            "writerPublic": wire.to_base64url(private.public_key().public_bytes(*wire.RAW)),
        }
        write("writer-key.json", key)
        return key


# MARK: - Plumbing


def parse_options(args: list[str]) -> dict:
    """`--name value` pairs, and a bare `--name` at the end or before another
    option is a flag, held as "true" so `--all` is not read as an empty value."""
    options: dict = {}
    index = 0
    while index < len(args):
        argument = args[index]
        if not argument.startswith("--"):
            index += 1
            continue
        following = args[index + 1] if index + 1 < len(args) else None
        if following is None or following.startswith("--"):
            options[argument[2:]] = "true"
            index += 1
            continue
        options[argument[2:]] = following
        index += 2
    return options


def require(options: dict, name: str) -> str:
    value = options.get(name)
    if not value:
        raise Failure(f"--{name} is required")
    return value


COMMANDS = {
    "connect": lambda o: connect(require(o, "handoff")),
    "keygen": lambda o: keygen(),
    "send": lambda o: send(require(o, "url"), o.get("day") or today()),
    "read": read,
    "sync": sync,
    "query": query,
    "ask": ask,
    "status": lambda o: status(o.get("url")),
    "edits": edits,
}


def main(argv: list[str] | None = None) -> None:
    args = sys.argv[1:] if argv is None else argv
    command, rest = (args[0], args[1:]) if args else ("", [])
    run = COMMANDS.get(command)
    if run is None:
        print(USAGE, file=sys.stderr)
        raise SystemExit(2)
    # The reading layer raises where this tool used to exit, and a traceback is
    # not an error message. One place turns it back into a line a person can
    # act on, which is what this has always printed.
    try:
        run(parse_options(rest))
    except (Failure, ArchiveError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2) from None


if __name__ == "__main__":
    main()
