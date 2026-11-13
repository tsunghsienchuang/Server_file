from contextlib import nullcontext
import errno
import http.client
import json
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

    def request(self, path, *, host=preview.FILES_HOST, language="zh-TW", method="GET", headers=None):
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
            request_headers = {"Host": host, "Accept-Language": language, "Connection": "close", **(headers or {})}
            request = f"{method} {path} HTTP/1.1\r\n"
            request += "".join(f"{name}: {value}\r\n" for name, value in request_headers.items())
            client.sendall((request + "\r\n").encode("ascii"))
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

    def test_name_sort_applies_natural_order_before_search_limit(self):
        names = ["Chapter1.txt", "chapter2.txt", "chapter10.txt"]
        for name in reversed(names):
            (self.root / name).touch()
        with patch.object(preview, "SEARCH_LIMIT", 2):
            for mode, expected in (("name-asc", names[:2]), ("name-desc", names[::-1][:2])):
                status, _, body = self.request(f"/?q=chapter&sort={mode}", language="en-US")
                self.assertEqual(status, 200)
                self.assertEqual([name for name in names if name.encode() in body],
                                 [name for name in names if name in expected])
                self.assertLess(body.index(expected[0].encode()), body.index(expected[1].encode()))

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

    def move(self, source, destination, mtime, **headers):
        target = preview.entry_href(destination, True) if destination.parts else "/"
        request_headers = {
            "Origin": f"http://{preview.FILES_HOST}",
            "X-Preview-Token": "fixture-token",
            "X-Preview-Destination": target,
            "X-Preview-File-Mtime": str(mtime),
            **headers,
        }
        status, _, body = self.request(preview.entry_href(source, False) + "?move=1", method="POST",
                                       headers=request_headers)
        return status, json.loads(body)

    def test_move_and_move_out_preserve_tags_with_native_and_nfs_paths(self):
        directory = Path("Archive folder")
        (self.root / directory).mkdir()
        for unsupported in (None, errno.ENOSYS, errno.EINVAL):
            with self.subTest(unsupported=unsupported):
                name = f"檔案 {unsupported} %.txt"
                relative = Path(name)
                original = self.root / relative
                original.write_text("fictional data", encoding="utf-8")
                modified = original.stat().st_mtime_ns
                preview.update_file_tag(self.root, relative, "green", True)
                force_fallback = (nullcontext() if unsupported is None else
                                  patch.object(preview, "rename_without_replacement",
                                               side_effect=OSError(unsupported, "no native no-replace")))
                with force_fallback:
                    status, payload = self.move(relative, directory, modified)
                    self.assertEqual(status, 200, payload)
                    moved = directory / name
                    self.assertEqual(payload["url"], preview.entry_href(moved, False))
                    self.assertEqual(payload["path"], str(self.root / moved))
                    self.assertFalse(original.exists())
                    self.assertEqual((self.root / moved).read_text(encoding="utf-8"), "fictional data")
                    self.assertEqual(preview.read_file_tags(self.root, moved), ("green",))
                    self.assertEqual(preview.read_file_tags(self.root, relative), ())
                    self.assertEqual(self.move(moved, Path(), modified)[0], 200)
                    self.assertTrue(original.exists())
                    self.assertEqual(preview.read_file_tags(self.root, relative), ("green",))

    def test_move_rejects_collision_unsafe_path_and_stale_request(self):
        relative = Path("notes.txt")
        original = self.root / relative
        original.write_text("original", encoding="utf-8")
        modified = original.stat().st_mtime_ns
        directory = Path("archive")
        (self.root / directory).mkdir()
        occupied = self.root / directory / relative
        self.assertEqual(self.move(relative, Path(), modified)[0], 409)
        self.assertEqual(self.move(relative, directory, modified + 1)[0], 409)
        self.assertEqual(self.move(relative, directory, modified, Origin="http://example.invalid")[0], 403)
        self.assertEqual(self.move(relative, Path(preview.TRASH_DIRECTORY), modified)[0], 403)
        self.assertEqual(self.move(relative, directory, modified, **{"X-Preview-Destination": "/../"})[0], 400)
        (self.root / "folder-alias").symlink_to(self.root / directory)
        self.assertEqual(self.move(relative, Path("folder-alias"), modified)[0], 404)
        occupied.symlink_to(self.base / "outside.txt")
        self.assertEqual(self.move(relative, directory, modified)[0], 409)
        self.assertTrue(occupied.is_symlink())
        occupied.unlink()
        os.link(original, occupied)
        self.assertEqual(self.move(relative, directory, modified)[0], 409)
        self.assertEqual(occupied.stat().st_ino, original.stat().st_ino)
        occupied.unlink()
        with patch.object(preview, "rename_without_replacement", side_effect=OSError(errno.EXDEV, "cross-device")):
            self.assertEqual(self.move(relative, directory, modified)[0], 409)
        self.assertFalse(occupied.exists())
        self.assertEqual(original.read_text(encoding="utf-8"), "original")

    def test_move_fallback_restores_source_if_destination_appears(self):
        source = Path("notes.txt")
        original = self.root / source
        original.write_text("original", encoding="utf-8")
        modified = original.stat().st_mtime_ns
        directory = Path("archive")
        destination = self.root / directory
        destination.mkdir()
        destination_inode = destination.stat().st_ino
        native_link = os.link

        def link_after_collision(name, new_name, **options):
            if name == "file" and os.fstat(options["dst_dir_fd"]).st_ino == destination_inode:
                (destination / source.name).write_text("occupied", encoding="utf-8")
            return native_link(name, new_name, **options)

        with patch.object(preview, "rename_without_replacement", side_effect=OSError(errno.EINVAL, "unsupported")):
            with patch.object(preview.os, "link", side_effect=link_after_collision):
                self.assertEqual(self.move(source, directory, modified)[0], 409)
        self.assertEqual(original.read_text(encoding="utf-8"), "original")
        self.assertEqual((destination / source.name).read_text(encoding="utf-8"), "occupied")
        self.assertFalse(any(self.root.glob(preview.RENAME_STAGE_PREFIX + "*")))


if __name__ == "__main__":
    unittest.main()
