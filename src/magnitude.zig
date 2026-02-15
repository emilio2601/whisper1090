const std = @import("std");

pub fn computeMagnitude(iq_samples: []const u8, magnitude_out: []u16) void {
    std.debug.assert(iq_samples.len % 2 == 0);
    std.debug.assert(magnitude_out.len == iq_samples.len / 2);

    for (0..magnitude_out.len) |i| {
        const raw_i: i32 = @as(i32, iq_samples[i * 2]) - 128;
        const raw_q: i32 = @as(i32, iq_samples[i * 2 + 1]) - 128;
        magnitude_out[i] = @intCast(raw_i * raw_i + raw_q * raw_q);
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
    // (-128)^2 + (-128)^2 = 32768
    try std.testing.expectEqual(@as(u16, 32768), mag[0]);
}

test "magnitude of (255,128)" {
    var mag: [1]u16 = undefined;
    computeMagnitude(&.{ 255, 128 }, &mag);
    // (127)^2 + 0^2 = 16129
    try std.testing.expectEqual(@as(u16, 16129), mag[0]);
}

test "magnitude of (228,228) strong signal" {
    var mag: [1]u16 = undefined;
    computeMagnitude(&.{ 228, 228 }, &mag);
    // (100)^2 + (100)^2 = 20000
    try std.testing.expectEqual(@as(u16, 20000), mag[0]);
}
