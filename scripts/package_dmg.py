#!/usr/bin/env python3
"""Package an existing Developer ID signed candidate. Does not notarize or publish."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile


def run(arguments):
    result = subprocess.run(arguments, check=True, capture_output=True, text=True, timeout=120)
    return result.stdout + result.stderr


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def files(directory):
    return {str(p.relative_to(directory)): sha(p)
            for p in directory.rglob('*') if p.is_file() and not p.is_symlink()}


def main():
    if len(sys.argv) != 3:
        raise SystemExit('Usage: WIFISENTINEL_SIGN_IDENTITY=<existing Developer ID> '
                         'python3 scripts/package_dmg.py <signed.app> <output-directory>')
    identity = os.environ.get('WIFISENTINEL_SIGN_IDENTITY', '')
    if not identity.startswith('Developer ID Application: '):
        raise SystemExit('An existing Developer ID Application identity is required; no ad-hoc fallback.')
    root = Path(__file__).resolve().parents[1]
    app = Path(sys.argv[1]).resolve(strict=True)
    output = Path(sys.argv[2]).resolve()
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    version, build = info['CFBundleShortVersionString'], info['CFBundleVersion']
    if info['CFBundleIdentifier'] != 'local.WiFiSentinel':
        raise SystemExit('Unexpected application identity.')
    if not all(re.fullmatch(r'[0-9]+(?:\.[0-9]+)*', s) for s in [version, build]):
        raise SystemExit('Unsafe version or build value.')
    if any(p.is_symlink() for p in app.rglob('*')):
        raise SystemExit('This package expects the current self-contained app without nested symlinks.')
    architecture = run(['/usr/bin/lipo', '-archs', str(app / 'Contents/MacOS/WiFiSentinel')]).strip()
    if architecture != 'arm64':
        raise SystemExit('Only the currently checked arm64 distribution is supported by this workflow.')
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)])
    signature = run(['/usr/bin/codesign', '--display', '--verbose=4', str(app)])
    if 'Authority=' + identity not in signature or 'Timestamp=' not in signature or '(runtime)' not in signature:
        raise SystemExit('Candidate must already have the selected Developer ID, hardened runtime and secure timestamp.')
    provenance = json.loads((app / 'Contents/Resources/BuildInfo.json').read_text())
    if provenance.get('sourceTreeDirty') is not False or not re.fullmatch(r'[0-9a-f]{40}', provenance.get('sourceCommit') or ''):
        raise SystemExit('Distribution preparation requires a clean, recorded Git source commit.')
    output.mkdir(parents=True, exist_ok=True)
    name = f'WiFiSentinel-{version}-build{build}-macos-arm64-unnotarized.dmg'
    dmg = output / name
    if dmg.exists() or dmg.with_suffix('.dmg.sha256').exists():
        raise SystemExit('Refusing to overwrite an existing package or checksum.')
    with tempfile.TemporaryDirectory(prefix='dmg-stage-', dir=output) as temporary:
        work = Path(temporary)
        stage, mount = work / 'contents', work / 'mount'
        stage.mkdir()
        mount.mkdir()
        shutil.copytree(app, stage / 'WiFiSentinel.app')
        (stage / 'Applications').symlink_to('/Applications', target_is_directory=True)
        (stage / 'README.txt').write_text(
            '\u672c\u6587\u7531CODEX\u5168\u81ea\u52a8\u7f16\u5199\u3002\n\n'
            'WiFiSentinel local preparation package - NOT NOTARIZED\n\n'
            'This is not a completed public release. Do not disable macOS security checks.\n'
            'After a notarized release becomes available, drag WiFiSentinel.app to Applications.\n'
            'Quit any previous instance normally before replacing it.\n'
            'Automatic recovery is off at each launch and requires confirmation in the app.\n'
            'Location permission for reading a network name remains your choice.\n')
        for document in ['LICENSE', 'THIRD_PARTY_NOTICES.md']:
            shutil.copy2(root / document, stage / document)
        expected_files = files(stage)
        run(['/usr/bin/hdiutil', 'create', '-format', 'UDZO', '-fs', 'HFS+', '-volname',
             'WiFiSentinel ' + version, '-srcfolder', str(stage), str(dmg)])
        run(['/usr/bin/codesign', '--sign', identity, '--timestamp', '--identifier',
             'local.WiFiSentinel.dmg', str(dmg)])
        run(['/usr/bin/codesign', '--verify', '--strict', str(dmg)])
        run(['/usr/bin/hdiutil', 'verify', str(dmg)])
        run(['/usr/bin/hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', str(mount), str(dmg)])
        try:
            if os.readlink(mount / 'Applications') != '/Applications':
                raise RuntimeError('Incorrect Applications drag target.')
            if files(mount) != expected_files:
                raise RuntimeError('Mounted package content differs from staging.')
            run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(mount / 'WiFiSentinel.app')])
        finally:
            run(['/usr/bin/hdiutil', 'detach', str(mount)])
    checksum = sha(dmg)
    dmg.with_suffix('.dmg.sha256').write_text(checksum + '  ' + name + '\n')
    report = {'version': version, 'build': build, 'architecture': architecture,
              'minimumSystemVersion': info['LSMinimumSystemVersion'],
              'sourceCommit': provenance['sourceCommit'], 'filename': name,
              'bytes': dmg.stat().st_size, 'sha256': checksum,
              'developerIDSigned': True, 'hardenedRuntime': True, 'secureTimestamp': True,
              'readOnlyMountMatchesStaging': True, 'applicationsTarget': '/Applications',
              'notarized': False, 'stapled': False, 'releaseReady': False,
              'candidateLaunched': False, 'appInstalledOrRestarted': False}
    (output / 'package-report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
