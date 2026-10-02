"""The archive as an MCP server, so any agent can read it without being taught how.

**It runs here, next to the reading key, and it has to.** Answering a question
means decrypting days, and the private half of the reading key never leaves this
machine — that is the whole design. A version of this living on the bucket
service would need that key, which would hand the service the one thing it must
never have. So the agent connects to a process on the reader's own machine, and
the service stays a place that holds ciphertext it cannot open.

**The tools answer questions, not queries.** Handing an agent a `select` against
a million events would make it responsible for the traps in this data: summing
overlapping sleep, adding hourly steps to daily steps, reading a blood oxygen of
0.97 as "0.97%". So the surface is nights, workouts, daily totals and
distributions — shapes where the corrections have already happened — with one
raw escape hatch for the questions nobody anticipated.

**Writing goes through the phone, and only the phone.** `phone_data_write` seals
an edit to the reading key and signs it with the editor key; the service holds
ciphertext it cannot open, and the phone opens it, checks the signature itself
and puts the samples into Health. Nothing here can put a number into Health
directly, and nothing on the service can either.

The descriptions carry what a reader has to know, because that is the point: no
prompt is written anywhere, so anything the agent needs must arrive with the
tool.

Transport is JSON-RPC 2.0 over stdio, newline-delimited, spoken directly rather
than through a library — it is a hundred lines and it keeps the reading side
free of dependencies that would have to be trusted with this of all data.
"""

from __future__ import annotations

import json
import sys
import time

import efferent_hpke as wire

from .analysis import (
    RECORDS,
    TOTALS,
    UNIT_NOTES,
    daily_totals,
    distribution,
    empty_distribution,
    fold,
    group_of,
    nights,
    what_a_day_holds,
    workouts,
)
from .archive import (
    load,
    load_state,
    mirror_versions,
    mirrored_days,
    open_archive,
    read_day,
    save_state,
    write,
    write_day,
)
from .days import add_days, days_between, is_day, today
from .edits import OUTCOME_CODES, is_edit_name, writable_shapes

NAME = "efferent"
VERSION = "1.0.0"
#: Versions this server knows how to speak, newest first. A client asking for
#: one of them gets it back; anything else gets the newest and finds out at once
#: rather than halfway through a call.
PROTOCOL_VERSIONS = ("2025-06-18", "2025-03-26", "2024-11-05")

#: How long an answer may go on trusting the mirror before asking the archive
#: whether anything moved. Short enough that "today" means today, long enough
#: that a conversation of twenty questions costs one check.
FRESH_FOR = 5 * 60

#: Days re-listed on every check. The phone re-reads the last week on every
#: refresh, so this is where rewrites actually happen; the day count catches
#: everything else.
RECENT_DAYS = 14

#: Rows one answer will return. Past this the answer is data to be processed
#: rather than read, and the caller wants a coarser grouping or a shorter range —
#: which the refusal says outright instead of quietly truncating.
MAX_ROWS = 1000

#: Where what each day holds is kept between questions.
METRICS = "metrics.json"


# MARK: - The archive, kept close


