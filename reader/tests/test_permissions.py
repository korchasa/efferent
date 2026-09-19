"""The reader's own files hold the key and the readings, so nobody else reads them."""

import os
import stat
import tempfile
import unittest
from pathlib import Path

from efferent.archive import write, write_day


def permission(path: Path) -> int:
    return stat.S_IMODE(path.stat().st_mode)


class Permissions(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="efferent-permissions-")
        self.home = Path(self.root) / "reader"
        self.previous = os.environ.get("EFFERENT_HOME")
        os.environ["EFFERENT_HOME"] = str(self.home)

    def tearDown(self):
        if self.previous is None:
            os.environ.pop("EFFERENT_HOME", None)
        else:
            os.environ["EFFERENT_HOME"] = self.previous

    def test_the_reader_keeps_its_directory_and_plaintext_private(self):
        write("mirror.json", {"endpoint": "https://efferent.example", "days": {}})
        # The kept metric record goes down the same path but compactly, and it
        # holds the same kind of thing: which metrics this person records, how
        # many readings a day, and when each device arrived.
        write("metrics.json", {"2026-08-27": {"v": "1:2"}}, compact=True)
        write_day("2026-08-27", [{"id": "sample", "v": 1}])
        # The editor key can ask the phone to write into Health, and the record
        # of edits names what was written and when.
        write("editor-key.json", {"editorPrivate": "x", "editorPublic": "y"})
        write("edits.json", [{"name": "1757228400000-abcdefgh", "at": "", "items": []}])

        self.assertEqual(permission(self.home), 0o700)
        self.assertEqual(permission(self.home / "mirror.json"), 0o600)
        self.assertEqual(permission(self.home / "metrics.json"), 0o600)
        self.assertEqual(permission(self.home / "days"), 0o700)
        self.assertEqual(permission(self.home / "days" / "2026-08-27.ndjson"), 0o600)
        self.assertEqual(permission(self.home / "editor-key.json"), 0o600)
        self.assertEqual(permission(self.home / "edits.json"), 0o600)


if __name__ == "__main__":
    unittest.main()
