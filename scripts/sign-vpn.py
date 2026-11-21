#!/usr/bin/env python3
"""Sign a VPN candidate; never install, activate or connect it."""
import argparse
import datetime
import hashlib
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

CAPABILITY = 'packet-tunnel-provider-systemextension'
LOCK_CAPABILITY = 'content-filter-provider-systemextension'


def validate_profile(data, bundle_id, now=None, capabilities=None, certificate_sha1=None):
    capabilities = capabilities or [CAPABILITY]
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
    if not all(cap in source.get('com.apple.developer.networking.networkextension', []) for cap in capabilities):
        raise RuntimeError('Profile does not authorize required Network Extension capabilities')
    if data.get('ProvisionsAllDevices') is not True or source.get('get-task-allow') or source.get('com.apple.security.get-task-allow'):
        raise RuntimeError('Use Developer ID provisioning profiles for direct distribution')
    if certificate_sha1 is not None and not any(
        isinstance(cert, bytes) and hashlib.sha1(cert).hexdigest().upper() == certificate_sha1.upper()
        for cert in data.get('DeveloperCertificates', [])
    ):
        raise RuntimeError('Profile does not authorize the selected signing certificate')
    entitlements = {
        key: source[key], 'com.apple.developer.team-identifier': team,
        'com.apple.developer.networking.networkextension': capabilities,
    }
    return team, entitlements


def load_profile(path, bundle_id, capabilities=None, certificate_sha1=None):
    decoded = subprocess.run(['security', 'cms', '-D', '-i', str(path)], check=True, capture_output=True).stdout
    return validate_profile(plistlib.loads(decoded), bundle_id, capabilities=capabilities, certificate_sha1=certificate_sha1)


def validate_bundle_metadata(app, extension, lock=None):
    versions = []
    bundles = [(app, 'dev.vibemonitoring.app'), (extension, 'dev.vibemonitoring.app.tunnel')]
    if lock is not None: bundles.append((lock, 'dev.vibemonitoring.app.lock'))
    for bundle, identifier in bundles:
        info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
        if info.get('CFBundleIdentifier') != identifier:
            raise RuntimeError('Unexpected bundle identifier')
        description = info.get('NSSystemExtensionUsageDescription')
        if not isinstance(description, str) or not description.strip():
            raise RuntimeError('Both app and system extension need NSSystemExtensionUsageDescription')
        versions.append((info.get('CFBundleShortVersionString'), info.get('CFBundleVersion')))
    if any(version != versions[0] for version in versions) or not all(versions[0]):
        raise RuntimeError('App and system extension versions must match')
    if not isinstance(versions[0][1], str) or not re.fullmatch(r'[0-9]{1,10}', versions[0][1]):
        raise RuntimeError('Use a numeric build number for the versioned Mach service')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--identity', required=True, help='Developer ID Application certificate name or SHA-1')
    parser.add_argument('--app-profile', required=True, type=Path)
    parser.add_argument('--tunnel-profile', required=True, type=Path)
    parser.add_argument('--lock-profile', required=True, type=Path)
    args = parser.parse_args()
    identities = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'],
                                check=True, capture_output=True, text=True).stdout
    matches = [line for line in identities.splitlines() if args.identity in line and 'Developer ID Application:' in line]
    if len(matches) != 1:
        raise RuntimeError('Select one available Developer ID Application identity; Apple Development/Distribution are not substitutes')
    certificate = re.search(r'\b([A-Fa-f0-9]{40})\b', matches[0])
    if certificate is None: raise RuntimeError('Signing certificate fingerprint is unavailable')
    fingerprint = certificate.group(1)
    app_team, app_ent = load_profile(args.app_profile, 'dev.vibemonitoring.app', [CAPABILITY, LOCK_CAPABILITY], fingerprint)
    ext_team, ext_ent = load_profile(args.tunnel_profile, 'dev.vibemonitoring.app.tunnel', [CAPABILITY], fingerprint)
    lock_team, lock_ent = load_profile(args.lock_profile, 'dev.vibemonitoring.app.lock', [LOCK_CAPABILITY], fingerprint)
    if app_team != ext_team or app_team != lock_team:
        raise RuntimeError('Both profiles must belong to the same team')
    if '(' + app_team + ')' not in matches[0]:
        raise RuntimeError('Signing identity must belong to the provisioning profiles team')
    # macOS Team-ID-prefixed App Groups authorize the Network Extension Mach service.
    for entitlements in [app_ent, ext_ent, lock_ent]:
        entitlements['com.apple.security.application-groups'] = [app_team + '.dev.vibemonitoring.app']
    app_ent['com.apple.developer.system-extension.install'] = True
    lock_ent['com.apple.security.app-sandbox'] = True
    ext_ent.update({'com.apple.security.app-sandbox': True, 'com.apple.security.network.client': True,
                    'com.apple.security.network.server': True})
    root = Path(__file__).resolve().parent.parent
    app = root / 'dist/VibeMonitoring-VPN.app'
    extension = app / 'Contents/Library/SystemExtensions/dev.vibemonitoring.app.tunnel.systemextension'
    if not extension.is_dir():
        raise RuntimeError('Build the VPN candidate first')
    lock = app / 'Contents/Library/SystemExtensions/dev.vibemonitoring.app.lock.systemextension'
    validate_bundle_metadata(app, extension, lock)
    for bundle, identifier in [(extension, 'dev.vibemonitoring.app.tunnel'), (lock, 'dev.vibemonitoring.app.lock')]:
        ext_info = bundle / 'Contents/Info.plist'
        info = plistlib.loads(ext_info.read_bytes())
        info['NetworkExtension']['NEMachServiceName'] = app_team + '.' + identifier + '.' + info['CFBundleVersion']
        ext_info.write_bytes(plistlib.dumps(info))
    with tempfile.TemporaryDirectory(prefix='vibe-signing-') as folder:
        for bundle, profile, entitlements, name in [
            (extension, args.tunnel_profile, ext_ent, 'tunnel'), (lock, args.lock_profile, lock_ent, 'lock'),
            (app, args.app_profile, app_ent, 'app'),
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
