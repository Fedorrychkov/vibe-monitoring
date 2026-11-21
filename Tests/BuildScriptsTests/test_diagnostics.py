import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('diagnostics', Path(__file__).resolve().parents[2] / 'scripts/diagnose-vpn.py')
diagnostics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(diagnostics)


class DiagnosticsTests(unittest.TestCase):
    def test_dns_connect_tls_and_http_failures_remain_distinct(self):
        self.assertEqual(diagnostics.classify(6, {}), 'DNS')
        self.assertEqual(diagnostics.classify(7, {}), 'connection / address availability')
        self.assertEqual(diagnostics.classify(28, {'time_connect': '0.2'}), 'TLS establishment')
        self.assertEqual(diagnostics.classify(28, {'time_appconnect': '0.4'}), 'HTTP response wait')
        self.assertEqual(diagnostics.classify(0, {}), 'HTTP response')

    def test_mapped_addresses_do_not_count_as_native_ipv6(self):
        self.assertEqual(diagnostics.effective_family('192.0.2.1'), 'IPv4')
        self.assertEqual(diagnostics.effective_family('2001:db8::1'), 'IPv6')
        self.assertEqual(diagnostics.effective_family('::ffff:192.0.2.1'), 'IPv4-mapped')
        self.assertEqual(diagnostics.effective_family(''), 'unknown')
