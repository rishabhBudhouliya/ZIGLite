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
            // For now, always start from page 2 (first data page after root)
            // TODO: Add random starting positions
            const start_page: u32 = 2;

            const result = try range_scanner.rangeScanSync(
                &pager,
                start_page,
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
