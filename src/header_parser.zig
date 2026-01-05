const std = @import("std");

pub const HeaderError = error{ HeaderTooShort, InvalidMagicString, InvalidPageType, InvalidHeaderLength };

pub const SQLiteHeader = struct { header_string: [16]u8, page_size: u16, file_format_write_version: u8, file_format_read_version: u8, reserved_space: u8, max_payload_fraction: u8, min_payload_fraction: u8, leaf_payload_fraction: u8, file_change_counter: u32, size_in_pages: u32, page_no_freelist_trunk: u32, total_freelist_pages: u32, schema_cookie: u32, schema_format_number: u32, page_cache_size: u32, root_page_size: u32, database_text_encoding: u32, user_version: u32, vacuum_mode: u32, application_id: u32, reserved: [20]u8, version_valid: u32, sqlite_version_number: u32 };

pub const BtreeHeader = struct { page_type: u8, cells: u16, right_most_pointer: u32 };

pub fn parseDatabaseHeader(page_content: []const u8) HeaderError!SQLiteHeader {
    if (page_content.len < 100) {
        return HeaderError.HeaderTooShort;
    }
    const header_slice = page_content[0..100];
    var header: SQLiteHeader = undefined;

    header.page_size = std.mem.readInt(u16, header_slice[16..18], .big);
    return header;
}

// could be leaf or interior caller will know
pub fn parseBtreeHeader(header: []const u8) HeaderError!BtreeHeader {
    if (header.len < 8) {
        return HeaderError.InvalidHeaderLength;
    }

    var b_header: BtreeHeader = undefined;
    b_header.page_type = header[0];

    // Validate page type
    if (b_header.page_type != 0x02 and b_header.page_type != 0x05 and
        b_header.page_type != 0x0a and b_header.page_type != 0x0d) {
        return HeaderError.InvalidPageType;
    }

    b_header.cells = std.mem.readInt(u16, header[3..5], .big);

    // Interior pages (0x02, 0x05) have 12-byte header with rightmost pointer
    // Leaf pages (0x0a, 0x0d) have 8-byte header, no rightmost pointer
    if (b_header.page_type == 0x02 or b_header.page_type == 0x05) {
        // Interior page: read rightmost pointer from bytes 8-11
        if (header.len < 12) {
            return HeaderError.InvalidHeaderLength;
        }
        b_header.right_most_pointer = std.mem.readInt(u32, header[8..12], .big);
    } else {
        // Leaf page: no rightmost pointer
        b_header.right_most_pointer = 0;
    }

    return b_header;
}
