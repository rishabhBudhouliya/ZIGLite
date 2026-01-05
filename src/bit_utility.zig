const std = @import("std");

pub const result = struct { value: u64, next_position: u8 };

pub fn ProcessVarint(b: []const u8) result {
    var x: u64 = 0;
    for (b, 0..) |byte, i| {
        if (i < 8) {
            x = (x << 7) | (byte & 0x7f);
            if (byte & 0x80 == 0) {
                return .{ .value = x, .next_position = @intCast(i + 1) };
            }
        }
        if (i == 8) {
            x = (x << 8) | byte;
            return .{ .value = x, .next_position = @intCast(i + 1) };
        }
    }
    return .{ .value = x, .next_position = @intCast(b.len) };
}
