"""Days: the unit everything on the reading side is addressed by."""

import re
from datetime import date, datetime, timedelta, timezone

DAY = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def is_day(value: object) -> bool:
    """A calendar day, and one that exists: the regex alone would accept the
    31st of February, and a day nobody can write is a day a reader could ask
    for forever."""
    if not isinstance(value, str) or not DAY.match(value):
        return False
    try:
        return date.fromisoformat(value).isoformat() == value
    except ValueError:
        return False


def add_days(day: str, count: int) -> str:
    return (date.fromisoformat(day) + timedelta(days=count)).isoformat()


def day_before(day: str) -> str:
    """Listings skip *after* a key while a range asks *from* one, so the
    boundary is moved by a day, which is what it means."""
    return add_days(day, -1)


def days_between(start: str, end: str) -> int:
    return (date.fromisoformat(end) - date.fromisoformat(start)).days


def day_range(start: str, end: str) -> list[str]:
    """Every day in an inclusive range, in order."""
    days = []
    day = start
    while day <= end:
        days.append(day)
        day = add_days(day, 1)
    return days


def today() -> str:
    return datetime.now(timezone.utc).date().isoformat()


def now_iso() -> str:
    """The moment in the shape the reader's own files already carry: milliseconds
    and a Z. Changing it would make a stamp written yesterday sort against one
    written today."""
    return (
        datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.")
        + f"{datetime.now(timezone.utc).microsecond // 1000:03d}Z"
    )
