# Test Data

## vectors/

Small, deterministic test cases committed to the repo. These power unit tests
and should never depend on external I/Q captures.

- `known_messages.json` - Hex-encoded Mode S messages with expected decode output
- `crc_edge_cases.json` - CRC-24 edge cases for soft correction testing
- `preamble.bin` - Crafted preamble patterns for correlator testing

## Real I/Q samples

Large I/Q captures live in `../samples/` (gitignored). Run `scripts/fetch_samples.sh`
to pull them from object storage.

Format: unsigned 8-bit I/Q interleaved (cu8), 2.4 Msps.
