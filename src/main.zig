//! lmp3 - a small audio player.
//!   UI:       capy-ui/capy (single page: now playing + playlist)
//!   Decoding: mackron/dr_libs (mp3, wav, flac)
//!   Output:   mackron/miniaudio
const std = @import("std");
const capy = @import("capy");
const audio = @import("audio.zig");
const dialog = @import("dialog.zig");
const Decoder = @import("decoder.zig").Decoder;

pub usingnamespace capy.cross_platform;

var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
pub const capy_allocator = gpa_state.allocator();

// ------------------------------------------------------------------ state

const Track = struct {
    path: []u8,
    title: []u8,
    /// Text currently shown on this track's playlist row. Capy keeps the slice, so we own it.
    row_text: [:0]u8,
};

/// Button clicks only record what the user asked for; the main loop carries it out,
/// so no handler ever runs while the widget it belongs to is being modified.
const Action = union(enum) { add, prev, toggle, stop, next, select: usize };

const Marker = enum { none, playing, paused };

/// Two alternating buffers so a label never gets the identical slice twice.
const TextBuf = struct {
    bufs: [2][512]u8 = undefined,
    flip: u1 = 0,

    fn print(self: *TextBuf, comptime fmt: []const u8, args: anytype) []const u8 {
        self.flip +%= 1;
        return std.fmt.bufPrint(&self.bufs[self.flip], fmt, args) catch "...";
    }
};

const App = struct {
    allocator: std.mem.Allocator,
    engine: audio.Engine,
    tracks: std.ArrayList(Track),
    rows: std.ArrayList(*capy.Button),
    /// Index of the track that is loaded (playing or paused).
    current: ?usize = null,
    pending: ?Action = null,
    /// Millisecond timestamp at which the end of the current track was first noticed.
    finish_seen_ms: ?i64 = null,

    now_label: *capy.Label = undefined,
    time_label: *capy.Label = undefined,
    play_button: *capy.Button = undefined,
    playlist: *capy.Container = undefined,

    now_text: TextBuf = .{},
    time_text: TextBuf = .{},
    shown_pos: i64 = -1,
    shown_dur: i64 = -1,
};

var app: App = undefined;

// ------------------------------------------------------------------ playlist

fn makeRowText(index: usize, title: []const u8, marker: Marker) ![:0]u8 {
    const m = switch (marker) {
        .none => "    ",
        .playing => "\u{25B6}  ",
        .paused => "\u{2016}  ",
    };
    return std.fmt.allocPrintZ(app.allocator, "{s}{d:0>2}.  {s}", .{ m, index + 1, title });
}

fn markerFor(index: usize) Marker {
    if (app.current != index) return .none;
    return if (app.engine.playing) .playing else .paused;
}

fn refreshRow(index: usize) void {
    const track = &app.tracks.items[index];
    const text = makeRowText(index, track.title, markerFor(index)) catch return;
    app.rows.items[index].setLabel(text);
    app.allocator.free(track.row_text);
    track.row_text = text;
}

fn addTrack(path: []const u8) !void {
    const index = app.tracks.items.len;

    const owned_path = try app.allocator.dupe(u8, path);
    errdefer app.allocator.free(owned_path);
    const title = try app.allocator.dupe(u8, std.fs.path.stem(path));
    errdefer app.allocator.free(title);
    const row_text = try makeRowText(index, title, .none);
    errdefer app.allocator.free(row_text);

    const row = capy.button(.{ .label = row_text, .onclick = onRowClicked });
    try app.playlist.add(row);
    try app.rows.append(row);
    try app.tracks.append(.{ .path = owned_path, .title = title, .row_text = row_text });
}

// ------------------------------------------------------------------ status display

/// Updates the "now playing" label, the play/pause button and the playlist markers.
fn refreshStatus() void {
    if (app.current) |i| {
        refreshRow(i);
        app.now_label.setText(app.now_text.print("{s}", .{app.tracks.items[i].title}));
    }
    app.play_button.setLabel(if (app.engine.playing) "Pause" else "Play");
}

