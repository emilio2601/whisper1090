const std = @import("std");

pub const max_message_bits = 112;

pub const SoftBit = struct {
    hard: u1,
    llr_f32: f32,
};

pub fn samplesPerBit(sample_rate_hz: u32) f64 {
    return @as(f64, @floatFromInt(sample_rate_hz)) / 1_000_000.0;
}

pub fn samplesForBits(num_bits: usize, sample_rate_hz: u32) usize {
    return @intFromFloat(@ceil(@as(f64, @floatFromInt(num_bits)) * samplesPerBit(sample_rate_hz)));
}

pub fn extractSoftBits(magnitude: []const u16, start: usize, out: []SoftBit, sample_rate_hz: u32) void {
    const spb = samplesPerBit(sample_rate_hz);

    for (out, 0..) |*bit, i| {
        const bit_center = @as(f64, @floatFromInt(i)) * spb;

        // Sample at 1/4 and 3/4 of the bit period (center of each half-bit)
        const c1_pos: usize = @intFromFloat(@round(bit_center + spb * 0.25));
        const c2_pos: usize = @intFromFloat(@round(bit_center + spb * 0.75));

        const e_first: i32 = if (start + c1_pos < magnitude.len)
            @as(i32, magnitude[start + c1_pos])
        else
            0;
        const e_second: i32 = if (start + c2_pos < magnitude.len)
            @as(i32, magnitude[start + c2_pos])
        else
            0;

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

pub fn computeSignalLevel(magnitude: []const u16, start: usize, num_bits: usize, sample_rate_hz: u32) u16 {
    const num_samples = samplesForBits(num_bits, sample_rate_hz);
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
    // At 2.4 Msps, bit 0 centers at 0.6 (1/4) and 1.8 (3/4)
    // round(0.6)=1, round(1.8)=2
    mag[1] = 1000;
    mag[2] = 0;

    var bits: [1]SoftBit = undefined;
    extractSoftBits(&mag, 0, &bits, 2_400_000);
    try std.testing.expectEqual(@as(u1, 1), bits[0].hard);
    try std.testing.expect(bits[0].llr_f32 > 0);
}

test "soft bit extraction - bit=0 means second half high" {
    var mag = [_]u16{0} ** 300;
    mag[1] = 0;
    mag[2] = 1000;

    var bits: [1]SoftBit = undefined;
    extractSoftBits(&mag, 0, &bits, 2_400_000);
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

test "samples per bit at different rates" {
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), samplesPerBit(2_000_000), 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 2.4), samplesPerBit(2_400_000), 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), samplesPerBit(8_000_000), 0.01);
}
