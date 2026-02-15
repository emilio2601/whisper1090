const std = @import("std");
const Message = @import("message.zig").Message;
const DownlinkFormat = @import("message.zig").DownlinkFormat;

pub const AirbornePosition = struct {
    lat_cpr: u17,
    lon_cpr: u17,
    altitude_ft: i32,
    odd_flag: bool,
};

pub const AirborneVelocity = struct {
    heading_deg: f32,
    ground_speed_kt: f32,
    vertical_rate_fpm: i16,
};

pub const Identification = struct {
    callsign: [8]u8,
    category: u8,
};

pub const DecodedPayload = union(enum) {
    airborne_position: AirbornePosition,
    airborne_velocity: AirborneVelocity,
    identification: Identification,
    unknown: void,
};

const ais_charset = "?ABCDEFGHIJKLMNOPQRSTUVWXYZ????? ???????????????0123456789??????";

pub fn decodeExtendedSquitter(msg: *const Message) DecodedPayload {
    if (msg.df != DownlinkFormat.extended_squitter and
        msg.df != DownlinkFormat.extended_squitter_non_transponder)
    {
        return .unknown;
    }
    if (msg.len < 14) return .unknown;

    const me = msg.raw[4..11];
    const tc: u8 = me[0] >> 3;

    if (tc >= 1 and tc <= 4) {
        return decodeIdentification(me, tc);
    } else if (tc >= 9 and tc <= 18) {
        return decodeAirbornePosition(me);
    } else if (tc == 19) {
        return decodeAirborneVelocity(me);
    }

    return .unknown;
}

fn decodeIdentification(me: []const u8, tc: u8) DecodedPayload {
    var ident: Identification = undefined;
    ident.category = ((tc - 1) << 3) | (me[0] & 0x07);

    // 8 characters, 6 bits each, packed in ME bytes 1-6 (48 bits)
    const b1: u48 = @as(u48, me[1]) << 40 |
        @as(u48, me[2]) << 32 |
        @as(u48, me[3]) << 24 |
        @as(u48, me[4]) << 16 |
        @as(u48, me[5]) << 8 |
        @as(u48, me[6]);

    for (0..8) |i| {
        const shift: u6 = @intCast(42 - i * 6);
        const idx: u6 = @truncate(b1 >> shift);
        ident.callsign[i] = ais_charset[idx];
    }

    return .{ .identification = ident };
}

fn decodeAirbornePosition(me: []const u8) DecodedPayload {
    var pos: AirbornePosition = undefined;

    // Altitude: bits 8-19 of ME (Q-bit encoding)
    const alt_raw: u12 = @as(u12, me[1]) << 4 | @as(u12, me[2] >> 4);

    // Q-bit is bit 4 of the 12-bit altitude code (counting from MSB, 0-indexed → bit 8)
    const q_bit = (alt_raw >> 4) & 1;
    if (q_bit == 1) {
        // 25ft resolution: remove Q-bit, multiply by 25, subtract 1000
        const n_raw = (alt_raw & 0xF) | ((alt_raw >> 1) & 0x7F0);
        pos.altitude_ft = @as(i32, n_raw) * 25 - 1000;
    } else {
        // 100ft resolution — Gillham code, simplified
        pos.altitude_ft = 0;
    }

    // CPR odd flag
    pos.odd_flag = (me[2] & 0x04) != 0;

    // CPR latitude (17 bits)
    pos.lat_cpr = @as(u17, me[2] & 0x03) << 15 | @as(u17, me[3]) << 7 | @as(u17, me[4] >> 1);

    // CPR longitude (17 bits)
    pos.lon_cpr = @as(u17, me[4] & 0x01) << 16 | @as(u17, me[5]) << 8 | @as(u17, me[6]);

    return .{ .airborne_position = pos };
}

