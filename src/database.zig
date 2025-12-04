// user interface api
// also implement b+tree search here
const std = @import("std");
const pager = @import("pager.zig");
const header_parser = @import("header_parser.zig");
const btree = @import("btree.zig");

pub const Database = struct {
    p: pager.Pager,

    pub fn newDatabase(file_name: []const u8) !Database {
        const p = try pager.Pager.open(file_name);
        return Database{ .p = p };
    }

    pub fn search(self: *Database, alloc: std.mem.Allocator, row_id: u64) !void {
        var current_page_id: u32 = 1; // Start at root

        // Navigate down the B+Tree
        while (true) {
            const page_data = self.p.getPage(current_page_id);

            // Determine header offset (page 1 has 100-byte database header first)
            const header_offset: usize = if (current_page_id == 1) 100 else 0;

            // Parse B+Tree header (try both 8 and 12 bytes, parser handles it)
            const btree_header = try header_parser.parseBtreeHeader(page_data[header_offset..@min(page_data.len, header_offset + 12)]);

            // Calculate where cell pointers and content start
            const header_size: usize = if (btree_header.page_type == 0x05 or btree_header.page_type == 0x02) 12 else 8;
            const content_offset = header_offset + header_size;

            // Cell pointers: 2 bytes per cell
            const cell_pointers_size = btree_header.cells * 2;
            const cell_pointers = page_data[content_offset .. content_offset + cell_pointers_size];

            // Create page object
            const page = try btree.NewPage(alloc, btree_header, cell_pointers, page_data);

            switch (page) {
                .l_page => |*leaf_page| {
                    // Found leaf page! Search for row_id here
                    const cell_idx = try leaf_page.findCellIndex(row_id);

                    // Verify we found the exact row_id
                    const found_row_id = try leaf_page.GetRowId(cell_idx);
                    if (found_row_id != row_id) {
                        std.debug.print("Row ID {} not found (closest is {})\n", .{ row_id, found_row_id });
                        return error.RowNotFound;
                    }

                    std.debug.print("Found in leaf page {}, cell index: {}\n", .{ current_page_id, cell_idx });

                    // Extract the actual record
                    const rec = try leaf_page.getRecord(alloc, cell_idx);
                    _ = rec; // Use later when record parsing is fixed
                    std.debug.print("Successfully extracted record for row_id {}\n", .{row_id});

                    return; // Done!
                },
                .i_page => |*interior_page| {
                    // Interior page: find which child to navigate to
                    const cell_idx = try interior_page.findCellIndex(row_id);

                    // Get the child page number to navigate to
                    if (cell_idx < btree_header.cells) {
                        current_page_id = interior_page.GetLeftmostPageId(cell_idx);
                    } else {
                        // Use rightmost pointer
                        current_page_id = btree_header.right_most_pointer;
                    }

                    std.debug.print("Navigating to child page: {}\n", .{current_page_id});
                    // Continue loop to next page
                },
            }
        }
    }
};

pub fn main() !void {
    std.debug.print("=== Database B+Tree Search Test ===\n\n", .{});

    // Setup allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Open database
    const db_path = "sample.db";
    std.debug.print("Opening database: {s}\n", .{db_path});

    var db = try Database.newDatabase(db_path);
    defer db.p.close();

    std.debug.print("✓ Database opened\n\n", .{});

    // Search for row_id 70
    const target_row_id: u64 = 70;
    std.debug.print("Searching for row_id: {}\n", .{target_row_id});
    std.debug.print("Navigating B+Tree...\n\n", .{});

    try db.search(allocator, target_row_id);

    std.debug.print("\n=== Search Complete ===\n", .{});
}

test "database compiles" {
    // This forces database.zig to be compiled during tests
    _ = Database;
}
