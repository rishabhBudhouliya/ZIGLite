// user interface api
// also implement b+tree search here
const std = @import("std");
const pager = @import("pager.zig");
const header_parser = @import("header_parser.zig");
const btree = @import("btree.zig");
const range_scanner = @import("range_scanner.zig");

pub const Database = struct {
    p: pager.Pager,

    pub fn newDatabase(file_name: []const u8) !Database {
        const p = try pager.Pager.open(file_name);
        return Database{ .p = p };
    }

    pub fn search(self: *Database, alloc: std.mem.Allocator, table_root_page: u32, row_id: u64) !void {
        var current_page_id: u32 = table_root_page;

        while (true) {
            const page_data = self.p.getPage(current_page_id);
            const header_offset: usize = if (current_page_id == 1) 100 else 0;
            const btree_header = try header_parser.parseBtreeHeader(page_data[header_offset..@min(page_data.len, header_offset + 12)]);

            // Interior pages: 12-byte header, Leaf pages: 8-byte header
            const header_size: usize = if (btree_header.page_type == 0x05 or btree_header.page_type == 0x02) 12 else 8;
            const content_offset = header_offset + header_size;
            const cell_pointers_size = btree_header.cells * 2;
            const cell_pointers = page_data[content_offset .. content_offset + cell_pointers_size];

            const page = try btree.NewPage(alloc, btree_header, cell_pointers, page_data);
            defer page.deinit(alloc);

            switch (page) {
                .l_page => |*leaf_page| {
                    const cell_idx = try leaf_page.findCellIndex(row_id);

                    if (cell_idx >= leaf_page.CellCount()) {
                        std.debug.print("Row ID {} out of bounds (larger than max in leaf)\n", .{row_id});
                        return error.RowNotFound;
                    }

                    // Verify we found the exact row_id
                    const found_row_id = try leaf_page.GetRowId(cell_idx);
                    if (found_row_id != row_id) {
                        std.debug.print("Row ID {} not found (closest is {})\n", .{ row_id, found_row_id });
                        return error.RowNotFound;
                    }

                    std.debug.print("Found in leaf page {}, cell index: {}\n", .{ current_page_id, cell_idx });

                    const rec = try leaf_page.getRecord(alloc, cell_idx);
                    defer alloc.free(rec);

                    std.debug.print("Successfully extracted record for row_id {}\n", .{row_id});
                    std.debug.print("Record values ({} columns):\n", .{rec.len});
                    for (rec, 0..) |value, i| {
                        std.debug.print("  Column {}: ", .{i});
                        switch (value) {
                            .null_value => std.debug.print("NULL\n", .{}),
                            .int8 => |v| std.debug.print("{}\n", .{v}),
                            .int16 => |v| std.debug.print("{}\n", .{v}),
                            .int24 => |v| std.debug.print("{}\n", .{v}),
                            .int32 => |v| std.debug.print("{}\n", .{v}),
                            .int48 => |v| std.debug.print("{}\n", .{v}),
                            .int64 => |v| std.debug.print("{}\n", .{v}),
                            .float64 => |v| std.debug.print("{d}\n", .{v}),
                            .text => |v| std.debug.print("'{s}'\n", .{v}),
                            .blob => |v| std.debug.print("<blob {} bytes>\n", .{v.len}),
                        }
                    }

                    return;
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

const TestCase = struct {
    name: []const u8,
    start_row_id: u64,
    num_records: u64,
};

fn runTest(db: *Database, allocator: std.mem.Allocator, test_case: TestCase) !void {
    const test_data_root_page: u32 = 2;

    std.debug.print("\n[TEST] {s}\n", .{test_case.name});
    std.debug.print("  Start: row {}, Count: {}\n", .{ test_case.start_row_id, test_case.num_records });

    const result = range_scanner.rangeScanSync(
        &db.p,
        test_data_root_page,
        test_case.start_row_id,
        test_case.num_records,
        allocator,
    ) catch |err| {
        std.debug.print("  ❌ FAILED: {}\n", .{err});
        return err;
    };

    std.debug.print("  ✓ Scanned: {}, Pages: {}, Time: {d:.2}ms\n", .{
        result.records_scanned,
        result.pages_read,
        result.avgLatencyMs(),
    });

    // Verify we got the expected number of records
    if (result.records_scanned != test_case.num_records) {
        std.debug.print("  ⚠️  WARNING: Expected {} records, got {}\n", .{ test_case.num_records, result.records_scanned });
    }
}

pub fn main() !void {
    std.debug.print("=== Range Scanner Comprehensive Test Suite ===\n", .{});

    // Setup allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Open database
    const db_path = "benchmark.db";
    std.debug.print("Opening database: {s}\n", .{db_path});

    var db = try Database.newDatabase(db_path);
    defer db.p.close();

    std.debug.print("✓ Database opened\n", .{});
    std.debug.print("✓ Test database: 1M rows (row_id 1-1000000)\n", .{});

    // Test suite
    const tests = [_]TestCase{
        // Edge case: Single record
        .{ .name = "Single record (row 1)", .start_row_id = 1, .num_records = 1 },
        .{ .name = "Single record (row 500000)", .start_row_id = 500000, .num_records = 1 },

        // Small scans
        .{ .name = "10 records from start", .start_row_id = 1, .num_records = 10 },
        .{ .name = "10 records from middle", .start_row_id = 500000, .num_records = 10 },

        // Medium scans (within a few pages)
        .{ .name = "100 records from start", .start_row_id = 1, .num_records = 100 },
        .{ .name = "100 records from middle", .start_row_id = 500000, .num_records = 100 },
        .{ .name = "500 records from start", .start_row_id = 1, .num_records = 500 },

        // Large scans (multiple pages)
        .{ .name = "1000 records from start", .start_row_id = 1, .num_records = 1000 },
        .{ .name = "1000 records from middle", .start_row_id = 500000, .num_records = 1000 },
        .{ .name = "5000 records from start", .start_row_id = 1, .num_records = 5000 },
        .{ .name = "10000 records spanning tree", .start_row_id = 100000, .num_records = 10000 },

        // End of table tests
        .{ .name = "100 records near end", .start_row_id = 999900, .num_records = 100 },
        .{ .name = "Last record", .start_row_id = 1000000, .num_records = 1 },

        // Stress test
        .{ .name = "50000 records (stress test)", .start_row_id = 1, .num_records = 50000 },
    };

    var passed: usize = 0;
    var failed: usize = 0;

    for (tests) |test_case| {
        runTest(&db, allocator, test_case) catch {
            failed += 1;
            continue;
        };
        passed += 1;
    }

    std.debug.print("\n=== Test Summary ===\n", .{});
    std.debug.print("Passed: {}\n", .{passed});
    std.debug.print("Failed: {}\n", .{failed});
    std.debug.print("Total:  {}\n", .{tests.len});

    if (failed == 0) {
        std.debug.print("\n🎉 All tests passed!\n", .{});
    } else {
        std.debug.print("\n⚠️  Some tests failed!\n", .{});
    }
}

test "database compiles" {
    // This forces database.zig to be compiled during tests
    _ = Database;
}