class Reader:
    """Everything the tools read through, so freshness is decided once."""

    def __init__(self) -> None:
        self.state: dict | None = None
        self.archive = None
        self.checked_at = 0.0
        #: What the archive said it holds at the last check, kept so an answer
        #: that needs it does not go and ask a second time.
        self.remote: dict | None = None
        #: Set when the archive could not be reached, and returned with the
        #: answer. A quietly stale answer about health data is worse than a late
        #: one.
        self.warning: str | None = None

    def open(self):
        if self.state is None or self.archive is None:
            self.state = load_state()
            self.archive = open_archive(self.state["endpoint"])
        return self.state, self.archive

    def stats(self) -> dict | None:
        try:
            _, archive = self.open()
            self.remote = archive.stats()
            return self.remote
        except Exception as error:  # noqa: BLE001 — every failure is the same answer
            self.remote = None
            self.warning = (
                f"the archive could not be reached ({error}); "
                "answering from the local mirror, which may be behind"
            )
            return None

    def holds(self) -> dict | None:
        """What the archive holds, as of the check that came with this answer.

        Not a second round trip. Every check already asks — it is how the mirror
        knows whether it is behind — and asking again costs another walk of the
        whole listing on the service, which is a second and a half. The overview
        used to do exactly that, and it was most of why it took nearly five."""
        self.refresh()
        return self.remote

    def refresh(self, force: bool = False) -> None:
        """Bring the mirror in line with the archive.

        Two requests in the ordinary case: what the archive holds in total, and
        the last fortnight in detail. The count catches history arriving, the
        fortnight catches the days the phone rewrites. A mismatch that neither
        explains falls through to a full listing, which is six requests and
        happens almost never.

        Neither of those catches a day older than the fortnight being rewritten:
        the recent listing does not reach it and the count does not move, so the
        mirror would go on answering from its old copy for good. That is not a
        rare shape — a workout deleted a week later, a day the phone's own
        archive check owed back, any correction to history at all. So a forced
        check reads the whole listing instead of the recent one, which is what
        `phone_data_sync` is for and why it is the only caller that forces."""
        if not force and time.time() - self.checked_at < FRESH_FOR:
            return
        self.warning = None

        remote = self.stats()
        if not remote:
            return
        held, archive = self.open()
        state = self.reload(held)
        self.checked_at = time.time()

        try:
            if force:
                self.take_whole(archive, state)
                return
            self.take(archive, state, archive.list(start=add_days(today(), -RECENT_DAYS)))
            if behind(remote, state):
                self.take_whole(archive, state)
        except Exception as error:  # noqa: BLE001
            self.warning = (
                f"the mirror could not be brought up to date ({error}); "
                "answering from what it already had"
            )

    def reload(self, held: dict) -> dict:
        """The mirror's record of itself, read fresh rather than remembered.

        The command line tool keeps this same mirror, so a record held in memory
        since the first question of a session is behind whatever that tool has
        copied since. Two things follow from trusting it: those days are fetched
        a second time, and the next save writes a file that has forgotten them.

        A record that cannot be read is not a reason to stop answering — this
        process still has the one it was working from, and a question about last
        week should not fail because a file moved."""
        try:
            self.state = load_state()
            return self.state
        except Exception as error:  # noqa: BLE001
            self.warning = (
                f"the mirror's own record could not be read ({error}); "
                "answering from what this session already had"
            )
            return held

    def take_whole(self, archive, state: dict) -> None:
        """The whole archive, listed and taken.

        A listing that walks to the end is the only thing that can say a day has
        *gone*, and a day that has gone must lose its record: what the record
        claims is "the archive holds this version of this day", and that has
        stopped being true. Left in place it is worse than useless — it makes
        the mirror's count disagree with the archive's for good, so every
        ordinary question afterwards falls through to this same expensive walk.

        The record goes and the file stays. The archive losing a day does not
        make the local copy worthless; it may be the last one, and this is not
        the layer that gets to decide otherwise."""
        listing = archive.list()
        present = {entry["day"] for entry in listing}
        dropped = False
        for day in list(state["days"]):
            if day in present:
                continue
            del state["days"][day]
            dropped = True
        self.take(archive, state, listing, dropped)

    def take(self, archive, state: dict, listing: list[dict], save: bool = False) -> None:
        """Copy the days whose stored version is not the one the archive holds."""
        stale = {
            entry["day"]: entry["uploaded"]
            for entry in listing
            if state["days"].get(entry["day"]) != entry["uploaded"]
        }
        if not stale:
            if save:
                save_state(state)
            return
        for fetched in archive.several(sorted(stale)):
            write_day(fetched["day"], fetched["events"])
            state["days"][fetched["day"]] = stale[fetched["day"]]
        save_state(state)

    def collect(self, frm: str, to: str, keep) -> list[dict]:
        """The events in a range that a caller cares about, day by day.

        `keep` is applied before anything is held on to, because a decade of
        heart rate is eight hundred thousand readings and a question about sleep
        has no use for any of them."""
        self.refresh()
        return [
            {"day": day, "events": [e for e in read_day(day) if keep(e)]}
            for day in mirrored_days(frm, to)
        ]

    def mirrored(self) -> list[str]:
        return mirrored_days()


def what_each_day_holds() -> list[dict]:
    """What every mirrored day holds, worked out once per day and kept.

    The overview reads nothing else, and reading it the direct way meant opening
    every day in the mirror — 217 MB and two seconds — to answer with 3 KB about
    a dozen metrics. A day never changes once it is written, so the answer for it
    never changes either.

    **What is kept is a claim about a file, and the file is what tests it.**
    Every entry carries the size and modification time of the day it was read
    from, and an entry whose fingerprint no longer matches is thrown away and
    worked out again. That is the whole safety of this: a record that has gone
    stale, gone missing, or gone wrong costs a read, never a wrong answer.
    Deleting `metrics.json` is always safe, and so is having none."""
    versions = mirror_versions()
    try:
        kept = load(METRICS)
        if not isinstance(kept, dict):
            kept = {}
    except (OSError, ValueError):
        kept = {}

    days: list[dict] = []
    rebuilt: dict = {}
    moved = False
    # In day order, because the fold takes a metric's kind and unit from the
    # first day that holds it. `mirror_versions` answers sorted for exactly this.
    for day, version in versions.items():
        remembered = kept.get(day)
        if isinstance(remembered, dict) and remembered.get("v") == version:
            rebuilt[day] = remembered
            days.append({"day": day, "held": remembered["m"]})
            continue
        held = what_a_day_holds(read_day(day))
        rebuilt[day] = {"v": version, "m": held}
        days.append({"day": day, "held": held})
        moved = True

    # A day that left the mirror leaves this record too, and that is a change
    # even though nothing was read.
    if moved or len(kept) != len(rebuilt):
        write(METRICS, rebuilt, compact=True)
    return days


