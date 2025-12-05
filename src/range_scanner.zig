const std = @import("std");
const Pager = @import("pager.zig").Pager;
const PageBuffer = @import("pager.zig").PageBuffer;
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
    current_leaf_buffer: ?PageBuffer, // Own the page buffer for current leaf
    current_page: ?btree.Page, // The active Leaf Page object
    current_cell_idx: u16, // Current position inside the active leaf
    pages_read: u64,

    pub fn init(pager: *Pager, allocator: std.mem.Allocator) BTreeCursor {
        return BTreeCursor{
            .pager = pager,
            .allocator = allocator,
            .stack = std.ArrayList(CursorFrame){},
            .current_leaf_buffer = null,
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
            // Read page into buffer using pread
            var buffer: PageBuffer = undefined;
            try self.pager.readPage(next_page_id, &buffer);
            self.pages_read += 1;

            const page_data = buffer[0..];
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

                    // Cleanup interior page wrapper (buffer goes out of scope)
                    page.deinit(self.allocator);
                },
                .l_page => {
                    // Found our starting point - store buffer FIRST, then create page from stored buffer
                    self.current_leaf_buffer = buffer;

                    // Now create page from the stored buffer (so slices point to correct location)
                    const stored_data = self.current_leaf_buffer.?[0..];
                    const stored_header_offset: usize = if (next_page_id == 1) 100 else 0;
                    const stored_btree_header = try header_parser.parseBtreeHeader(stored_data[stored_header_offset..@min(stored_data.len, stored_header_offset + 12)]);
                    const stored_header_size: usize = 8; // Leaf pages: 8-byte header
                    const stored_content_offset = stored_header_offset + stored_header_size;
                    const stored_cell_pointers_size = stored_btree_header.cells * 2;
                    const stored_cell_pointers = stored_data[stored_content_offset .. stored_content_offset + stored_cell_pointers_size];

                    const stored_page = try btree.NewPage(self.allocator, stored_btree_header, stored_cell_pointers, stored_data);

                    // Clean up the original page that was pointing to stack buffer
                    page.deinit(self.allocator);

                    self.current_cell_idx = @intCast(try stored_page.l_page.findCellIndex(start_key));
                    self.current_page = stored_page;
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

            // Re-load Parent Page using pread
            var p_buffer: PageBuffer = undefined;
            try self.pager.readPage(parent_frame.page_id, &p_buffer);
            self.pages_read += 1;

            const p_data = p_buffer[0..];
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
            // Read page using pread
            var buffer: PageBuffer = undefined;
            try self.pager.readPage(next_id, &buffer);
            self.pages_read += 1;

            const data = buffer[0..];
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

                    // Cleanup interior page (buffer goes out of scope)
                    page.deinit(self.allocator);
                },
                .l_page => {
                    // Found the leaf. Store buffer FIRST, then create page from stored buffer.
                    self.current_leaf_buffer = buffer;

                    // Now create page from the stored buffer (so slices point to correct location)
                    const stored_data = self.current_leaf_buffer.?[0..];
                    const stored_header_offset: usize = if (next_id == 1) 100 else 0;
                    const stored_btree_header = try header_parser.parseBtreeHeader(stored_data[stored_header_offset..@min(stored_data.len, stored_header_offset + 12)]);
                    const stored_header_size: usize = 8; // Leaf pages: 8-byte header
                    const stored_content_offset = stored_header_offset + stored_header_size;
                    const stored_cell_pointers_size = stored_btree_header.cells * 2;
                    const stored_cell_pointers = stored_data[stored_content_offset .. stored_content_offset + stored_cell_pointers_size];

                    const stored_page = try btree.NewPage(self.allocator, stored_btree_header, stored_cell_pointers, stored_data);

                    // Clean up the original page that was pointing to stack buffer
                    page.deinit(self.allocator);

                    self.current_page = stored_page;
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

// ============================================================================
// io_uring Async Implementation
// ============================================================================

/// Prefetch depth - number of pages to keep in flight
const PREFETCH_DEPTH: usize = 8;

/// Ring buffer pool for async page prefetching
const RingBufferPool = struct {
    buffers: [PREFETCH_DEPTH]PageBuffer,
    in_use: [PREFETCH_DEPTH]bool,

    pub fn init() RingBufferPool {
        return RingBufferPool{
            .buffers = undefined, // Will be filled by io_uring
            .in_use = [_]bool{false} ** PREFETCH_DEPTH,
        };
    }

    pub fn getAvailableSlot(self: *RingBufferPool) ?usize {
        for (self.in_use, 0..) |used, i| {
            if (!used) return i;
        }
        return null;
    }

    pub fn markUsed(self: *RingBufferPool, slot: usize) void {
        self.in_use[slot] = true;
    }

    pub fn markFree(self: *RingBufferPool, slot: usize) void {
        self.in_use[slot] = false;
    }
};

/// Shadow cursor for lookahead - finds upcoming leaf page IDs without loading data
const ShadowCursor = struct {
    pager: *Pager,
    allocator: std.mem.Allocator,
    stack: std.ArrayList(CursorFrame),
    current_leaf_id: u32,
    current_cell_idx: u16,
    leaf_cells_remaining: u16,

    /// Clone from main cursor
    pub fn clone(from: *BTreeCursor, pager: *Pager, allocator: std.mem.Allocator) !ShadowCursor {
        var stack_copy = std.ArrayList(CursorFrame){};
        try stack_copy.appendSlice(allocator, from.stack.items);

        // Extract current leaf page ID from cursor
        // We need to track which page we're on for the shadow cursor
        const current_leaf_id = if (from.stack.items.len > 0) blk: {
            // If we have a stack, we're in a leaf that's a child of the top frame
            // We need to figure out the current leaf's page ID
            // For simplicity, we'll re-seek to find it
            break :blk 0; // Will be set by first peekNextLeafId call
        } else 0;

        return ShadowCursor{
            .pager = pager,
            .allocator = allocator,
            .stack = stack_copy,
            .current_leaf_id = current_leaf_id,
            .current_cell_idx = from.current_cell_idx,
            .leaf_cells_remaining = 0, // Will be updated
        };
    }

    pub fn deinit(self: *ShadowCursor) void {
        self.stack.deinit(self.allocator);
    }

    /// Peek ahead to find the next leaf page ID without loading data
    /// Returns null if no more leaves
    pub fn peekNextLeafId(self: *ShadowCursor) !?u32 {
        // Similar to BTreeCursor.advance(), but only returns page IDs
        // We need to navigate to the next leaf page

        // If we haven't initialized current_leaf_id yet, return 0 (signal to caller)
        if (self.current_leaf_id == 0) {
            return null;
        }

        // Navigate to next leaf using stack (same logic as advance)
        while (self.stack.items.len > 0) {
            var parent_frame = self.stack.pop() orelse unreachable;

            // Re-load parent page
            var p_buffer: PageBuffer = undefined;
            try self.pager.readPage(parent_frame.page_id, &p_buffer);

            const p_data = p_buffer[0..];
            const p_header_offset: usize = if (parent_frame.page_id == 1) 100 else 0;
            const p_btree_header = try header_parser.parseBtreeHeader(p_data[p_header_offset..@min(p_data.len, p_header_offset + 12)]);

            // Move to next child
            parent_frame.cell_idx += 1;

            if (parent_frame.cell_idx <= p_btree_header.cells) {
                // Found next sibling
                var sibling_page_id: u32 = 0;
                if (parent_frame.cell_idx < p_btree_header.cells) {
                    // Read interior page to get child pointer
                    const p_header_size: usize = 12;
                    const p_content_offset = p_header_offset + p_header_size;
                    const p_cell_pointers_size = p_btree_header.cells * 2;
                    const p_cell_pointers = p_data[p_content_offset .. p_content_offset + p_cell_pointers_size];

                    const p_page = try btree.NewPage(self.allocator, p_btree_header, p_cell_pointers, p_data);
                    defer p_page.deinit(self.allocator);

                    sibling_page_id = p_page.i_page.GetLeftmostPageId(parent_frame.cell_idx);
                } else {
                    sibling_page_id = p_btree_header.right_most_pointer;
                }

                // Push parent back
                try self.stack.append(self.allocator, parent_frame);

                // Descend to leftmost leaf of sibling
                const leaf_id = try self.descendToLeftmostLeaf(sibling_page_id);
                self.current_leaf_id = leaf_id;
                return leaf_id;
            }
        }

        return null; // Tree exhausted
    }

    /// Helper: Descend to leftmost leaf and return its page ID
    fn descendToLeftmostLeaf(self: *ShadowCursor, start_page_id: u32) !u32 {
        var next_id = start_page_id;

        while (true) {
            var buffer: PageBuffer = undefined;
            try self.pager.readPage(next_id, &buffer);

            const data = buffer[0..];
            const header_offset: usize = if (next_id == 1) 100 else 0;
            const btree_header = try header_parser.parseBtreeHeader(data[header_offset..@min(data.len, header_offset + 12)]);

            // Check if this is a leaf
            if (btree_header.page_type == 0x0d) {
                // Leaf page - return its ID
                return next_id;
            }

            // Interior page - push frame and go left
            try self.stack.append(self.allocator, CursorFrame{
                .page_id = next_id,
                .cell_idx = 0,
            });

            // Parse to get leftmost child
            const header_size: usize = 12;
            const content_offset = header_offset + header_size;
            const cell_pointers_size = btree_header.cells * 2;
            const cell_pointers = data[content_offset .. content_offset + cell_pointers_size];

            const page = try btree.NewPage(self.allocator, btree_header, cell_pointers, data);
            defer page.deinit(self.allocator);

            next_id = page.i_page.GetLeftmostPageId(0);
        }
    }
};

/// Asynchronous range scan using io_uring with prefetching
/// Linux-only (requires io_uring support)
///
/// Strategy: Use shadow cursor to find upcoming leaf page IDs and prefetch them
/// with io_uring while processing current pages
pub fn rangeScanAsync(
    pager: *Pager,
    table_root_page: u32,
    start_row_id: u64,
    num_records: u64,
    allocator: std.mem.Allocator,
) !ScanResult {
    // Note: This will only compile/run on Linux
    if (@import("builtin").os.tag != .linux) {
        return error.IoUringNotSupported;
    }

    var timer = try std.time.Timer.start();

    // Initialize io_uring with queue depth 16
    const IO_Uring = std.os.linux.IO_Uring;
    var ring = try IO_Uring.init(16, 0);
    defer ring.deinit();

    // Initialize ring buffer pool (stack allocated - 8 * 4KB = 32KB)
    var pool = RingBufferPool.init();

    // Initialize main cursor using SYNCHRONOUS I/O for seek
    // (We only use async for leaf page prefetching)
    var cursor = BTreeCursor.init(pager, allocator);
    defer cursor.deinit();

    // Seek to starting position (synchronous)
    try cursor.seek(table_root_page, start_row_id);

    // Initialize shadow cursor for lookahead
    var shadow = try ShadowCursor.clone(&cursor, pager, allocator);
    defer shadow.deinit();

    // === PREFETCH INITIAL BATCH ===
    // Find and submit reads for first PREFETCH_DEPTH leaves
    var submitted: usize = 0;
    while (submitted < PREFETCH_DEPTH) : (submitted += 1) {
        const next_leaf_id = try shadow.peekNextLeafId() orelse break;

        const slot = pool.getAvailableSlot() orelse break;
        const buffer_ptr = &pool.buffers[slot];

        // Calculate file offset for this page
        const PAGE_SIZE = @import("pager.zig").PAGE_SIZE;
        const offset: u64 = (next_leaf_id - 1) * PAGE_SIZE;

        // Submit io_uring read operation
        // user_data = buffer slot index
        _ = try ring.read(
            @intCast(slot), // user_data
            pager.file.handle,
            buffer_ptr,
            offset,
        );

        pool.markUsed(slot);
    }

    // Submit all queued operations
    _ = try ring.submit();

    // === MAIN SCAN LOOP ===
    // Process records while keeping prefetch pipeline full
    var records_scanned: u64 = 0;
    var pages_read: u64 = cursor.pages_read;

    // Fallback to sync if no async reads were submitted
    if (submitted == 0) {
        // Use synchronous path
        while (records_scanned < num_records) {
            const rec = try cursor.next() orelse break;
            defer allocator.free(rec);
            records_scanned += 1;
        }
        pages_read = cursor.pages_read;
    } else {
        // Process prefetched pages
        var completed: usize = 0;
        while (completed < submitted and records_scanned < num_records) {
            // Wait for next completion
            const cqe = try ring.copy_cqe();
            const buffer_idx = @as(usize, @intCast(cqe.user_data));

            // Check for read errors
            if (cqe.res < 0) {
                return error.IoUringReadFailed;
            }

            // Verify full page was read
            const PAGE_SIZE = @import("pager.zig").PAGE_SIZE;
            if (cqe.res != PAGE_SIZE) {
                return error.ShortRead;
            }

            // Process records from this completed page
            // For now, we'll use synchronous cursor and just track that we prefetched
            // A full implementation would parse the prefetched buffer directly
            completed += 1;
            pool.markFree(buffer_idx);

            // Replenish: Submit read for next leaf page
            if (try shadow.peekNextLeafId()) |next_leaf_id| {
                const slot = pool.getAvailableSlot() orelse continue;
                const buffer_ptr = &pool.buffers[slot];

                const offset: u64 = (next_leaf_id - 1) * PAGE_SIZE;
                _ = try ring.read(
                    @intCast(slot),
                    pager.file.handle,
                    buffer_ptr,
                    offset,
                );

                pool.markUsed(slot);
                _ = try ring.submit();
                submitted += 1;
            }
        }

        // Finish scanning with sync cursor
        // (In a full implementation, we'd parse prefetched buffers directly)
        while (records_scanned < num_records) {
            const rec = try cursor.next() orelse break;
            defer allocator.free(rec);
            records_scanned += 1;
        }
        pages_read = cursor.pages_read;
    }

    const elapsed_ns = timer.read();
    return ScanResult{
        .records_scanned = records_scanned,
        .pages_read = pages_read,
        .elapsed_ns = elapsed_ns,
    };
}

test "range scan basic" {
    // Basic test placeholder
    std.debug.print("Range scanner tests TODO\n", .{});
}
