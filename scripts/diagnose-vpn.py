#!/usr/bin/env python3
"""Small manual A/B probe of the current network. Never changes a VPN, proxy or route."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import ipaddress
import subprocess
import time

TARGETS = {'Apple': 'https://www.apple.com/', 'GitHub': 'https://github.com/'}
FIELDS = ['http_code', 'time_namelookup', 'time_connect', 'time_appconnect', 'time_starttransfer', 'time_total', 'remote_ip']


def classify(code, metrics):
    if code == 0:
        return 'HTTP response'
    if code in (5, 6):
        return 'DNS'
    if float(metrics.get('time_appconnect', 0)) > 0:
        return 'HTTP response wait'
    if float(metrics.get('time_connect', 0)) > 0:
        return 'TLS establishment'
    return 'connection / address availability'


def effective_family(address):
    try:
        value = ipaddress.ip_address(address)
        if isinstance(value, ipaddress.IPv6Address) and value.ipv4_mapped is not None:
            return 'IPv4-mapped'
        return 'IPv' + str(value.version)
    except ValueError:
        return 'unknown'


def probe(item):
    name, url, family, round_number = item
    template = '\\n'.join('%{' + field + '}' for field in FIELDS)
    result = subprocess.run(['curl', '-' + str(family), '--head', '--silent', '--output', '/dev/null',
                             '--connect-timeout', '5', '--max-time', '8', '--write-out', template, url],
                            capture_output=True, text=True, timeout=10)
    metrics = dict(zip(FIELDS, result.stdout.strip().splitlines()))
    actual_family = effective_family(metrics.pop('remote_ip', ''))
    return {'target': name, 'family': family, 'effective_family': actual_family, 'round': round_number, 'curl_code': result.returncode,
            'phase': classify(result.returncode, metrics), **metrics}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--label', required=True, help='Manually state the current client; this script does not detect it')
    parser.add_argument('--rounds', type=int, choices=range(1, 6), default=3)
    args = parser.parse_args()
    work = [(name, url, family, n) for n in range(1, args.rounds + 1)
            for name, url in TARGETS.items() for family in (4, 6)]
    with ThreadPoolExecutor(max_workers=2) as executor:
        results = list(executor.map(probe, work))
    print(json.dumps({'label': args.label, 'measured_at_unix': int(time.time()),
                      'note': 'HEAD via current network, no credentials. curl timing fields are cumulative. TCP ready can be acknowledged by the local TUN before an upstream connection. The requested family flag is not proof of native IPv6; see effective_family.',
                      'results': results}, indent=2))


if __name__ == '__main__':
    main()
