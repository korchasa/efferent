"""Import the phone's connection handoff without sending its reading key anywhere."""

import re
from urllib.parse import urlsplit

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey

import efferent_hpke as wire

from .archive import EDITOR, READING, STATE, ArchiveError, home, load, pkcs8, write


def parse_connection_handoff(text: str) -> dict:
    """The handoff, checked, as the files the reader keeps: PKCS8 for each
    private half, raw for each public half."""
    instruction = wire.field(text, "Instruction")
    if "setup_guide" not in instruction or not re.search(
        r"Keep the reading key( and the editor key)? local", instruction
    ):
        raise ArchiveError("the instruction must call setup_guide and keep the reading key local")
    mcp = wire.field(text, "MCP")
    parts = urlsplit(mcp)
    if parts.scheme not in ("http", "https"):
        raise ArchiveError("MCP must use HTTP or HTTPS")
    if parts.query or parts.fragment or "/mcp/b/" not in parts.path:
        raise ArchiveError("MCP must end in /mcp/b/<bucket-id>, without a query or fragment")

    endpoint, bucket, private_raw, editor_raw = wire.connection(text)
    reading = X25519PrivateKey.from_private_bytes(private_raw)
    connection = {
        "mcpURL": mcp,
        "endpoint": endpoint,
        "bucket": bucket,
        "reading": {
            "readingPrivate": pkcs8(reading),
            "readingPublic": wire.to_base64url(reading.public_key().public_bytes(*wire.RAW)),
        },
    }
    if editor_raw is not None:
        editor = Ed25519PrivateKey.from_private_bytes(editor_raw)
        connection["editor"] = {
            "editorPrivate": pkcs8(editor),
            "editorPublic": wire.to_base64url(editor.public_key().public_bytes(*wire.RAW)),
        }
    return connection


def install_connection_handoff(text: str) -> dict:
    """Move a validated handoff into the reader's private files.

    A reader that already exists is not overwritten — except for one case that
    would otherwise cost a whole re-sync: a fresh handoff for the *same*
    archive, from a phone that has since learnt to write, adds the editor key
    to a reader that has none and touches nothing else."""
    connection = parse_connection_handoff(text)
    if "editor" in connection and same_reader(connection) and not (home() / EDITOR).exists():
        write(EDITOR, connection["editor"])
        return connection
    for name in (READING, STATE, EDITOR):
        if (home() / name).exists():
            raise ArchiveError(
                f"{home() / name} already exists — use a different EFFERENT_HOME; "
                "refusing to overwrite it"
            )
    write(READING, connection["reading"])
    write(STATE, {"endpoint": connection["endpoint"], "days": {}, "syncedAt": ""})
    if "editor" in connection:
        write(EDITOR, connection["editor"])
    return connection


def same_reader(connection: dict) -> bool:
    """Whether the reader in the home holds this very reading key."""
    try:
        return load(READING)["readingPublic"] == connection["reading"]["readingPublic"]
    except (OSError, ValueError, KeyError):
        return False
