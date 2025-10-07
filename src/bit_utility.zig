const std = @import("std");

const result = struct { value: u64, next_position: u8 };

pub fn ProcessVarint(b: []u8) result {
    var x: i64 = undefined;
    for (b) |i| {
        if (i < 8) {
            x = (x << 7) | (b[i] & 0x7f);
            if (b[i] & 0x80 == 0) {
                return .{ .value = x, .nextPos = i + 1 };
            }
        }
        if (i == 8) {
            x = (x << 8) | b[i];
            return .{ .value = x, .nextPos = i + 1 };
        }
    }
    return x;
}
