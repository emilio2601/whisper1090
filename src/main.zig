const std = @import("std");
const magnitude = @import("magnitude.zig");
const preamble = @import("preamble.zig");
const demod = @import("demod.zig");
const message_mod = @import("message.zig");
const decode = @import("decode.zig");
const aircraft_mod = @import("aircraft.zig");
const stats_mod = @import("stats.zig");

const Message = message_mod.Message;
const beast = @import("beast.zig");
const SoftBit = demod.SoftBit;

const CHUNK_SIZE = 256 * 1024;
const OVERLAP_SAMPLES = 512;
const OVERLAP_BYTES = OVERLAP_SAMPLES * 2;

const OutputFormat = enum { text, beast };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var ifile_path: ?[]const u8 = null;
    var sample_rate: u32 = 2_400_000;
    var seek_samples: u64 = 0;
    var limit_samples: ?u64 = null;
    var show_stats = false;
    var quiet = false;
    var verbosity: u8 = 0;
    var output_format: OutputFormat = .text;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if ((std.mem.eql(u8, args[i], "--ifile") or std.mem.eql(u8, args[i], "-f")) and i + 1 < args.len) {
            ifile_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--sample-rate") and i + 1 < args.len) {
            sample_rate = std.fmt.parseInt(u32, args[i + 1], 10) catch 2_400_000;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--seek") and i + 1 < args.len) {
            seek_samples = std.fmt.parseInt(u64, args[i + 1], 10) catch {
                std.debug.print("Invalid --seek value: {s}\n", .{args[i + 1]});
                return;
            };
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--limit") and i + 1 < args.len) {
            limit_samples = std.fmt.parseInt(u64, args[i + 1], 10) catch {
                std.debug.print("Invalid --limit value: {s}\n", .{args[i + 1]});
                return;
            };
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--format") and i + 1 < args.len) {
            i += 1;
            if (std.mem.eql(u8, args[i], "beast")) {
                output_format = .beast;
            } else if (std.mem.eql(u8, args[i], "text")) {
                output_format = .text;
            } else {
                std.debug.print("Unknown format: {s} (expected: text, beast)\n", .{args[i]});
                return;
            }
        } else if (std.mem.eql(u8, args[i], "--stats")) {
            show_stats = true;
        } else if (std.mem.eql(u8, args[i], "--quiet") or std.mem.eql(u8, args[i], "-q")) {
            quiet = true;
        } else if (std.mem.eql(u8, args[i], "-vvv")) {
            verbosity = 3;
        } else if (std.mem.eql(u8, args[i], "-vv")) {
            verbosity = 2;
        } else if (std.mem.eql(u8, args[i], "-v")) {
            verbosity +|= 1;
        } else if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            std.debug.print(
                \\whisper1090: soft-decision ADS-B decoder
                \\
                \\Usage: whisper1090 -f <path.iq> [options]
                \\
                \\Input:
                \\  -f, --ifile <path>       Input file (cu8 I/Q samples)
                \\  --sample-rate <hz>       Sample rate in Hz (default: 2400000)
                \\  --seek <samples>         Skip to sample offset before processing
                \\  --limit <samples>        Stop after processing N samples
                \\
                \\Output:
                \\  --format text|beast      Output format (default: text)
                \\  -q, --quiet              Suppress message output on stdout
                \\  --stats                  Print summary statistics to stderr
                \\
                \\Debug:
                \\  -v                       Verbose: per-message decode details
                \\  -vv                      Debug: also show raw message bytes
                \\  -vvv                     Trace: also show every preamble hit
                \\
            , .{});
            return;
        } else {
            std.debug.print("Unknown option: {s}\n", .{args[i]});
            return;
        }
    }

    if (ifile_path == null) {
        std.debug.print("whisper1090: soft-decision ADS-B decoder\n", .{});
        std.debug.print("Usage: whisper1090 -f <path.iq> [--format text|beast] [--stats] [-v|-vv|-vvv]\n", .{});
        return;
    }

    const file = try std.fs.cwd().openFile(ifile_path.?, .{});
    defer file.close();

    if (seek_samples > 0) {
        file.seekTo(seek_samples * 2) catch |err| {
            std.debug.print("Failed to seek to sample {d}: {}\n", .{ seek_samples, err });
            return;
        };
    }

    var stats = stats_mod.Stats.init();
    var table = aircraft_mod.AircraftTable.init(allocator);
    defer table.deinit();
    var icao_filter = message_mod.IcaoFilter.init(allocator);
    defer icao_filter.deinit();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_bw = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_bw.interface;

    var read_buf: [CHUNK_SIZE + OVERLAP_BYTES]u8 = undefined;
    var overlap_buf: [OVERLAP_BYTES]u8 = [_]u8{0} ** OVERLAP_BYTES;
    var has_overlap = false;

    const max_mag_samples = (CHUNK_SIZE + OVERLAP_BYTES) / 2;
    var mag_buf: [max_mag_samples]u16 = undefined;

    var total_sample_offset: u64 = seek_samples;

    const preamble_len = preamble.preambleSamples(sample_rate);
    const max_msg_samples = demod.samplesForBits(112, sample_rate);

    const stop_at_sample = if (limit_samples) |limit| seek_samples + limit else null;

    while (true) {
        if (stop_at_sample) |stop| {
            if (total_sample_offset >= stop) break;
        }

        var offset: usize = 0;
        if (has_overlap) {
            @memcpy(read_buf[0..OVERLAP_BYTES], &overlap_buf);
            offset = OVERLAP_BYTES;
        }

        const bytes_read = try file.read(read_buf[offset..]);
        if (bytes_read == 0) break;

        const total_bytes = offset + bytes_read;
        const aligned_bytes = total_bytes - (total_bytes % 2);
        if (aligned_bytes < 2) break;

        const num_samples = aligned_bytes / 2;
        magnitude.computeMagnitude(read_buf[0..aligned_bytes], mag_buf[0..num_samples]);
        stats.samples_processed += num_samples;

        var pos: usize = 0;
        while (pos + preamble_len + max_msg_samples <= num_samples) {
            const preamble_result = preamble.detectPreamble(mag_buf[0..num_samples], pos, sample_rate) orelse {
                pos += 1;
                continue;
            };

            stats.preambles_detected += 1;

            if (verbosity >= 3) {
                std.debug.print("PREAMBLE:{d}\n", .{total_sample_offset + pos});
            }

            const timestamp_ns = (total_sample_offset + pos) * 1_000_000_000 / sample_rate;
            const data_start: usize = pos + preamble_len;

            const phase_step: f32 = 0.05;
            const phase_range: f32 = 0.5;

            var phase_buf: [32]f32 = undefined;
            var n_phases: usize = 0;
            phase_buf[0] = preamble_result.fractional_offset;
            n_phases = 1;
            var sweep: f32 = phase_step;
            while (sweep <= phase_range + 0.001) : (sweep += phase_step) {
                if (n_phases + 2 > phase_buf.len) break;
                phase_buf[n_phases] = preamble_result.fractional_offset - sweep;
                n_phases += 1;
                phase_buf[n_phases] = preamble_result.fractional_offset + sweep;
                n_phases += 1;
            }

            const BestDecode = struct {
                msg: Message,
                signal_level: u16,
                num_bits: usize,
                phase_idx: usize,
                frac_off: f32,
            };
            var best_decode: ?BestDecode = null;

            for (phase_buf[0..n_phases], 0..) |frac_off, phase_idx| {
                for ([_]usize{ 112, 56 }) |num_bits| {
                    const needed_samples = demod.samplesForBits(num_bits, sample_rate);
                    if (data_start + needed_samples > num_samples) continue;

                    var soft_bits: [112]SoftBit = undefined;
                    demod.resampleAndExtract(
                        mag_buf[0..num_samples],
                        data_start,
                        frac_off,
                        num_bits,
                        sample_rate,
                        soft_bits[0..num_bits],
                    );

                    const signal_level = demod.computeSignalLevel(mag_buf[0..num_samples], data_start, num_bits, sample_rate);

                    if (verbosity >= 2 and phase_idx == 0 and num_bits == 112) {
                        var raw_bytes: [14]u8 = undefined;
                        const crc_mod = @import("crc.zig");
                        crc_mod.bitsToBytes(soft_bits[0..num_bits], &raw_bytes);
                        std.debug.print("RAW:{d}:", .{total_sample_offset + pos});
                        for (raw_bytes) |b| {
                            std.debug.print("{X:0>2}", .{b});
                        }
                        std.debug.print("\n", .{});
                    }

                    if (Message.fromSoftBits(soft_bits[0..num_bits], num_bits, timestamp_ns, signal_level, &icao_filter)) |msg| {
                        const better = if (best_decode) |best|
                            msg.score > best.msg.score
                        else
                            true;

                        if (better) {
                            best_decode = .{
                                .msg = msg,
                                .signal_level = signal_level,
                                .num_bits = num_bits,
                                .phase_idx = phase_idx,
                                .frac_off = frac_off,
                            };
                        }
                    }
                }
            }

            if (best_decode) |best| {
                const msg = best.msg;

                stats.snr_sum_decoded += preamble_result.score;
                stats.snr_count_decoded += 1;
                stats.messages_decoded += 1;
                if (msg.crc_corrected_bits > 0) {
                    stats.crc_corrected += 1;
                } else {
                    stats.crc_ok += 1;
                }

                if (verbosity >= 1) {
                    std.debug.print("DECODE: [{X:0>6}] DF{d} bits={d} phase={d}/{d:.2} crc_fix={d} score={d} sig={d} snr={d:.1} sample={d}\n", .{
                        msg.icao,
                        @intFromEnum(msg.df),
                        best.num_bits,
                        best.phase_idx,
                        best.frac_off,
                        msg.crc_corrected_bits,
                        msg.score,
                        best.signal_level,
                        preamble_result.score,
                        total_sample_offset + pos,
                    });
                }

                if (msg.df == .extended_squitter and msg.crc_corrected_bits == 0) {
                    icao_filter.add(msg.icao);
                }

                const payload = decode.decodeExtendedSquitter(&msg);
                const ac = table.getOrCreate(msg.icao) catch null;
                if (ac) |a| {
                    a.updateFromPayload(payload, msg.timestamp_ns);
                    if (a.messages_received == 1) {
                        stats.unique_aircraft += 1;
                    }
                }

                if (!quiet) {
                    switch (output_format) {
                        .text => printMessage(stdout, &msg, payload) catch {},
                        .beast => beast.writeBeastMessage(stdout, &msg) catch {},
                    }
                }

                const skip_samples = demod.samplesForBits(best.num_bits, sample_rate);
                pos = data_start + skip_samples;
            } else {
                stats.snr_sum_failed += preamble_result.score;
                stats.snr_count_failed += 1;
                stats.crc_failed += 1;
                pos += 1;
            }
        }

        if (aligned_bytes >= OVERLAP_BYTES) {
            @memcpy(&overlap_buf, read_buf[aligned_bytes - OVERLAP_BYTES .. aligned_bytes]);
            has_overlap = true;
        }

        if (!has_overlap) {
            total_sample_offset += num_samples;
        } else {
            total_sample_offset += (aligned_bytes - OVERLAP_BYTES) / 2;
        }
    }

    try stdout.flush();

    if (show_stats) {
        stats.debugPrint();
    }
}

