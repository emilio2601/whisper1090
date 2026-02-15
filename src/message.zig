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
    _,
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

        // Determine message length from DF
        msg.len = if (df_val >= 16) 14 else 7;
        const required_bits = @as(usize, msg.len) * 8;
        if (num_bits < required_bits) return null;

        @memcpy(msg.soft_bits[0..required_bits], soft_bits[0..required_bits]);

        const result = crc.softCrcCorrect(msg.soft_bits[0..required_bits], msg.raw[0..msg.len]);
        msg.crc_ok = result.crc_ok;
        msg.crc_corrected_bits = result.bits_corrected;

        if (!msg.crc_ok) return null;

        // Extract ICAO: for DF17/18 it's bytes 1-3
        // For other DFs, ICAO is XORed with the CRC remainder
        switch (msg.df) {
            .extended_squitter, .extended_squitter_non_transponder => {
                msg.icao = @as(u24, msg.raw[1]) << 16 | @as(u24, msg.raw[2]) << 8 | msg.raw[3];
            },
            else => {
                msg.icao = @as(u24, msg.raw[1]) << 16 | @as(u24, msg.raw[2]) << 8 | msg.raw[3];
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

    const msg = Message.fromSoftBits(&soft_bits, 112, 0, 500);
    try std.testing.expect(msg != null);
    try std.testing.expectEqual(DownlinkFormat.extended_squitter, msg.?.df);
    try std.testing.expectEqual(@as(u24, 0x4840D6), msg.?.icao);
    try std.testing.expectEqual(@as(u8, 14), msg.?.len);
    try std.testing.expect(msg.?.crc_ok);
}
