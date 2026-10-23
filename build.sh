#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
if (( $# )); then
    print -u2 'Usage: ./build.sh'
    exit 2
fi
mkdir -p .build build
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
sdk_path="$(xcrun --show-sdk-path)"
app_path="$PWD/build/slink.app"
python3 - <<'PY'
from pathlib import Path
import shutil
app = Path('build/slink.app')
if app.exists():
    shutil.rmtree(app)
(app/'Contents/MacOS').mkdir(parents=True)
(app/'Contents/Resources').mkdir()
PY
for arch in arm64 x86_64; do
    xcrun swiftc -swift-version 5 -O -whole-module-optimization \
        -sdk "$sdk_path" -target "$arch-apple-macos13.0" \
        -module-cache-path "$PWD/.build/swift-$arch" \
        Sources/SpringIcon.swift Sources/TimingService.swift Sources/Main.swift \
        -o ".build/slink-$arch"
done
xcrun lipo -create .build/slink-arm64 .build/slink-x86_64 -output "$app_path/Contents/MacOS/slink"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
python3 Tools/package_app.py --app "$app_path" --targets size-targets.json \
    --zip "$PWD/build/slink.zip" --report "$PWD/build/size-report.json"
# Refresh outer directory metadata so Finder can re-evaluate this package.
# Then check that a fresh archive still has the matched size. Signed file
# contents remain unchanged.
touch "$app_path/Contents" "$app_path"
python3 - "$app_path" "$PWD/build/size-report.json" <<'PY'
import json
from pathlib import Path
import subprocess
import sys
import tempfile
app = Path(sys.argv[1])
report_path = Path(sys.argv[2])
report = json.loads(report_path.read_text())
with tempfile.TemporaryDirectory(prefix='slink-directory-refresh-') as temporary:
    archive = Path(temporary)/'slink.zip'
    subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent',
                    str(app), str(archive)], check=True)
    actual = archive.stat().st_size
    expected = report['matches']['zipBytes']
    if actual != expected:
        raise RuntimeError(f'Directory metadata refresh changed ZIP size: {actual} != {expected}')
report['matches']['directoryModificationTimesRefreshed'] = True
report['matches']['afterDirectoryRefreshDittoZipBytes'] = actual
report_path.write_text(json.dumps(report, indent=2)+'\n')
PY
"$app_path/Contents/MacOS/slink" --self-check
print "Built app: $app_path"