fn printMessage(writer: anytype, msg: *const Message, payload: decode.DecodedPayload) !void {
    const icao = msg.icao;
    const corrected_str: []const u8 = if (msg.crc_corrected_bits > 0) "*" else "";

    switch (payload) {
        .identification => |ident| {
            const callsign = std.mem.trimRight(u8, &ident.callsign, " ");
            try writer.print("[{X:0>6}] IDENT: {s}{s}\n", .{ icao, callsign, corrected_str });
        },
        .airborne_position => |pos| {
            try writer.print("[{X:0>6}] POS: alt={d}ft cpr_lat={d} cpr_lon={d} odd={}{s}\n", .{
                icao,
                pos.altitude_ft,
                pos.lat_cpr,
                pos.lon_cpr,
                @as(u1, @intFromBool(pos.odd_flag)),
                corrected_str,
            });
        },
        .airborne_velocity => |vel| {
            try writer.print("[{X:0>6}] VEL: spd={d:.0}kt hdg={d:.0}deg vrate={d}fpm{s}\n", .{
                icao,
                vel.ground_speed_kt,
                vel.heading_deg,
                vel.vertical_rate_fpm,
                corrected_str,
            });
        },
        .unknown => {
            try writer.print("[{X:0>6}] DF{d} ", .{ icao, @intFromEnum(msg.df) });
            for (msg.raw[0..msg.len]) |b| {
                try writer.print("{X:0>2}", .{b});
            }
            try writer.print("{s}\n", .{corrected_str});
        },
    }
}

test {
    _ = @import("magnitude.zig");
    _ = @import("preamble.zig");
    _ = @import("demod.zig");
    _ = @import("crc.zig");
    _ = @import("message.zig");
    _ = @import("decode.zig");
    _ = @import("beast.zig");
    _ = @import("aircraft.zig");
    _ = @import("sample_source.zig");
    _ = @import("stats.zig");
}
