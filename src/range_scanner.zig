const std = @import("std");
const Pager = @import("pager.zig").Pager;
const header_parser = @import("header_parser.zig");
const btree = @import("btree.zig");
const record = @import("record.zig");

// Range scanner for B+Tree traversal
// Implements both synchronous and asynchronous (io_uring) versions

pub const ScanResult = struct {
    records_scanned: u64,
    pages_read: u64,
    elapsed_ns: u64,

    pub fn avgLatencyMs(self: ScanResult) f64 {
        return @as(f64, @floatFromInt(self.elapsed_ns)) / 1_000_000.0;
    }
};

/// Cursor frame - tracks position in Interior pages (breadcrumbs)
const CursorFrame = struct {
    page_id: u32,
    cell_idx: u16, // The index of the child pointer we followed
};

/// B+Tree Cursor - Iterator pattern for range scanning
pub const BTreeCursor = struct {
    pager: *Pager,
    allocator: std.mem.Allocator,

    // Traversal State
    stack: std.ArrayList(CursorFrame),
    current_page: ?btree.Page, // The active Leaf Page object
    current_cell_idx: u16, // Current position inside the active leaf
    pages_read: u64,

    pub fn init(pager: *Pager, allocator: std.mem.Allocator) BTreeCursor {
        return BTreeCursor{
            .pager = pager,
            .allocator = allocator,
            .stack = std.ArrayList(CursorFrame){},
            .current_page = null,
            .current_cell_idx = 0,
            .pages_read = 0,
        };
    }

    pub fn deinit(self: *BTreeCursor) void {
        // MEMORY FIX: Ensure we release the active page if we stop early
        if (self.current_page) |page| {
            page.deinit(self.allocator);
        }
        self.stack.deinit(self.allocator);
    }

    /// Phase 1: SEEK (Vertical Drop)
    /// Find the leaf containing start_key and populate stack
    pub fn seek(self: *BTreeCursor, root_page_id: u32, start_key: u64) !void {
        var next_page_id = root_page_id;

        while (true) {
            const page_data = self.pager.getPage(next_page_id);
            self.pages_read += 1;

            const header_offset: usize = if (next_page_id == 1) 100 else 0;
            const btree_header = try header_parser.parseBtreeHeader(page_data[header_offset..@min(page_data.len, header_offset + 12)]);

            const header_size: usize = if (btree_header.page_type == 0x05 or btree_header.page_type == 0x02) 12 else 8;
            const content_offset = header_offset + header_size;
            const cell_pointers_size = btree_header.cells * 2;
            const cell_pointers = page_data[content_offset .. content_offset + cell_pointers_size];

            const page = try btree.NewPage(self.allocator, btree_header, cell_pointers, page_data);

            switch (page) {
                .i_page => |*interior| {
                    // Find child covering the range
                    const cell_idx = try interior.findCellIndex(start_key);

                    // Push Frame
                    try self.stack.append(self.allocator, CursorFrame{
                        .page_id = next_page_id,
                        .cell_idx = @intCast(cell_idx),
                    });

                    // Determine next page ID
                    if (cell_idx < btree_header.cells) {
                        next_page_id = interior.GetLeftmostPageId(cell_idx);
                    } else {
                        next_page_id = btree_header.right_most_pointer;
                    }

                    // Cleanup interior page wrapper
                    page.deinit(self.allocator);
                },
                .l_page => |*leaf| {
                    // Found our starting point
                    self.current_cell_idx = @intCast(try leaf.findCellIndex(start_key));
                    self.current_page = page; // TAKE OWNERSHIP
                    return;
                },
            }
        }
    }

    /// User API: Get current record, move to next
    pub fn next(self: *BTreeCursor) !?[]record.Value {
        // If we have no page, we are done
        const page = self.current_page orelse return null;

        // 1. Check if we have valid data at current index
        const leaf = &page.l_page;
        if (self.current_cell_idx >= leaf.CellCount()) {
            // We are at the end of this leaf. Attempt to move to next leaf.
            const has_more = try self.advance();
            if (!has_more) return null; // End of Tree

            // Recurse: we are now at start of new leaf
            return self.next();
        }

        // 2. Fetch Data
        const rec = try leaf.getRecord(self.allocator, self.current_cell_idx);

        // 3. Move index forward locally
        self.current_cell_idx += 1;

        return rec;
    }

    /// Phase 2: ADVANCE (Horizontal Walk + Grandparent Fix)
    /// Returns true if a new leaf was found, false if tree is exhausted
    fn advance(self: *BTreeCursor) !bool {
        // 1. Release current leaf (Memory Fix)
        if (self.current_page) |page| {
            page.deinit(self.allocator);
            self.current_page = null;
        }

        // 2. Backtrack up the stack (Grandparent Fix)
        while (self.stack.items.len > 0) {
            var parent_frame = self.stack.pop() orelse unreachable;

            // Re-load Parent Page
            const p_data = self.pager.getPage(parent_frame.page_id);
            self.pages_read += 1;

            const p_header_offset: usize = if (parent_frame.page_id == 1) 100 else 0;
            const p_btree_header = try header_parser.parseBtreeHeader(p_data[p_header_offset..@min(p_data.len, p_header_offset + 12)]);

            const p_header_size: usize = 12; // Interior pages always 12 bytes
            const p_content_offset = p_header_offset + p_header_size;
            const p_cell_pointers_size = p_btree_header.cells * 2;
            const p_cell_pointers = p_data[p_content_offset .. p_content_offset + p_cell_pointers_size];

            const p_page = try btree.NewPage(self.allocator, p_btree_header, p_cell_pointers, p_data);
            defer p_page.deinit(self.allocator);

            // Move to next child in this parent
            parent_frame.cell_idx += 1;

            // Check if this parent has more children
            // Note: valid indices are 0 to N-1 (cells) AND N (rightmost)
            if (parent_frame.cell_idx <= p_btree_header.cells) {
                // Determine the Page ID of the new sibling
                var sibling_page_id: u32 = 0;
                if (parent_frame.cell_idx < p_btree_header.cells) {
                    sibling_page_id = p_page.i_page.GetLeftmostPageId(parent_frame.cell_idx);
                } else {
                    // The last child is the right-most pointer
                    sibling_page_id = p_btree_header.right_most_pointer;
                }

                // Push parent back with updated index
                try self.stack.append(self.allocator, parent_frame);

                // 3. Drill down to leftmost leaf of this new sibling
                try self.descendToLeftmost(sibling_page_id);
                return true;
            }

            // If parent is exhausted, loop continues (pop Grandparent)
        }

        return false; // Stack empty, tree finished
    }

    /// Helper: Given a page ID, dive left until a leaf is hit
    fn descendToLeftmost(self: *BTreeCursor, start_page_id: u32) !void {
        var next_id = start_page_id;
        while (true) {
            const data = self.pager.getPage(next_id);
            self.pages_read += 1;

            const header_offset: usize = if (next_id == 1) 100 else 0;
            const btree_header = try header_parser.parseBtreeHeader(data[header_offset..@min(data.len, header_offset + 12)]);

            const header_size: usize = if (btree_header.page_type == 0x05 or btree_header.page_type == 0x02) 12 else 8;
            const content_offset = header_offset + header_size;
            const cell_pointers_size = btree_header.cells * 2;
            const cell_pointers = data[content_offset .. content_offset + cell_pointers_size];

            const page = try btree.NewPage(self.allocator, btree_header, cell_pointers, data);

            switch (page) {
                .i_page => |*interior| {
                    // Push frame (always index 0 for leftmost)
                    try self.stack.append(self.allocator, CursorFrame{
                        .page_id = next_id,
                        .cell_idx = 0,
                    });

                    // Get left-most child
                    next_id = interior.GetLeftmostPageId(0);

                    page.deinit(self.allocator);
                },
                .l_page => {
                    // Found the leaf. Set as active.
                    self.current_page = page;
                    self.current_cell_idx = 0;
                    return;
                },
            }
        }
    }
};

