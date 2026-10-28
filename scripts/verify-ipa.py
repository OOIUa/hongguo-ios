#!/usr/bin/env python3
"""Verify the packaged device binary, resources, signing state and deployment target."""
import hashlib
import json
import plistlib
import struct
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

root = Path(__file__).resolve().parent.parent
release = json.loads((root / 'Configuration/Release.json').read_text())
ipa = Path(sys.argv[1]) if len(sys.argv) > 1 else root / f'dist/Hongguo-iOS-{release["version"]}-unsigned.ipa'
with zipfile.ZipFile(ipa) as archive:
    assert archive.testzip() is None, 'IPA archive is corrupt'
    prefix = 'Payload/Hongguo.app/'
    names = archive.namelist()
    for name in names:
        assert not name.startswith('/') and '..' not in Path(name).parts, 'Invalid archive path'
    info = plistlib.loads(archive.read(prefix + 'Info.plist'))
    assert info['CFBundleIdentifier'] == 'com.ooiua.hongguo.ios'
    assert info['CFBundleSupportedPlatforms'] == ['iPhoneOS']
    assert info['MinimumOSVersion'] == release['minimumOSVersion']
    assert info['CFBundleShortVersionString'] == release['version'], 'IPA version differs from Release.json'
    assert info['CFBundleVersion'] == str(release['build']), 'IPA build differs from Release.json'
    assert prefix + 'PureSign.js' in names and prefix + 'BufferRuntime.js' in names
    assert prefix + 'Assets.car' in names
    assert not any(name.endswith('embedded.mobileprovision') for name in names)
    binary = archive.read(prefix + info['CFBundleExecutable'])
    magic, cpu = struct.unpack_from('<II', binary)
    assert magic == 0xFEEDFACF and cpu == 0x0100000C, 'Expected a device arm64 Mach-O binary'
    with tempfile.TemporaryDirectory(prefix='hongguo-ipa-verify-') as tmp:
        archive.extractall(tmp)
        result = subprocess.run(['/usr/bin/codesign', '-dv', str(Path(tmp) / 'Payload/Hongguo.app')], capture_output=True, text=True)
        assert result.returncode != 0 and 'not signed at all' in result.stderr, 'Expected an unsigned app bundle'
report = {
    'ipa': ipa.name, 'bytes': ipa.stat().st_size, 'version': info['CFBundleShortVersionString'],
    'build': info['CFBundleVersion'], 'bundle_identifier': info['CFBundleIdentifier'],
    'minimum_ios': info['MinimumOSVersion'], 'platform': 'iPhoneOS', 'architecture': 'arm64',
    'unsigned': True, 'signing_resources_present': True,
    'sha256': hashlib.sha256(ipa.read_bytes()).hexdigest()
}
print(json.dumps(report, ensure_ascii=False, indent=2))
