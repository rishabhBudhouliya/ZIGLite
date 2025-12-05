const std = @import("std");
const expect = std.testing.expect;

const bit_utils = @import("bit_utility.zig");

pub const Value = union(enum) { null_value, int8: i8, int16: i16, int24: i32, int32: i32, int48: i64, int64: i64, float64: f64, text: []const u8, blob: []const u8 };

pub const RecordData = struct {
    row_id: u64,
    payload_size: u64,
    payload: []const u8,
};

pub fn CreateRecord(alloc: std.mem.Allocator, payload: []const u8) ![]Value {
    // for now, return an empty payload if length is empty
    if (payload.len == 0) {
        return &[_]Value{};
    }
    const result = bit_utils.ProcessVarint(payload);
    const header_size = result.value;
    const next_bit_position = result.next_position;

    var column_list = payload[next_bit_position..header_size];
    var body = payload[header_size..];

    // First pass: count how many columns there are
    var num_columns: usize = 0;
    var temp_list = column_list;
    while (temp_list.len > 0) {
        const col_val = bit_utils.ProcessVarint(temp_list);
        temp_list = temp_list[col_val.next_position..];
        num_columns += 1;
    }

    var count: usize = 0;
    const record: []Value = try alloc.alloc(Value, num_columns);
    while (column_list.len > 0) {
        const column_value = bit_utils.ProcessVarint(column_list);
        const next_col = column_value.next_position;
        const column = column_value.value;

        column_list = column_list[next_col..];
        switch (column) {
            0 => {
                record[count] = Value.null_value;
                count += 1;
            },
            1 => {
                const val = @as(i8, @bitCast(body[0]));
                body = body[1..];
                record[count] = Value{ .int8 = val };
                count += 1;
            },
            2 => {
                const val = std.mem.readInt(i16, body[0..2], .big);
                body = body[2..];
                record[count] = Value{ .int16 = val };
                count += 1;
            },
            3 => {
                // 3 bytes from the body
                const val: i32 = @intCast((@as(u32, body[0]) << 16) |
                    (@as(u32, body[1]) << 8) |
                    @as(u32, body[2]));
                body = body[3..];
                record[count] = Value{ .int24 = val };
                count += 1;
            },
            4 => {
                const val = std.mem.readInt(i32, body[0..4], .big);
                body = body[4..];
                record[count] = Value{ .int32 = val };
                count += 1;
            },
            5 => {
                // 48-bit integer (6 bytes) - manual bit shifting
                const val: i64 = @intCast((@as(u64, body[0]) << 40) |
                    (@as(u64, body[1]) << 32) |
                    (@as(u64, body[2]) << 24) |
                    (@as(u64, body[3]) << 16) |
                    (@as(u64, body[4]) << 8) |
                    @as(u64, body[5]));
                body = body[6..];
                record[count] = Value{ .int48 = val };
                count += 1;
            },
            6 => {
                const val = std.mem.readInt(i64, body[0..8], .big);
                body = body[8..];
                record[count] = Value{ .int64 = val };
                count += 1;
            },
            7 => {
                const int_bits = std.mem.readInt(u64, body[0..8], .big);
                const val: f64 = @bitCast(int_bits);
                body = body[8..];
                record[count] = Value{ .float64 = val };
                count += 1;
            },
            8 => {
                // Serial type 8: constant 0 (doesn't consume bytes from body)
                record[count] = Value{ .int32 = 0 };
                count += 1;
            },
            9 => {
                // Serial type 9: constant 1 (doesn't consume bytes from body)
                record[count] = Value{ .int32 = 1 };
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
                    const n: usize = @intCast((column - 12) / 2);
                    record[count] = Value{ .blob = body[0..n] };
                    body = body[n..];
                    count += 1;
                } else if (column >= 13 and column % 2 != 0) {
                    const n: usize = @intCast((column - 13) / 2);
                    record[count] = Value{ .text = body[0..n] };
                    body = body[n..];
                    count += 1;
                }
            },
        }
    }
    return record;
}

test "test Record" {
    const a = 10;
    try expect(a == 10);
}
