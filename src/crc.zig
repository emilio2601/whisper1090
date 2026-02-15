const std = @import("std");
const SoftBit = @import("demod.zig").SoftBit;

pub const generator: u32 = 0xFFF409;

pub fn computeCrc24(data: []const u8) u32 {
    var crc: u32 = 0;
    for (data) |byte| {
        crc ^= @as(u32, byte) << 16;
        for (0..8) |_| {
            crc <<= 1;
            if (crc & 0x1000000 != 0) {
                crc ^= generator;
            }
        }
    }
    return crc & 0xFFFFFF;
}

pub fn verifyCrc24(msg: []const u8) bool {
    return computeCrc24(msg) == 0;
}

pub const SoftCrcResult = struct {
    crc_ok: bool,
    bits_corrected: u8,
};

pub fn softCrcCorrect(soft_bits: []SoftBit, msg_bytes: []u8) SoftCrcResult {
    const num_bits = msg_bytes.len * 8;
    const is_long = msg_bytes.len == 14;

    bitsToBytes(soft_bits[0..num_bits], msg_bytes);
    if (verifyCrc24(msg_bytes)) {
        return .{ .crc_ok = true, .bits_corrected = 0 };
    }

    const syndrome = computeCrc24(msg_bytes);

    const max_candidates: usize = if (is_long) 15 else 8;
    var candidates: [15]usize = undefined;
    const n_cand = collectWeakBits(soft_bits[0..num_bits], candidates[0..max_candidates]);

    // Try 1-bit flips
    for (candidates[0..n_cand]) |b0| {
        if (syndromeForBit(b0, msg_bytes.len) == syndrome) {
            flipBit(msg_bytes, b0);
            soft_bits[b0].hard ^= 1;
            return .{ .crc_ok = true, .bits_corrected = 1 };
        }
    }

    // 2-bit correction only for long (112-bit) messages
    if (!is_long) return .{ .crc_ok = false, .bits_corrected = 0 };

    for (0..n_cand) |i| {
        for (i + 1..n_cand) |j| {
            if (syndromeForBit(candidates[i], msg_bytes.len) ^ syndromeForBit(candidates[j], msg_bytes.len) == syndrome) {
                flipBit(msg_bytes, candidates[i]);
                flipBit(msg_bytes, candidates[j]);
                soft_bits[candidates[i]].hard ^= 1;
                soft_bits[candidates[j]].hard ^= 1;
                return .{ .crc_ok = true, .bits_corrected = 2 };
            }
        }
    }

    return .{ .crc_ok = false, .bits_corrected = 0 };
}

fn syndromeForBit(bit_pos: usize, msg_len: usize) u32 {
    const byte_idx = bit_pos / 8;
    const bit_idx: u3 = @intCast(7 - (bit_pos % 8));

    var temp = std.mem.zeroes([14]u8);
    temp[byte_idx] = @as(u8, 1) << bit_idx;
    return computeCrc24(temp[0..msg_len]);
}

fn collectWeakBits(soft_bits: []const SoftBit, out: []usize) usize {
    var abs_llrs: [112]struct { idx: usize, abs_llr: f32 } = undefined;
    for (soft_bits, 0..) |bit, i| {
        abs_llrs[i] = .{ .idx = i, .abs_llr = @abs(bit.llr_f32) };
    }

    const items = abs_llrs[0..soft_bits.len];
    std.mem.sort(@TypeOf(items[0]), items, {}, struct {
        fn lessThan(_: void, a: @TypeOf(items[0]), b: @TypeOf(items[0])) bool {
            return a.abs_llr < b.abs_llr;
        }
    }.lessThan);

    const n = @min(out.len, soft_bits.len);
    for (0..n) |i| {
        out[i] = items[i].idx;
    }
    return n;
}

fn flipBit(bytes: []u8, bit_pos: usize) void {
    const byte_idx = bit_pos / 8;
    const bit_idx: u3 = @intCast(7 - (bit_pos % 8));
    bytes[byte_idx] ^= @as(u8, 1) << bit_idx;
}

fn bitsToBytes(soft_bits: []const SoftBit, out: []u8) void {
    for (0..out.len) |byte_idx| {
        var byte_val: u8 = 0;
        for (0..8) |bit_idx| {
            byte_val = (byte_val << 1) | soft_bits[byte_idx * 8 + bit_idx].hard;
        }
        out[byte_idx] = byte_val;
    }
}

test "CRC-24 of empty is zero" {
    try std.testing.expectEqual(@as(u32, 0), computeCrc24(&.{}));
}

test "CRC-24 known vector" {
    const msg = [_]u8{ 0x8D, 0x48, 0x40, 0xD6, 0x20, 0x2C, 0xC3, 0x71, 0xC3, 0x2C, 0xE0, 0x57, 0x60, 0x98 };
    try std.testing.expect(verifyCrc24(&msg));
}

test "soft CRC corrects 1-bit error" {
    const msg_good = [_]u8{ 0x8D, 0x48, 0x40, 0xD6, 0x20, 0x2C, 0xC3, 0x71, 0xC3, 0x2C, 0xE0, 0x57, 0x60, 0x98 };

    var soft_bits: [112]SoftBit = undefined;
    for (0..112) |i| {
        const byte_idx = i / 8;
        const bit_idx: u3 = @intCast(7 - (i % 8));
        const hard: u1 = @truncate(msg_good[byte_idx] >> bit_idx);
        soft_bits[i] = .{ .hard = hard, .llr_f32 = if (hard == 1) 100.0 else -100.0 };
    }

    // Corrupt bit 40 (make it the weakest)
    soft_bits[40].hard ^= 1;
    soft_bits[40].llr_f32 = 0.5;

    var msg_bytes: [14]u8 = undefined;
    const result = softCrcCorrect(&soft_bits, &msg_bytes);
    try std.testing.expect(result.crc_ok);
    try std.testing.expectEqual(@as(u8, 1), result.bits_corrected);
    try std.testing.expect(verifyCrc24(&msg_bytes));
}

test "flipBit works correctly" {
    var bytes = [_]u8{ 0xFF, 0x00 };
    flipBit(&bytes, 0);
    try std.testing.expectEqual(@as(u8, 0x7F), bytes[0]);
    flipBit(&bytes, 8);
    try std.testing.expectEqual(@as(u8, 0x80), bytes[1]);
}
