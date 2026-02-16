const std = @import("std");

pub fn computeMagnitude(iq_samples: []const u8, magnitude_out: []u16) void {
    std.debug.assert(iq_samples.len % 2 == 0);
    std.debug.assert(magnitude_out.len == iq_samples.len / 2);

    for (0..magnitude_out.len) |i| {
        const abs_i: u16 = @intCast(@abs(@as(i16, iq_samples[i * 2]) - 128));
        const abs_q: u16 = @intCast(@abs(@as(i16, iq_samples[i * 2 + 1]) - 128));
        const mx = @max(abs_i, abs_q);
        const mn = @min(abs_i, abs_q);
        magnitude_out[i] = mx + @as(u16, @truncate((mn * 103) >> 8));
    }
}

test "magnitude of DC center (128,128) is zero" {
    var mag: [1]u16 = undefined;
    computeMagnitude(&.{ 128, 128 }, &mag);
    try std.testing.expectEqual(@as(u16, 0), mag[0]);
}

test "magnitude of (0,0) centered" {
    var mag: [1]u16 = undefined;
    computeMagnitude(&.{ 0, 0 }, &mag);
    // max(128,128) + 128*103/256 = 128 + 51 = 179
    try std.testing.expectEqual(@as(u16, 179), mag[0]);
}

test "magnitude of (255,128)" {
    var mag: [1]u16 = undefined;
    computeMagnitude(&.{ 255, 128 }, &mag);
    // max(127,0) + 0*103/256 = 127
    try std.testing.expectEqual(@as(u16, 127), mag[0]);
}

test "magnitude of (228,228) strong signal" {
    var mag: [1]u16 = undefined;
    computeMagnitude(&.{ 228, 228 }, &mag);
    // max(100,100) + 100*103/256 = 100 + 40 = 140
    try std.testing.expectEqual(@as(u16, 140), mag[0]);
}

test "magnitude is linear and proportional to amplitude" {
    var mag1: [1]u16 = undefined;
    var mag2: [1]u16 = undefined;
    computeMagnitude(&.{ 128 + 50, 128 }, &mag1);
    computeMagnitude(&.{ 128 + 100, 128 }, &mag2);
    // Should be approximately 2x (linear)
    const ratio = @as(f32, @floatFromInt(mag2[0])) / @as(f32, @floatFromInt(mag1[0]));
    try std.testing.expect(ratio > 1.8 and ratio < 2.2);
}
