# whisper1090

Soft-decision ADS-B decoder for 1090 MHz, written in Zig.

## Architecture

Pipeline: I/Q samples → magnitude → preamble detection → soft bit
extraction (LLR) → hard decision + CRC → soft CRC correction →
Beast binary output.

Key innovation: per-bit log-likelihood ratios (LLRs) carried through
the entire pipeline, enabling confidence-guided CRC correction
(up to 4-bit errors from the N least-confident bits), per-field
confidence scoring, and interference separation.

## Project structure

```
src/
  main.zig          - CLI entry point, config, I/O orchestration
  sample_source.zig - Abstraction over RTL-SDR / file / network input
  magnitude.zig     - I/Q to magnitude conversion (SIMD)
  preamble.zig      - Sliding preamble correlator
  demod.zig         - Soft bit extraction, LLR computation
  crc.zig           - CRC-24 computation and soft correction
  message.zig       - Mode S message types (tagged union)
  decode.zig        - ADS-B/Mode S protocol decode (DF17, CPR, etc.)
  beast.zig         - Beast binary output format
  aircraft.zig      - Aircraft state tracking, position validation
  stats.zig         - Runtime metrics and observability
```

## Technical references

- CRC polynomial: 0xFFF409 (24-bit)
- Sample rate: 2.4 Msps, unsigned 8-bit I/Q (cu8)
- PPM modulation: 1μs bits, 0.5μs half-bits
- Preamble: 8μs, pulses at 0, 1, 3.5, 4.5 μs
- LLR: α * (E_first_half - E_second_half) per bit
- Soft CRC: sort bits by |LLR|, search bottom-N (N=15) for
  syndrome matches up to 4-bit corrections
- Beast format: 0x1a escape, type byte, 6B MLAT timestamp,
  1B signal level, raw Mode S bytes

## Key resource

"The 1090MHz Riddle" by Junzi Sun (mode-s.org) is the primary
protocol reference. readsb (wiedehopf fork) is the comparison
baseline.

## Build & test

```
zig build
zig build test
./zig-out/bin/whisper1090 --ifile samples/capture.bin
```

Cross-compile for Pi 3:
```
zig build -Dtarget=aarch64-linux-gnu
```

## Zig 0.15 API notes

This project targets Zig 0.15. Key breaking changes from 0.14:

- **stdout/stderr**: `std.io.getStdOut()` is gone. Use explicit buffered writers:
  ```zig
  var buf: [4096]u8 = undefined;
  var bw = std.fs.File.stdout().writer(&buf);
  const stdout = &bw.interface;
  try stdout.print("hello\n", .{});
  try stdout.flush();  // always flush before exit
  ```
  Same pattern for stderr: `std.fs.File.stderr().writer(&buf)`.
- **Build system**: Use `b.createModule(...)` with `.root_module` (already done in build.zig).
- **`std.debug.print`** still works for quick debug output (writes to stderr, unbuffered).

## Conventions

- No allocator in hot path (demod/CRC/preamble)
- Comptime for lookup tables (CRC syndrome table, magnitude LUT)
- Tagged unions for message types, not boolean flags
- All signal processing types carry units in name (magnitude_u16, llr_f32, etc.)