fn setCurrent(new: ?usize, idle_message: []const u8) void {
    const old = app.current;
    app.current = new;
    if (old) |i| refreshRow(i);
    if (new == null) {
        app.now_label.setText(idle_message);
        app.time_label.setText("0:00 / 0:00");
    }
    app.shown_pos = -1; // force the time label to refresh
    refreshStatus();
}

fn formatTime(buf: *TextBuf, pos: i64, dur: i64) []const u8 {
    return buf.print("{d}:{d:0>2} / {d}:{d:0>2}", .{ @divFloor(pos, 60), @mod(pos, 60), @divFloor(dur, 60), @mod(dur, 60) });
}

fn updateTime() void {
    const pos: i64 = @intFromFloat(app.engine.positionSeconds());
    const dur: i64 = @intFromFloat(app.engine.durationSeconds());
    if (pos == app.shown_pos and dur == app.shown_dur) return;
    app.shown_pos = pos;
    app.shown_dur = dur;
    app.time_label.setText(formatTime(&app.time_text, pos, dur));
}

// ------------------------------------------------------------------ playback control

fn playIndex(index: usize) bool {
    const track = app.tracks.items[index];
    app.engine.load(track.path) catch |err| return playFailed(track, err);
    app.engine.play() catch |err| return playFailed(track, err);
    app.finish_seen_ms = null;
    setCurrent(index, "");
    return true;
}

fn playFailed(track: Track, err: anyerror) bool {
    app.engine.unload();
    setCurrent(null, "");
    app.now_label.setText(app.now_text.print("Can't play \"{s}\": {s}", .{ track.title, @errorName(err) }));
    return false;
}

fn togglePlayback() void {
    if (!app.engine.isLoaded()) {
        if (app.tracks.items.len > 0) _ = playIndex(app.current orelse 0);
        return;
    }
    if (app.engine.playing) {
        app.engine.pause();
    } else {
        app.engine.play() catch {};
    }
    refreshStatus();
}

fn stopPlayback() void {
    app.engine.unload();
    app.finish_seen_ms = null;
    setCurrent(null, "Stopped");
}

fn step(forward: bool) void {
    const len = app.tracks.items.len;
    if (len == 0) return;
    const target = if (app.current) |cur|
        (if (forward) (cur + 1) % len else (cur + len - 1) % len)
    else
        0;
    _ = playIndex(target);
}

/// Called from the main loop: when the current track has ended, play the next one.
fn checkTrackEnded() void {
    if (!app.engine.isLoaded() or !app.engine.finished.load(.acquire)) return;

    // The decoder runs dry slightly before the speakers do; let the buffered tail play out.
    const now = std.time.milliTimestamp();
    const seen = app.finish_seen_ms orelse {
        app.finish_seen_ms = now;
        return;
    };
    if (now - seen < 400) return;

    var next = (app.current orelse return) + 1;
    while (next < app.tracks.items.len) : (next += 1) {
        if (playIndex(next)) return;
    }
    stopPlayback();
    app.now_label.setText("End of playlist");
}

fn addFiles() void {
    var picked = dialog.pickFiles(app.allocator) catch |err| {
        app.now_label.setText(app.now_text.print("File dialog unavailable: {s}", .{@errorName(err)}));
        return;
    };
    defer dialog.freePaths(app.allocator, &picked);
    addPaths(picked.items);
}

fn addPaths(paths: []const []u8) void {
    const first_new = app.tracks.items.len;
    for (paths) |path| {
        if (!Decoder.isSupported(path)) continue;
        addTrack(path) catch continue;
    }
    // Nothing playing yet: start with the first song that was just added.
    if (!app.engine.isLoaded() and app.tracks.items.len > first_new) _ = playIndex(first_new);
}

