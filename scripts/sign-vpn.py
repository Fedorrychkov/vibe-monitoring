#!/usr/bin/env python3
"""Sign a VPN candidate; never install, activate or connect it."""
import argparse
import datetime
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

CAPABILITY = 'packet-tunnel-provider-systemextension'


def validate_profile(data, bundle_id, now=None):
    now = now or datetime.datetime.now(datetime.timezone.utc)
    expiration = data.get('ExpirationDate')
    if not isinstance(expiration, datetime.datetime):
        raise RuntimeError('Provisioning profile has no expiration date')
    if expiration.tzinfo is None:
        expiration = expiration.replace(tzinfo=datetime.timezone.utc)
    if expiration <= now:
        raise RuntimeError('Provisioning profile has expired')
    teams = data.get('TeamIdentifier', [])
    if len(teams) != 1 or not re.fullmatch(r'[A-Z0-9]{10}', teams[0]):
        raise RuntimeError('Provisioning profile has an invalid team')
    team = teams[0]
    source = data.get('Entitlements', {})
    key = 'com.apple.application-identifier' if 'com.apple.application-identifier' in source else 'application-identifier'
    if source.get(key) != team + '.' + bundle_id:
        raise RuntimeError('Provisioning profile has the wrong application identifier')
    if CAPABILITY not in source.get('com.apple.developer.networking.networkextension', []):
        raise RuntimeError('Profile does not authorize a packet-tunnel system extension')
    if data.get('ProvisionsAllDevices') is not True or source.get('get-task-allow') or source.get('com.apple.security.get-task-allow'):
        raise RuntimeError('Use Developer ID provisioning profiles for direct distribution')
    entitlements = {
        key: source[key], 'com.apple.developer.team-identifier': team,
        'com.apple.developer.networking.networkextension': [CAPABILITY],
    }
    return team, entitlements


def load_profile(path, bundle_id):
    decoded = subprocess.run(['security', 'cms', '-D', '-i', str(path)], check=True, capture_output=True).stdout
    return validate_profile(plistlib.loads(decoded), bundle_id)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--identity', required=True, help='Developer ID Application certificate name or SHA-1')
    parser.add_argument('--app-profile', required=True, type=Path)
    parser.add_argument('--tunnel-profile', required=True, type=Path)
    args = parser.parse_args()
    identities = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'],
                                check=True, capture_output=True, text=True).stdout
    matches = [line for line in identities.splitlines() if args.identity in line and 'Developer ID Application:' in line]
    if len(matches) != 1:
        raise RuntimeError('Select one available Developer ID Application identity; Apple Development/Distribution are not substitutes')
    app_team, app_ent = load_profile(args.app_profile, 'dev.vibemonitoring.app')
    ext_team, ext_ent = load_profile(args.tunnel_profile, 'dev.vibemonitoring.app.tunnel')
    if app_team != ext_team:
        raise RuntimeError('Both profiles must belong to the same team')
    if '(' + app_team + ')' not in matches[0]:
        raise RuntimeError('Signing identity must belong to the provisioning profiles team')
    app_ent['com.apple.developer.system-extension.install'] = True
    ext_ent.update({'com.apple.security.app-sandbox': True, 'com.apple.security.network.client': True,
                    'com.apple.security.network.server': True})
    root = Path(__file__).resolve().parent.parent
    app = root / 'dist/VibeMonitoring-VPN.app'
    extension = app / 'Contents/Library/SystemExtensions/dev.vibemonitoring.app.tunnel.systemextension'
    if not extension.is_dir():
        raise RuntimeError('Build the VPN candidate first')
    ext_info = extension / 'Contents/Info.plist'
    info = plistlib.loads(ext_info.read_bytes())
    info['NetworkExtension']['NEMachServiceName'] = app_team + '.dev.vibemonitoring.app.tunnel'
    ext_info.write_bytes(plistlib.dumps(info))
    with tempfile.TemporaryDirectory(prefix='vibe-signing-') as folder:
        for bundle, profile, entitlements, name in [
            (extension, args.tunnel_profile, ext_ent, 'tunnel'), (app, args.app_profile, app_ent, 'app'),
        ]:
            shutil.copyfile(profile, bundle / 'Contents/embedded.provisionprofile')
            ent_path = Path(folder) / (name + '.plist')
            ent_path.write_bytes(plistlib.dumps(entitlements))
            subprocess.run(['codesign', '--force', '--options', 'runtime', '--timestamp', '--sign', args.identity,
                            '--entitlements', str(ent_path), str(bundle)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    print('Signed candidate:', app)
    print('Not installed or connected. Complete notarization and crash/leak checks before trusting protection.')


if __name__ == '__main__':
    main()
