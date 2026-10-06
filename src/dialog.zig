//! "Add songs" file picker with multi-selection.
//!  - Windows: the native Open dialog (comdlg32 `GetOpenFileNameW`).
//!  - Linux/BSD: `zenity --file-selection --multiple` if zenity is installed.
//! Capy itself has no file dialog.
const std = @import("std");
const builtin = @import("builtin");

pub const Paths = std.ArrayList([]u8);

/// Shows the picker and returns the chosen files as UTF-8 paths (empty on cancel).
/// The caller owns the list and every path in it.
pub fn pickFiles(allocator: std.mem.Allocator) !Paths {
    return switch (builtin.os.tag) {
        .windows => pickWindows(allocator),
        .linux, .freebsd, .openbsd, .netbsd => pickZenity(allocator),
        else => error.FileDialogUnsupported,
    };
}

// ---------------------------------------------------------------- Windows

const OPENFILENAMEW = extern struct {
    lStructSize: u32,
    hwndOwner: ?*anyopaque,
    hInstance: ?*anyopaque,
    lpstrFilter: ?[*:0]const u16,
    lpstrCustomFilter: ?[*:0]u16,
    nMaxCustFilter: u32,
    nFilterIndex: u32,
    lpstrFile: ?[*]u16,
    nMaxFile: u32,
    lpstrFileTitle: ?[*]u16,
    nMaxFileTitle: u32,
    lpstrInitialDir: ?[*:0]const u16,
    lpstrTitle: ?[*:0]const u16,
    Flags: u32,
    nFileOffset: u16,
    nFileExtension: u16,
    lpstrDefExt: ?[*:0]const u16,
    lCustData: isize,
    lpfnHook: ?*anyopaque,
    lpTemplateName: ?[*:0]const u16,
    pvReserved: ?*anyopaque,
    dwReserved: u32,
    FlagsEx: u32,
};

extern "comdlg32" fn GetOpenFileNameW(lpofn: *OPENFILENAMEW) callconv(.winapi) c_int;

const OFN_NOCHANGEDIR: u32 = 0x00000008;
const OFN_ALLOWMULTISELECT: u32 = 0x00000200;
const OFN_PATHMUSTEXIST: u32 = 0x00000800;
const OFN_FILEMUSTEXIST: u32 = 0x00001000;
const OFN_EXPLORER: u32 = 0x00080000;

fn pickWindows(allocator: std.mem.Allocator) !Paths {
    var result = Paths.init(allocator);
    errdefer freePaths(allocator, &result);

    // Room for a few hundred selected files.
    const buf = try allocator.alloc(u16, 64 * 1024);
    defer allocator.free(buf);
    @memset(buf, 0);

    const filter = std.unicode.utf8ToUtf16LeStringLiteral(
        "Audio files (*.mp3;*.wav;*.flac)\x00*.mp3;*.wav;*.flac\x00All files (*.*)\x00*.*\x00",
    );
    const title = std.unicode.utf8ToUtf16LeStringLiteral("Add songs");

    var ofn = std.mem.zeroes(OPENFILENAMEW);
    ofn.lStructSize = @sizeOf(OPENFILENAMEW);
    ofn.lpstrFilter = filter;
    ofn.nFilterIndex = 1;
    ofn.lpstrFile = buf.ptr;
    ofn.nMaxFile = @intCast(buf.len);
    ofn.lpstrTitle = title;
    ofn.Flags = OFN_EXPLORER | OFN_ALLOWMULTISELECT | OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;

    // Returns 0 when the user cancels (or on error): nothing to add.
    if (GetOpenFileNameW(&ofn) == 0) return result;

    // One file:   "C:\dir\song.mp3" NUL NUL
    // Many files: "C:\dir" NUL "a.mp3" NUL "b.mp3" NUL NUL
    const first = std.mem.sliceTo(buf, 0);
    const rest = buf[first.len + 1 ..];

    if (rest[0] == 0) {
        try result.append(try std.unicode.utf16LeToUtf8Alloc(allocator, first));
        return result;
    }

    const dir = try std.unicode.utf16LeToUtf8Alloc(allocator, first);
    defer allocator.free(dir);
    const sep: []const u8 = if (dir.len > 0 and (dir[dir.len - 1] == '\\' or dir[dir.len - 1] == '/')) "" else "\\";

    var offset: usize = 0;
    while (offset < rest.len and rest[offset] != 0) {
        const name16 = std.mem.sliceTo(rest[offset..], 0);
        offset += name16.len + 1;
        const name = try std.unicode.utf16LeToUtf8Alloc(allocator, name16);
        defer allocator.free(name);
        const full = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ dir, sep, name });
        errdefer allocator.free(full);
        try result.append(full);
    }
    return result;
}

// ---------------------------------------------------------------- Linux / BSD

fn pickZenity(allocator: std.mem.Allocator) !Paths {
    var result = Paths.init(allocator);
    errdefer freePaths(allocator, &result);

    const run = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            "zenity",
            "--file-selection",
            "--multiple",
            "--separator=\n",
            "--title=Add songs",
            "--file-filter=Audio files | *.mp3 *.wav *.flac",
        },
    }) catch return error.FileDialogUnavailable; // zenity not installed
    defer allocator.free(run.stdout);
    defer allocator.free(run.stderr);

    var lines = std.mem.splitScalar(u8, run.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, "\r ");
        if (trimmed.len == 0) continue;
        try result.append(try allocator.dupe(u8, trimmed));
    }
    return result;
}

pub fn freePaths(allocator: std.mem.Allocator, paths: *Paths) void {
    for (paths.items) |p| allocator.free(p);
    paths.deinit();
}
