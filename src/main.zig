const std = @import("std");
const magnitude = @import("magnitude.zig");
const preamble = @import("preamble.zig");
const demod = @import("demod.zig");
const message_mod = @import("message.zig");
const decode = @import("decode.zig");
const aircraft_mod = @import("aircraft.zig");
const stats_mod = @import("stats.zig");

const Message = message_mod.Message;
const SoftBit = demod.SoftBit;

const CHUNK_SIZE = 256 * 1024;
const OVERLAP_SAMPLES = 512;
const OVERLAP_BYTES = OVERLAP_SAMPLES * 2;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var ifile_path: ?[]const u8 = null;
    var show_stats = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--ifile") and i + 1 < args.len) {
            ifile_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--stats")) {
            show_stats = true;
        } else if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            std.debug.print("Usage: whisper1090 --ifile <path.iq> [--stats]\n", .{});
            return;
        }
    }

    if (ifile_path == null) {
        std.debug.print("whisper1090: soft-decision ADS-B decoder\n", .{});
        std.debug.print("Usage: whisper1090 --ifile <path.iq> [--stats]\n", .{});
        return;
    }

    const file = try std.fs.cwd().openFile(ifile_path.?, .{});
    defer file.close();

    var stats = stats_mod.Stats.init();
    var table = aircraft_mod.AircraftTable.init(allocator);
    defer table.deinit();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_bw = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_bw.interface;

    var read_buf: [CHUNK_SIZE + OVERLAP_BYTES]u8 = undefined;
    var overlap_buf: [OVERLAP_BYTES]u8 = [_]u8{0} ** OVERLAP_BYTES;
    var has_overlap = false;

    const max_mag_samples = (CHUNK_SIZE + OVERLAP_BYTES) / 2;
    var mag_buf: [max_mag_samples]u16 = undefined;

    var total_sample_offset: u64 = 0;

    while (true) {
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

        const preamble_len = preamble.preamble_samples;
        const max_msg_samples: usize = @intFromFloat(@round(112.0 * demod.samples_per_bit));

        var pos: usize = 0;
        while (pos + preamble_len + max_msg_samples <= num_samples) {
            if (!preamble.detectPreamble(mag_buf[0..num_samples], pos)) {
                pos += 1;
                continue;
            }

            stats.preambles_detected += 1;

            const data_start = pos + preamble_len;
            const timestamp_ns = (total_sample_offset + pos) * 1000 / 2400 * 1000;

            var decoded = false;
            for ([_]usize{ 112, 56 }) |num_bits| {
                const needed_samples: usize = @intFromFloat(@round(@as(f32, @floatFromInt(num_bits)) * demod.samples_per_bit));
                if (data_start + needed_samples > num_samples) continue;

                var soft_bits: [112]SoftBit = undefined;
                demod.extractSoftBits(mag_buf[0..num_samples], data_start, soft_bits[0..num_bits]);

                const signal_level = demod.computeSignalLevel(mag_buf[0..num_samples], data_start, num_bits);

                if (Message.fromSoftBits(soft_bits[0..num_bits], num_bits, timestamp_ns, signal_level)) |msg| {
                    stats.messages_decoded += 1;
                    if (msg.crc_corrected_bits > 0) {
                        stats.crc_corrected += 1;
                    } else {
                        stats.crc_ok += 1;
                    }

                    const payload = decode.decodeExtendedSquitter(&msg);
                    const ac = table.getOrCreate(msg.icao) catch null;
                    if (ac) |a| {
                        a.updateFromPayload(payload, msg.timestamp_ns);
                        if (a.messages_received == 1) {
                            stats.unique_aircraft += 1;
                        }
                    }

                    printMessage(stdout, &msg, payload) catch {};

                    const skip_samples: usize = @intFromFloat(@round(@as(f32, @floatFromInt(num_bits)) * demod.samples_per_bit));
                    pos = data_start + skip_samples;
                    decoded = true;
                    break;
                }
            }

            if (!decoded) {
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

    stats.debugPrint();
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
            try writer.print("[{X:0>6}] DF{d}{s}\n", .{ icao, @intFromEnum(msg.df), corrected_str });
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
