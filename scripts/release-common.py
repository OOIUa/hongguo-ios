#!/usr/bin/env python3
"""Small REST-only release helpers. A transport/auth failure is never treated as a missing release."""
import json
import re
import subprocess
import sys
from urllib.parse import quote


def api_json(endpoint, missing_ok=False):
    reply = subprocess.run(['gh', 'api', '--include', endpoint], capture_output=True, text=True, check=False)
    text = reply.stdout.replace('\r\n', '\n')
    header, separator, body = text.partition('\n\n')
    match = re.match(r'HTTP/\S+\s+([0-9]{3})', header)
    if not match:
        raise RuntimeError('GitHub REST transport/authentication failed; release state is unknown')
    status = int(match.group(1))
    if status == 404 and missing_ok:
        return None
    if reply.returncode != 0 or status != 200:
        raise RuntimeError('GitHub REST returned HTTP ' + str(status))
    if not separator:
        raise RuntimeError('GitHub REST response was incomplete')
    return json.loads(body)


def version(tag):
    match = re.fullmatch(r'v([0-9]+)\.([0-9]+)\.([0-9]+)', tag)
    if not match:
        raise ValueError('Expected stable release tag vX.Y.Z')
    return tuple(int(item) for item in match.groups())


def latest(repo):
    return api_json('repos/' + repo + '/releases/latest', missing_ok=True)


def published_release(repo, tag):
    target = api_json('repos/' + repo + '/releases/tags/' + quote(tag, safe=''))
    if target.get('draft') is not False or target.get('prerelease') is not False or target.get('tag_name') != tag:
        raise RuntimeError('Stable feeds require an already public, non-prerelease release. Verify/publish a draft before attempting feed synchronization.')
    return target


def main():
    operation, repo, tag = sys.argv[1:]
    version(tag)
    if operation == 'require-missing':
        existing = api_json('repos/' + repo + '/releases/tags/' + quote(tag, safe=''), missing_ok=True)
        if existing is not None:
            if existing.get('draft'):
                raise RuntimeError('A draft already exists. Inspect its assets and failure log, then publish or remove that draft before retrying. Drafts cannot back stable feeds.')
            raise RuntimeError('A public release already exists. Do not overwrite assets; use release-sync-feeds.sh TAG --from-release to recover feed synchronization.')
    elif operation == 'latest-flag':
        current = latest(repo)
        print('false' if current and version(current['tag_name']) > version(tag) else 'true')
    elif operation == 'guard-sync-latest':
        published_release(repo, tag)
        current = latest(repo)
        if current and version(current['tag_name']) > version(tag):
            print('Newer GitHub release ' + current['tag_name'] + ' exists; keeping stable feeds. Synchronize that release with --from-release instead.')
            return 42
    else:
        raise ValueError('Unknown release operation')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (RuntimeError, ValueError, OSError) as error:
        sys.exit('Release check failed: ' + str(error))
