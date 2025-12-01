// user interface api
// also implement b+tree search here
const std = @import("std");
const pager = @import("pager.zig");
const header_parser = @import("header_parser.zig");
const btree = @import("btree.zig");

pub const Database = struct {
    p: pager.Pager,

    pub fn newDatabase(file_name: []const u8) !Database {
        const p = pager.Pager.open(file_name);
        return Database{ .p = p };
    }

    pub fn search(self: *Database, alloc: std.mem.Allocator, row_id: u64) void {
        const page_id = 1;
        var bTree_header: header_parser.BtreeHeader = undefined;
        // search through the first page?
        const page_content = self.p.getPage(1);
        if (page_id == 1) {
            // first page processing
            bTree_header = header_parser.parseBtreeHeader(page_content[100..112]);
            if (bTree_header) {
                if (bTree_header.page_type == 0x0d) {
                    page_content = page_content[108..];
                } else {
                    page_content = page_content[112..];
                }
            } else |err| {
                std.debug.print(err, .{});
            }
        } else {
            bTree_header = header_parser.parseBtreeHeader(page_content[0..12]);
            if (bTree_header) {
                if (bTree_header.page_type == 0x0d) {
                    page_content = page_content[8..];
                } else {
                    page_content = page_content[12..];
                }
            } else |err| {
                std.debug.print(err, .{});
            }
        }
        const page = btree.NewPage(alloc, bTree_header, page_content[0..(2 * bTree_header.cells)], page_content);
        switch (page) {
            .l_page => |leaf_page| {},
            .i_page => |interior_page| {
                
            },
        }
    }
};