fn perform(action: Action) void {
    switch (action) {
        .add => addFiles(),
        .prev => step(false),
        .next => step(true),
        .toggle => togglePlayback(),
        .stop => stopPlayback(),
        .select => |i| if (i < app.tracks.items.len) {
            _ = playIndex(i);
        },
    }
}

// ------------------------------------------------------------------ click handlers

fn onPrev(_: *anyopaque) anyerror!void {
    app.pending = .prev;
}
fn onToggle(_: *anyopaque) anyerror!void {
    app.pending = .toggle;
}
fn onStop(_: *anyopaque) anyerror!void {
    app.pending = .stop;
}
fn onNext(_: *anyopaque) anyerror!void {
    app.pending = .next;
}
fn onAdd(_: *anyopaque) anyerror!void {
    app.pending = .add;
}
fn onRowClicked(sender: *anyopaque) anyerror!void {
    const button: *capy.Button = @ptrCast(@alignCast(sender));
    for (app.rows.items, 0..) |row, i| {
        if (row == button) {
            app.pending = .{ .select = i };
            return;
        }
    }
}

// ------------------------------------------------------------------ main

pub fn main() !void {
    const allocator = capy_allocator;

    try capy.init();
    defer capy.deinit();

    var window = try capy.Window.init();
    defer window.deinit();

    app = .{
        .allocator = allocator,
        .engine = audio.Engine.init(allocator),
        .tracks = std.ArrayList(Track).init(allocator),
        .rows = std.ArrayList(*capy.Button).init(allocator),
    };
    defer {
        app.engine.deinit();
        for (app.tracks.items) |t| {
            allocator.free(t.path);
            allocator.free(t.title);
            allocator.free(t.row_text);
        }
        app.tracks.deinit();
        app.rows.deinit();
    }

    app.now_label = capy.label(.{ .text = "Nothing playing", .layout = .{ .alignment = .Center } });
    app.time_label = capy.label(.{ .text = "0:00 / 0:00", .layout = .{ .alignment = .Center } });
    app.play_button = capy.button(.{ .label = "Play", .onclick = onToggle });
    app.playlist = try capy.column(.{ .spacing = 2 }, .{});

    try window.set(capy.column(.{ .spacing = 10 }, .{
        capy.label(.{ .text = "NOW PLAYING", .layout = .{ .alignment = .Center } }),
        app.now_label,
        app.time_label,
        capy.row(.{ .spacing = 6 }, .{
            capy.button(.{ .label = "Prev", .onclick = onPrev }),
            app.play_button,
            capy.button(.{ .label = "Stop", .onclick = onStop }),
            capy.button(.{ .label = "Next", .onclick = onNext }),
            capy.button(.{ .label = "Add songs...", .onclick = onAdd }),
        }),
        capy.label(.{ .text = "Playlist", .layout = .{ .alignment = .Left } }),
        capy.expanded(capy.scrollable(app.playlist)),
    }));

    window.setTitle("lmp3");
    window.setPreferredSize(560, 640);
    window.show();

    // Files given on the command line go straight into the playlist.
    {
        var args = try std.process.argsWithAllocator(allocator);
        defer args.deinit();
        _ = args.skip();
        var given = std.ArrayList([]u8).init(allocator);
        defer given.deinit();
        while (args.next()) |arg| try given.append(@constCast(arg));
        addPaths(given.items);
    }

    // Event loop. We poll instead of calling capy.runEventLoop() so we can update the
    // time display and advance to the next track between UI events without a timer.
    while (true) {
        var i: usize = 0;
        while (i < 64) : (i += 1) {
            if (!capy.stepEventLoop(.Asynchronous)) return; // window closed
        }

        if (app.pending) |action| {
            app.pending = null;
            perform(action);
        }
        checkTrackEnded();
        if (app.engine.isLoaded()) updateTime();

        std.time.sleep(8 * std.time.ns_per_ms);
    }
}
