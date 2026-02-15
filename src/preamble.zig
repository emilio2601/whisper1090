const std = @import("std");

pub fn preambleSamples(sample_rate_hz: u32) usize {
    // Preamble is 8μs. Data starts after.
    return @intFromFloat(@round(8.0 * @as(f64, @floatFromInt(sample_rate_hz)) / 1_000_000.0));
}

pub fn detectPreamble(magnitude: []const u16, pos: usize, sample_rate_hz: u32) bool {
    const sps = @as(f64, @floatFromInt(sample_rate_hz)) / 1_000_000.0;

    // Need enough samples for preamble (8μs) + some margin
    const preamble_end: usize = @intFromFloat(@ceil(5.0 * sps));
    if (pos + preamble_end + 3 > magnitude.len) return false;

    const m = magnitude[pos..];

    // Pulse positions in μs: 0.0, 1.0, 3.5, 4.5
    // Each pulse is 0.5μs wide
    // Noise gaps: 1.5-3.5μs, 5.0-8.0μs (we check 5.0-6.5μs)
    const p0_start: usize = @intFromFloat(@round(0.0 * sps));
    const p0_end: usize = @intFromFloat(@round(0.5 * sps));
    const p1_start: usize = @intFromFloat(@round(1.0 * sps));
    const p1_end: usize = @intFromFloat(@round(1.5 * sps));
    const p2_start: usize = @intFromFloat(@round(3.5 * sps));
    const p2_end: usize = @intFromFloat(@round(4.0 * sps));
    const p3_start: usize = @intFromFloat(@round(4.5 * sps));
    const p3_end: usize = @intFromFloat(@round(5.0 * sps));

    const n0_start: usize = @intFromFloat(@round(2.0 * sps));
    const n0_end: usize = @intFromFloat(@round(3.0 * sps));
    const n1_start: usize = @intFromFloat(@round(5.5 * sps));
    const n1_end: usize = @intFromFloat(@round(7.0 * sps));

    if (pos + n1_end > magnitude.len) return false;

    const p0 = sumRegion(m, p0_start, p0_end);
    const p1 = sumRegion(m, p1_start, p1_end);
    const p2 = sumRegion(m, p2_start, p2_end);
    const p3 = sumRegion(m, p3_start, p3_end);
    const pulse_total = p0 + p1 + p2 + p3;

    const n0 = sumRegion(m, n0_start, n0_end);
    const n1 = sumRegion(m, n1_start, n1_end);
    const noise_total = n0 + n1;

    // Pulse count for averaging
    const pulse_count: u32 = @intCast((p0_end - p0_start) + (p1_end - p1_start) + (p2_end - p2_start) + (p3_end - p3_start));
    if (pulse_count == 0) return false;

    const avg_pulse = pulse_total / pulse_count;
    if (avg_pulse < 100) return false;

    // Noise count for averaging
    const noise_count: u32 = @intCast((n0_end - n0_start) + (n1_end - n1_start));
    const noise_scaled = if (noise_count > 0) noise_total * pulse_count / noise_count else 0;
    if (pulse_total < noise_scaled * 2) return false;

    // Each pulse pair must individually exceed noise average
    const pulse_pair_count: u32 = @intCast(@max(1, (p0_end - p0_start)));
    const noise_per_sample = if (noise_count > 0) noise_total / noise_count else 0;
    const min_pulse = noise_per_sample * pulse_pair_count + avg_pulse / 4;
    if (p0 < min_pulse or p1 < min_pulse or p2 < min_pulse or p3 < min_pulse) return false;

    return true;
}

fn sumRegion(m: []const u16, start: usize, end: usize) u32 {
    var sum: u32 = 0;
    for (m[start..end]) |v| {
        sum += v;
    }
    return sum;
}

test "all-zero magnitude is not a preamble" {
    var mag = [_]u16{0} ** 32;
    try std.testing.expect(!detectPreamble(&mag, 0, 2_400_000));
}

test "synthetic preamble is detected at 2.4 Msps" {
    // At 2.4 Msps: sps = 2.4
    // Pulse positions (0.0, 0.5, 1.0, 1.5, 3.5, 4.0, 4.5, 5.0) → samples
    // p0: round(0.0)..round(1.2) = [0, 1)
    // p1: round(2.4)..round(3.6) = [2, 4)
    // p2: round(8.4)..round(9.6) = [8, 10)
    // p3: round(10.8)..round(12.0) = [11, 12)
    // n0: round(4.8)..round(7.2) = [5, 7)
    // n1: round(13.2)..round(16.8) = [13, 17)
    var mag = [_]u16{0} ** 32;
    // Set pulse samples high
    mag[0] = 500; // p0
    mag[2] = 500;
    mag[3] = 500; // p1
    mag[8] = 500;
    mag[9] = 500; // p2
    mag[11] = 500; // p3
    try std.testing.expect(detectPreamble(&mag, 0, 2_400_000));
}

test "weak signal rejected" {
    var mag = [_]u16{5} ** 32;
    try std.testing.expect(!detectPreamble(&mag, 0, 2_400_000));
}
