const std = @import("std");
const Pager = @import("pager.zig").Pager;
const range_scanner = @import("range_scanner.zig");

pub fn main() !void {
    // Parse command-line arguments
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Determine benchmark mode: sync, async, or both (default)
    const Mode = enum { sync, async_only, both };
    var mode: Mode = .both;

    if (args.len > 1) {
        if (std.mem.eql(u8, args[1], "sync")) {
            mode = .sync;
        } else if (std.mem.eql(u8, args[1], "async")) {
            mode = .async_only;
        } else {
            std.debug.print("Usage: {s} [sync|async]\n", .{args[0]});
            std.debug.print("  sync  - Run synchronous benchmark only\n", .{});
            std.debug.print("  async - Run asynchronous benchmark only (Linux only)\n", .{});
            std.debug.print("  (no arg) - Run both benchmarks\n", .{});
            return;
        }
    }

    std.debug.print("=== io_uring B+Tree Benchmark ===\n", .{});
    std.debug.print("Mode: {s}\n\n", .{@tagName(mode)});

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

    std.debug.print("✓ Database opened ({} bytes)\n", .{pager.db_size});
    std.debug.print("✓ Page size: {} bytes\n", .{pager.page_size});
    std.debug.print("✓ OS: {s}\n\n", .{@tagName(@import("builtin").os.tag)});

    // Test configuration
    const TEST_DATA_ROOT_PAGE: u32 = 2; // From: SELECT rootpage FROM sqlite_master WHERE name='test_data'

    // === SANITY CHECK: Quick validation (only if running both modes) ===
    if (mode == .both) {
        std.debug.print("=== SANITY CHECK ===\n", .{});
        std.debug.print("Testing both sync and async with 100 records...\n\n", .{});

        const sanity_size: u64 = 100;
        const sanity_start: u64 = 1;

        // Test sync
        std.debug.print("1. Sync test:\n", .{});
        const sync_result = try range_scanner.rangeScanSync(
            &pager,
            TEST_DATA_ROOT_PAGE,
            sanity_start,
            sanity_size,
            allocator,
        );
        std.debug.print("   Records: {}, Pages: {}, Time: {d:.2}ms\n", .{
            sync_result.records_scanned,
            sync_result.pages_read,
            sync_result.avgLatencyMs(),
        });

        // Test async (Linux only)
        if (@import("builtin").os.tag == .linux) {
            std.debug.print("\n2. Async test (io_uring):\n", .{});
            const async_result = range_scanner.rangeScanAsync(
                &pager,
                TEST_DATA_ROOT_PAGE,
                sanity_start,
                sanity_size,
                allocator,
            ) catch |err| {
                std.debug.print("   ❌ FAILED: {}\n", .{err});
                std.debug.print("   io_uring may not be available on this system\n", .{});
                return err;
            };

            std.debug.print("   Records: {}, Pages: {}, Time: {d:.2}ms\n", .{
                async_result.records_scanned,
                async_result.pages_read,
                async_result.avgLatencyMs(),
            });

            // Verify correctness
            if (sync_result.records_scanned != async_result.records_scanned) {
                std.debug.print("\n❌ ERROR: Record count mismatch!\n", .{});
                std.debug.print("   Sync: {}, Async: {}\n", .{
                    sync_result.records_scanned,
                    async_result.records_scanned,
                });
                return error.AsyncSyncMismatch;
            }

            std.debug.print("\n✅ Sanity check PASSED - Both implementations return same results\n", .{});

            // Calculate speedup
            const speedup = sync_result.avgLatencyMs() / async_result.avgLatencyMs();
            std.debug.print("   Speedup: {d:.2}x ({d:.1}% ", .{ speedup, (speedup - 1.0) * 100.0 });
            if (speedup > 1.0) {
                std.debug.print("faster)\n", .{});
            } else {
                std.debug.print("slower)\n", .{});
            }
        } else {
            std.debug.print("\n⚠️  Skipping async test (not on Linux)\n", .{});
            std.debug.print("   io_uring requires Linux. Current OS: {s}\n", .{@tagName(@import("builtin").os.tag)});
        }

        std.debug.print("\n", .{});
    }

    // === FULL BENCHMARK ===
    // Test different scan sizes to observe how prefetching benefits larger scans
    const scan_sizes = [_]u64{ 100, 1000, 10000, 100000 };
    const iterations: u64 = 50; // Run 50 iterations per configuration for statistical significance

    std.debug.print("Configuration:\n", .{});
    std.debug.print("  Scan sizes: ", .{});
    for (scan_sizes) |size| {
        std.debug.print("{} ", .{size});
    }
    std.debug.print("\n", .{});
    std.debug.print("  Iterations per config: {}\n", .{iterations});
    std.debug.print("\n", .{});

    // Run synchronous benchmark
    if (mode == .sync or mode == .both) {
        std.debug.print("Running SYNCHRONOUS (pread) benchmark...\n", .{});

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
    }

    // Run asynchronous benchmark (Linux only)
    if ((mode == .async_only or mode == .both) and @import("builtin").os.tag == .linux) {
        std.debug.print("\n\nRunning ASYNCHRONOUS (io_uring) benchmark...\n", .{});

        for (scan_sizes) |scan_size| {
            std.debug.print("\nScan size: {} records\n", .{scan_size});

            var total_latency_ns: u64 = 0;
            var total_pages: u64 = 0;

            for (0..iterations) |i| {
                const start_row_id: u64 = 1;

                const result = range_scanner.rangeScanAsync(
                    &pager,
                    TEST_DATA_ROOT_PAGE,
                    start_row_id,
                    scan_size,
                    allocator,
                ) catch |err| {
                    std.debug.print("  ❌ Async failed: {}\n", .{err});
                    break;
                };

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
    } else if (mode == .async_only and @import("builtin").os.tag != .linux) {
        std.debug.print("\n⚠️  Cannot run async benchmark: io_uring requires Linux\n", .{});
        std.debug.print("   Current OS: {s}\n", .{@tagName(@import("builtin").os.tag)});
    }

    std.debug.print("\n=== Benchmark Complete ===\n", .{});
}
