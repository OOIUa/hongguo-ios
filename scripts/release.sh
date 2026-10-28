#!/bin/bash
# Prepare a validated release locally. Publication and Git pushes are separate explicit steps.
set -euo pipefail
release_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$release_root"
release_tag="${1:-}"
release_mode="${2:-}"
if [[ -z "$release_tag" || ( -n "$release_mode" && "$release_mode" != "--skip-build" ) ]]; then
  echo "Usage: scripts/release.sh vX.Y.Z [--skip-build]" >&2
  exit 2
fi
python3 scripts/generate-feeds.py --tag "$release_tag" --config-only >/dev/null
python3 scripts/test-feeds.py
if [[ "$release_mode" != "--skip-build" ]]; then
  bash scripts/build-unsigned.sh
fi
python3 scripts/generate-feeds.py --tag "$release_tag"
python3 scripts/generate-feeds.py --tag "$release_tag" --check
python3 scripts/package-source.py
python3 - <<'PY'
import hashlib, json
from pathlib import Path
config = json.loads(Path('Configuration/Release.json').read_text())
ipa = Path(f"dist/Hongguo-iOS-{config['version']}-unsigned.ipa")
digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
ipa.with_name(ipa.name + '.sha256').write_text(digest + '  ' + ipa.name + '\n')
notes = '\n'.join('- ' + item for item in config['releaseNotes'])
Path('build').mkdir(exist_ok=True)
Path('build/release-notes.md').write_text(f"红果 iOS {config['version']}（build {config['build']}）\n\n{notes}\n\n未签名 IPA，需要自行签名后安装。最低 iOS {config['minimumOSVersion']}。\n")
print(f"Prepared {ipa.name}; feeds are in distribution/. No release or commit was created.")
PY
