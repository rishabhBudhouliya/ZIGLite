const std = @import("std");

const bit_utils = @import("BitM.zig");

const Value = union(enum) { null_value, int8: i8, int16: i16, int24: i32, int32: i32, int48: i64, int64: i64, float64: f64, text: []const u8, blob: []const u8 };

pub fn CreateRecord(alloc: std.heap.DebugAllocator(.{}), payload: *const []u8) []Value {
    // for now, return an empty payload if length is empty
    if (payload.len == 0) {
        return {};
    }
    const result = bit_utils.ProcessVarint(payload);
    if (result == null) {
        std.debug.print("Unable to process first varint of payload");
        return null;
    }
    const header_size = result.value;
    const next_bit_position = result.nextPos;

    const column_list = payload[next_bit_position..header_size];
    const body = payload[header_size..];

    const count = 0;
    const record: []Value = try alloc.allocator().alloc(Value, column_list.len);
    while (column_list.len > 0) {
        const column_value = bit_utils.ProcessVarint(column_list);
        const next_col = column_value.nextPos;
        const column = column_value.value;

        if (next_col < 0) {
            return null;
        }

        column_list = column_list[next_col..];
        switch (column) {
            0 => {
                record[count] = Value.null_value;
                count += 1;
            },
            1 => {
                const val = @as(i8, @bitCast(body.*[0]));
                body.* = body.*[1..];
                record[count] = Value{ .int8 = val };
                count += 1;
            },
            2 => {
                const val = std.mem.readInt(i16, body.*[0..2], .big);
                body.* = body.*[2..];
                record[count] = Value{ .int16 = val };
                count += 1;
            },
            3 => {
                // 3 bytes from the body
                const val = std.mem.readInt(i32, body.*[0..3], .big);
                body.* = body.*[3..];
                record[count] = Value{ .int24 = val };
                count += 1;
            },
            4 => {
                const val = std.mem.readInt(i32, body.*[0..4], .big);
                body.* = body.*[4..];
                record[count] = Value{ .int32 = val };
                count += 1;
            },
            5 => {
                const val = std.mem.readInt(i64, body.*[0..6], .big);
                body.* = body.*[6..];
                record[count] = Value{ .int48 = val };
                count += 1;
            },
            6 => {
                const val = std.mem.readInt(i64, body.*[0..8], .big);
                body.* = body.*[8..];
                record[count] = Value{ .int64 = val };
                count += 1;
            },
            7 => {
                const val = std.mem.readInt(f64, body.*[0..8], .big);
                body.* = body.*[8..];
                record[count] = Value{ .float64 = val };
                count += 1;
            },
            8 => {
                const val = i32(0);
                body.* = body.*[4..];
                record[count] = Value{ .int32 = val };
                count += 1;
            },
            9 => {
                const val = i32(1);
                body.* = body.*[4..];
                record[count] = Value{ .int32 = val };
                count += 1;
            },
            10 => {
                std.debug.print("Serial code not supported: {any}\n", .{10});
            },
            11 => {
                std.debug.print("Serial code not supported: {any}\n", .{11});
            },
            else => {
                if (column >= 12 and column % 2 == 0) {
                    const n = (column - 12) / 2;
                    record[count] = Value{ .blob = body.*[0..n] };
                    body.* = body.*[n..];
                    count += 1;
                } else if (column >= 13 and column % 2 != 0) {
                    const n = (column - 13) / 2;
                    record[count] = Value{ .text = body.*[0..n] };
                    body.* = body.*[n..];
                    count += 1;
                }
            },
        }
    }
    return record;
}
