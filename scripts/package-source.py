#!/usr/bin/env python3
"""Package the corresponding source and build/test instructions without local build data."""
import hashlib
import os
import zipfile
from pathlib import Path

root = Path(__file__).resolve().parent.parent
output = root / 'dist/Hongguo-iOS-0.1.0-source.zip'
output.parent.mkdir(exist_ok=True)
excluded = {'build', 'dist', '.git', 'xcuserdata', '__pycache__', '.DS_Store', 'project.xcworkspace'}
count = 0
with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
    for directory, children, files in os.walk(root):
        children[:] = sorted(d for d in children if d not in excluded)
        for filename in sorted(files):
            if filename in excluded or filename.endswith('.xcuserstate'): continue
            path = Path(directory) / filename
            if path.is_symlink(): continue
            archive.write(path, 'hongguo-ios/' + path.relative_to(root).as_posix())
            count += 1
digest = hashlib.sha256(output.read_bytes()).hexdigest()
output.with_suffix(output.suffix + '.sha256').write_text(digest + '  ' + output.name + '\n')
print(f'Source archive: {output.name} ({count} files, {output.stat().st_size} bytes)')
