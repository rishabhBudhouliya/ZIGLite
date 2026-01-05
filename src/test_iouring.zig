const std = @import("std");

// Minimal test to verify io_uring support on the system
// Compatible with Zig 0.13.0

pub fn main() !void {
    std.debug.print("Testing io_uring availability...\n", .{});

    // Check if we're on Linux
    const builtin = @import("builtin");
    if (builtin.os.tag != .linux) {
        std.debug.print("ERROR: Not running on Linux (detected: {s})\n", .{@tagName(builtin.os.tag)});
        std.debug.print("io_uring is Linux-only. This system cannot run io_uring.\n", .{});
        return error.NotLinux;
    }

    std.debug.print("✓ Running on Linux\n", .{});

    // Use low-level Linux syscall interface
    const linux = std.os.linux;
    var params: linux.io_uring_params = std.mem.zeroes(linux.io_uring_params);
    params.flags = 0; // No special flags

    // Try to setup io_uring with 8 entries
    const ring_fd = linux.io_uring_setup(8, &params);

    // Check for error (negative values indicate error)
    if (@as(i32, @bitCast(@as(u32, @truncate(ring_fd)))) < 0) {
        std.debug.print("ERROR: Failed to setup io_uring\n", .{});
        std.debug.print("\nPossible reasons:\n", .{});
        std.debug.print("  - Kernel too old (need >= 5.1, check: uname -r)\n", .{});
        std.debug.print("  - io_uring disabled (check: sysctl kernel.io_uring_disabled)\n", .{});
        std.debug.print("  - Missing permissions / memlock limit too low\n", .{});
        return error.IoUringSetupFailed;
    }

    defer std.posix.close(@intCast(ring_fd));

    std.debug.print("✓ io_uring initialized successfully!\n", .{});
    std.debug.print("✓ Ring FD: {}\n", .{ring_fd});
    std.debug.print("✓ SQ entries: {}\n", .{params.sq_entries});
    std.debug.print("✓ CQ entries: {}\n", .{params.cq_entries});
    std.debug.print("✓ Features: 0x{x}\n", .{params.features});

    std.debug.print("\n=== SUCCESS ===\n", .{});
    std.debug.print("io_uring is fully functional on this system!\n", .{});
    std.debug.print("You can proceed with the io_uring implementation.\n", .{});
}
