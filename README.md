# ZIGLite

A SQLite database file parser implemented in Zig, designed for learning and understanding SQLite's internal file format through direct binary parsing.

## Overview

ZIGLite provides low-level access to SQLite database files by parsing the binary format directly. It implements core SQLite file format parsing capabilities including headers, B-tree structures, and record payloads using memory-mapped I/O for efficient file access.

## Features

- **Memory-mapped I/O**: Efficient file access using `mmap`
- **Full SQLite Format Support**: Parse database headers, B-tree pages, and record structures
- **B-tree Navigation**: Support for both leaf and interior table B-tree pages
- **Type-safe Parsing**: Leverages Zig's type system for safe value representation
- **Multiple Data Types**: Support for integers, floats, text, BLOBs, and NULL values
- **Zero-copy Operations**: Efficient parsing with minimal memory overhead
- **Async I/O Support**: io_uring-based asynchronous operations for improved performance

## Quick Start

### Prerequisites

- Zig 0.13.0 or later
- POSIX-compliant system (for mmap support)
- Linux (for io_uring async operations)

### Building

```bash
# Build the project
zig build

# Run tests
zig build test

# Run the executable
zig build run -- <database-file>

# Build in release mode
zig build -Doptimize=ReleaseFast
```

### Usage Example

```bash
# Parse a SQLite database
zig build run -- sample.db

# Run with cold cache testing (Linux)
zig build run -- --cold-cache sample.db
```

## Architecture

### Core Components

| Component | Description |
|-----------|-------------|
| **Pager** (`src/pager.zig`) | Manages memory-mapped file I/O and page-level access |
| **B-Tree** (`src/btree.zig`) | Implements SQLite's B-tree page structures (leaf and interior pages) |
| **Header Parser** (`src/header_parser.zig`) | Parses database and B-tree page headers |
| **Record Parser** (`src/record.zig`) | Parses SQLite record format with support for multiple value types |
| **Bit Utilities** (`src/bit_utility.zig`) | Variable-length integer parsing and big-endian conversions |

### Project Structure

```
ZIGLite/
├── build.zig                  # Build configuration
├── src/
│   ├── main.zig               # Entry point
│   ├── root.zig               # Module root
│   ├── pager.zig              # Memory-mapped file access
│   ├── btree.zig              # B-tree page structures
│   ├── header_parser.zig      # Header parsing
│   ├── record.zig             # Record/cell payload parsing
│   └── bit_utility.zig        # Binary parsing utilities
└── sample.db                  # Sample SQLite database
```

## SQLite Format Details

### Database File Structure

1. **Header** (100 bytes): File metadata including page size, file format versions, and schema information
2. **Pages** (4096 bytes default): Data organized in B-tree structure
3. **Page Contents**: Page header, cell pointer array, unallocated space, and cell content area

### Supported B-Tree Page Types

- `0x0d` - Leaf table B-tree page
- `0x05` - Interior table B-tree page
- `0x0a` - Leaf index B-tree page (planned)
- `0x02` - Interior index B-tree page (planned)

### Supported Data Types

- Integers: 8, 16, 24, 32, 48, 64-bit signed integers
- Floating Point: 64-bit IEEE floating point
- Text: UTF-8 encoded text strings
- BLOB: Binary large objects
- NULL: Null values

## Performance

ZIGLite includes async I/O support using Linux's io_uring for improved performance:
- Asynchronous page prefetching
- Reduced I/O latency
- Better throughput for large database scans

See `async-io-uring-plan.md` for implementation details and benchmarks.

## Development

### Running Tests

```bash
# Run all tests
zig build test

# Run with verbose output
zig build test --summary all
```

### Code Style

- Uses Zig standard library exclusively (no external dependencies)
- Big-endian byte order throughout (SQLite standard)
- Error handling via Zig's error unions
- Debug allocator for memory safety during development

## Learning Resources

This project is designed as a learning tool for understanding:
- SQLite's internal file format
- Low-level binary parsing
- Memory-mapped I/O techniques
- B-tree data structures
- Systems programming in Zig

### References

- [SQLite File Format Documentation](https://www.sqlite.org/fileformat.html)
- [Zig Language Documentation](https://ziglang.org/documentation/)
- [Build Your Own SQLite - CodeCrafters](https://codecrafters.io/challenges/sqlite)

## Current Status

The project is in active development with the following completed:
- Memory-mapped pager implementation
- Database and page header parsing
- B-tree page structure support (leaf and interior)
- Record parsing for all major data types
- Async I/O with io_uring
- Range scan optimizations

### Roadmap

- [ ] Complete index B-tree page support
- [ ] Query execution engine
- [ ] Write/modify capabilities
- [ ] Additional performance optimizations
- [ ] Comprehensive test coverage
- [ ] Cross-platform support improvements

## Contributing

This is primarily a learning project, but contributions, suggestions, and feedback are welcome. Feel free to open issues or submit pull requests.

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Acknowledgments

Built as a hands-on exploration of SQLite internals and systems programming with Zig.
