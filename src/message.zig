const std = @import("std");
const SoftBit = @import("demod.zig").SoftBit;
const crc = @import("crc.zig");

pub const DownlinkFormat = enum(u5) {
    short_air_air_surveillance = 0,
    altitude_reply = 4,
    identity_reply = 5,
    all_call_reply = 11,
    long_air_air_surveillance = 16,
    extended_squitter = 17,
    extended_squitter_non_transponder = 18,
    military_extended_squitter = 19,
    comm_b_altitude_reply = 20,
    comm_b_identity_reply = 21,
    comm_d_elm = 24,
    _,

    pub fn isValid(self: DownlinkFormat) bool {
        return switch (self) {
            .short_air_air_surveillance,
            .altitude_reply,
            .identity_reply,
            .all_call_reply,
            .long_air_air_surveillance,
            .extended_squitter,
            .extended_squitter_non_transponder,
            .military_extended_squitter,
            .comm_b_altitude_reply,
            .comm_b_identity_reply,
            .comm_d_elm,
            => true,
            _ => false,
        };
    }
};

pub const IcaoFilter = struct {
    known: std.AutoHashMap(u24, void),

    pub fn init(allocator: std.mem.Allocator) IcaoFilter {
        return .{ .known = std.AutoHashMap(u24, void).init(allocator) };
    }

    pub fn deinit(self: *IcaoFilter) void {
        self.known.deinit();
    }

    pub fn add(self: *IcaoFilter, icao: u24) void {
        self.known.put(icao, {}) catch {};
    }

    pub fn contains(self: *const IcaoFilter, icao: u24) bool {
        return self.known.contains(icao);
    }
};

