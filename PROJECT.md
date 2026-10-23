# slink project

slink is a self-contained, menu-bar-only macOS sampling utility. All source, tests, and build tools live in this repository.

## Layout

- `Sources/Main.swift`: accessory-app lifecycle and five menu commands.
- `Sources/SpringIcon.swift`: drawing for the menu-bar spring icon.
- `Sources/TimingService.swift`: permission checks, focused-window availability queries, mouse-button samples, and process-local scheduling modes.
- `Resources/Info.plist`: app identity, version, copyright, and menu-bar startup metadata.
- `Tests/TimingTests.swift`: sampling, authorization, lifecycle, and callback tests using injected providers.
- `Tools/package_app.py`: fixed byte-budget packaging and signature/archive checks.
- `Tools/verify_app.py`: packaged-app metadata, runtime, integrity, and archive verification.
- `Tools/test_packaging.py`: generated-code integration test for packaging.
- `size-targets.json`: executable, bundle, and ZIP byte budgets.

## Development

Run `./test.sh` for the sampling tests and `./build.sh` to produce the universal app. Then run `python3 Tools/verify_app.py` for packaged checks. Build caches go into `.build/`; artifacts and reports go into `build/`. Both directories are excluded from version control.

Quiet mode always restores the default sampling schedule. The runtime remains limited to observation and process-local scheduling. See [README.md](README.md) for behavior, permissions, and limitations.
