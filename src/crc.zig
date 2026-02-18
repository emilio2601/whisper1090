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

    // Phase 1: Brute-force syndrome table for 1-bit errors (all positions)
    const syn1 = if (is_long) SyndromeTable112.lookup1(syndrome) else SyndromeTable56.lookup1(syndrome);
    if (syn1) |bit_pos| {
        flipBit(msg_bytes, bit_pos);
        soft_bits[bit_pos].hard ^= 1;
        return .{ .crc_ok = true, .bits_corrected = 1 };
    }

    // Phase 2: Brute-force 2-bit using syndrome table
    // For each bit position, check if (syndrome ^ syndromeForBit(b)) is a known 1-bit syndrome
    const syn_table = if (is_long) &SyndromeTable112.table else &SyndromeTable56.table;
    const max_bits: usize = if (is_long) 112 else 56;
    for (0..max_bits) |b0| {
        const s0 = syn_table[b0];
        const residual = syndrome ^ s0;
        const b1_opt = if (is_long) SyndromeTable112.lookup1(residual) else SyndromeTable56.lookup1(residual);
        if (b1_opt) |b1| {
            if (b1 > b0) {
                flipBit(msg_bytes, b0);
                flipBit(msg_bytes, b1);
                soft_bits[b0].hard ^= 1;
                soft_bits[b1].hard ^= 1;
                return .{ .crc_ok = true, .bits_corrected = 2 };
            }
        }
    }

    // Phase 3: Soft-bit 3-bit correction (weakest N candidates)
    if (!is_long) return .{ .crc_ok = false, .bits_corrected = 0 };

    const max_candidates: usize = 15;
    var candidates: [15]usize = undefined;
    const n_cand = collectWeakBits(soft_bits[0..num_bits], candidates[0..max_candidates]);

    var synd: [15]u32 = undefined;
    for (0..n_cand) |ci| {
        synd[ci] = syn_table[candidates[ci]];
    }

    for (0..n_cand) |ci| {
        for (ci + 1..n_cand) |cj| {
            const s2 = synd[ci] ^ synd[cj];
            for (cj + 1..n_cand) |ck| {
                if (s2 ^ synd[ck] == syndrome) {
                    flipBit(msg_bytes, candidates[ci]);
                    flipBit(msg_bytes, candidates[cj]);
                    flipBit(msg_bytes, candidates[ck]);
                    soft_bits[candidates[ci]].hard ^= 1;
                    soft_bits[candidates[cj]].hard ^= 1;
                    soft_bits[candidates[ck]].hard ^= 1;
                    return .{ .crc_ok = true, .bits_corrected = 3 };
                }
            }
        }
    }

    return .{ .crc_ok = false, .bits_corrected = 0 };
}

// Comptime syndrome tables: precomputed CRC-24 syndrome for each single-bit error position.
// Used for O(1) lookup of 1-bit corrections and O(n) lookup of 2-bit corrections.
fn SyndromeTableFor(comptime n_bits: usize) type {
    const n_bytes = n_bits / 8;

    return struct {
        pub const table: [n_bits]u32 = blk: {
            var t: [n_bits]u32 = undefined;
            for (0..n_bits) |bit_pos| {
                var temp: [n_bytes]u8 = .{0} ** n_bytes;
                const byte_idx = bit_pos / 8;
                const bit_idx: u3 = @intCast(7 - (bit_pos % 8));
                temp[byte_idx] = @as(u8, 1) << bit_idx;
                t[bit_pos] = computeCrc24Comptime(&temp);
            }
            break :blk t;
        };

        // Map from syndrome value → bit position.
        // Simple perfect hash isn't possible, so use a flat array indexed by syndrome.
        // 24-bit syndromes → 16M entries is too large. Use a small hash map instead.
        const hash_bits = 8; // 256 buckets
        const bucket_count = 1 << hash_bits;
        const max_chain = 4; // max entries per bucket

        const Entry = struct { syndrome: u32, bit_pos: u8 };
        const Bucket = struct {
            entries: [max_chain]Entry,
            len: u8,
        };

        const hash_table: [bucket_count]Bucket = blk: {
            @setEvalBranchQuota(1_000_000);
            var ht: [bucket_count]Bucket = undefined;
            for (&ht) |*b| {
                b.len = 0;
                for (&b.entries) |*e| {
                    e.syndrome = 0;
                    e.bit_pos = 0;
                }
            }
            for (0..n_bits) |bit_pos| {
                const s = table[bit_pos];
                const idx = hashSyndrome(s);
                const b = &ht[idx];
                if (b.len < max_chain) {
                    b.entries[b.len] = .{ .syndrome = s, .bit_pos = @intCast(bit_pos) };
                    b.len += 1;
                }
            }
            break :blk ht;
        };

        fn hashSyndrome(s: u32) usize {
            // XOR-fold 24 bits into hash_bits
            return @as(usize, (s ^ (s >> 8) ^ (s >> 16)) & (bucket_count - 1));
        }

        fn lookup1(syndrome: u32) ?usize {
            const idx = hashSyndrome(syndrome);
            const bucket = hash_table[idx];
            for (bucket.entries[0..bucket.len]) |e| {
                if (e.syndrome == syndrome) return @as(usize, e.bit_pos);
            }
            return null;
        }
    };
}

pub const SyndromeTable56 = SyndromeTableFor(56);
pub const SyndromeTable112 = SyndromeTableFor(112);

pub const SyndromeTable32 = SyndromeTableFor(32);
pub const SyndromeTable88 = SyndromeTableFor(88);

fn computeCrc24Comptime(data: []const u8) u32 {
    @setEvalBranchQuota(100_000);
    var c: u32 = 0;
    for (data) |byte| {
        c ^= @as(u32, byte) << 16;
        for (0..8) |_| {
            c <<= 1;
            if (c & 0x1000000 != 0) {
                c ^= generator;
            }
        }
    }
    return c & 0xFFFFFF;
}

fn syndromeForBit(bit_pos: usize, msg_len: usize) u32 {
    const byte_idx = bit_pos / 8;
    const bit_idx: u3 = @intCast(7 - (bit_pos % 8));

    var temp = std.mem.zeroes([14]u8);
    temp[byte_idx] = @as(u8, 1) << bit_idx;
    return computeCrc24(temp[0..msg_len]);
}

pub fn collectWeakBits(soft_bits: []const SoftBit, out: []usize) usize {
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

pub fn flipBit(bytes: []u8, bit_pos: usize) void {
    const byte_idx = bit_pos / 8;
    const bit_idx: u3 = @intCast(7 - (bit_pos % 8));
    bytes[byte_idx] ^= @as(u8, 1) << bit_idx;
}

pub fn bitsToBytes(soft_bits: []const SoftBit, out: []u8) void {
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
