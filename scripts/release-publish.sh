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
python3 scripts/generate-feeds.py --tag "$release_tag" --config-only >/dev/null
release_feeds=distribution
release_flags=(--verify-tag)
if [[ "$release_tag" == *-beta.* ]]; then
  release_feeds="build/beta-feeds/$release_tag"
  release_flags+=(--prerelease --latest=false)
fi
python3 scripts/generate-feeds.py --tag "$release_tag" --output "$release_feeds" --check
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
sections = config.get('releaseNotesSections')
if isinstance(sections, dict) and sections:
    parts = []
    for group in ('新增', '优化', '修复'):
        items = sections.get(group)
        if items:
            parts.append('### ' + group + '\n' + '\n'.join('- ' + item for item in items))
    notes = '\n\n'.join(parts) + '\n'
else:
    notes = '\n'.join('- ' + item for item in config['releaseNotes']) + '\n'
Path('build').mkdir(exist_ok=True)
Path('build/release-notes.md').write_text(notes)
PY
if [[ "$release_feeds" == distribution ]]; then
  python3 scripts/release-common.py latest-flag "$release_repo" "$release_tag" >/dev/null
fi
release_assets=("$release_ipa" "${release_ipa}.sha256" "$release_source" "${release_source}.sha256"
  "$release_feeds/update.json" "$release_feeds/source.json" "$release_feeds/source-cn.json" "$release_feeds/source-cn-backup.json")
release_uploads=("${release_assets[@]}")
if [[ "$release_feeds" != distribution ]]; then
  release_uploads[0]="$release_ipa#红果 iOS 测试版（无签名 iPhone IPA）"
fi
gh release create "$release_tag" --repo "$release_repo" --draft "${release_flags[@]}" \
  --title "${release_tag}" --notes-file build/release-notes.md \
  "${release_uploads[@]}"
if [[ "$release_feeds" == distribution ]]; then
  release_latest="$(python3 scripts/release-common.py latest-flag "$release_repo" "$release_tag")"
  release_flags=("--latest=$release_latest")
else
  gh release view "$release_tag" --repo "$release_repo" --json tagName,isDraft,isPrerelease,assets > build/beta-draft.json
  python3 - "$release_tag" "${release_assets[@]}" <<'PY'
import hashlib, json, sys
from pathlib import Path
draft = json.loads(Path("build/beta-draft.json").read_text())
if draft["tagName"] != sys.argv[1] or not (draft["isDraft"] and draft["isPrerelease"]):
    sys.exit("Expected a prerelease draft for the selected tag.")
remote = {a["name"]: (a["size"], a["digest"]) for a in draft["assets"] if a["state"].lower() == "uploaded"}
local = {p.name: (p.stat().st_size, "sha256:" + hashlib.sha256(p.read_bytes()).hexdigest())
         for p in map(Path, sys.argv[2:])}
if remote != local:
    sys.exit("The uploaded draft assets do not match the prepared prerelease files.")
PY
fi
gh release edit "$release_tag" --repo "$release_repo" --draft=false "${release_flags[@]}"
