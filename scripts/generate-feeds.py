#!/usr/bin/env python3
"""Generate QNQ feeds and the update manifest only from a validated unsigned device IPA."""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import plistlib
import re
import stat
import struct
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parent.parent
BUNDLE_ID = "com.ooiua.hongguo.ios"
MIRRORS = {"gh-proxy": "https://gh-proxy.com/", "ghfast": "https://ghfast.top/"}
GENERATED = ("update.json", "source.json", "source-cn.json", "source-cn-backup.json")


class ValidationError(ValueError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


def read_config(path: Path, tag: str | None = None) -> dict:
    config = json.loads(path.read_text(encoding="utf-8"))
    require(isinstance(config, dict), "Release.json must be an object")
    require(isinstance(config.get("version"), str) and re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", config["version"]) is not None,
            "version must be a stable numeric X.Y.Z version")
    require(type(config.get("build")) is int and config["build"] > 0, "build must be a positive integer")
    require(isinstance(config.get("repository"), str) and re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", config["repository"]) is not None,
            "repository must be owner/name")
    require(isinstance(config.get("minimumOSVersion"), str) and re.fullmatch(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?", config["minimumOSVersion"]) is not None,
            "minimumOSVersion must be a numeric OS version")
    require(isinstance(config.get("releaseNotes"), list) and bool(config["releaseNotes"]) and
            all(isinstance(item, str) and item.strip() for item in config["releaseNotes"]), "releaseNotes must contain nonempty strings")
    if tag is not None:
        require(tag == "v" + config["version"], "Tag does not match Configuration/Release.json")
    return config


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def inspect_macho(binary: bytes, expected_minimum: str) -> None:
    require(len(binary) >= 32, "Missing/truncated Mach-O header")
    magic, cpu, _, file_type, commands, command_bytes, _, _ = struct.unpack_from("<8I", binary)
    require(magic == 0xFEEDFACF and cpu == 0x0100000C and file_type == 2, "Expected a thin arm64 device executable")
    require(commands <= 4096 and command_bytes <= len(binary) - 32, "Invalid Mach-O load-command table")
    position, device_platform = 32, False
    expected = tuple(int(item) for item in expected_minimum.split("."))
    expected = (expected + (0, 0))[:3]
    for _ in range(commands):
        require(position + 8 <= 32 + command_bytes, "Truncated Mach-O command")
        command, size = struct.unpack_from("<II", binary, position)
        require(size >= 8 and size % 4 == 0 and size <= 32 + command_bytes - position, "Invalid Mach-O command length")
        require(command != 0x1D, "Signed IPA rejected: LC_CODE_SIGNATURE is present")
        if command == 0x32:  # LC_BUILD_VERSION
            require(size >= 24, "Truncated LC_BUILD_VERSION")
            platform, minimum = struct.unpack_from("<II", binary, position + 8)
            require(platform == 2, "Simulator/non-iOS executable rejected")
            actual = ((minimum >> 16) & 0xFFFF, (minimum >> 8) & 0xFF, minimum & 0xFF)
            require(actual == expected, "Mach-O deployment target disagrees with Release.json")
            device_platform = True
        position += size
    require(position == 32 + command_bytes and device_platform, "Missing/invalid device build-version command")


def validate_ipa(path: Path, config: dict, *, use_codesign: bool = True) -> dict:
    require(path.is_file(), "IPA file does not exist")
    require(path.name == f"Hongguo-iOS-{config['version']}-unsigned.ipa", "IPA filename disagrees with release version")
    require(path.stat().st_size > 0, "IPA is empty")
    try:
        with zipfile.ZipFile(path) as archive:
            entries = archive.infolist()
            names = [entry.filename for entry in entries]
            require(len(names) == len(set(names)), "Duplicate archive paths rejected")
            require(len(names) <= 20000 and sum(entry.file_size for entry in entries) <= 1024 * 1024 * 1024, "IPA archive exceeds validation limits")
            for entry in entries:
                item = PurePosixPath(entry.filename)
                require(not item.is_absolute() and ".." not in item.parts and "\\" not in entry.filename, "Unsafe archive path")
                require(not stat.S_ISLNK(entry.external_attr >> 16), "Archive symlinks rejected")
                require("_CodeSignature" not in item.parts and item.name != "embedded.mobileprovision", "Signed/provisioned bundle rejected")
            require(archive.testzip() is None, "IPA archive CRC verification failed")
            info_names = [name for name in names if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name)]
            require(info_names == ["Payload/Hongguo.app/Info.plist"], "Expected exactly Payload/Hongguo.app")
            prefix = "Payload/Hongguo.app/"
            info = plistlib.loads(archive.read(prefix + "Info.plist"))
            require(info.get("CFBundleIdentifier") == BUNDLE_ID, "Unexpected bundle identifier")
            require(info.get("CFBundleShortVersionString") == config["version"], "IPA version disagrees with Release.json")
            require(info.get("CFBundleVersion") == str(config["build"]), "IPA build disagrees with Release.json")
            require(info.get("MinimumOSVersion") == config["minimumOSVersion"], "IPA minimum OS disagrees with Release.json")
            require(info.get("CFBundleSupportedPlatforms") == ["iPhoneOS"], "Expected iPhoneOS package")
            executable = info.get("CFBundleExecutable")
            require(isinstance(executable, str) and re.fullmatch(r"[A-Za-z0-9_.-]+", executable) is not None, "Invalid bundle executable")
            for resource in ("PureSign.js", "BufferRuntime.js", "Assets.car"):
                require(prefix + resource in names, f"Required packaged resource missing: {resource}")
            inspect_macho(archive.read(prefix + executable), config["minimumOSVersion"])
            if use_codesign and sys.platform == "darwin":
                with tempfile.TemporaryDirectory(prefix="hongguo-feed-verify-") as folder:
                    archive.extractall(folder)
                    command = subprocess.run(["/usr/bin/codesign", "-dv", str(Path(folder) / prefix)], capture_output=True, text=True, check=False)
                    require(command.returncode != 0 and "not signed at all" in command.stderr,
                            "codesign did not confirm an unsigned app")
    except (zipfile.BadZipFile, KeyError, plistlib.InvalidFileException, struct.error, OSError) as error:
        raise ValidationError("Invalid IPA: " + type(error).__name__) from error
    return {"version": config["version"], "build": config["build"], "minimumOSVersion": config["minimumOSVersion"],
            "bundleIdentifier": BUNDLE_ID, "sha256": file_sha256(path), "size": path.stat().st_size, "unsigned": True}


def timestamp(value: str | None = None) -> str:
    if value is None:
        return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise ValidationError("publishedAt must be an ISO8601 timestamp") from error
    require(parsed.utcoffset() is not None, "publishedAt must include a timezone")
    return parsed.astimezone(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def make_documents(config: dict, actual: dict, published_at: str) -> dict[str, dict]:
    version, repository = config["version"], config["repository"]
    download = f"https://github.com/{repository}/releases/download/v{version}/Hongguo-iOS-{version}-unsigned.ipa"
    raw = f"https://raw.githubusercontent.com/{repository}/main/distribution/"
    mirrors = {name: prefix + download for name, prefix in MIRRORS.items()}
    update = {"version": version, "build": config["build"], "minimumOSVersion": config["minimumOSVersion"],
              "releaseNotes": config["releaseNotes"], "publishedAt": published_at, "downloadURL": download,
              "sha256": actual["sha256"], "size": actual["size"], "mirrors": mirrors}
    documents = {"update.json": update}
    routes = [("source.json", "GitHub 直连", "", download),
              ("source-cn.json", "国内加速", MIRRORS["gh-proxy"], mirrors["gh-proxy"]),
              ("source-cn-backup.json", "国内备用加速", MIRRORS["ghfast"], mirrors["ghfast"])]
    for name, title, proxy, address in routes:
        icon = proxy + raw + "icon.png"
        app = {"name": "红果独立版", "type": "1", "bundleIdentifier": BUNDLE_ID,
               "version": version, "build": config["build"], "minimumOSVersion": config["minimumOSVersion"],
               "versionDate": published_at, "versionDescription": "\n".join(config["releaseNotes"]) + "\n未签名 IPA，需使用本人的证书签名后安装。",
               "lock": "0", "downloadURL": address, "isLanZouCloud": "0", "iconURL": icon,
               "tintColor": "C94426", "size": str(actual["size"]), "sha256": actual["sha256"]}
        documents[name] = {"name": "红果 iOS · " + title,
                           "message": "项目维护者发布的未签名 IPA；需要自行签名安装。" + ("加速服务由第三方提供。" if proxy else ""),
                           "identifier": repository.lower().replace("/", ".") + "." + name.removesuffix(".json"),
                           "sourceURL": proxy + raw + name, "sourceicon": icon, "apps": [app]}
    return documents


def generate(config_path: Path, ipa: Path, output: Path, *, tag: str | None = None, published_at: str | None = None,
             check: bool = False, use_codesign: bool = True) -> dict:
    config = read_config(config_path, tag)
    actual = validate_ipa(ipa, config, use_codesign=use_codesign)
    icon = output / "icon.png"
    require(icon.is_file() and icon.read_bytes().startswith(b"\x89PNG\r\n\x1a\n"), "distribution/icon.png must be a PNG")
    if check and published_at is None:
        published_at = json.loads((output / "update.json").read_text(encoding="utf-8"))["publishedAt"]
    documents = make_documents(config, actual, timestamp(published_at))
    if check:
        for name, expected in documents.items():
            require(json.loads((output / name).read_text(encoding="utf-8")) == expected, "Generated metadata differs from validated IPA/config: " + name)
    else:
        output.mkdir(parents=True, exist_ok=True)
        for name, document in documents.items():
            data = json.dumps(document, ensure_ascii=False, indent=2) + "\n"
            temporary = output / (name + ".tmp")
            temporary.write_text(data, encoding="utf-8")
            os.replace(temporary, output / name)
    return actual


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=ROOT / "Configuration/Release.json")
    parser.add_argument("--ipa", type=Path)
    parser.add_argument("--output", type=Path, default=ROOT / "distribution")
    parser.add_argument("--tag")
    parser.add_argument("--published-at")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--config-only", action="store_true")
    args = parser.parse_args()
    try:
        config = read_config(args.config, args.tag)
        if args.config_only:
            print(json.dumps(config, ensure_ascii=False)); return
        ipa = args.ipa or ROOT / f"dist/Hongguo-iOS-{config['version']}-unsigned.ipa"
        actual = generate(args.config, ipa, args.output, tag=args.tag, published_at=args.published_at, check=args.check)
        print(json.dumps(actual, ensure_ascii=False, indent=2))
    except (ValidationError, ValueError, OSError) as error:
        parser.exit(1, f"Feed validation failed: {error}\n")


if __name__ == "__main__":
    main()
