const std = @import("std");

pub const preamble_samples = 16;
pub const samples_per_bit: f32 = 2.4;

pub fn detectPreamble(magnitude: []const u16, pos: usize) bool {
    if (pos + preamble_samples > magnitude.len) return false;

    const m = magnitude[pos..];

    // At 2.4 Msps, pulse positions in microseconds → samples:
    //   0.0μs → 0.0,  1.0μs → 2.4,  3.5μs → 8.4,  4.5μs → 10.8
    // Pulse regions (high): [0,1], [2,3], [8,9], [10,11]
    // Noise regions (low):  [4,5], [6,7], [12,13]
    const pulse_total: u32 = @as(u32, m[0]) + m[1] + m[2] + m[3] + m[8] + m[9] + m[10] + m[11];
    const noise_total: u32 = @as(u32, m[4]) + m[5] + m[6] + m[7] + m[12] + m[13];

    // Minimum signal level: average pulse sample must be meaningful
    // With centered I/Q, magnitude range is [0, 32768], noise floor ~100-300
    const avg_pulse = pulse_total / 8;
    if (avg_pulse < 200) return false;

    // Pulse energy must dominate noise
    if (pulse_total < noise_total * 2) return false;

    // Each individual pulse pair must be strong relative to noise
    const noise_avg = if (noise_total > 0) noise_total / 6 else 0;
    const p0: u32 = @as(u32, m[0]) + m[1];
    const p1: u32 = @as(u32, m[2]) + m[3];
    const p2: u32 = @as(u32, m[8]) + m[9];
    const p3: u32 = @as(u32, m[10]) + m[11];

    const min_pulse = noise_avg + avg_pulse / 4;
    if (p0 < min_pulse or p1 < min_pulse or p2 < min_pulse or p3 < min_pulse) return false;

    return true;
}

test "all-zero magnitude is not a preamble" {
    var mag = [_]u16{0} ** 32;
    try std.testing.expect(!detectPreamble(&mag, 0));
}

test "synthetic preamble is detected" {
    var mag = [_]u16{0} ** 32;
    // Set pulse regions high
    mag[0] = 500;
    mag[1] = 500;
    mag[2] = 500;
    mag[3] = 500;
    mag[8] = 500;
    mag[9] = 500;
    mag[10] = 500;
    mag[11] = 500;
    // Noise regions stay at 0
    try std.testing.expect(detectPreamble(&mag, 0));
}

test "weak signal rejected" {
    var mag = [_]u16{0} ** 32;
    // Pulse too weak
    mag[0] = 5;
    mag[1] = 5;
    mag[2] = 5;
    mag[3] = 5;
    mag[8] = 5;
    mag[9] = 5;
    mag[10] = 5;
    mag[11] = 5;
    try std.testing.expect(!detectPreamble(&mag, 0));
}

test "noisy signal rejected" {
    var mag = [_]u16{0} ** 32;
    // Pulse regions
    mag[0] = 200;
    mag[1] = 200;
    mag[2] = 200;
    mag[3] = 200;
    mag[8] = 200;
    mag[9] = 200;
    mag[10] = 200;
    mag[11] = 200;
    // Noise regions also high — should fail the 2x check
    mag[4] = 200;
    mag[5] = 200;
    mag[6] = 200;
    mag[7] = 200;
    mag[12] = 200;
    mag[13] = 200;
    try std.testing.expect(!detectPreamble(&mag, 0));
}
