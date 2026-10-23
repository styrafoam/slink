#!/usr/bin/env python3
"""Integration regression: compile, pad, verify, extract, and execute benign code.

The test uses generated code and changes no permissions or settings.
"""

import json
from pathlib import Path
import plistlib
import subprocess
import tempfile

from package_app import package, pad_adhoc_universal


def main() -> None:
    project = Path(__file__).resolve().parents[1]
    targets = json.loads((project / "size-targets.json").read_text())
    try:
        pad_adhoc_universal(b"not an executable", 3000)
    except ValueError:
        pass
    else:
        raise AssertionError("Non-Mach-O data was accepted.")
    with tempfile.TemporaryDirectory(prefix="slink-size-test-") as temporary:
        root = Path(temporary)
        app = root / "slink.app"
        contents = app / "Contents"
        executable = contents / "MacOS/slink"
        executable.parent.mkdir(parents=True)
        resources = contents / "Resources"
        resources.mkdir()
        (resources / "IndependentProbe.txt").write_text("Generated independent integration probe.\n")
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "slink",
            "CFBundleIdentifier": "local.slink.sampling.packaging-test",
            "CFBundleName": "slink",
            "CFBundlePackageType": "APPL",
        }))
        source = root / "probe.c"
        source.write_text('#include <stdio.h>\nint main(void) { puts("independent-probe-ok"); return 23; }\n')
        subprocess.run(["xcrun", "clang", "-arch", "x86_64", "-arch", "arm64",
                        "-mmacosx-version-min=13.0", str(source), "-o", str(executable)],
                       check=True, capture_output=True)
        before = subprocess.run([str(executable)], capture_output=True)
        report = package(app, root / "slink.zip", root / "report.json", targets)
        after = subprocess.run([str(executable)], capture_output=True)
        assert before.returncode == after.returncode == 23
        assert before.stdout == after.stdout == b"independent-probe-ok\n"
        assert report["matches"]["executableBytes"] == targets["executableBytes"]
        assert report["matches"]["bundleLogicalBytes"] == targets["bundleLogicalBytes"]
        assert report["matches"]["zipBytes"] == targets["zipBytes"]
        assert report["matches"]["ordinaryDittoZipMatches"]
        assert report["matches"]["extractedDittoZipMatches"]
        assert report["matches"]["strictAdHocSignatureValid"]
        assert report["matches"]["extractedBytesIdentical"]
        print("PASS: generated universal code runs identically before/after exact size matching.")
        print("PASS: executable, bundle, supplied ZIP, and ordinary ditto ZIP match pinned byte counts.")
        print("PASS: all extracted file hashes match and both app signatures pass strict validation.")


if __name__ == "__main__":
    main()
