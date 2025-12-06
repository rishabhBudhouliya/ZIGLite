const std = @import("std");

const bit_utils = @import("bit_utility.zig");
const record = @import("record.zig");
const header_parser = @import("header_parser.zig");

pub const Page = union(enum) {
    l_page: LeafPage,
    i_page: InteriorPage,

    pub fn deinit(self: Page, allocator: std.mem.Allocator) void {
        switch (self) {
            .l_page => |lp| allocator.free(lp.b_page.offsets),
            .i_page => |ip| allocator.free(ip.b_page.offsets),
        }
    }
};

pub fn NewPage(alloc: std.mem.Allocator, bh: header_parser.BtreeHeader, cell_pointer: []u8, page_content: []u8) !Page {
    const base_page = try BasePage.init(try parseCellPointers(alloc, cell_pointer), page_content, bh);
    switch (bh.page_type) {
        0x0d => return Page{ .l_page = LeafPage{ .b_page = base_page } },
        0x05 => return Page{ .i_page = InteriorPage{ .b_page = base_page } },
        else => return error.InvalidPageType,
    }
}

// at this level, I won't know the size of the page or its internals.
// this is a runtime known information
const BasePage = struct {
    bh: header_parser.BtreeHeader,
    offsets: []const u16,
    content: []const u8,

    pub fn init(cell_pointer: []const u16, page_content: []const u8, header: header_parser.BtreeHeader) !BasePage {
        return .{ .bh = header, .offsets = cell_pointer, .content = page_content };
    }
};

pub const LeafPage = struct {
    b_page: BasePage,
    pub fn CellCount(self: *const LeafPage) usize {
        return self.b_page.offsets.len;
    }

    pub fn findCellIndex(self: *const LeafPage, target_id: u64) !usize {
        var left: usize = 0;
        var right: usize = self.CellCount();

        while (left < right) {
            const mid = left + (right - left) / 2;
            const mid_row_id = try self.GetRowId(mid);

            if (mid_row_id < target_id) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }
        return left;
    }

    pub fn GetRowId(self: *const LeafPage, i: u64) !u64 {
        if (i >= self.b_page.offsets.len) {
            return 0;
        }
        const offset = self.b_page.offsets[i];
        const cell = self.b_page.content[offset..];
        // size of payload within leaf cell
        const size = bit_utils.ProcessVarint(cell);
        const result = bit_utils.ProcessVarint(cell[size.next_position..]);
        return result.value;
    }

    pub fn getRecord(self: *const LeafPage, alloc: std.mem.Allocator, i: u64) ![]record.Value {
        // each page has a header, offset and cells
        const offset = self.b_page.offsets[i];
        // we have the offset (location of where the cell is)
        const cell = self.b_page.content[offset..];
        // within the cell, we have size of payload, row id, payload, page overflow
        const size = bit_utils.ProcessVarint(cell);
        const row_id = bit_utils.ProcessVarint(cell[size.next_position..]);
        // i == row_id_result.value
        const start_position = row_id.next_position + size.next_position;
        const payload = cell[(start_position)..(start_position + size.value)];
        return record.CreateRecord(alloc, payload);
    }
};

pub fn parseCellPointers(alloc: std.mem.Allocator, cell_pointer: []u8) ![]u16 {
    const offsets = try alloc.alloc(u16, (cell_pointer.len) / 2);
    for (0..(cell_pointer.len) / 2) |pointer| {
        offsets[pointer] = std.mem.readInt(u16, cell_pointer[pointer * 2 ..][0..2], .big);
    }
    return offsets;
}

pub const InteriorPage = struct {
    b_page: BasePage,

    pub fn CellCount(self: *const InteriorPage) usize {
        return self.b_page.offsets.len;
    }

    pub fn findCellIndex(self: *const InteriorPage, target_id: u64) !usize {
        var left: usize = 0;
        var right: usize = self.CellCount();

        while (left < right) {
            const mid = left + (right - left) / 2;
            const mid_row_id = try self.GetRowId(mid);

            if (mid_row_id < target_id) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }
        return left;
    }

    pub fn GetRowId(self: *const InteriorPage, i: u64) !u64 {
        if (i >= self.b_page.offsets.len) {
            return 0;
        }
        const offset = self.b_page.offsets[i];
        const cell = self.b_page.content[offset..self.b_page.content.len];
        const cell_after_skip = cell[4..cell.len];
        const result = bit_utils.ProcessVarint(cell_after_skip);
        return result.value;
    }

    pub fn GetLeftmostPageId(self: *const InteriorPage, i: u64) u32 {
        if (i >= self.b_page.offsets.len) {
            return 0;
        }
        const offset = self.b_page.offsets[i];
        const cell = self.b_page.content[offset..self.b_page.content.len];
        const left_page_number = std.mem.readInt(u32, cell[0..4], .big);
        return left_page_number;
    }
};

pub fn main() !void {
    const cp = [_]u16{ 10, 12, 14, 16 };
    const page_content = [3]u8{ 5, 5, 5 };
    const header = header_parser.BtreeHeader{ .page_type = 1, .cells = 10, .right_most_pointer = 10 };
    const bPage = try BasePage.init(&cp, &page_content, header);
    const page = InteriorPage{ .b_page = bPage };
    std.debug.print("Page: {any}\n", .{page});
}
