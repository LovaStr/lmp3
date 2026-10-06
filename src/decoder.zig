//! Audio decoding with mackron/dr_libs (dr_mp3, dr_wav, dr_flac).
//!
//! A whole file is read into memory and decoded from there. That keeps non-ASCII
//! file names working on Windows (Zig opens the file, dr_libs never sees the path)
//! and keeps the audio thread free of file I/O.
const std = @import("std");

const c = @cImport({
    @cInclude("dr_libs.h");
});

pub const Format = enum { mp3, wav, flac };

pub const Decoder = struct {
    allocator: std.mem.Allocator,
    /// The encoded file. Must outlive the dr_libs decoder.
    data: []u8,
    channels: u32,
    sample_rate: u32,
    /// Length in PCM frames (one frame = one sample for every channel).
    total_frames: u64,
    backend: Backend,

    const Backend = union(Format) {
        mp3: *c.drmp3,
        wav: *c.drwav,
        flac: *c.drflac,
    };

    pub fn formatOf(path: []const u8) ?Format {
        const ext = std.fs.path.extension(path);
        if (std.ascii.eqlIgnoreCase(ext, ".mp3")) return .mp3;
        if (std.ascii.eqlIgnoreCase(ext, ".wav")) return .wav;
        if (std.ascii.eqlIgnoreCase(ext, ".flac")) return .flac;
        return null;
    }

    pub fn isSupported(path: []const u8) bool {
        return formatOf(path) != null;
    }

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !*Decoder {
        const format = formatOf(path) orelse return error.UnsupportedFormat;

        const data = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024 * 1024);
        errdefer allocator.free(data);

        const self = try allocator.create(Decoder);
        errdefer allocator.destroy(self);

        switch (format) {
            .mp3 => {
                const mp3 = try allocator.create(c.drmp3);
                errdefer allocator.destroy(mp3);
                if (c.drmp3_init_memory(mp3, data.ptr, data.len, null) == 0) return error.DecodeFailed;
                self.* = .{
                    .allocator = allocator,
                    .data = data,
                    .channels = mp3.channels,
                    .sample_rate = mp3.sampleRate,
                    // Uses the Xing/Info header when present, otherwise scans the file once.
                    .total_frames = c.drmp3_get_pcm_frame_count(mp3),
                    .backend = .{ .mp3 = mp3 },
                };
            },
            .wav => {
                const wav = try allocator.create(c.drwav);
                errdefer allocator.destroy(wav);
                if (c.drwav_init_memory(wav, data.ptr, data.len, null) == 0) return error.DecodeFailed;
                self.* = .{
                    .allocator = allocator,
                    .data = data,
                    .channels = wav.channels,
                    .sample_rate = wav.sampleRate,
                    .total_frames = wav.totalPCMFrameCount,
                    .backend = .{ .wav = wav },
                };
            },
            .flac => {
                const raw = c.drflac_open_memory(data.ptr, data.len, null);
                const flac: *c.drflac = @as(?*c.drflac, raw) orelse return error.DecodeFailed;
                self.* = .{
                    .allocator = allocator,
                    .data = data,
                    .channels = flac.channels,
                    .sample_rate = flac.sampleRate,
                    .total_frames = flac.totalPCMFrameCount,
                    .backend = .{ .flac = flac },
                };
            },
        }

        if (self.channels == 0 or self.sample_rate == 0) {
            self.close();
            return error.DecodeFailed;
        }
        return self;
    }

    /// Decodes up to `frames` PCM frames as interleaved f32 into `out`
    /// (`out.len` must be at least `frames * channels`).
    /// Returns the number of frames written; less than `frames` means end of stream.
    /// Safe to call from the audio thread: it does not allocate.
    pub fn read(self: *Decoder, out: []f32, frames: usize) usize {
        std.debug.assert(out.len >= frames * self.channels);
        const n: u64 = switch (self.backend) {
            .mp3 => |p| c.drmp3_read_pcm_frames_f32(p, frames, out.ptr),
            .wav => |p| c.drwav_read_pcm_frames_f32(p, frames, out.ptr),
            .flac => |p| c.drflac_read_pcm_frames_f32(p, frames, out.ptr),
        };
        return @intCast(n);
    }

    pub fn close(self: *Decoder) void {
        const allocator = self.allocator;
        switch (self.backend) {
            .mp3 => |p| {
                c.drmp3_uninit(p);
                allocator.destroy(p);
            },
            .wav => |p| {
                _ = c.drwav_uninit(p);
                allocator.destroy(p);
            },
            .flac => |p| c.drflac_close(p),
        }
        allocator.free(self.data);
        allocator.destroy(self);
    }
};
