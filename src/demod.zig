const std = @import("std");

pub const max_message_bits = 112;
pub const samples_per_bit: f32 = 2.4;

pub const SoftBit = struct {
    hard: u1,
    llr_f32: f32,
};

pub fn extractSoftBits(magnitude: []const u16, start: usize, out: []SoftBit) void {
    for (out, 0..) |*bit, i| {
        const bit_start_f = @as(f32, @floatFromInt(i)) * samples_per_bit;
        const half_f = bit_start_f + samples_per_bit / 2.0;
        const bit_end_f = bit_start_f + samples_per_bit;

        const bit_start: usize = @intFromFloat(@round(bit_start_f));
        const half: usize = @intFromFloat(@round(half_f));
        const bit_end: usize = @intFromFloat(@round(bit_end_f));

        var e_first: i32 = 0;
        var e_second: i32 = 0;

        var s = bit_start;
        while (s < half) : (s += 1) {
            if (start + s < magnitude.len) {
                e_first += @as(i32, magnitude[start + s]);
            }
        }
        s = half;
        while (s < bit_end) : (s += 1) {
            if (start + s < magnitude.len) {
                e_second += @as(i32, magnitude[start + s]);
            }
        }

        const llr: f32 = @floatFromInt(e_first - e_second);
        bit.llr_f32 = llr;
        bit.hard = if (llr >= 0) 1 else 0;
    }
}

pub fn softBitsToBytes(soft_bits: []const SoftBit, out: []u8) void {
    const num_bytes = soft_bits.len / 8;
    std.debug.assert(out.len >= num_bytes);
    for (0..num_bytes) |byte_idx| {
        var byte_val: u8 = 0;
        for (0..8) |bit_idx| {
            byte_val = (byte_val << 1) | soft_bits[byte_idx * 8 + bit_idx].hard;
        }
        out[byte_idx] = byte_val;
    }
}

pub fn computeSignalLevel(magnitude: []const u16, start: usize, num_bits: usize) u16 {
    const num_samples: usize = @intFromFloat(@round(@as(f32, @floatFromInt(num_bits)) * samples_per_bit));
    var sum: u64 = 0;
    var count: u64 = 0;
    for (0..num_samples) |s| {
        if (start + s < magnitude.len) {
            sum += magnitude[start + s];
            count += 1;
        }
    }
    if (count == 0) return 0;
    return @intCast(sum / count);
}

test "soft bit extraction - bit=1 means first half high" {
    var mag = [_]u16{0} ** 300;
    // Bit 0 at sample offset 0: first half [0,1) high, second half [1,2) low
    // With 2.4 sps/bit: bit 0 covers samples [0, 1, 2) approx
    // first half [0, 1), second half [1, 2)
    mag[0] = 1000;
    mag[1] = 0;

    var bits: [1]SoftBit = undefined;
    extractSoftBits(&mag, 0, &bits);
    try std.testing.expectEqual(@as(u1, 1), bits[0].hard);
    try std.testing.expect(bits[0].llr_f32 > 0);
}

test "soft bit extraction - bit=0 means second half high" {
    var mag = [_]u16{0} ** 300;
    mag[0] = 0;
    mag[1] = 1000;

    var bits: [1]SoftBit = undefined;
    extractSoftBits(&mag, 0, &bits);
    try std.testing.expectEqual(@as(u1, 0), bits[0].hard);
    try std.testing.expect(bits[0].llr_f32 < 0);
}

test "softBitsToBytes converts correctly" {
    const bits = [8]SoftBit{
        .{ .hard = 1, .llr_f32 = 1.0 },
        .{ .hard = 0, .llr_f32 = -1.0 },
        .{ .hard = 0, .llr_f32 = -1.0 },
        .{ .hard = 0, .llr_f32 = -1.0 },
        .{ .hard = 1, .llr_f32 = 1.0 },
        .{ .hard = 1, .llr_f32 = 1.0 },
        .{ .hard = 0, .llr_f32 = -1.0 },
        .{ .hard = 1, .llr_f32 = 1.0 },
    };
    var out: [1]u8 = undefined;
    softBitsToBytes(&bits, &out);
    try std.testing.expectEqual(@as(u8, 0x8D), out[0]);
}
