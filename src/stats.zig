const std = @import("std");

pub const Stats = struct {
    samples_processed: u64,
    preambles_detected: u64,
    messages_decoded: u64,
    crc_ok: u64,
    crc_corrected: u64,
    crc_failed: u64,
    unique_aircraft: u32,
    start_time_ns: u64,

    pub fn init() Stats {
        return std.mem.zeroes(Stats);
    }

    pub fn print(self: *const Stats, writer: anytype) !void {
        try writer.print(
            \\whisper1090 stats:
            \\  samples processed:  {}
            \\  preambles detected: {}
            \\  messages decoded:   {}
            \\  CRC ok:             {}
            \\  CRC corrected:      {}
            \\  CRC failed:         {}
            \\  unique aircraft:    {}
            \\
        , .{
            self.samples_processed,
            self.preambles_detected,
            self.messages_decoded,
            self.crc_ok,
            self.crc_corrected,
            self.crc_failed,
            self.unique_aircraft,
        });
    }

    pub fn debugPrint(self: *const Stats) void {
        std.debug.print(
            \\whisper1090 stats:
            \\  samples processed:  {}
            \\  preambles detected: {}
            \\  messages decoded:   {}
            \\  CRC ok:             {}
            \\  CRC corrected:      {}
            \\  CRC failed:         {}
            \\  unique aircraft:    {}
            \\
        , .{
            self.samples_processed,
            self.preambles_detected,
            self.messages_decoded,
            self.crc_ok,
            self.crc_corrected,
            self.crc_failed,
            self.unique_aircraft,
        });
    }
};

test "stats init is zeroed" {
    const s = Stats.init();
    try std.testing.expectEqual(@as(u64, 0), s.messages_decoded);
}
