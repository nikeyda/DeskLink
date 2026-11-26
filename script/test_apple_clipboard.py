#!/usr/bin/env python3
"""Check rich clipboard in a standard Mac screen-sharing session with a Debug iPad app.

The iPad uses its private test library and pasteboard. After the user signs in,
the Mac helper replaces its general clipboard with the two devices' test samples.
Repeat with the same result path after a USB interruption to read the pending run.
"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import time
import uuid


ROOT = Path(__file__).resolve().parents[1]
BUNDLE = 'local.nikey.desklink'


def device_file(device, direction, source, destination, required=True):
    return subprocess.run(['xcrun', 'devicectl', 'device', 'copy', direction, '--device', device,
                           '--domain-type', 'appDataContainer', '--domain-identifier', BUNDLE,
                           '--source', str(source), '--destination', str(destination), '--timeout', '12', '--quiet'],
                          check=required, stderr=None if required else subprocess.DEVNULL).returncode == 0


def seed_profile(device, host, profile, token, scratch):
    local = scratch / 'selected.json'
    device_file(device, 'from', 'Library/Application Support/DeskLink/library.json', local)
    book = json.loads(local.read_bytes())
    selected = next((c for c in book['computers'] if c['id'].lower() == str(profile)), None)
    if selected is None or selected.get('ssh') or selected['endpoint']['port'] != 5900 or (
            selected['endpoint']['host'].rstrip('.').lower() != host.rstrip('.').lower()):
        raise ValueError('Select a direct saved connection to the specified Mac on port 5900')
    for key in ('lastConnected', 'modifiedAt', 'connectionCounts', 'folder', 'linkFolder', 'deviceDisplays'):
        selected.pop(key, None)
    selected.update(saved=True, viewOnly=False, quality='standard', automaticallySharesClipboard=True,
                    remoteAudio=False, smoothVideo=False)
    local.write_text(json.dumps({'version': 1, 'folders': [], 'computers': [selected]}))
    device_file(device, 'to', local, f'tmp/DeskLinkTests/{token}.json')


def save(path, state):
    temporary = path.with_suffix(path.suffix + '.partial')
    temporary.write_text(json.dumps(state, indent=2) + '\n')
    temporary.replace(path)


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument('device', help='Paired iPad with the Debug test build installed')
    cli.add_argument('host', help='Hostname of the authorized Mac')
    cli.add_argument('result', type=Path, help='New JSON result file, or an existing run to resume monitoring')
    cli.add_argument('--saved-profile', type=uuid.UUID, help='Use the normal sign-in form for this saved computer')
    cli.add_argument('--minutes', type=float, default=120, help='Mac monitoring time; the app can still complete later')
    args = cli.parse_args()
    if args.minutes <= 0:
        cli.error('Use a positive monitoring time')
    build = ROOT / '.build'
    build.mkdir(exist_ok=True)
    new = not args.result.exists()
    if new:
        state = {'run': str(uuid.uuid4()).upper(), 'device': args.device, 'host': args.host,
                 'savedProfile': str(args.saved_profile) if args.saved_profile else None, 'stage': 'preparing'}
    else:
        state = json.loads(args.result.read_bytes())
        if state['device'] != args.device or state['host'] != args.host:
            cli.error('This receipt belongs to a different device or Mac')
    token = str(uuid.UUID(state['run'])).upper()
    base = f'tmp/DeskLinkTests/{token}'
    mac_receipt = args.result.with_suffix('.mac.json')
    with tempfile.TemporaryDirectory(dir=build, prefix='clipboard-peer-') as tmp:
        scratch = Path(tmp)
        observer_app = scratch / 'ClipboardPeer'
        subprocess.run(['swiftc', '-module-cache-path', str(build / 'FixtureModules'), str(ROOT / 'script/apple_clipboard_peer.swift'),
                        '-o', str(observer_app)], check=True)
        if new or state['stage'] == 'preparing':
            save(args.result, state)
            arguments = ['--test-library', token, '--mac-clipboard-peer', args.host]
            if state['savedProfile']:
                profile = uuid.UUID(state['savedProfile'])
                seed_profile(args.device, args.host, profile, token, scratch)
                arguments += ['--mac-clipboard-saved', str(profile).upper()]
            device_file(args.device, 'to', ROOT / 'Tests/Fixtures/clipboard-pixels.plist', base + '.pixels.plist')
            subprocess.run(['xcrun', 'devicectl', 'device', 'process', 'launch', '--device', args.device,
                            '--terminate-existing', '--timeout', '25', '--quiet', BUNDLE, '--', *arguments], check=True)
            state['stage'] = 'app-launched'
            save(args.result, state)
        deadline = time.monotonic() + args.minutes * 60
        observer = None
        receipt = scratch / 'receipt.json'
        try:
            while time.monotonic() < deadline:
                if device_file(args.device, 'from', base + '.receipt.json', receipt, required=False):
                    report = json.loads(receipt.read_bytes())
                    if report['run'] != token:
                        raise ValueError('An unrelated run returned a receipt')
                    stage = report['stage']
                    if stage != state['stage']:
                        state.update(report)
                        save(args.result, state)
                        print(stage, report.get('macToIPad', ''), flush=True)
                    if stage == 'both-directions-acknowledged':
                        if not mac_receipt.is_file():
                            print('The Mac receipt is missing.', flush=True)
                            return 1
                        mac = json.loads(mac_receipt.read_bytes())
                        if mac.get('run') != token:
                            raise ValueError('The Mac receipt belongs to a different run')
                        state['iPadToMac'] = mac
                        save(args.result, state)
                        ipad = report.get('macToIPad', {})
                        both = (all(ipad.get(key) is True for key in ('url', 'bold', 'png'))
                                and (mac.get('urlString') is True or mac.get('urlNative') is True)
                                and mac.get('bold') is True and mac.get('png') is True)
                        return 0 if both else 1
                    if stage in ('window-closed', 'fixture-setup-failed', 'missing-mac-acknowledgment'):
                        return 1
                    if observer is None and stage in ('standard-session-connected', 'mac-to-ipad-received', 'ipad-reply-published'):
                        command = [str(observer_app), token, str(ROOT / 'Tests/Fixtures'), str(mac_receipt)]
                        if stage != 'standard-session-connected':
                            command.append('--observe-reply')
                        observer = subprocess.Popen(command)
                if observer is not None and observer.poll() not in (None, 0):
                    return observer.returncode
                time.sleep(2 if observer else 7)
            print('Monitoring ended. The same result path can be used to resume.', flush=True)
            return 2
        finally:
            if observer is not None and observer.poll() is None:
                observer.terminate()
                observer.wait()


if __name__ == '__main__':
    raise SystemExit(main())
