const std = @import("std");

pub const PreambleResult = struct {
    score: f32,
    fractional_offset: f32,
};

const min_snr_ratio: f32 = 1.6;
const abs_floor: u32 = 2;

pub fn preambleSamples(sample_rate_hz: u32) usize {
    return @intFromFloat(@round(8.0 * @as(f64, @floatFromInt(sample_rate_hz)) / 1_000_000.0));
}

pub fn detectPreamble(magnitude: []const u16, pos: usize, sample_rate_hz: u32) ?PreambleResult {
    const sps = @as(f64, @floatFromInt(sample_rate_hz)) / 1_000_000.0;

    const n1_end: usize = @intFromFloat(@round(7.0 * sps));
    if (pos + n1_end > magnitude.len) return null;
    if (pos == 0 and n1_end + 2 > magnitude.len) return null;

    const score = scoreAt(magnitude, pos, sps);
    if (score == null) return null;
    const s_center = score.?;

    if (s_center < min_snr_ratio) return null;

    var fractional: f32 = 0.0;

    if (pos > 0 and pos + n1_end + 1 <= magnitude.len) {
        const s_left = scoreAt(magnitude, pos - 1, sps) orelse s_center;
        const s_right = scoreAt(magnitude, pos + 1, sps) orelse s_center;

        const denom = 2.0 * (s_left - 2.0 * s_center + s_right);
        if (@abs(denom) > 0.001) {
            fractional = (s_left - s_right) / denom;
            fractional = std.math.clamp(fractional, -0.5, 0.5);
        }
    }

    return .{
        .score = s_center,
        .fractional_offset = fractional,
    };
}

fn scoreAt(magnitude: []const u16, pos: usize, sps: f64) ?f32 {
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

    if (pos + n1_end > magnitude.len) return null;
    const m = magnitude[pos..];

    const p0 = sumRegion(m, p0_start, p0_end);
    const p1 = sumRegion(m, p1_start, p1_end);
    const p2 = sumRegion(m, p2_start, p2_end);
    const p3 = sumRegion(m, p3_start, p3_end);
    const pulse_total = p0 + p1 + p2 + p3;

    const pulse_count: u32 = @intCast((p0_end - p0_start) + (p1_end - p1_start) + (p2_end - p2_start) + (p3_end - p3_start));
    if (pulse_count == 0) return null;

    const avg_pulse = pulse_total / pulse_count;
    if (avg_pulse < abs_floor) return null;

    const n0 = sumRegion(m, n0_start, n0_end);
    const n1 = sumRegion(m, n1_start, n1_end);
    const noise_total = n0 + n1;

    const noise_count: u32 = @intCast((n0_end - n0_start) + (n1_end - n1_start));
    const noise_avg: f32 = if (noise_count > 0)
        @as(f32, @floatFromInt(noise_total)) / @as(f32, @floatFromInt(noise_count))
    else
        0.0;

    const pulse_avg: f32 = @as(f32, @floatFromInt(pulse_total)) / @as(f32, @floatFromInt(pulse_count));

    return pulse_avg / (noise_avg + 1.0);
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
    try std.testing.expect(detectPreamble(&mag, 0, 2_400_000) == null);
}

test "synthetic preamble is detected at 2.4 Msps" {
    var mag = [_]u16{0} ** 32;
    mag[0] = 50;
    mag[2] = 50;
    mag[3] = 50;
    mag[8] = 50;
    mag[9] = 50;
    mag[11] = 50;
    const result = detectPreamble(&mag, 0, 2_400_000);
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.score > 1.5);
}

test "flat noise rejected" {
    var mag = [_]u16{5} ** 32;
    try std.testing.expect(detectPreamble(&mag, 0, 2_400_000) == null);
}

test "weak but clear preamble detected" {
    var mag = [_]u16{1} ** 32;
    mag[0] = 10;
    mag[2] = 10;
    mag[3] = 10;
    mag[8] = 10;
    mag[9] = 10;
    mag[11] = 10;
    const result = detectPreamble(&mag, 0, 2_400_000);
    try std.testing.expect(result != null);
}
