const std = @import("std");
const Pager = @import("pager.zig").Pager;
const header_parser = @import("header_parser.zig");

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

/// Synchronous range scan using mmap
pub fn rangeScanSync(
    pager: *Pager,
    start_page: u32,
    num_records: u64,
    allocator: std.mem.Allocator,
) !ScanResult {
    _ = allocator; // Will use later for collecting actual records

    var timer = try std.time.Timer.start();

    var current_page_num = start_page;
    var records_scanned: u64 = 0;
    var pages_read: u64 = 0;

    // For simplified version: just iterate through pages
    // counting cells until we reach num_records
    while (records_scanned < num_records) {
        // Get page from pager (using mmap)
        const page_data = pager.getPage(current_page_num);
        pages_read += 1;

        // Parse B-tree header to get cell count
        const btree_header_size: usize = if (current_page_num == 1) 100 + 8 else 8;
        const header_start: usize = if (current_page_num == 1) 100 else 0;

        if (page_data.len < header_start + 8) {
            return error.PageTooSmall;
        }

        const btree_header = try header_parser.parseBtreeHeader(
            page_data[header_start..header_start + btree_header_size]
        );

        // Only handle leaf pages (0x0d) for now
        if (btree_header.page_type != 0x0d) {
            return error.NotLeafPage;
        }

        // Count cells in this page
        const cells_in_page = btree_header.cells;
        const records_to_read = @min(cells_in_page, num_records - records_scanned);
        records_scanned += records_to_read;

        // Check if there's a next page
        // In SQLite, right_most_pointer points to the next leaf page (or 0 if last)
        if (btree_header.right_most_pointer == 0 or records_scanned >= num_records) {
            break;
        }

        current_page_num = btree_header.right_most_pointer;
    }

    const elapsed = timer.read();

    return ScanResult{
        .records_scanned = records_scanned,
        .pages_read = pages_read,
        .elapsed_ns = elapsed,
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
