const std = @import("std");

pub const SampleSource = union(enum) {
    file: FileSource,
    // rtlsdr: RtlSdrSource,
    // network: NetworkSource,
};

pub const FileSource = struct {
    file: std.fs.File,
    buf: []u8,

    pub fn openFile(path: []const u8) !FileSource {
        const file = try std.fs.cwd().openFile(path, .{});
        return .{ .file = file, .buf = &.{} };
    }

    pub fn close(self: *FileSource) void {
        self.file.close();
    }
};

test "FileSource placeholder" {}
