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

pub fn resampleAndExtract(
    magnitude: []const u16,
    data_start: usize,
    fractional_offset: f32,
    num_bits: usize,
    sample_rate_hz: u32,
    out_bits: []SoftBit,
) void {
    std.debug.assert(out_bits.len >= num_bits);
    std.debug.assert(num_bits <= max_message_bits);

    const ratio: f64 = @as(f64, @floatFromInt(sample_rate_hz)) / 4_000_000.0;
    const grid_points = num_bits * 4;

    var grid: [max_message_bits * 4]u16 = undefined;

    for (0..grid_points) |i| {
        const src: f64 = @as(f64, fractional_offset) + @as(f64, @floatFromInt(i)) * ratio;
        const src_floor_f = @floor(src);
        const src_floor: usize = @intFromFloat(@max(src_floor_f, 0.0));
        const frac: f64 = src - src_floor_f;

        const abs_floor = data_start + src_floor;
        const abs_ceil = abs_floor + 1;

        const v0: f64 = if (abs_floor < magnitude.len) @floatFromInt(magnitude[abs_floor]) else 0.0;
        const v1: f64 = if (abs_ceil < magnitude.len) @floatFromInt(magnitude[abs_ceil]) else v0;

        const interp = v0 * (1.0 - frac) + v1 * frac;
        grid[i] = @intFromFloat(@min(interp, 65535.0));
    }

    for (0..num_bits) |n| {
        const base = n * 4;
        const first_half: i32 = @as(i32, grid[base]) + @as(i32, grid[base + 1]);
        const second_half: i32 = @as(i32, grid[base + 2]) + @as(i32, grid[base + 3]);
        const llr: f32 = @floatFromInt(first_half - second_half);
        out_bits[n] = .{
            .hard = if (llr >= 0) 1 else 0,
            .llr_f32 = llr,
        };
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
