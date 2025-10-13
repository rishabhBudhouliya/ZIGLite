const std = @import("std");

const sqlite_header = struct { header_string: [16]u8, page_size: [2]u8, file_format_write_version: u8, file_format_read_version: u8, reserved_space: u8, max_payload_fraction: u8, min_payload_fraction: u8, leaf_payload_fraction: u8, file_change_counter: [4]u8, size_in_pages: [4]u8, page_no_freelist_trunk: [4]u8, total_freelist_pages: [4]u8, schema_cookie: [4]u8, schema_format_number: [4]u8, page_cache_size: [4]u8, root_page_size: [4]u8, database_text_encoding: [4]u8, user_version: [4]u8, vacuum_mode: [4]u8, application_id: [4]u8, reserved: [20]u8, version_valid: [4]u8, sqlite_version_number: [4]u8 };

pub fn parseBTreeHeader() void {}

pub fn parseDatabaseHeader(page_content: []u8) void {
    if (page_content.len < 100) {
        // return error or log error
        return null;
    }
    const header = page_content[0..100];
}
