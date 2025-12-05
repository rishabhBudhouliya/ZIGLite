const std = @import("std");
const Pager = @import("pager.zig");
const btree = @import("btree.zig");

const CursorFrame = struct {
    page_id: u32,
    cell_idx: u16, 
};

pub const BtreeCursor = struct {
    pager: *Pager,
    allocator: std.mem.Allocator,

    stack: std.ArrayList(CursorFrame),
    current_page: ?Btree
}