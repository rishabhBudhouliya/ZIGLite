const std = @import("std");
const Pager = @import("pager.zig").Pager;
const range_scanner = @import("range_scanner.zig");

pub fn main() !void {
    std.debug.print("=== io_uring B+Tree Benchmark ===\n\n", .{});

    // Get allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Check if database file exists
    const db_path = "benchmark.db";
    std.debug.print("Opening database: {s}\n", .{db_path});

    // Open pager
    var pager = Pager.open(db_path) catch |err| {
        std.debug.print("ERROR: Failed to open database: {}\n", .{err});
        std.debug.print("Make sure you've generated it with: python3 scripts/generate_data.py\n", .{});
        return err;
    };
    defer pager.close();

    std.debug.print("✓ Database opened ({} bytes)\n", .{pager.data.len});
    std.debug.print("✓ Page size: {} bytes\n\n", .{pager.page_size});

    // Test configuration
    const TEST_DATA_ROOT_PAGE: u32 = 2; // From: SELECT rootpage FROM sqlite_master WHERE name='test_data'
    const scan_sizes = [_]u64{100}; // Start with just 100 records
    const iterations: u64 = 10; // Start with just 10 iterations for testing

    std.debug.print("Configuration:\n", .{});
    std.debug.print("  Scan sizes: ", .{});
    for (scan_sizes) |size| {
        std.debug.print("{} ", .{size});
    }
    std.debug.print("\n", .{});
    std.debug.print("  Iterations per config: {}\n", .{iterations});
    std.debug.print("\n", .{});

    // Run synchronous benchmark
    std.debug.print("Running SYNCHRONOUS (mmap) benchmark...\n", .{});

    for (scan_sizes) |scan_size| {
        std.debug.print("\nScan size: {} records\n", .{scan_size});

        var total_latency_ns: u64 = 0;
        var total_pages: u64 = 0;

        for (0..iterations) |i| {
            // Start from row_id 1 and scan forward
            // TODO: Add random starting positions for better coverage
            const start_row_id: u64 = 1;

            const result = try range_scanner.rangeScanSync(
                &pager,
                TEST_DATA_ROOT_PAGE,
                start_row_id,
                scan_size,
                allocator,
            );

            total_latency_ns += result.elapsed_ns;
            total_pages += result.pages_read;

            if (i < 3 or i == iterations - 1) {
                std.debug.print("  Iteration {}: {d:.2}ms, {} pages, {} records\n", .{
                    i + 1,
                    result.avgLatencyMs(),
                    result.pages_read,
                    result.records_scanned,
                });
            }
        }

        const avg_latency_ms = @as(f64, @floatFromInt(total_latency_ns)) / @as(f64, @floatFromInt(iterations)) / 1_000_000.0;
        const avg_pages = @as(f64, @floatFromInt(total_pages)) / @as(f64, @floatFromInt(iterations));

        std.debug.print("\nResults for {} records:\n", .{scan_size});
        std.debug.print("  Average latency: {d:.2} ms\n", .{avg_latency_ms});
        std.debug.print("  Average pages read: {d:.1}\n", .{avg_pages});
    }

    std.debug.print("\n=== Benchmark Complete ===\n", .{});
}