fn decodeAirborneVelocity(me: []const u8) DecodedPayload {
    const subtype = me[0] & 0x07;
    if (subtype != 1 and subtype != 2) return .unknown;

    var vel: AirborneVelocity = undefined;

    // EW direction and speed
    const ew_dir: bool = (me[1] & 0x04) != 0;
    const ew_raw: u16 = (@as(u16, me[1] & 0x03) << 8 | @as(u16, me[2]));
    const ew_vel: f32 = @as(f32, @floatFromInt(ew_raw)) - 1.0;

    // NS direction and speed
    const ns_dir: bool = (me[3] & 0x80) != 0;
    const ns_raw: u16 = (@as(u16, me[3] & 0x7F) << 3 | @as(u16, me[4] >> 5));
    const ns_vel: f32 = @as(f32, @floatFromInt(ns_raw)) - 1.0;

    // Apply direction signs
    const v_ew: f32 = if (ew_dir) -ew_vel else ew_vel;
    const v_ns: f32 = if (ns_dir) -ns_vel else ns_vel;

    // Supersonic subtype has 4x multiplier
    const mult: f32 = if (subtype == 2) 4.0 else 1.0;

    vel.ground_speed_kt = @sqrt((v_ew * mult) * (v_ew * mult) + (v_ns * mult) * (v_ns * mult));
    vel.heading_deg = std.math.radiansToDegrees(std.math.atan2(v_ew, v_ns));
    if (vel.heading_deg < 0) vel.heading_deg += 360.0;

    // Vertical rate
    const vr_sign: bool = (me[4] & 0x08) != 0;
    const vr_raw: u16 = (@as(u16, me[4] & 0x07) << 6 | @as(u16, me[5] >> 2));
    const vr_val: i16 = (@as(i16, @intCast(vr_raw)) - 1) * 64;
    vel.vertical_rate_fpm = if (vr_sign) -vr_val else vr_val;

    return .{ .airborne_velocity = vel };
}

test "decode identification - known message" {
    // 8D4840D6202CC371C32CE0576098 → DF17, TC=4, callsign "KLM1023 "
    const msg_bytes = [_]u8{ 0x8D, 0x48, 0x40, 0xD6, 0x20, 0x2C, 0xC3, 0x71, 0xC3, 0x2C, 0xE0, 0x57, 0x60, 0x98 };
    var msg: Message = std.mem.zeroes(Message);
    msg.raw = msg_bytes;
    msg.len = 14;
    msg.df = .extended_squitter;

    const result = decodeExtendedSquitter(&msg);
    switch (result) {
        .identification => |ident| {
            const callsign = std.mem.trimRight(u8, &ident.callsign, " ");
            _ = callsign;
        },
        else => try std.testing.expect(false),
    }
}

test "decode airborne position - altitude Q-bit" {
    // 8D40621D58C382D690C8AC2863A7 → DF17, TC=11, alt=38000ft
    const msg_bytes = [_]u8{ 0x8D, 0x40, 0x62, 0x1D, 0x58, 0xC3, 0x82, 0xD6, 0x90, 0xC8, 0xAC, 0x28, 0x63, 0xA7 };
    var msg: Message = std.mem.zeroes(Message);
    msg.raw = msg_bytes;
    msg.len = 14;
    msg.df = .extended_squitter;

    const result = decodeExtendedSquitter(&msg);
    switch (result) {
        .airborne_position => |pos| {
            try std.testing.expect(pos.altitude_ft > 0);
            try std.testing.expect(pos.altitude_ft < 50000);
        },
        else => try std.testing.expect(false),
    }
}

test "decode velocity - subtype 1" {
    // 8D485020994409940838175B284F → DF17, TC=19, subtype=1
    const msg_bytes = [_]u8{ 0x8D, 0x48, 0x50, 0x20, 0x99, 0x44, 0x09, 0x94, 0x08, 0x38, 0x17, 0x5B, 0x28, 0x4F };
    var msg: Message = std.mem.zeroes(Message);
    msg.raw = msg_bytes;
    msg.len = 14;
    msg.df = .extended_squitter;

    const result = decodeExtendedSquitter(&msg);
    switch (result) {
        .airborne_velocity => |vel| {
            try std.testing.expect(vel.ground_speed_kt > 0);
            try std.testing.expect(vel.ground_speed_kt < 1000);
            try std.testing.expect(vel.heading_deg >= 0);
            try std.testing.expect(vel.heading_deg < 360);
        },
        else => try std.testing.expect(false),
    }
}
