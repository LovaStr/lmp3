//! Playback engine: a dr_libs `Decoder` feeding a miniaudio output device.
//!
//! Threading: everything except `dataCallback` runs on the UI thread. The audio
//! thread only touches the decoder and two atomics, and the UI thread never frees
//! the decoder while the device is alive (the device is closed first).
const std = @import("std");
const Decoder = @import("decoder.zig").Decoder;

const c = @cImport({
    @cInclude("lmp_audio.h");
});

pub const Engine = struct {
    allocator: std.mem.Allocator,
    decoder: ?*Decoder = null,
    device: ?*c.lmp_device = null,
    channels: usize = 2,
    /// True while the device is running (UI thread only).
    playing: bool = false,
    /// PCM frames handed to the device so far.
    frames_played: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Set by the audio thread when the decoder ran dry.
    finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(allocator: std.mem.Allocator) Engine {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Engine) void {
        self.unload();
    }

    pub fn isLoaded(self: *const Engine) bool {
        return self.decoder != null;
    }

    /// Loads `path` and prepares the output device; call `play()` to start it.
    /// The device is (re)opened with the track's own channel count and sample rate;
    /// miniaudio converts to whatever the hardware wants.
    pub fn load(self: *Engine, path: []const u8) !void {
        self.unload();

        const dec = try Decoder.open(self.allocator, path);
        errdefer dec.close();

        self.decoder = dec;
        errdefer self.decoder = null;
        self.channels = dec.channels;
        self.frames_played.store(0, .release);
        self.finished.store(false, .release);

        const raw = c.lmp_device_open(@intCast(dec.channels), dec.sample_rate, dataCallback, self);
        self.device = @as(?*c.lmp_device, raw) orelse return error.AudioDeviceFailed;
    }

    /// Stops playback and releases the device and the decoder.
    pub fn unload(self: *Engine) void {
        // Close the device first: this waits for a running callback to return.
        if (self.device) |dev| c.lmp_device_close(dev);
        self.device = null;
        self.playing = false;
        if (self.decoder) |dec| dec.close();
        self.decoder = null;
    }

    pub fn play(self: *Engine) !void {
        const dev = self.device orelse return error.NothingLoaded;
        if (c.lmp_device_start(dev) == 0) return error.AudioDeviceFailed;
        self.playing = true;
    }

    pub fn pause(self: *Engine) void {
        const dev = self.device orelse return;
        _ = c.lmp_device_stop(dev);
        self.playing = false;
    }

    pub fn positionSeconds(self: *const Engine) f64 {
        const dec = self.decoder orelse return 0;
        const played: f64 = @floatFromInt(self.frames_played.load(.acquire));
        const pos = played / @as(f64, @floatFromInt(dec.sample_rate));
        return @min(pos, self.durationSeconds());
    }

    pub fn durationSeconds(self: *const Engine) f64 {
        const dec = self.decoder orelse return 0;
        return @as(f64, @floatFromInt(dec.total_frames)) / @as(f64, @floatFromInt(dec.sample_rate));
    }

    /// Runs on miniaudio's audio thread.
    fn dataCallback(user: ?*anyopaque, out: [*c]f32, frames: c_uint) callconv(.c) void {
        const self: *Engine = @ptrCast(@alignCast(user.?));
        const channels = self.channels;
        const want: usize = frames;
        const buf = out[0 .. want * channels];

        var got: usize = 0;
        if (self.decoder) |dec| got = dec.read(buf, want);

        if (got < want) {
            @memset(buf[got * channels ..], 0);
            self.finished.store(true, .release);
        }
        _ = self.frames_played.fetchAdd(got, .monotonic);
    }
};
