const std = @import("std");

// Fixed-size page buffer for SQLite pages (4KB standard)
pub const PAGE_SIZE: usize = 4096;
pub const PageBuffer = [PAGE_SIZE]u8;

// The pager manages file access using pread for deterministic I/O
pub const Pager = struct {
    file: std.fs.File,
    page_size: usize,
    db_size: u64, // Total file size for bounds checking

    /// Open a database file and prepare for pread-based access
    pub fn open(file_name: []const u8) !Pager {
        const file = try std.fs.cwd().openFile(file_name, .{ .mode = .read_only });
        errdefer file.close();

        const stat = try file.stat();

        return Pager{
            .file = file,
            .page_size = PAGE_SIZE,
            .db_size = stat.size,
        };
    }

    pub fn close(self: *Pager) void {
        self.file.close();
    }

    /// Read a single page into the provided buffer using pread
    /// SQLite pages are 1-indexed (page 1 is at offset 0)
    pub fn readPage(self: *Pager, page_num: u32, buffer: *PageBuffer) !void {
        // Calculate offset (SQLite pages are 1-indexed)
        // page_num starts at 1, so page 1 is at offset 0
        if (page_num == 0) {
            return error.InvalidPageNumber;
        }

        const offset: u64 = (page_num - 1) * self.page_size;

        // Bounds check
        if (offset + self.page_size > self.db_size) {
            return error.PageOutOfBounds;
        }

        // Use pread for position-independent reading
        const bytes_read = try std.posix.pread(self.file.handle, buffer, offset);

        // Verify we read a full page
        if (bytes_read != PAGE_SIZE) {
            return error.ShortRead;
        }
    }
};

pub fn main() !void {
    // Test the new pread-based pager
    var pager = try Pager.open("sample.db");
    defer pager.close();

    std.debug.print("Opened database ({} bytes)\n", .{pager.db_size});

    // Read page 1 into buffer
    var buffer: PageBuffer = undefined;
    try pager.readPage(1, &buffer);

    std.debug.print("First 16 bytes of page 1: {any}\n", .{buffer[0..16]});
}
