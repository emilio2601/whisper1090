const std = @import("std");
const Message = @import("message.zig").Message;

pub const escape_byte: u8 = 0x1A;

pub const BeastMsgType = enum(u8) {
    mode_ac = '1',
    mode_s_short = '2',
    mode_s_long = '3',
};

pub fn writeBeastMessage(writer: anytype, msg: *const Message) !void {
    try writer.writeByte(escape_byte);

    const msg_type: BeastMsgType = if (msg.len == 14) .mode_s_long else .mode_s_short;
    try writer.writeByte(@intFromEnum(msg_type));

    // 6-byte MLAT timestamp (big-endian, 12MHz clock)
    const mlat_12mhz = msg.timestamp_ns * 12 / 1000;
    try writeEscaped(writer, &std.mem.toBytes(std.mem.nativeTo(u48, @intCast(mlat_12mhz), .big)));

    // 1-byte signal level
    const signal_byte: u8 = @truncate(msg.signal_level_u16 >> 8);
    try writeEscaped(writer, &.{signal_byte});

    // Raw Mode S bytes
    try writeEscaped(writer, msg.raw[0..msg.len]);
}

fn writeEscaped(writer: anytype, data: []const u8) !void {
    for (data) |b| {
        try writer.writeByte(b);
        if (b == escape_byte) try writer.writeByte(escape_byte);
    }
}

test "escape byte is doubled" {
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writeEscaped(stream.writer(), &.{ 0x1A, 0xFF });
    const written = stream.getWritten();
    try std.testing.expectEqual(@as(usize, 3), written.len);
    try std.testing.expectEqual(@as(u8, 0x1A), written[0]);
    try std.testing.expectEqual(@as(u8, 0x1A), written[1]);
    try std.testing.expectEqual(@as(u8, 0xFF), written[2]);
}