def note(remote: dict | None, mirrored: int) -> str:
    """How the readable part of the archive stands against the archive itself.

    Two ways it can differ, and they are opposite facts. Fewer days here than
    there means history has not been copied down yet, which one call fixes. More
    days here than there means the archive has *lost* one — the local copy may be
    the last of it, and nothing this side can put it back. Saying "the whole
    archive is readable" of that second case is true and useless, which is
    exactly the shape of answer this reader is not supposed to give."""
    if not remote:
        return "the archive could not be asked what it holds"
    if remote["days"] > mirrored:
        return (
            f"{remote['days'] - mirrored} days of the archive are not copied here yet; "
            "run phone_data_sync to complete the picture"
        )
    if remote["complete"] and mirrored > remote["days"]:
        return (
            f"{mirrored - remote['days']} days are readable here that the archive no longer "
            "holds; this copy of them may be the only one left"
        )
    return "the whole archive is readable"


def behind(remote: dict, state: dict) -> bool:
    """Whether the archive holds days this mirror has no record of.

    `days` is a total only when the service walked the whole archive to count
    it. Past that it answers with `complete: false` and a floor, and a floor can
    prove one thing and not the other: above the mirror's own count it says the
    mirror is behind, at or below it says nothing at all. Read as a total it
    would disagree with every honest mirror for good, and buy a full listing on
    every question for the rest of that mirror's life."""
    mirrored = len(state["days"])
    return remote["days"] != mirrored if remote["complete"] else remote["days"] > mirrored


reader = Reader()


# MARK: - Arguments


SINCE = {
    "type": "string",
    "description": "First day, YYYY-MM-DD, inclusive. Defaults to 90 days before today.",
}
UNTIL = {"type": "string", "description": "Last day, YYYY-MM-DD, inclusive. Defaults to today."}


def range_of(given: dict, default_days: int) -> tuple[str, str]:
    to = day_of(given.get("until"), "until") or today()
    frm = day_of(given.get("since"), "since") or add_days(to, -default_days)
    if frm > to:
        raise ValueError(f"since ({frm}) is after until ({to})")
    return frm, to


def day_of(value: object, name: str) -> str | None:
    if value is None or value == "":
        return None
    text = str(value)[:10]
    if not is_day(text):
        raise ValueError(f"{name} must be a day, YYYY-MM-DD, got {value}")
    return text


def names_or(value: object, fallback: list[str]) -> list[str]:
    if not isinstance(value, list) or not value:
        return fallback
    return [str(name) for name in value]


def round1(value: float) -> float | int:
    rounded = round(value, 1)
    return int(rounded) if rounded == int(rounded) else rounded


def units_for(days: list[dict], metrics: list[str]) -> dict:
    units: dict = dict.fromkeys(metrics)
    for entry in days:
        for event in entry["events"]:
            metric = event.get("metric")
            if metric in units and not units[metric] and isinstance(event.get("unit"), str):
                units[metric] = event["unit"]
    return units


#: When something happened comes first, because that is what a reader scans for;
#: everything else by name, so the order of an answer never depends on the order
#: a day's events happened to arrive in.
INSTANTS = ("start", "end")