pub const Message = struct {
    raw: [14]u8,
    len: u8,
    df: DownlinkFormat,
    icao: u24,
    crc_ok: bool,
    crc_corrected_bits: u8,
    soft_bits: [112]SoftBit,
    signal_level_u16: u16,
    timestamp_ns: u64,

    pub fn fromSoftBits(
        soft_bits: []SoftBit,
        num_bits: usize,
        timestamp_ns: u64,
        signal_level: u16,
        icao_filter: ?*const IcaoFilter,
    ) ?Message {
        if (num_bits < 56) return null;

        var msg: Message = std.mem.zeroes(Message);
        msg.timestamp_ns = timestamp_ns;
        msg.signal_level_u16 = signal_level;

        const df_val: u5 = @truncate(
            (@as(u8, soft_bits[0].hard) << 4) |
                (@as(u8, soft_bits[1].hard) << 3) |
                (@as(u8, soft_bits[2].hard) << 2) |
                (@as(u8, soft_bits[3].hard) << 1) |
                soft_bits[4].hard,
        );

        msg.df = @enumFromInt(df_val);
        if (!msg.df.isValid()) return null;
        msg.len = if (df_val >= 16) 14 else 7;
        const required_bits = @as(usize, msg.len) * 8;
        if (num_bits < required_bits) return null;

        @memcpy(msg.soft_bits[0..required_bits], soft_bits[0..required_bits]);

        switch (msg.df) {
            .extended_squitter, .extended_squitter_non_transponder => {
                // DF17/18: CRC covers entire message, remainder must be 0
                const result = crc.softCrcCorrect(msg.soft_bits[0..required_bits], msg.raw[0..msg.len]);
                msg.crc_ok = result.crc_ok;
                msg.crc_corrected_bits = result.bits_corrected;
                if (!msg.crc_ok) return null;
                msg.icao = @as(u24, msg.raw[1]) << 16 | @as(u24, msg.raw[2]) << 8 | msg.raw[3];

                // For 2+ bit corrections, only accept if ICAO is already known
                // to avoid false positives from noise
                if (result.bits_corrected >= 2) {
                    if (icao_filter) |filter| {
                        if (!filter.contains(msg.icao)) return null;
                    }
                }
            },
            .all_call_reply => {
                // DF11: ICAO is in bytes 1-3 directly, CRC validates via PI field
                // Must use CRC(data_bytes) XOR PI, not CRC(all_bytes), because
                // PI = CRC(data) XOR IID, and CRC(all_bytes) != IID for IID != 0
                crc.bitsToBytes(msg.soft_bits[0..required_bits], msg.raw[0..msg.len]);
                const data_crc = crc.computeCrc24(msg.raw[0 .. msg.len - 3]);
                const pi: u24 = @as(u24, msg.raw[msg.len - 3]) << 16 |
                    @as(u24, msg.raw[msg.len - 2]) << 8 |
                    msg.raw[msg.len - 1];
                const remainder: u24 = @truncate(data_crc ^ pi);

                if (remainder & 0xFFFF80 == 0) {
                    const icao: u24 = @as(u24, msg.raw[1]) << 16 | @as(u24, msg.raw[2]) << 8 | msg.raw[3];
                    if (icao_filter) |filter| {
                        if (!filter.contains(icao)) return null;
                    }
                    msg.icao = icao;
                    msg.crc_ok = true;
                    msg.crc_corrected_bits = 0;
                } else {
                    // Soft 1-bit correction: try weakest bits
                    // Syndromes differ for data bits vs PI bits (same pattern as AP)
                    const data_bits: usize = (@as(usize, msg.len) - 3) * 8;
                    const max_candidates: usize = 15;
                    var candidates: [max_candidates]usize = undefined;
                    const n_cand = crc.collectWeakBits(msg.soft_bits[0..required_bits], candidates[0..max_candidates]);

                    var corrected = false;
                    for (candidates[0..n_cand]) |bit_pos| {
                        const syndrome: u24 = if (bit_pos < data_bits)
                            @truncate(crc.SyndromeTable32.table[bit_pos])
                        else
                            @as(u24, 1) << @intCast(23 - (bit_pos - data_bits));
                        const new_remainder = remainder ^ syndrome;
                        if (new_remainder & 0xFFFF80 != 0) continue;

                        crc.flipBit(msg.raw[0..msg.len], bit_pos);
                        msg.soft_bits[bit_pos].hard ^= 1;
                        const icao: u24 = @as(u24, msg.raw[1]) << 16 | @as(u24, msg.raw[2]) << 8 | msg.raw[3];

                        if (icao_filter) |filter| {
                            if (!filter.contains(icao)) {
                                // Undo the flip and try next candidate
                                crc.flipBit(msg.raw[0..msg.len], bit_pos);
                                msg.soft_bits[bit_pos].hard ^= 1;
                                continue;
                            }
                        }

                        msg.icao = icao;
                        msg.crc_ok = true;
                        msg.crc_corrected_bits = 1;
                        corrected = true;
                        break;
                    }

                    if (!corrected) return null;
                }
            },
            else => {
                // DF0/4/5/16/20/21: Address/Parity — CRC of data bytes XOR'd with AP field = ICAO
                crc.bitsToBytes(msg.soft_bits[0..required_bits], msg.raw[0..msg.len]);
                const data_crc = crc.computeCrc24(msg.raw[0 .. msg.len - 3]);
                const ap: u24 = @as(u24, msg.raw[msg.len - 3]) << 16 |
                    @as(u24, msg.raw[msg.len - 2]) << 8 |
                    msg.raw[msg.len - 1];
                const base_icao: u24 = @truncate(data_crc ^ ap);

                if (icao_filter) |filter| {
                    if (filter.contains(base_icao)) {
                        msg.icao = base_icao;
                        msg.crc_ok = true;
                        msg.crc_corrected_bits = 0;
                    } else {
                        // Soft 1-bit correction: try weakest bits, check if flipping
                        // produces a known ICAO via the address/parity relationship
                        const data_bits = (@as(usize, msg.len) - 3) * 8;
                        const syn_table = if (msg.len == 14) &crc.SyndromeTable88.table else &crc.SyndromeTable32.table;

                        const max_candidates: usize = 15;
                        var candidates: [max_candidates]usize = undefined;
                        const n_cand = crc.collectWeakBits(msg.soft_bits[0..required_bits], candidates[0..max_candidates]);

                        var corrected = false;
                        for (candidates[0..n_cand]) |bit_pos| {
                            const candidate_icao: u24 = if (bit_pos < data_bits)
                                @truncate(base_icao ^ syn_table[bit_pos])
                            else
                                base_icao ^ (@as(u24, 1) << @intCast(23 - (bit_pos - data_bits)));

                            if (filter.contains(candidate_icao)) {
                                crc.flipBit(msg.raw[0..msg.len], bit_pos);
                                msg.soft_bits[bit_pos].hard ^= 1;
                                msg.icao = candidate_icao;
                                msg.crc_ok = true;
                                msg.crc_corrected_bits = 1;
                                corrected = true;
                                break;
                            }
                        }

                        if (!corrected) return null;
                    }
                } else {
                    msg.icao = base_icao;
                    msg.crc_ok = true;
                    msg.crc_corrected_bits = 0;
                }
            },
        }

        return msg;
    }
};

test "message struct layout" {
    const msg: Message = std.mem.zeroes(Message);
    try std.testing.expectEqual(@as(u8, 0), msg.len);
}

test "fromSoftBits with known DF17 message" {
    const msg_bytes = [_]u8{ 0x8D, 0x48, 0x40, 0xD6, 0x20, 0x2C, 0xC3, 0x71, 0xC3, 0x2C, 0xE0, 0x57, 0x60, 0x98 };

    var soft_bits: [112]SoftBit = undefined;
    for (0..112) |i| {
        const byte_idx = i / 8;
        const bit_idx: u3 = @intCast(7 - (i % 8));
        const hard: u1 = @truncate(msg_bytes[byte_idx] >> bit_idx);
        soft_bits[i] = .{ .hard = hard, .llr_f32 = if (hard == 1) 100.0 else -100.0 };
    }

    const msg = Message.fromSoftBits(&soft_bits, 112, 0, 500, null);
    try std.testing.expect(msg != null);
    try std.testing.expectEqual(DownlinkFormat.extended_squitter, msg.?.df);
    try std.testing.expectEqual(@as(u24, 0x4840D6), msg.?.icao);
    try std.testing.expectEqual(@as(u8, 14), msg.?.len);
    try std.testing.expect(msg.?.crc_ok);
}
