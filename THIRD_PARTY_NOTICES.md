# VPN engine notices

The optional VPN build links the macOS slice of XTLS/libXray v26.11.9, which wraps XTLS/Xray-core v26.11.9. The monitoring-only build does not link this binary.

- libXray source and build instructions: https://github.com/XTLS/libXray/tree/v26.11.9
- Xray-core source: https://github.com/XTLS/Xray-core/tree/v26.11.9
- Pinned release archive: `libxray-apple-cgo.zip`
- Archive SHA-256: `7c58346709f1856782a48d8f9926fb815c8ad1bbaf9e5d9dec4ee0cd1f41ed6f`

libXray is MIT licensed. Xray-core is Mozilla Public License 2.0 licensed. Their upstream sources include further dependency notices. Preserve the upstream source availability and notices when distributing VPN binaries. A complete dependency notice/SBOM review remains a release gate; this repository currently publishes source and build scripts, not a public prebuilt VPN release.

## libXray MIT notice

Copyright (c) 2023-2025 XTLS

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
