"""Importing the phone's handoff, and refusing one that is not what it claims."""

import json
import os
import tempfile
import unittest
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey

import efferent_hpke as wire
from efferent.archive import ArchiveError
from efferent.connection import install_connection_handoff, parse_connection_handoff

INSTRUCTION = (
    "Connect the supplied Efferent MCP and call setup_guide first. The MCP is streamable HTTP "
    "with no authentication: register the address as it is, with no header and no key. If you "
    "cannot add a server in this session, POST a JSON-RPC tools/call for setup_guide to the "
    "address with Accept: application/json, text/event-stream. Keep the reading key and the "
    "editor key local and never pass either to a remote tool."
)


def raw(private) -> bytes:
    return private.private_bytes(
        serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption()
    )


def fixture(editor: bool = False) -> dict:
    reading = X25519PrivateKey.generate()
    public_raw = reading.public_key().public_bytes(*wire.RAW)
    bucket = wire.bucket_of(public_raw)
    reading_key = (
        f"efferent-reading-v1.{wire.to_base64url(raw(reading))}.{wire.to_base64url(public_raw)}"
    )

    signer = Ed25519PrivateKey.generate()
    editor_public = signer.public_key().public_bytes(*wire.RAW)
    editor_key = (
        f"efferent-editor-v1.{wire.to_base64url(raw(signer))}.{wire.to_base64url(editor_public)}"
    )

    lines = [
        "Instruction:",
        INSTRUCTION,
        "",
        "MCP:",
        f"https://efferent.example/mcp/b/{bucket}",
        "",
        "Reading key:",
        reading_key,
    ]
    read_only = "\n".join(lines)
    if editor:
        lines += ["", "Editor key:", editor_key]
    return {
        "bucket": bucket,
        "editorPublic": wire.to_base64url(editor_public),
        "text": "\n".join(lines),
        "readOnly": read_only,
    }


class Home(unittest.TestCase):
    """Each test gets a home of its own: the install tests write real files, and
    none of them may land in a real reader."""

    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="efferent-connection-")
        self.home = Path(self.root) / "reader"
        self.previous = os.environ.get("EFFERENT_HOME")
        os.environ["EFFERENT_HOME"] = str(self.home)

    def tearDown(self):
        if self.previous is None:
            os.environ.pop("EFFERENT_HOME", None)
        else:
            os.environ["EFFERENT_HOME"] = self.previous


class Parsing(Home):
    def test_a_phone_handoff_becomes_a_local_reader_configuration(self):
        made = fixture()

        connection = parse_connection_handoff(made["text"])

        self.assertEqual(connection["bucket"], made["bucket"])
        self.assertEqual(connection["endpoint"], "https://efferent.example")
        self.assertEqual(connection["mcpURL"], f"https://efferent.example/mcp/b/{made['bucket']}")
        self.assertEqual(len(connection["reading"]["readingPublic"]), 43)
        self.assertGreater(len(connection["reading"]["readingPrivate"]), 40)
        imported = serialization.load_der_private_key(
            wire.base64url(connection["reading"]["readingPrivate"]), password=None
        )
        self.assertIsInstance(imported, X25519PrivateKey)
        # A handoff from before writing existed: the agent can read, not write,
        # and the record says so rather than guessing a key.
        self.assertNotIn("editor", connection)

    def test_a_fourth_field_carries_the_editor_key(self):
        made = fixture(editor=True)

        connection = parse_connection_handoff(made["text"])

        self.assertEqual(connection["editor"]["editorPublic"], made["editorPublic"])
        imported = serialization.load_der_private_key(
            wire.base64url(connection["editor"]["editorPrivate"]), password=None
        )
        self.assertIsInstance(imported, Ed25519PrivateKey)

    def test_an_editor_key_whose_halves_do_not_match_is_refused(self):
        made, other = fixture(editor=True), fixture(editor=True)
        wrong = made["text"].replace(made["editorPublic"], other["editorPublic"])

        with self.assertRaisesRegex(ValueError, "editor key"):
            parse_connection_handoff(wrong)

    def test_a_key_for_another_bucket_is_refused(self):
        made = fixture()
        wrong = made["text"].replace(made["bucket"], "a" * 26)

        with self.assertRaisesRegex(ValueError, "different bucket"):
            parse_connection_handoff(wrong)

    def test_a_reading_key_cannot_be_smuggled_into_the_mcp_url(self):
        made = fixture()
        wrong = made["text"].replace(
            f"/mcp/b/{made['bucket']}", f"/mcp/b/{made['bucket']}?reading-key=secret"
        )

        with self.assertRaisesRegex(ArchiveError, "without a query"):
            parse_connection_handoff(wrong)

    def test_the_instruction_must_bootstrap_through_setup_guide(self):
        # Every mention goes, the request body's included: the parser has to see
        # the tool named somewhere in the line, not this particular sentence.
        wrong = fixture()["text"].replace("setup_guide", "some_tool")

        with self.assertRaisesRegex(ArchiveError, "must call setup_guide"):
            parse_connection_handoff(wrong)


class Installing(Home):
    def test_a_fresh_handoff_for_the_same_archive_adds_the_editor_key(self):
        made = fixture(editor=True)
        install_connection_handoff(made["readOnly"])
        before = (self.home / "reading-key.json").read_text()
        self.assertFalse((self.home / "editor-key.json").exists())

        # The phone learnt to write and handed the same archive over again: the
        # reader keeps its key and its mirror, and gains the one thing it lacked.
        install_connection_handoff(made["text"])

        editor = json.loads((self.home / "editor-key.json").read_text())
        self.assertEqual(editor["editorPublic"], made["editorPublic"])
        self.assertEqual((self.home / "reading-key.json").read_text(), before)

        # A handoff for another archive is still refused: two readers do not
        # share a home.
        with self.assertRaisesRegex(ArchiveError, "already exists"):
            install_connection_handoff(fixture(editor=True)["text"])


if __name__ == "__main__":
    unittest.main()