def table(rows: list[dict], drop: tuple[str, ...] = ()) -> dict:
    """A set of rows as a table: what they all agree on said once, the rest in
    columns.

    A reading is mostly its own labels. The metric, the unit and the device are
    the same on every row of an answer about one metric, and repeated per row
    they are two thirds of it — 500 heart rate readings came to 128 KB, which is
    a third of what some agents can hold at all. Said once they come to 39 KB,
    and nothing about the data has changed.

    **The columns are the keys the rows actually carry, never a list written
    here.** A fixed list would drop a field the day it appeared and nothing
    would say so — the same failure the day packing refuses one layer down, and
    for the same reason. A key that only some rows carry becomes a column with a
    null in the others, which is the honest shape: null means this row had none,
    and it is not the same as a zero."""
    kept = [{name: value for name, value in row.items() if name not in drop} for row in rows]

    every = sorted({name for row in kept for name in row}, key=lambda n: (_place(n), n))
    same: dict = {}
    columns: list[str] = []
    for name in every:
        first = kept[0].get(name) if kept else None
        # Only a value every row carries, and only a plain one: two objects that
        # look alike are not the same object, so hoisting one would be a claim
        # this cannot check. And only past one row — with a single row every
        # field trivially agrees, so hoisting them all saves nothing and leaves
        # an answer whose one row is empty.
        agreed = (
            len(kept) > 1
            and not isinstance(first, (dict, list))
            and all(name in row and row[name] == first for row in kept)
        )
        if agreed:
            same[name] = first
        else:
            columns.append(name)

    return {
        "sameOnEveryRow": same,
        "columns": columns,
        "rows": [[row.get(name) for name in columns] for row in kept],
    }


def _place(name: str) -> int:
    return INSTANTS.index(name) if name in INSTANTS else len(INSTANTS)


# MARK: - Tools


def overview(_: dict) -> dict:
    remote = reader.holds()
    days = what_each_day_holds()
    mirrored = [entry["day"] for entry in days]

    return {
        "archive": {
            "days": remote["days"],
            "firstDay": remote["firstDay"],
            "lastDay": remote["lastDay"],
            "megabytes": round1(remote["bytes"] / 1024 / 1024),
        }
        if remote
        else "unreachable",
        "readable": {
            "days": len(mirrored),
            "firstDay": mirrored[0] if mirrored else None,
            "lastDay": mirrored[-1] if mirrored else None,
            "note": note(remote, len(mirrored)),
        },
        "metrics": fold(days),
        "writable": writable_shapes(),
        "howToRead": [
            "A total (steps, distance, energy, exercise and stand minutes) is already summed by",
            "Health and must never be summed again from records — several devices write the same",
            "minutes and adding them double-counts.",
            "Totals come bucketed by day, and by hour only from the day the app was installed.",
            "A record belongs to the day it started on, so a night that began before midnight is",
            "in the evening's day.",
            "`writable` is what phone_data_write may put into Health, with the one unit each",
            "takes; a metric written there shows up in the other tools once the phone has applied",
            "it and re-uploaded the day.",
        ],
    }


def daily(given: dict) -> dict:
    frm, to = range_of(given, 90)
    if days_between(frm, to) > 400:
        raise ValueError(
            f"{days_between(frm, to)} days is too many for a daily table; ask for 400 or fewer, "
            "or use phone_data_statistics with group_by month or year"
        )
    metrics = names_or(given.get("metrics"), list(TOTALS))
    days = reader.collect(frm, to, lambda event: event.get("bucket") == "day")
    rows = daily_totals(days, metrics)
    return {
        "units": units_for(days, metrics),
        "columns": ["day", *metrics],
        "rows": [[row["day"], *(row["values"][metric] for metric in metrics)] for row in rows],
    }


def statistics(given: dict) -> dict:
    metric = str(given.get("metric") or "")
    if not metric:
        raise ValueError("metric is required")
    frm, to = range_of(given, 365)
    grouping = given.get("group_by") or "month"
    is_total = metric in TOTALS

    days = reader.collect(
        frm,
        to,
        lambda event: (
            event.get("metric") == metric
            and (event.get("bucket") == "day" if is_total else not event.get("bucket"))
        ),
    )

    groups: dict[str, list[float]] = {}
    unit = None
    for entry in days:
        label = group_of(entry["day"], grouping)
        values = groups.setdefault(label, [])
        for event in entry["events"]:
            value = event.get("value")
            if not isinstance(value, (int, float)) or isinstance(value, bool):
                continue
            if not unit and isinstance(event.get("unit"), str):
                unit = event["unit"]
            values.append(value)

    rows = sorted(
        (
            {"group": group, **(distribution(values) or empty_distribution())}
            for group, values in groups.items()
            if values
        ),
        key=lambda row: row["group"],
    )
    if len(rows) > MAX_ROWS:
        raise ValueError(
            f"{len(rows)} groups is more than an answer should carry; "
            "coarsen group_by or shorten the range"
        )

    answer = {"metric": metric, "unit": unit}
    if metric in UNIT_NOTES:
        answer["unitNote"] = UNIT_NOTES[metric]
    answer["over"] = "daily totals, one value per day" if is_total else "individual readings"
    answer["groupBy"] = grouping
    answer["rows"] = rows
    return answer


