#!/bin/bash
# Explicitly publish the already prepared package. Never replaces an existing release.
set -euo pipefail
release_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$release_root"
release_tag="${1:-}"
if [[ -z "$release_tag" ]]; then
  echo "Usage: scripts/release-publish.sh vX.Y.Z" >&2
  exit 2
fi
python3 scripts/generate-feeds.py --tag "$release_tag" --check
release_repo="$(python3 -c 'import json;print(json.load(open("Configuration/Release.json"))["repository"])')"
release_version="$(python3 -c 'import json;print(json.load(open("Configuration/Release.json"))["version"])')"
release_ipa="dist/Hongguo-iOS-${release_version}-unsigned.ipa"
release_source="dist/Hongguo-iOS-${release_version}-source.zip"
python3 scripts/release-common.py require-missing "$release_repo" "$release_tag"
python3 - <<'PY'
import hashlib, json, zipfile
from pathlib import Path
config = json.loads(Path('Configuration/Release.json').read_text())
for suffix in ('unsigned.ipa', 'source.zip'):
    item = Path(f"dist/Hongguo-iOS-{config['version']}-{suffix}")
    expected = hashlib.sha256(item.read_bytes()).hexdigest() + '  ' + item.name
    if item.with_name(item.name + '.sha256').read_text().strip() != expected:
        raise SystemExit('Release checksum file does not match ' + item.name)
with zipfile.ZipFile(f"dist/Hongguo-iOS-{config['version']}-source.zip") as archive:
    assert archive.testzip() is None, 'Source archive is corrupt'
    assert json.loads(archive.read('hongguo-ios/Configuration/Release.json')) == config, 'Source archive is for another version'
notes = '\n'.join('- ' + item for item in config['releaseNotes'])
Path('build').mkdir(exist_ok=True)
Path('build/release-notes.md').write_text(f"红果 iOS {config['version']}（build {config['build']}）\n\n{notes}\n\n未签名 IPA，需要自行签名后安装。最低 iOS {config['minimumOSVersion']}。\n\n附带对应版本源码及 SHA-256 校验文件。\n")
PY
# Check before creating the draft, and again immediately before making it public.
python3 scripts/release-common.py latest-flag "$release_repo" "$release_tag" >/dev/null
gh release create "$release_tag" --repo "$release_repo" --verify-tag --draft \
  --title "红果 iOS ${release_version}" --notes-file build/release-notes.md \
  "$release_ipa" "${release_ipa}.sha256" "$release_source" "${release_source}.sha256" \
  distribution/update.json distribution/source.json distribution/source-cn.json distribution/source-cn-backup.json
release_latest="$(python3 scripts/release-common.py latest-flag "$release_repo" "$release_tag")"
gh release edit "$release_tag" --repo "$release_repo" --draft=false "--latest=$release_latest"
