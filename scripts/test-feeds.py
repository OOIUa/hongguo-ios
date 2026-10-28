#!/usr/bin/env python3
"""Offline feed/IPA validation tests. Synthetic Mach-O fixtures never bypass CLI validation."""
from __future__ import annotations

import base64
import importlib.util
import json
import plistlib
import struct
import tempfile
import unittest
from unittest import mock
import zipfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("generate_feeds", Path(__file__).with_name("generate-feeds.py"))
feeds = importlib.util.module_from_spec(spec)
spec.loader.exec_module(feeds)
release_spec = importlib.util.spec_from_file_location("release_common", Path(__file__).with_name("release-common.py"))
release = importlib.util.module_from_spec(release_spec)
release_spec.loader.exec_module(release)


class FeedTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="hongguo-feed-tests-")
        self.root = Path(self.temporary.name)
        self.config = {"version": "0.1.1", "build": 2, "repository": "OOIUa/hongguo-ios", "minimumOSVersion": "17.0", "releaseNotes": ["合成发布测试"]}
        self.config_path = self.root / "Release.json"
        self.config_path.write_text(json.dumps(self.config), encoding="utf-8")
        self.output = self.root / "distribution"
        self.output.mkdir()
        self.output.joinpath("icon.png").write_bytes(base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII="))
        self.ipa = self.root / "Hongguo-iOS-0.1.1-unsigned.ipa"

    def tearDown(self):
        self.temporary.cleanup()

    def package(self, changes=None, *, signature=False, profile=False, signature_directory=False, platform=2, deployment=17 << 16, corrupt_path=False):
        info = {"CFBundleIdentifier": feeds.BUNDLE_ID, "CFBundleShortVersionString": "0.1.1", "CFBundleVersion": "2",
                "MinimumOSVersion": "17.0", "CFBundleSupportedPlatforms": ["iPhoneOS"], "CFBundleExecutable": "Hongguo"}
        info.update(changes or {})
        command = struct.pack("<6I", 0x32, 24, platform, deployment, 0, 0)
        if signature:
            command += struct.pack("<4I", 0x1D, 16, 0, 0)
        binary = struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, 2, 2 if signature else 1, len(command), 0, 0) + command
        with zipfile.ZipFile(self.ipa, "w") as archive:
            prefix = "Payload/Hongguo.app/"
            archive.writestr(prefix + "Info.plist", plistlib.dumps(info))
            archive.writestr(prefix + "Hongguo", binary)
            for resource in ("PureSign.js", "BufferRuntime.js", "Assets.car"):
                archive.writestr(prefix + resource, b"synthetic test resource")
            if profile:
                archive.writestr(prefix + "embedded.mobileprovision", b"synthetic")
            if signature_directory:
                archive.writestr(prefix + "_CodeSignature/CodeResources", b"synthetic")
            if corrupt_path:
                archive.writestr("../../escape", b"synthetic")

    def generate(self, **options):
        return feeds.generate(self.config_path, self.ipa, self.output, tag="v0.1.1", published_at="2026-10-28T12:00:00Z", use_codesign=False, **options)

    def test_consistent_actual_metadata_and_urls(self):
        self.package()
        report = self.generate()
        update = json.loads((self.output / "update.json").read_text())
        self.assertEqual(update["sha256"], feeds.file_sha256(self.ipa))
        self.assertEqual(update["size"], self.ipa.stat().st_size)
        self.assertEqual(update["build"], 2)
        self.assertTrue(report["unsigned"])
        direct = "https://github.com/OOIUa/hongguo-ios/releases/download/v0.1.1/Hongguo-iOS-0.1.1-unsigned.ipa"
        for filename, prefix in [("source.json", ""), ("source-cn.json", "https://gh-proxy.com/"), ("source-cn-backup.json", "https://ghfast.top/")]:
            source = json.loads((self.output / filename).read_text())
            app = source["apps"][0]
            self.assertEqual(app["downloadURL"], prefix + direct)
            self.assertEqual(source["sourceURL"], prefix + "https://raw.githubusercontent.com/OOIUa/hongguo-ios/main/distribution/" + filename)
            self.assertEqual(app["iconURL"], prefix + "https://raw.githubusercontent.com/OOIUa/hongguo-ios/v0.1.1/distribution/icon.png")
            for key in ("version", "build", "minimumOSVersion", "sha256"):
                self.assertEqual(app[key], update[key])
            self.assertEqual(int(app["size"]), update["size"])
            self.assertEqual(app["versionDate"], update["publishedAt"])
        self.generate(check=True)

    def test_metadata_drift_is_rejected(self):
        for changes in [{"CFBundleShortVersionString": "0.1.0"}, {"CFBundleVersion": "1"}, {"MinimumOSVersion": "16.0"},
                        {"CFBundleIdentifier": "invalid.bundle"}, {"CFBundleSupportedPlatforms": ["iPhoneSimulator"]}]:
            with self.subTest(changes=changes):
                self.package(changes)
                with self.assertRaises(feeds.ValidationError):
                    self.generate()
                self.assertFalse((self.output / "update.json").exists())

    def test_signed_and_provisioned_packages_are_rejected(self):
        for options in [{"signature": True}, {"profile": True}, {"signature_directory": True}]:
            with self.subTest(options=options):
                self.package(**options)
                with self.assertRaises(feeds.ValidationError):
                    self.generate()

    def test_bad_archive_traversal_and_binary_target_are_rejected(self):
        for options in [{"corrupt_path": True}, {"platform": 7}, {"deployment": 16 << 16}]:
            with self.subTest(options=options):
                self.package(**options)
                with self.assertRaises(feeds.ValidationError):
                    self.generate()
        self.ipa.write_bytes(b"not a zip")
        with self.assertRaises(feeds.ValidationError):
            self.generate()

    def test_source_tampering_fails_check_without_changing_files(self):
        self.package(); self.generate()
        path = self.output / "source-cn.json"
        tampered = json.loads(path.read_text())
        tampered["apps"][0]["sha256"] = "0" * 64
        path.write_text(json.dumps(tampered))
        original = path.read_bytes()
        with self.assertRaises(feeds.ValidationError):
            self.generate(check=True)
        self.assertEqual(path.read_bytes(), original)

    def test_tag_config_filename_and_timestamp_are_validated(self):
        self.package()
        with self.assertRaises(feeds.ValidationError):
            feeds.read_config(self.config_path, "v0.1.2")
        with self.assertRaises(feeds.ValidationError):
            feeds.timestamp("2026-10-28T12:00:00")
        renamed = self.ipa.with_name("wrong.ipa")
        self.ipa.rename(renamed)
        with self.assertRaises(feeds.ValidationError):
            feeds.validate_ipa(renamed, self.config, use_codesign=False)
        self.assertEqual(feeds.timestamp("2026-10-28T08:00:00-04:00"), "2026-10-28T12:00:00Z")

    def test_failed_ipa_validation_does_not_overwrite_published_metadata(self):
        self.package(); self.generate()
        before = {name: (self.output / name).read_bytes() for name in feeds.GENERATED}
        self.package({"CFBundleVersion": "99"})
        with self.assertRaises(feeds.ValidationError):
            self.generate()
        self.assertEqual(before, {name: (self.output / name).read_bytes() for name in feeds.GENERATED})

    def test_rest_only_a_real_404_means_release_absent(self):
        def response(status, body, code):
            return mock.Mock(stdout=f"HTTP/2.0 {status} Test\r\nContent-Type: application/json\r\n\r\n{body}", returncode=code)
        with mock.patch.object(release.subprocess, "run", return_value=response(404, '{"message":"Not Found"}', 1)):
            self.assertIsNone(release.api_json("repos/example/test/releases/latest", missing_ok=True))
        for reply in [response(401, '{}', 1), response(500, '{}', 1), mock.Mock(stdout="", returncode=1)]:
            with mock.patch.object(release.subprocess, "run", return_value=reply):
                with self.assertRaises(RuntimeError):
                    release.api_json("repos/example/test/releases/latest", missing_ok=True)
        with mock.patch.object(release.subprocess, "run", return_value=response(200, '{"tag_name":"v0.1.1"}', 0)):
            self.assertEqual(release.latest("example/test")["tag_name"], "v0.1.1")

    def test_version_comparison_is_numeric(self):
        self.assertGreater(release.version("v0.1.10"), release.version("v0.1.9"))
        self.assertGreater(release.version("v1.0.0"), release.version("v0.99.99"))
        for bad in ["v0.1", "v0.1.1-beta", "../v0.1.1", "v0.1.1\n"]:
            with self.assertRaises(ValueError):
                release.version(bad)

    def test_stable_sync_rejects_draft_and_prerelease_assets(self):
        for draft, prerelease in [(True, False), (False, True), (True, True)]:
            with mock.patch.object(release, "api_json", return_value={"draft": draft, "prerelease": prerelease, "tag_name": "v0.1.1"}):
                with self.assertRaises(RuntimeError):
                    release.published_release("example/test", "v0.1.1")
        with mock.patch.object(release, "api_json", return_value={"draft": False, "prerelease": False, "tag_name": "v0.1.1"}):
            self.assertEqual(release.published_release("example/test", "v0.1.1")["tag_name"], "v0.1.1")


if __name__ == "__main__":
    unittest.main(verbosity=2)