def sleep(given: dict) -> dict:
    frm, to = range_of(given, 90)
    # A night named by the last day of the range is finished on the day after
    # it, and the night before the first day reaches into it. Both ends are
    # widened so neither night comes back as a half.
    days = reader.collect(
        add_days(frm, -1), add_days(to, 1), lambda event: event.get("metric") == "sleep"
    )
    events = [event for entry in days for event in entry["events"]]
    rows = [night for night in nights(events) if frm <= night["night"] <= to]
    if len(rows) > MAX_ROWS:
        raise ValueError(f"{len(rows)} nights is too many; ask for less")

    hours = [night["asleepHours"] for night in rows if night["asleepHours"] > 0]
    return {
        "nightsRecorded": len(rows),
        "nightsInRange": days_between(frm, to) + 1,
        "asleepHours": distribution(hours),
        "rows": rows,
    }


def workouts_tool(given: dict) -> dict:
    frm, to = range_of(given, 365)
    days = reader.collect(frm, to, lambda event: event.get("metric") == "workout")
    wanted = str(given["activity"]) if given.get("activity") else None
    found = [w for w in workouts(days) if not wanted or w["activity"] == wanted]

    by_activity: dict = {}
    for workout in found:
        seen = by_activity.setdefault(workout["activity"], {"count": 0, "minutes": 0})
        seen["count"] += 1
        seen["minutes"] = round1(seen["minutes"] + workout["minutes"])

    answer = {
        "total": len(found),
        "byActivity": dict(sorted(by_activity.items(), key=lambda pair: -pair[1]["count"])),
        **table(found[:MAX_ROWS]),
    }
    if len(found) > MAX_ROWS:
        answer["note"] = f"showing the first {MAX_ROWS} of {len(found)}"
    return answer


def samples(given: dict) -> dict:
    metric = str(given.get("metric") or "")
    if not metric:
        raise ValueError("metric is required")
    frm, to = range_of(given, 7)
    try:
        limit = min(int(given.get("limit") or 500) or 500, 5000)
    except (TypeError, ValueError):
        limit = 500

    days = reader.collect(frm, to, lambda event: event.get("metric") == metric)
    events = sorted(
        (event for entry in days for event in entry["events"]),
        key=lambda event: str(event.get("start")),
    )

    shown = events[:limit]
    answer = {"metric": metric}
    if metric in UNIT_NOTES:
        answer["unitNote"] = UNIT_NOTES[metric]
    answer["matched"] = len(events)
    answer["returned"] = len(shown)
    # The metric is already named above, and the identifier is derived from it
    # and the instant — both of which are in the table.
    answer.update(table(shown, ("id", "metric")))
    return answer


def write_tool(given: dict) -> dict:
    items = given.get("items")
    if not isinstance(items, list):
        raise ValueError("items must be a list")
    _, archive = reader.open()
    answer = archive.submit_edits(items)
    return {
        **answer,
        "items": len(items),
        "note": "Stored sealed; the phone applies it the next time it is opened or wakes to "
        "send. phone_data_edits reports what became of it, by this name.",
    }


def edits_tool(given: dict) -> dict:
    status = "pending" if given.get("status") == "pending" else "all"
    after = str(given["after"]) if given.get("after") else None
    if after and not is_edit_name(after):
        raise ValueError("after must be the name of an edit, as an earlier answer gave it")
    _, archive = reader.open()
    page = archive.edits(after=after, status=status)
    return {**page, "codes": list(OUTCOME_CODES)}


def sync_tool(_: dict) -> dict:
    before = len(reader.mirrored())
    reader.refresh(force=True)
    after = reader.mirrored()
    return {
        "copied": len(after) - before,
        "readable": len(after),
        "firstDay": after[0] if after else None,
        "lastDay": after[-1] if after else None,
    }


QUANTITIES = ", ".join(
    f"{name} in {shape['unit']}"
    for name, shape in writable_shapes().items()
    if shape["kind"] == "quantity"
)

