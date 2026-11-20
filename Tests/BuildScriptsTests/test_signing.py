import copy
import datetime
import importlib.util
import plistlib
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('vibe_signing', ROOT / 'scripts/sign-vpn.py')
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class SigningTests(unittest.TestCase):
    def test_system_extension_usage_description_is_required_in_both_bundles(self):
        with tempfile.TemporaryDirectory() as directory:
            app, extension = Path(directory) / 'App', Path(directory) / 'Extension'
            for bundle, identifier in [(app, 'dev.vibemonitoring.app'), (extension, 'dev.vibemonitoring.app.tunnel')]:
                (bundle / 'Contents').mkdir(parents=True)
                info = {'CFBundleIdentifier': identifier, 'CFBundleShortVersionString': '0.3.1',
                        'CFBundleVersion': '6', 'NSSystemExtensionUsageDescription': 'VPN protection'}
                (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
            signing.validate_bundle_metadata(app, extension)
            for bundle in [app, extension]:
                path = bundle / 'Contents/Info.plist'
                info = plistlib.loads(path.read_bytes())
                info['CFBundleVersion'] = 'invalid/service'
                path.write_bytes(plistlib.dumps(info))
            with self.assertRaisesRegex(RuntimeError, 'numeric build number'):
                signing.validate_bundle_metadata(app, extension)
            for bundle in [app, extension]:
                path = bundle / 'Contents/Info.plist'
                info = plistlib.loads(path.read_bytes())
                info['CFBundleVersion'] = '6'
                path.write_bytes(plistlib.dumps(info))
            path = extension / 'Contents/Info.plist'
            info = plistlib.loads(path.read_bytes())
            del info['NSSystemExtensionUsageDescription']
            path.write_bytes(plistlib.dumps(info))
            with self.assertRaisesRegex(RuntimeError, 'NSSystemExtensionUsageDescription'):
                signing.validate_bundle_metadata(app, extension)

    def profile(self):
        return {
            'ExpirationDate': datetime.datetime(2099, 1, 1), 'TeamIdentifier': ['ABCDE12345'],
            'ProvisionsAllDevices': True,
            'Entitlements': {
                'com.apple.application-identifier': 'ABCDE12345.dev.vibemonitoring.app',
                'com.apple.developer.networking.networkextension': [signing.CAPABILITY, 'dns-proxy-systemextension'],
                'keychain-access-groups': ['ABCDE12345.*'], 'unrelated-capability': True,
            },
        }

    def test_valid_profile_is_narrowed_to_required_capabilities(self):
        team, ent = signing.validate_profile(self.profile(), 'dev.vibemonitoring.app')
        self.assertEqual(team, 'ABCDE12345')
        self.assertEqual(ent['com.apple.developer.networking.networkextension'], [signing.CAPABILITY])
        self.assertNotIn('keychain-access-groups', ent)
        self.assertNotIn('unrelated-capability', ent)

    def test_expired_wrong_app_missing_capability_and_development_profiles_fail(self):
        for patch in [{'ExpirationDate': datetime.datetime(2000, 1, 1)}, {'ProvisionsAllDevices': False}]:
            profile = self.profile(); profile.update(patch)
            with self.assertRaises(RuntimeError): signing.validate_profile(profile, 'dev.vibemonitoring.app')
        for key, value in [
            ('com.apple.application-identifier', 'ABCDE12345.other.app'),
            ('com.apple.developer.networking.networkextension', ['packet-tunnel-provider']),
            ('get-task-allow', True),
        ]:
            profile = copy.deepcopy(self.profile()); profile['Entitlements'][key] = value
            with self.assertRaises(RuntimeError): signing.validate_profile(profile, 'dev.vibemonitoring.app')


if __name__ == '__main__': unittest.main()
