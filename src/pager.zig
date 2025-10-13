const std = @import("std");

// the pager should hold the reference of file it opened
// it should also hold the reference of mmap accessed block
const Pager = struct {
    file: std.fs.File,
    data: []align(std.heap.page_size_min) u8, // a slice: fat pointer pointing to mmapped data
    page_size: u32 = 4096,

    // open a file and create mmap instance?
    pub fn open(file_name: []const u8) !Pager {
        const file = try std.fs.cwd().openFile(file_name, .{ .mode = .read_only });
        errdefer file.close();

        const stat = try file.stat();
        const size = stat.size;

        // mmap api
        const data = try std.posix.mmap(null, size, std.posix.PROT.READ, .{ .TYPE = .SHARED }, file.handle, 0);
        return Pager{ .file = file, .data = data };
    }

    pub fn close(self: *Pager) void {
        self.file.close();
        std.posix.munmap(self.data);
    }

    // assuming a page is array of bytes
    pub fn getPage(self: *Pager, page_num: u32) []u8 {
        // for page = 1, we would get the first 4096 bytes
        const offset: usize = (page_num - 1) * self.page_size;
        const end = offset + self.page_size;
        return self.data[offset..end];
    }
};

pub fn main() !void {
    // Prints to stderr, ignoring potential errors.
    var pager = try Pager.open("sample.db");
    defer pager.close();

    std.debug.print("opened database, mapped {} bytes\n", .{pager.data.len});
    const page1 = pager.getPage(1);
    std.debug.print("First 16 bytes of page 1: {any}\n", .{page1[0..16]});
}
