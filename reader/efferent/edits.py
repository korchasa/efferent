"""The words an edit and its outcome are told in.

The wire module carries what an edit *is*, because it is also the script the
setup guide hands an agent. These are the words that come back about one, which
only a reader ever sees.
"""

import re

import efferent_hpke as wire

#: The phone's word for why it refused one item. `awaitingApproval` and
#: `declined` are legacy: a build that asked its owner before changing or
#: removing a record produced them, no phone does now, and an outcome is told
#: once and never revised. `replayed` means the phone had already answered this
#: very edit and wrote nothing the second time, which only happens when the
#: service hands back an edit it should have deleted.
OUTCOME_CODES = (
    "unknownMetric",
    "badUnit",
    "badRange",
    "unauthorized",
    "notFound",
    "healthRefused",
    "badSignature",
    "cannotOpen",
    "malformed",
    "awaitingApproval",
    "declined",
    "replayed",
)

EDIT_NAME = re.compile(r"^\d{13}-[a-z2-7]{8}$")


def is_edit_name(value: object) -> bool:
    return isinstance(value, str) and bool(EDIT_NAME.match(value))


def writable_shapes() -> dict:
    """What each writable metric takes, in the shape an agent is told it.

    Built from the wire module rather than written twice: that module is the
    script the guide hands out, and a second list of metrics here would be the
    one that goes out of date."""
    return {
        name: (
            {"kind": "category", "stages": list(wire.SLEEP_STAGES)}
            if unit is None
            else {"kind": "quantity", "unit": unit}
        )
        for name, unit in wire.WRITABLE.items()
    }
