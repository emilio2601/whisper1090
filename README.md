# whisper1090
A soft-decision ADS-B decoder for 1090 MHz, written in Zig. Extracts per-bit log-likelihood ratios from raw I/Q samples instead of hard 0/1 decisions, enabling confidence-guided CRC correction (up to 4-bit errors), interference separation, and improved decoding range.
