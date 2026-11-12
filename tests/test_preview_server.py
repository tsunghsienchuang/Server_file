import http.client
import os
from pathlib import Path
import socket
import sys
from tempfile import TemporaryDirectory
import threading
import unittest
from unittest.mock import patch


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Sources"))
import preview_server as preview


class PreviewServerTests(unittest.TestCase):
    def setUp(self):
        temporary = TemporaryDirectory(prefix="server-files-test-")
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name).resolve()
        self.root = self.base / "files"
        self.root.mkdir()

    def request(self, path, *, host=preview.FILES_HOST, language="zh-TW"):
        server, client = socket.socketpair()

        def handle_request():
            with server:
                preview.PreviewHandler(
                    server, ("127.0.0.1", 0), None,
                    directory=str(self.root), home_directory=self.root,
                    upload_token="fixture-token",
                )

        worker = threading.Thread(target=handle_request, daemon=True)
        worker.start()
        response = http.client.HTTPResponse(client)
        try:
            client.settimeout(5)
            client.sendall(
                f"GET {path} HTTP/1.1\r\nHost: {host}\r\n"
                f"Accept-Language: {language}\r\nConnection: close\r\n\r\n".encode("ascii")
            )
            response.begin()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            response.close()
            client.close()
            worker.join(5)
            self.assertFalse(worker.is_alive(), "HTTP request did not finish")

    def test_page_title_localized_controls_and_private_metadata(self):
        (self.root / "檔名.txt").write_text("example", encoding="utf-8")
        private = self.root / preview.TRASH_DIRECTORY
        private.mkdir()
        (private / preview.FILE_TAG_STORE).write_text('{"private-fixture": []}', encoding="utf-8")
        status, headers, body = self.request("/", language="en-US")
        self.assertEqual(status, 200)
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertIn(b"<title>Server file</title>", body)
        self.assertIn(b'lang="en"', body)
        self.assertIn("檔名.txt".encode(), body)
        self.assertNotIn(b"File name.txt", body)
        status, _, listing = self.request(f"/{preview.TRASH_DIRECTORY}/?hidden=1")
        self.assertEqual(status, 200)
        self.assertNotIn(preview.FILE_TAG_STORE.encode(), listing)
        status, _, body = self.request(f"/{preview.TRASH_DIRECTORY}/{preview.FILE_TAG_STORE}")
        self.assertEqual(status, 404)
        self.assertNotIn(b"private-fixture", body)
        self.assertEqual(self.request("/", host="example.invalid")[0], 400)

    def test_sorts_dates_sizes_and_kinds(self):
        fixture = (
            ("zeta.txt", b"x" * 14, 10),
            ("alpha.json", b"{}", 30),
            ("middle.csv", b"a,b\n" + b"1,2\n" * 15, 20),
        )
        for name, data, modified in fixture:
            path = self.root / name
            path.write_bytes(data)
            os.utime(path, (modified, modified))
        entries = list(preview.folder_entries(self.root, self.root))
        expected = {
            "newest": ["alpha.json", "middle.csv", "zeta.txt"],
            "oldest": ["zeta.txt", "middle.csv", "alpha.json"],
            "smallest": ["alpha.json", "zeta.txt", "middle.csv"],
            "largest": ["middle.csv", "zeta.txt", "alpha.json"],
            "kind-asc": ["middle.csv", "alpha.json", "zeta.txt"],
            "kind-desc": ["zeta.txt", "alpha.json", "middle.csv"],
        }
        for mode, names in expected.items():
            with self.subTest(mode=mode):
                ordered = sorted(entries, key=lambda entry: preview.order_key(entry, mode, self.root))
                self.assertEqual([entry.path.name for entry in ordered], names)

    def test_content_search_skips_binary_and_symlinks_and_caps_results(self):
        term = "fjord"
        (self.root / "found.txt").write_text("Fjord water", encoding="utf-8")
        (self.root / "binary.txt").write_bytes(b"fjord\0")
        outside = self.base / "outside.txt"
        outside.write_text(term, encoding="utf-8")
        (self.root / "alias.txt").symlink_to(outside)
        (self.root / "oversized.txt").write_text(term + " " * 50, encoding="utf-8")
        with patch.object(preview, "CONTENT_SEARCH_FILE_BYTES", 20):
            matches, truncated = preview.search_entries(
                self.root, term, "newest", content_search=preview.ContentSearch(term)
            )
        self.assertEqual([entry.path.name for entry in matches], ["found.txt"])
        self.assertFalse(truncated)
        (self.root / "another.txt").write_text(term, encoding="utf-8")
        with patch.object(preview, "SEARCH_LIMIT", 1):
            matches, truncated = preview.search_entries(
                self.root, term, "newest", content_search=preview.ContentSearch(term)
            )
        self.assertEqual(len(matches), 1)
        self.assertTrue(truncated)


if __name__ == "__main__":
    unittest.main()
