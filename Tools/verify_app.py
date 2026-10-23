#!/usr/bin/env python3
"""Verify packaged slink artifacts, menu-only startup, and ZIP round trips."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
COPYRIGHT = 'Independent local-input sampling utility.'
MENU_TITLES = ['Refresh', 'Prioritize Heating', 'Prioritize Cooling', 'Quiet mode', 'Quit']


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def manifest(app):
    assert not any(p.is_symlink() for p in app.rglob('*')), 'Unexpected bundle symlink'
    return {str(p.relative_to(app)): {'bytes': p.stat().st_size, 'sha256': sha(p)}
            for p in sorted(app.rglob('*')) if p.is_file()}


def bundle_bytes(app):
    return sum(entry['bytes'] for entry in manifest(app).values())


def verify_signature(app):
    subprocess.run(['codesign', '--verify', '--deep', '--strict', '--all-architectures',
                    str(app)], check=True)


def verify_menu_only_runtime(info, executable, architectures):
    """Check launch metadata and each shipped slice, not just a GUI-free CLI path.

    AppKit itself has window classes; only imports and selectors referenced by our
    executable are checked. This does not claim a live WindowServer inspection.
    """
    assert info.get('LSUIElement') is True, 'slink must launch as a menu-bar agent'
    assert not info.get('NSMainNibFile') and not info.get('NSMainStoryboardFile'), (
        'slink must not load a window or storyboard at startup')
    build = (ROOT/'build.sh').read_text()
    compiled_paths = sorted(set(re.findall(r'Sources/[A-Za-z0-9_/-]+\.swift', build)))
    assert 'Sources/Main.swift' in compiled_paths, 'Cannot identify compiled entrypoint'
    compiled = '\n'.join((ROOT/path).read_text() for path in compiled_paths)
    entrypoint = (ROOT/'Sources/Main.swift').read_text()
    assert re.search(r'setActivationPolicy\(\s*\.accessory\s*\)', entrypoint), (
        'Entrypoint must remain absent from Dock and application switcher')
    forbidden_source = [r'\bimport\s+SwiftUI\b', r'\.regular\b',
                        r'\bNS(?:Window|Panel|Alert|OpenPanel|SavePanel|WindowController)\b',
                        r'\bNSHostingView\b', r'\bmainMenu\s*=',
                        r'\b(?:revealWindow)\s*\(',
                        r'\badd(?:Local|Global)MonitorForEvents\s*\(']
    for expression in forbidden_source:
        assert not re.search(expression, compiled), f'Window or keyboard UI in compiled source: {expression}'
    for title in MENU_TITLES:
        assert '"'+title+'"' in compiled, f'Missing status-menu command: {title}'

    forbidden_imports = [
        '_OBJC_CLASS_$_NSWindow', '_OBJC_CLASS_$_NSPanel', '_OBJC_CLASS_$_NSAlert',
        '_OBJC_CLASS_$_NSOpenPanel', '_OBJC_CLASS_$_NSSavePanel',
        '_OBJC_CLASS_$_NSWindowController', '_OBJC_CLASS_$_NSTextField',
        '_OBJC_CLASS_$_NSTextView', '_OBJC_CLASS_$_NSEvent',
        '_NSAboutPanelOptionApplicationName', '_NSAboutPanelOptionApplicationVersion',
        '_NSAboutPanelOptionCredits',
    ]
    forbidden_selectors = [
        'setMainMenu:', 'addLocalMonitorForEventsMatchingMask:handler:',
        'addGlobalMonitorForEventsMatchingMask:handler:',
    ]
    slices = {}
    for architecture in architectures:
        imports = subprocess.check_output(
            ['xcrun', 'nm', '-arch', architecture, '-u', str(executable)], text=True)
        for name in forbidden_imports:
            assert not re.search(r'(?m)^\s*'+re.escape(name)+r'\s*$', imports), (
                f'{architecture}: forbidden UI import {name}')
        assert 'SwiftUI' not in imports, f'{architecture}: SwiftUI runtime is still compiled'
        libraries = subprocess.check_output(
            ['otool', '-arch', architecture, '-L', str(executable)], text=True)
        assert 'SwiftUI.framework' not in libraries, f'{architecture}: SwiftUI is linked'
        selectors = subprocess.check_output(
            ['otool', '-arch', architecture, '-v', '-s', '__TEXT', '__objc_methname',
             str(executable)], text=True)
        for selector in forbidden_selectors:
            assert not re.search(r'(?m)\s'+re.escape(selector)+r'\s*$', selectors), (
                f'{architecture}: forbidden UI selector {selector}')
        slices[architecture] = {'noWindowDialogOrKeyboardMonitorImports': True,
                                'noWindowRevealOrMainMenuSelectors': True,
                                'swiftUIFrameworkLinked': False}
    return {'LSUIElement': True, 'accessoryActivationPolicyInEntrypoint': True,
            'startupNibOrStoryboard': False, 'compiledSourceFiles': compiled_paths,
            'requiredStatusMenuTitles': MENU_TITLES, 'allArchitectureChecks': slices,
            'quietModeCanRevealWindow': False,
            'liveWindowServerInspectionPerformed': False}


def check_round_trip(app, archive, expected_zip_bytes):
    """Independently check extraction and fresh recompression of the app bundle."""
    expected_files = manifest(app)
    assert archive.stat().st_size == expected_zip_bytes, f'{archive}: ZIP size differs'
    with tempfile.TemporaryDirectory(prefix='slink-round-trip-') as temporary:
        directory = Path(temporary)
        compressed = directory/'fresh.zip'
        subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent',
                        str(app), str(compressed)], check=True)
        assert compressed.stat().st_size == expected_zip_bytes, f'{app}: fresh ZIP size differs'
        extracted_dir = directory/'extracted'
        subprocess.run(['ditto', '-x', '-k', str(archive), str(extracted_dir)], check=True)
        extracted = extracted_dir/app.name
        assert manifest(extracted) == expected_files, f'{archive}: extracted file bytes differ'
        verify_signature(extracted)
        recompressed = directory/'extracted.zip'
        subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent',
                        str(extracted), str(recompressed)], check=True)
        assert recompressed.stat().st_size == expected_zip_bytes, f'{archive}: round-trip ZIP size differs'
        return {'bundleLogicalBytes': sum(p['bytes'] for p in expected_files.values()),
                'zipBytes': archive.stat().st_size,
                'freshDittoZipBytes': compressed.stat().st_size,
                'extractedFilesIdentical': True,
                'extractedDittoZipBytes': recompressed.stat().st_size,
                'extractedSignatureValid': True}


def main():
    app = ROOT/'build/slink.app'
    executable = app/'Contents/MacOS/slink'
    archive = ROOT/'build/slink.zip'
    package = json.loads((ROOT/'build/size-report.json').read_text())
    targets = json.loads((ROOT/'size-targets.json').read_text())
    info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
    assert info['CFBundleName'] == 'slink' and info['CFBundleIdentifier'] == 'local.slink.sampling'
    assert info['NSHumanReadableCopyright'] == COPYRIGHT
    assert executable.stat().st_size == targets['executableBytes']
    assert bundle_bytes(app) == targets['bundleLogicalBytes']
    assert archive.stat().st_size == targets['zipBytes']
    assert manifest(app) == package['output']['files'], 'Packaged file manifest differs'
    assert sha(archive) == package['output']['zipSHA256']
    verify_signature(app)
    architectures = subprocess.check_output(['lipo', '-archs', str(executable)], text=True).split()
    assert set(architectures) == {'arm64', 'x86_64'}
    menu_only = verify_menu_only_runtime(info, executable, architectures)
    output = subprocess.check_output([str(executable), '--self-check'], text=True)
    assert 'independent local input-sampling utility' in output
    assert all(f'{value} ns' in output for value in [1000000, 8000000, 32000000])
    imports = subprocess.check_output(['xcrun', 'nm', '-u', str(executable)], text=True)
    forbidden = ['_CGEventPost', '_CGEventPostToPid', '_CGEventTapCreate', '_AXUIElementPerformAction',
                 '_AXUIElementSetAttributeValue', '_posix_spawn', '_execve', '_socket', '_connect']
    for name in forbidden:
        assert not re.search(r'(?m)^\s*'+re.escape(name)+r'\s*$', imports), name
    assert '_AXUIElementCopyAttributeValue' in imports
    assert '_CGEventSourceButtonState' in imports
    assert not any(p.suffix in {'.jar', '.dylib', '.sh'} for p in app.rglob('*'))
    round_trip = check_round_trip(app, archive, targets['zipBytes'])

    source_files = list((ROOT/'Sources').glob('*.swift')) + list((ROOT/'Tools').glob('*.py'))
    source_files += [ROOT/'Resources/Info.plist', ROOT/'size-targets.json', ROOT/'build.sh', ROOT/'test.sh']
    report = {
        'generatedUTC': datetime.now(timezone.utc).isoformat(),
        'project': 'slink', 'app': 'slink', 'bundleIdentifier': info['CFBundleIdentifier'],
        'architectures': architectures, 'exactBytes': targets,
        'packagedExecutableRunsWithoutGUI': True,
        'menuOnlyRuntime': menu_only,
        'strictSignaturesAllArchitectures': True,
        'roundTrip': round_trip,
        'runtimeImports': {'accessibilityQueryPresent': True, 'physicalButtonReadPresent': True,
                           'inputPostingOrOtherAppActionsPresent': False, 'directNetworkOrProcessLaunchPresent': False},
        'tests': {'packagedSelfCheckPassed': True,
                  'menuAndTimingSuitesRunByThisVerifier': False},
        'ui': {'inspectedDuringThisVerification': False,
               'pixelComparisonPerformed': False, 'liveMenuTimingWithPermissionGranted': False},
        'permissionChangedDuringVerification': False,
        'sourceAndBuildInputSHA256': {str(p.relative_to(ROOT)): sha(p) for p in sorted(source_files)},
        'packageReport': 'size-report.json'
    }
    (ROOT/'build/validation.json').write_text(json.dumps(report, indent=2)+'\n')
    print('PASS: current byte sizes, all-architecture signatures, executable self-check, '
          'menu-only metadata and runtime, allowed runtime imports, ZIP round trips, '
          'and packaged file integrity.')


if __name__ == '__main__':
    main()
