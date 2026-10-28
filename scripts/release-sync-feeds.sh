#!/bin/bash
# Commit only generated JSON files on top of current origin/main; never reset/force-push main.
set -euo pipefail
release_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$release_root"
release_tag="${1:-}"
release_mode="${2:-}"
if [[ ! "$release_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ || ( -n "$release_mode" && "$release_mode" != "--from-release" ) ]]; then
  echo "Usage: scripts/release-sync-feeds.sh vX.Y.Z [--from-release]" >&2
  exit 2
fi
release_temp="$(mktemp -d "${TMPDIR:-/tmp}/hongguo-feed-sync.XXXXXX")"
release_worktree="$release_temp/main"
cleanup_release_sync() {
  if [[ -d "$release_worktree" ]]; then git worktree remove --force "$release_worktree"; fi
  rm -rf "$release_temp"
}
trap cleanup_release_sync EXIT
# Recover against the tag configuration even if main already develops another version.
git show "$release_tag:Configuration/Release.json" > "$release_temp/Release.json"
release_repo="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["repository"])' "$release_temp/Release.json")"
release_version="${release_tag#v}"
guard_latest() {
  if python3 scripts/release-common.py guard-sync-latest "$release_repo" "$release_tag"; then
    return 0
  else
    release_status=$?
    if [[ "$release_status" == 42 ]]; then exit 0; else exit "$release_status"; fi
  fi
}
guard_latest
mkdir -p "$release_temp/distribution"
git show "$release_tag:distribution/icon.png" > "$release_temp/distribution/icon.png"
# Rehash actual remote bytes: a valid update.json alone does not prove an uploaded IPA.
gh release download "$release_tag" --repo "$release_repo" \
  --pattern "Hongguo-iOS-${release_version}-unsigned.ipa" --dir "$release_temp"
gh release download "$release_tag" --repo "$release_repo" --pattern '*.json' --dir "$release_temp/distribution"
python3 scripts/generate-feeds.py --config "$release_temp/Release.json" --tag "$release_tag" \
  --ipa "$release_temp/Hongguo-iOS-${release_version}-unsigned.ipa" --output "$release_temp/distribution" --check
if [[ "$release_mode" != "--from-release" ]]; then
  python3 scripts/generate-feeds.py --tag "$release_tag" --check >/dev/null
  for release_file in update.json source.json source-cn.json source-cn-backup.json; do
    cmp "distribution/$release_file" "$release_temp/distribution/$release_file"
  done
fi
for release_attempt in 1 2 3; do
  git fetch origin main
  git merge-base --is-ancestor "$release_tag" origin/main
  guard_latest
  git worktree add --detach "$release_worktree" origin/main
  # A concurrent higher-version feed must not be replaced by an older retry.
  if python3 - "$release_worktree/distribution/update.json" "$release_temp/distribution/update.json" <<'PY'
import json, re, sys
from pathlib import Path
def key(document):
    version = document['version']
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version):
        raise SystemExit('Malformed stable update version; refusing to overwrite it.')
    return tuple(map(int, version.split('.'))) + (int(document['build']),)
existing, proposed = map(Path, sys.argv[1:])
if existing.exists() and key(json.loads(existing.read_text())) > key(json.loads(proposed.read_text())):
    print('Stable feeds already describe a newer release; no downgrade performed.')
    sys.exit(42)
PY
  then
    :
  else
    release_status=$?
    if [[ "$release_status" == 42 ]]; then exit 0; else exit "$release_status"; fi
  fi
  mkdir -p "$release_worktree/distribution"
  for release_file in update.json source.json source-cn.json source-cn-backup.json; do
    cp "$release_temp/distribution/$release_file" "$release_worktree/distribution/$release_file"
  done
  git -C "$release_worktree" add -- distribution/update.json distribution/source.json distribution/source-cn.json distribution/source-cn-backup.json
  if git -C "$release_worktree" diff --cached --quiet; then
    echo "Stable feeds already match $release_tag."
    exit 0
  fi
  git -C "$release_worktree" -c user.name='github-actions[bot]' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
    commit -m "Update distribution feeds for $release_tag"
  if git -C "$release_worktree" push origin HEAD:main; then
    echo "Stable feeds synchronized for $release_tag."
    exit 0
  fi
  git worktree remove --force "$release_worktree"
  echo "main changed or push was rejected; retrying from current origin/main ($release_attempt/3)." >&2
done
echo "Unable to synchronize feeds after three attempts; no history was overwritten." >&2
exit 1
