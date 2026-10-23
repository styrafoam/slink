# Packaging

`size-targets.json` defines fixed logical byte budgets for the executable, app bundle, and ZIP archive. `package_app.py` signs the app, adds inert padding, and verifies the result.

## Padding design

The app bundle includes a zero-filled `Contents/Resources/SizeBallast.bin` to balance resource bytes. The runtime never reads this file.

The packager extends the final universal Mach-O slice's existing ad-hoc signature allocation. It updates the corresponding container, signature allocation, and link-edit sizes, and regenerates the changed header pages' CodeDirectory hashes. Padding follows the parsed signature SuperBlob. Loaded program sections are preserved; the padding is not executable code. Developer ID and CMS-signed binaries are rejected.

A deterministic mixture of zero and pseudorandom padding bytes tunes the archive's compressed size. The packaging report records the method, padding amounts, probe count, hashes, and actual sizes. A standard ZIP-comment fallback is reported explicitly if exact ordinary recompression could not be achieved.

## Checks

The packager verifies strict ad-hoc signatures for both architectures, executable and bundle byte counts, archive size, file hashes after extraction, and the extracted app's signature. It also measures fresh compression and recompression after extraction. `verify_app.py` requires both recompression sizes to equal the configured budget.

`test_packaging.py` compiles a small universal test program, packages it, and checks that it executes identically before and after padding. It does not request permissions or inspect user input.

## Limits

Bundle size means the sum of regular-file logical sizes. Filesystem allocation can differ. ZIP budgets are checked with macOS `ditto -c -k --sequesterRsrc --keepParent`; other compressors, metadata, or operating-system versions can change compressed size. The executable must fit within its byte budget and have enough spare space to tune compression. The tool does not strip working code to force a fit.

Generated outputs, temporary files, caches, and reports are not committed.