TOOLS = [
    {
        "name": "phone_data_overview",
        "title": "What the archive holds",
        "description": "\n".join(
            [
                "Start here. Reports what this Health archive contains before anything is asked "
                "of it:",
                "the range of days, how many there are, and for every metric its kind, unit, "
                "first and",
                "last day, and how many days carry it.",
                "",
                "The first day of a metric is the day the device that measures it arrived, so a "
                "question",
                "about heart rate before that day is not a gap in the data — nothing was "
                "measuring.",
                "Takes no arguments.",
            ]
        ),
        "inputSchema": {"type": "object", "properties": {}},
        "run": overview,
    },
    {
        "name": "phone_data_daily",
        "title": "Daily totals",
        "description": "\n".join(
            [
                "One row per day with the day's totals: steps, distance, flights, active and basal",
                "energy, exercise and stand minutes, and — once something has written them — "
                "dietary",
                "energy, protein, carbohydrates, fat and water. This is the table to answer 'how "
                "active",
                "was I' and 'what did I eat'.",
                "",
                "Reads the daily buckets only, so it can never double-count against the hourly "
                "ones.",
                "A null means the day carries no total for that metric, which is not the same as "
                "a zero.",
                "Refuses ranges over 400 days — use phone_data_statistics for anything longer.",
            ]
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "metrics": {
                    "type": "array",
                    "items": {"type": "string", "enum": list(TOTALS)},
                    "description": f"Which totals to include. Defaults to all of: "
                    f"{', '.join(TOTALS)}.",
                },
                "since": SINCE,
                "until": UNTIL,
            },
        },
        "run": daily,
    },
    {
        "name": "phone_data_statistics",
        "title": "Distribution of a metric over time",
        "description": "\n".join(
            [
                "How one metric is distributed, grouped by day, week, month or year: count, min, "
                "p10,",
                "median, mean, p90, max and sum per group. This is the tool for trends and for any",
                "question spanning years — it never returns the underlying readings.",
                "",
                "For a total, the numbers are over that metric's daily totals, one per day.",
                "For a record (heart rate, HRV, respiratory rate, blood oxygen), they are over the",
                "individual readings, of which there can be hundreds in a day.",
                "Blood oxygen arrives as a fraction: 0.97 means 97%.",
            ]
        ),
        "inputSchema": {
            "type": "object",
            "required": ["metric"],
            "properties": {
                "metric": {
                    "type": "string",
                    "enum": [*TOTALS, *(m for m in RECORDS if m not in ("sleep", "workout"))],
                    "description": "The metric to describe. Sleep and workouts have their own "
                    "tools.",
                },
                "since": SINCE,
                "until": UNTIL,
                "group_by": {
                    "type": "string",
                    "enum": ["day", "week", "month", "year"],
                    "description": "How to group the days. Defaults to month.",
                },
            },
        },
        "run": statistics,
    },
    {
        "name": "phone_data_sleep",
        "title": "Nights of sleep",
        "description": "\n".join(
            [
                "One row per night: hours asleep, hours in bed, the breakdown by stage, and when "
                "it",
                "started and ended.",
                "",
                "Two things are decided here that a reader of the raw events would get wrong. "
                "Overlapping",
                "stretches are merged rather than added, because more than one source can "
                "describe the",
                "same minutes and adding them invents hours of sleep. A night runs noon to noon "
                "and is",
                "named by the evening it began in, so a night is one row rather than two halves.",
                "A missing night means nothing was recorded — the watch was off, not that nobody "
                "slept.",
            ]
        ),
        "inputSchema": {"type": "object", "properties": {"since": SINCE, "until": UNTIL}},
        "run": sleep,
    },
    {
        "name": "phone_data_workouts",
        "title": "Recorded workouts",
        "description": "\n".join(
            [
                "Every workout in a range — activity, when it started, how long it lasted — plus "
                "a count",
                "and total minutes per activity.",
                "",
                "The workouts come as a table: `columns` names what each row holds, in order, and",
                "`sameOnEveryRow` holds the fields every workout agrees on, said once. The counts "
                "in",
                "`byActivity` are over every workout found, not only the rows shown.",
                "",
                "The phone sends Apple's activity number and this translates it, so an activity "
                "comes",
                "back as 'walking' rather than as 52. A workout is what was deliberately "
                "recorded; it is",
                "not the same as the day's movement, which lives in phone_data_daily.",
            ]
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "since": SINCE,
                "until": UNTIL,
                "activity": {
                    "type": "string",
                    "description": "Keep only this activity, e.g. walking, cycling, swimming.",
                },
            },
        },
        "run": workouts_tool,
    },
    {
        "name": "phone_data_samples",
        "title": "Raw readings",
        "description": "\n".join(
            [
                "The individual readings for one metric. The escape hatch for questions the other "
                "tools",
                "do not shape — the time of day something happened, what a single reading was, "
                "which",
                "device recorded it.",
                "",
                "As a table: `columns` names what each row holds, in order, and `sameOnEveryRow` "
                "holds",
                "the fields every reading agrees on, said once instead of on every row. A null in "
                "a",
                "column means that reading carried nothing there, which is not the same as a zero.",
                "",
                "The identifier is not carried. It was only ever derived from the metric and the "
                "instant",
                "a reading began, and both are here. Two readings can begin in the same second — "
                "one",
                "heartbeat seen by two watches, two sleep stages starting together — and then "
                "they are",
                "two rows that may differ in nothing at all. That is the data, not a duplicate to "
                "remove.",
                "",
                "Capped, and deliberately so: a decade of heart rate is eight hundred thousand "
                "readings.",
                "For anything about a trend or an average, phone_data_statistics is both cheaper "
                "and harder",
                "to misread.",
            ]
        ),
        "inputSchema": {
            "type": "object",
            "required": ["metric"],
            "properties": {
                "metric": {"type": "string", "description": "Which metric's readings to return."},
                "since": SINCE,
                "until": UNTIL,
                "limit": {
                    "type": "integer",
                    "description": "How many readings at most. Defaults to 500, maximum 5000.",
                },
            },
        },
        "run": samples,
    },
    {
        "name": "phone_data_write",
        "title": "Write into Health",
        "description": "\n".join(
            [
                "Put entries into Apple Health through the phone: meals as dietary energy, "
                "protein,",
                "carbohydrates, fat and water; sleep by stage; body mass. The edit is sealed to "
                "the",
                "phone's key and signed here, the service stores it unopened, and the phone "
                "applies it",
                "the next time it is opened or wakes to send — minutes to hours, never at once.",
                "phone_data_edits says when it has, and the days it touched are re-uploaded so the",
                "other tools show the result.",
                "",
                "Each item is a `put` or a `delete`. The `id` is your handle for one entry: a "
                "second",
                "`put` under the same id replaces the entry, a `delete` removes it, so pick ids "
                "you can",
                "rebuild — `agent:meal:2026-09-07:lunch` — and reuse them for a correction. Only "
                "entries",
                "written this way can be replaced or removed; what the watch, the phone or "
                "another app",
                "recorded is Health's and stays as it is.",
                "",
                "`start` and `end` are whole seconds since 1970 and both must be in the past — "
                "Health",
                "refuses an entry that ends in the future. A quantity needs `value` and the "
                "metric's",
                f"exact unit ({QUANTITIES}); sleep needs `stage` and no value.",
                "A meal is a short interval; a night of sleep is one item per stage, or one",
                "asleepUnspecified stretch when the stages are not known. Anything wrong with an "
                "item",
                "is refused here, before anything is sealed, with the field named.",
            ]
        ),
        "inputSchema": {
            "type": "object",
            "required": ["items"],
            "properties": {
                "items": {
                    "type": "array",
                    "minItems": 1,
                    "maxItems": wire.MAX_ITEMS_PER_EDIT,
                    "description": f"The entries to write, up to {wire.MAX_ITEMS_PER_EDIT} in one "
                    "edit.",
                    "items": {
                        "type": "object",
                        "required": ["op", "id"],
                        "properties": {
                            "op": {
                                "type": "string",
                                "enum": ["put", "delete"],
                                "description": "put adds or replaces the entry under this id; "
                                "delete removes it.",
                            },
                            "id": {
                                "type": "string",
                                "description": "Your handle for the entry: 1 to 120 characters "
                                "of letters, digits, . _ : -",
                            },
                            "metric": {
                                "type": "string",
                                "enum": list(wire.WRITABLE),
                                "description": "What the entry is. put only.",
                            },
                            "start": {
                                "type": "integer",
                                "description": "Whole seconds since 1970. put only.",
                            },
                            "end": {
                                "type": "integer",
                                "description": "Whole seconds since 1970, not before start, in "
                                "the past. put only.",
                            },
                            "value": {
                                "type": "number",
                                "description": "For a quantity: the amount, zero or more, in the "
                                "metric's unit.",
                            },
                            "unit": {
                                "type": "string",
                                "description": "For a quantity: the metric's own unit, exactly.",
                            },
                            "stage": {
                                "type": "string",
                                "enum": list(wire.SLEEP_STAGES),
                                "description": "For sleep: which stage this stretch was.",
                            },
                        },
                    },
                }
            },
        },
        "run": write_tool,
    },
    {
        "name": "phone_data_edits",
        "title": "What became of the edits",
        "description": "\n".join(
            [
                "The edits sent to the phone and what it did with each: `pending` until the phone "
                "has",
                "looked, then `applied`; `failed` if the phone could not do it, and `partial` "
                "when some",
                "of it landed. `awaiting` and `declined` come from a phone that used to ask before",
                "changing anything; no phone does now, and those only appear on old edits.",
                "For anything refused, the",
                "phone's word for why is listed per item — badRange for an end in the future, "
                "badUnit",
                "for a unit the metric does not take, unauthorized when Health access to that "
                "type was",
                "declined on the phone, notFound for a delete of an id never written, "
                "healthRefused when",
                "Health itself said no, replayed when the phone had already answered that very "
                "edit and",
                "wrote nothing the second time. Edits this machine submitted also show the ids "
                "they carried.",
                "",
                "Every item lands, including one that changes or removes a record already in "
                "Health —",
                "which can only ever be a record this app itself wrote for you. The phone keeps "
                "what",
                "each change pushed out and shows its owner what you did, so anything unwanted is "
                "put",
                "back by them, not prevented beforehand. An outcome is told once and never "
                "revised.",
                "",
                "An edit stays pending until the phone is opened or wakes to send, which can be "
                "hours.",
                "Newest last; follow `next` for more.",
            ]
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "status": {
                    "type": "string",
                    "enum": ["pending", "all"],
                    "description": "pending lists only what the phone has not applied yet. "
                    "Defaults to all.",
                },
                "after": {
                    "type": "string",
                    "description": "Continue after this edit name, as the previous answer's "
                    "`next` gave it.",
                },
            },
        },
        "run": edits_tool,
    },
    {
        "name": "phone_data_sync",
        "title": "Copy the archive down",
        "description": "\n".join(
            [
                "Bring the local copy of the archive up to date. The other tools refresh what "
                "they need",
                "on their own, so this is only worth calling to make the whole history readable "
                "at once —",
                "phone_data_overview says when that is not already true.",
                "",
                "Safe to interrupt and safe to repeat: a day is either the version the archive "
                "holds or",
                "an older one, and this replaces the older ones.",
            ]
        ),
        "inputSchema": {"type": "object", "properties": {}},
        "run": sync_tool,
    },
]


