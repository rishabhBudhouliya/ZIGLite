const std = @import("std");

const bit_utils = @import("BitM.zig");

const Page = union(enum) {
    l_page: LeafPage,
    i_page: InteriorPage,
};

pub fn NewPage(alloc: std.heap.DebugAllocator(.{}), bh: BtreeHeader, cell_pointer: []u8, page_content: []u8) Page {
    // var alloc = std.heap.DebugAllocator(.{}).init;
    const base_page = try BasePage.init(parseCellPointers(alloc, cell_pointer), page_content, bh);
    switch (bh.Type) {
        0x0d => return &LeafPage{base_page},
        0x05 => return &InteriorPage{base_page},
    }
}

// at this level, I won't know the size of the page or its internals.
// this is a runtime known information
const BasePage = struct {
    bh: *BtreeHeader,
    offsets: []const u16,
    content: []const u8,

    pub fn init(cell_pointer: []const u16, page_content: []const u8, header: *BtreeHeader) !BasePage {
        return .{ .bh = header, .offsets = cell_pointer, .content = page_content };
    }
};

const BtreeHeader = struct { Type: u8, Cells: u16, RightMostPointer: *u32 };

pub const LeafPage = struct {
    b_page: BasePage,
    pub fn CellCount(self: *const LeafPage) !u8 {
        return self.b_page.offsets.len;
    }

    pub fn GetRowId(self: *const LeafPage, i: u64) !u64 {
        if (i < 0 or i >= self.b_page.offsets.len) {
            return 0;
        }
        const offset = self.b_page.offsets[i];
        if (offset != 0) {
            const cell = self.b_page.content[offset..self.b_page.content.len];
            _ = bit_utils.ProcessVarint(cell);
        }
        const cell = self.b_page.content[offset..self.b_page.content.len];
        cell = cell[4..cell.len];
        const result = bit_utils.ProcessVarint(cell);
        return result.value;
    }

    pub fn GetRecord(self: *const LeafPage, i: u64) Record {}
};

pub fn parseCellPointers(alloc: std.heap.DebugAllocator(.{}), cell_pointer: []u8) []u16 {
    const allocator = alloc.allocator();
    const offsets = try allocator.alloc(u16, (cell_pointer.len) / 2);
    for ((cell_pointer.len) / 2) |pointer| {
        offsets[pointer] = std.mem.readInt(u16, cell_pointer[pointer * 2 .. pointer * 2 + 2], .big);
    }
    return offsets;
}

pub const InteriorPage = struct {
    b_page: BasePage,

    pub fn CellCount(self: *const InteriorPage) !u8 {
        return self.b_page.offsets.len;
    }

    pub fn GetRowId(self: *const InteriorPage, i: u64) !?u64 {
        if (i < 0 or i >= self.b_page.offsets.len) {
            return 0;
        }
        const offset = self.b_page.offsets[i];
        const cell = self.b_page.content[offset..self.b_page.content.len];
        cell = cell[4..cell.len];
        const result = bit_utils.ProcessVarint(cell);
        return result.value;
    }

    pub fn GetLeftmostPageId(self: *const InteriorPage, i: u64) u32 {
        if (i < 0 or i >= self.b_page.offsets.len) {
            return 0;
        }
        const offset = self.b_page.offsets[i];
        const cell = self.b_page.content[offset..self.b_page.content.len];
        const left_page_number = std.mem.readInt(u32, cell[0..4], .big);
        return left_page_number;
    }
};

pub fn main() !void {
    // var alloc = std.heap.DebugAllocator(.{}).init;
    // const dbAlloc = alloc.allocator();
    var temp: u32 = 10;
    const cp = [_]u16{ 10, 12, 14, 16 };
    // const cp_slice: []u16 = cp[0..];
    const page_content = [3]u8{ 5, 5, 5 };
    var header = BtreeHeader{ .Type = 1, .Cells = 10, .RightMostPointer = &temp };
    const bPage = try BasePage.init(&cp, &page_content, &header);
    const page = InteriorPage{ .b_page = bPage };
    std.debug.print("Page: {any}\n", .{page});
}
