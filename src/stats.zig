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
    snr_sum_decoded: f64,
    snr_count_decoded: u64,
    snr_sum_failed: f64,
    snr_count_failed: u64,

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
            \\  avg SNR decoded:    {d:.2}
            \\  avg SNR failed:     {d:.2}
            \\
        , .{
            self.samples_processed,
            self.preambles_detected,
            self.messages_decoded,
            self.crc_ok,
            self.crc_corrected,
            self.crc_failed,
            self.unique_aircraft,
            if (self.snr_count_decoded > 0) self.snr_sum_decoded / @as(f64, @floatFromInt(self.snr_count_decoded)) else 0.0,
            if (self.snr_count_failed > 0) self.snr_sum_failed / @as(f64, @floatFromInt(self.snr_count_failed)) else 0.0,
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
            \\  avg SNR decoded:    {d:.2}
            \\  avg SNR failed:     {d:.2}
            \\
        , .{
            self.samples_processed,
            self.preambles_detected,
            self.messages_decoded,
            self.crc_ok,
            self.crc_corrected,
            self.crc_failed,
            self.unique_aircraft,
            if (self.snr_count_decoded > 0) self.snr_sum_decoded / @as(f64, @floatFromInt(self.snr_count_decoded)) else 0.0,
            if (self.snr_count_failed > 0) self.snr_sum_failed / @as(f64, @floatFromInt(self.snr_count_failed)) else 0.0,
        });
    }
};

test "stats init is zeroed" {
    const s = Stats.init();
    try std.testing.expectEqual(@as(u64, 0), s.messages_decoded);
}
