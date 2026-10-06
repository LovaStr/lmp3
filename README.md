# lmp3

A small audio player written in Zig.

| Part     | Library |
|----------|---------|
| UI       | [capy-ui/capy](https://github.com/capy-ui/capy) – one window: now playing, transport buttons, playlist |
| Decoding | [mackron/dr_libs](https://github.com/mackron/dr_libs) – `dr_mp3`, `dr_wav`, `dr_flac` (MP3, WAV, FLAC) |
| Output   | [mackron/miniaudio](https://github.com/mackron/miniaudio) (see "Why not zoto?" below) |

## Build and run

Requires **Zig 0.14.1** exactly (Capy refuses to build with any other version).

```sh
zig fetch --save git+https://github.com/capy-ui/capy   # once: records Capy + its hash in build.zig.zon
zig build run                                          # or: zig build -Doptimize=ReleaseSafe
```

On Linux you also need the GTK4 development package (Capy's backend). `zig build run -- a.mp3 b.flac` adds files from the command line.

## Using it

* **Add songs...** opens a file dialog where you can select several files at once (Windows: native dialog; Linux: `zenity`).
* Click a row in the playlist to play it. The playing row is marked with ▶ (‖ when paused).
* Prev / Play-Pause / Stop / Next work as expected; playback moves on to the next song automatically.

## Layout

```
build.zig, build.zig.zon
src/main.zig        Capy UI, playlist, event loop
src/audio.zig       Engine: decoder -> output device, position/duration
src/decoder.zig     dr_libs wrapper (mp3/wav/flac -> f32 frames)
src/dialog.zig      multi-select file picker
src/c/              C glue: dr_libs + miniaudio implementations, tiny device wrapper
vendor/             dr_mp3.h dr_wav.h dr_flac.h miniaudio.h (unmodified single-header libraries)
```

## Why not zoto?

[braheezy/zoto](https://github.com/braheezy/zoto) currently targets Zig 0.16 (it uses `std.Io.Mutex`, `std.Options.debug_io`, ...), while Capy
targets Zig 0.14.1 and uses `usingnamespace`, which Zig 0.15 removed. They cannot be compiled by the same compiler into one executable, so
audio output uses miniaudio instead. Only `src/audio.zig` and `src/c/` would change if you later switch to zoto (e.g. once Capy supports a newer Zig).

## Known limitations

* The playlist is a Capy scroll view; after adding many songs you may need to resize the window once before the scrollbar range updates.
* No seeking or volume control yet.
