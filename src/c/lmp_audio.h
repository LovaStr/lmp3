/* Tiny wrapper around a miniaudio playback device, imported into Zig (see audio.zig).
 * It keeps miniaudio's large structs on the C side so Zig only sees an opaque handle. */
#ifndef LMP_AUDIO_H
#define LMP_AUDIO_H

typedef struct lmp_device lmp_device;

/* Called on the audio thread. Must fill `out` with frames * channels interleaved f32 samples. */
typedef void (*lmp_data_cb)(void* user, float* out, unsigned int frames);

/* Opens (but does not start) a default-output playback device. Returns NULL on failure. */
lmp_device* lmp_device_open(unsigned int channels, unsigned int sample_rate, lmp_data_cb cb, void* user);
/* Return 1 on success, 0 on failure. */
int lmp_device_start(lmp_device* dev);
int lmp_device_stop(lmp_device* dev);
/* Stops the device (waiting for the callback to finish) and frees it. */
void lmp_device_close(lmp_device* dev);

#endif
