const std = @import("std");
const decode = @import("decode.zig");

pub const Aircraft = struct {
    icao: u24,
    callsign: [8]u8,
    latitude: f64,
    longitude: f64,
    altitude_ft: i32,
    heading_deg: f32,
    ground_speed_kt: f32,
    vertical_rate_fpm: i16,
    last_seen_ns: u64,
    messages_received: u32,

    even_cpr_lat: u17,
    even_cpr_lon: u17,
    odd_cpr_lat: u17,
    odd_cpr_lon: u17,
    even_cpr_time_ns: u64,
    odd_cpr_time_ns: u64,

    has_callsign: bool,
    has_altitude: bool,
    has_velocity: bool,

    pub fn init(icao: u24) Aircraft {
        var a: Aircraft = std.mem.zeroes(Aircraft);
        a.icao = icao;
        return a;
    }

    pub fn updateFromPayload(self: *Aircraft, payload: decode.DecodedPayload, timestamp_ns: u64) void {
        self.last_seen_ns = timestamp_ns;
        self.messages_received += 1;

        switch (payload) {
            .identification => |ident| {
                self.callsign = ident.callsign;
                self.has_callsign = true;
            },
            .airborne_position => |pos| {
                self.altitude_ft = pos.altitude_ft;
                self.has_altitude = true;
                if (pos.odd_flag) {
                    self.odd_cpr_lat = pos.lat_cpr;
                    self.odd_cpr_lon = pos.lon_cpr;
                    self.odd_cpr_time_ns = timestamp_ns;
                } else {
                    self.even_cpr_lat = pos.lat_cpr;
                    self.even_cpr_lon = pos.lon_cpr;
                    self.even_cpr_time_ns = timestamp_ns;
                }
            },
            .airborne_velocity => |vel| {
                self.heading_deg = vel.heading_deg;
                self.ground_speed_kt = vel.ground_speed_kt;
                self.vertical_rate_fpm = vel.vertical_rate_fpm;
                self.has_velocity = true;
            },
            .unknown => {},
        }
    }
};

pub const AircraftTable = struct {
    entries: std.AutoHashMap(u24, Aircraft),

    pub fn init(allocator: std.mem.Allocator) AircraftTable {
        return .{ .entries = std.AutoHashMap(u24, Aircraft).init(allocator) };
    }

    pub fn deinit(self: *AircraftTable) void {
        self.entries.deinit();
    }

    pub fn getOrCreate(self: *AircraftTable, icao: u24) !*Aircraft {
        const result = try self.entries.getOrPut(icao);
        if (!result.found_existing) {
            result.value_ptr.* = Aircraft.init(icao);
        }
        return result.value_ptr;
    }
};

test "aircraft table get or create" {
    const allocator = std.testing.allocator;
    var table = AircraftTable.init(allocator);
    defer table.deinit();

    const ac = try table.getOrCreate(0xABCDEF);
    try std.testing.expectEqual(@as(u24, 0xABCDEF), ac.icao);
}

test "aircraft update from identification" {
    var ac = Aircraft.init(0x123456);
    ac.updateFromPayload(.{ .identification = .{
        .callsign = "TEST1234".*,
        .category = 0xA0,
    } }, 1000);
    try std.testing.expect(ac.has_callsign);
    try std.testing.expectEqualStrings("TEST1234", &ac.callsign);
}

test "aircraft update from position" {
    var ac = Aircraft.init(0x123456);
    ac.updateFromPayload(.{ .airborne_position = .{
        .lat_cpr = 1000,
        .lon_cpr = 2000,
        .altitude_ft = 35000,
        .odd_flag = false,
    } }, 1000);
    try std.testing.expect(ac.has_altitude);
    try std.testing.expectEqual(@as(i32, 35000), ac.altitude_ft);
    try std.testing.expectEqual(@as(u17, 1000), ac.even_cpr_lat);
}