/// Synchronous range scan using BTreeCursor (clean iterator pattern)
pub fn rangeScanSync(
    pager: *Pager,
    table_root_page: u32,
    start_row_id: u64,
    num_records: u64,
    allocator: std.mem.Allocator,
) !ScanResult {
    var timer = try std.time.Timer.start();

    // Initialize cursor
    var cursor = BTreeCursor.init(pager, allocator);
    defer cursor.deinit();

    // Seek to starting position
    try cursor.seek(table_root_page, start_row_id);

    // Scan records using iterator pattern
    var records_scanned: u64 = 0;
    while (records_scanned < num_records) {
        const rec = try cursor.next() orelse break; // End of tree
        defer allocator.free(rec);
        records_scanned += 1;
    }

    const elapsed_ns = timer.read();
    return ScanResult{
        .records_scanned = records_scanned,
        .pages_read = cursor.pages_read,
        .elapsed_ns = elapsed_ns,
    };
}

/// Asynchronous range scan using io_uring
/// TODO: Implement prefetching with batched I/O
pub fn rangeScanAsync(
    db_file: std.fs.File,
    start_page: u32,
    num_records: u64,
    allocator: std.mem.Allocator,
) !ScanResult {
    _ = db_file;
    _ = start_page;
    _ = num_records;
    _ = allocator;

    // Placeholder for io_uring implementation
    return error.NotImplementedYet;
}

test "range scan basic" {
    // Basic test placeholder
    std.debug.print("Range scanner tests TODO\n", .{});
}
