const std = @import("std");

pub const Stats = struct {
    samples_processed: u64,
    preambles_detected: u64,
    messages_decoded: u64,
    crc_ok: u64,
    crc_corrected_1bit: u64,
    crc_corrected_2bit: u64,
    crc_corrected_3bit: u64,
    crc_failed: u64,
    unique_aircraft: u32,
    start_time_ns: u64,
    snr_sum_decoded: f64,
    snr_count_decoded: u64,
    snr_sum_failed: f64,
    snr_count_failed: u64,

    time_magnitude_ns: u64,
    time_preamble_ns: u64,
    time_phase_search_ns: u64,
    time_total_ns: u64,
    phase_attempts: u64,
    sample_rate: u32,

    pub fn init() Stats {
        return std.mem.zeroes(Stats);
    }

    fn fmtMs(ns: u64) f64 {
        return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
    }

    fn fmtPct(part: u64, total: u64) f64 {
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(part)) / @as(f64, @floatFromInt(total)) * 100.0;
    }

    fn realTimeRatio(self: *const Stats) f64 {
        if (self.time_total_ns == 0 or self.sample_rate == 0) return 0.0;
        const recording_ns: f64 = @as(f64, @floatFromInt(self.samples_processed)) / @as(f64, @floatFromInt(self.sample_rate)) * 1e9;
        return recording_ns / @as(f64, @floatFromInt(self.time_total_ns));
    }

    pub fn print(self: *const Stats, writer: anytype) !void {
        const scan_ns = self.time_total_ns -| self.time_magnitude_ns -| self.time_phase_search_ns;
        try writer.print(
            \\whisper1090 stats:
            \\  samples processed:  {}
            \\  preambles detected: {}
            \\  messages decoded:   {}
            \\  CRC ok:             {}
            \\  CRC corrected 1-bit:{}
            \\  CRC corrected 2-bit:{}
            \\  CRC corrected 3-bit:{}
            \\  CRC failed:         {}
            \\  unique aircraft:    {}
            \\  avg SNR decoded:    {d:.2}
            \\  avg SNR failed:     {d:.2}
            \\  phase attempts:     {}
            \\  timing:
            \\    total:            {d:.0}ms ({d:.2}x real-time)
            \\    magnitude:        {d:.0}ms ({d:.1}%)
            \\    preamble scan:    {d:.0}ms ({d:.1}%)
            \\    phase search:     {d:.0}ms ({d:.1}%)
            \\
        , .{
            self.samples_processed,
            self.preambles_detected,
            self.messages_decoded,
            self.crc_ok,
            self.crc_corrected_1bit,
            self.crc_corrected_2bit,
            self.crc_corrected_3bit,
            self.crc_failed,
            self.unique_aircraft,
            if (self.snr_count_decoded > 0) self.snr_sum_decoded / @as(f64, @floatFromInt(self.snr_count_decoded)) else 0.0,
            if (self.snr_count_failed > 0) self.snr_sum_failed / @as(f64, @floatFromInt(self.snr_count_failed)) else 0.0,
            self.phase_attempts,
            fmtMs(self.time_total_ns),
            self.realTimeRatio(),
            fmtMs(self.time_magnitude_ns),
            fmtPct(self.time_magnitude_ns, self.time_total_ns),
            fmtMs(scan_ns),
            fmtPct(scan_ns, self.time_total_ns),
            fmtMs(self.time_phase_search_ns),
            fmtPct(self.time_phase_search_ns, self.time_total_ns),
        });
    }

    pub fn debugPrint(self: *const Stats) void {
        const scan_ns = self.time_total_ns -| self.time_magnitude_ns -| self.time_phase_search_ns;
        std.debug.print(
            \\whisper1090 stats:
            \\  samples processed:  {}
            \\  preambles detected: {}
            \\  messages decoded:   {}
            \\  CRC ok:             {}
            \\  CRC corrected 1-bit:{}
            \\  CRC corrected 2-bit:{}
            \\  CRC corrected 3-bit:{}
            \\  CRC failed:         {}
            \\  unique aircraft:    {}
            \\  avg SNR decoded:    {d:.2}
            \\  avg SNR failed:     {d:.2}
            \\  phase attempts:     {}
            \\  timing:
            \\    total:            {d:.0}ms ({d:.2}x real-time)
            \\    magnitude:        {d:.0}ms ({d:.1}%)
            \\    preamble scan:    {d:.0}ms ({d:.1}%)
            \\    phase search:     {d:.0}ms ({d:.1}%)
            \\
        , .{
            self.samples_processed,
            self.preambles_detected,
            self.messages_decoded,
            self.crc_ok,
            self.crc_corrected_1bit,
            self.crc_corrected_2bit,
            self.crc_corrected_3bit,
            self.crc_failed,
            self.unique_aircraft,
            if (self.snr_count_decoded > 0) self.snr_sum_decoded / @as(f64, @floatFromInt(self.snr_count_decoded)) else 0.0,
            if (self.snr_count_failed > 0) self.snr_sum_failed / @as(f64, @floatFromInt(self.snr_count_failed)) else 0.0,
            self.phase_attempts,
            fmtMs(self.time_total_ns),
            self.realTimeRatio(),
            fmtMs(self.time_magnitude_ns),
            fmtPct(self.time_magnitude_ns, self.time_total_ns),
            fmtMs(scan_ns),
            fmtPct(scan_ns, self.time_total_ns),
            fmtMs(self.time_phase_search_ns),
            fmtPct(self.time_phase_search_ns, self.time_total_ns),
        });
    }
};

test "stats init is zeroed" {
    const s = Stats.init();
    try std.testing.expectEqual(@as(u64, 0), s.messages_decoded);
}