# MARK: - JSON-RPC over stdio


INSTRUCTIONS = " ".join(
    [
        "This is one person's Apple Health history, day by day, from an end-to-end encrypted",
        "archive. Call phone_data_overview first: it says what the data covers, when each metric",
        "starts, and the few ways this data misleads a reader who treats it as a plain table.",
        "phone_data_write puts meals, sleep and weight into Health through the phone.",
    ]
)


def handle(request: dict) -> dict | None:
    # A notification has no id and takes no answer. `notifications/initialized`
    # is the only one that arrives, and replying to it is a protocol error
    # rather than a harmless extra.
    notification = request.get("id") is None
    method = request.get("method")
    params = request.get("params") or {}

    if method == "initialize":
        asked = str(params.get("protocolVersion") or "")
        return result(
            request.get("id"),
            {
                "protocolVersion": asked if asked in PROTOCOL_VERSIONS else PROTOCOL_VERSIONS[0],
                "capabilities": {"tools": {}},
                "serverInfo": {"name": NAME, "version": VERSION},
                "instructions": INSTRUCTIONS,
            },
        )
    if method == "ping":
        return result(request.get("id"), {})
    if method == "tools/list":
        return result(
            request.get("id"),
            {
                "tools": [
                    {name: tool[name] for name in ("name", "title", "description", "inputSchema")}
                    for tool in TOOLS
                ]
            },
        )
    if method == "tools/call":
        name = str(params.get("name") or "")
        tool = next((candidate for candidate in TOOLS if candidate["name"] == name), None)
        if not tool:
            return result(request.get("id"), text(f"no such tool: {name}", True))
        try:
            answer = tool["run"](params.get("arguments") or {})
            body = {"warning": reader.warning, **answer} if reader.warning else answer
            # Without indentation. Nothing reads this but a model, which pays
            # for every character of it and is no better at reading the laid-out
            # form — the spaces were a fifth of every answer this server sent.
            return result(request.get("id"), text(json.dumps(body, separators=(",", ":"))))
        except Exception as error:  # noqa: BLE001
            # Reported as a failed tool call rather than as a broken connection:
            # the agent can read it, correct the arguments and try again.
            return result(request.get("id"), text(str(error), True))

    if notification:
        return None
    return {
        "jsonrpc": "2.0",
        "id": request.get("id"),
        "error": {"code": -32601, "message": f"unknown method: {method}"},
    }


def result(request_id: object, value: object) -> dict:
    return {"jsonrpc": "2.0", "id": request_id, "result": value}


def text(body: str, is_error: bool = False) -> dict:
    answer: dict = {"content": [{"type": "text", "text": body}]}
    if is_error:
        answer["isError"] = True
    return answer


def serve() -> None:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            answer = handle(json.loads(line))
        except ValueError as error:
            answer = {
                "jsonrpc": "2.0",
                "id": None,
                "error": {"code": -32700, "message": f"could not read that: {error}"},
            }
        if answer is not None:
            sys.stdout.write(json.dumps(answer, separators=(",", ":")) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    serve()
