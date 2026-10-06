/* Single translation unit holding the implementations of the header-only libraries. */

/* mackron/dr_libs: decoding */
#define DR_MP3_IMPLEMENTATION
#include "dr_mp3.h"
#define DR_WAV_IMPLEMENTATION
#include "dr_wav.h"
#define DR_FLAC_IMPLEMENTATION
#include "dr_flac.h"

/* mackron/miniaudio: output only (decoding is done by dr_libs above) */
#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

#include <stdlib.h>
#include "lmp_audio.h"

struct lmp_device {
    ma_device dev;
    lmp_data_cb cb;
    void* user;
};

static void lmp_on_data(ma_device* d, void* out, const void* in, ma_uint32 frames) {
    struct lmp_device* self = (struct lmp_device*)d->pUserData;
    (void)in;
    self->cb(self->user, (float*)out, (unsigned int)frames);
}

lmp_device* lmp_device_open(unsigned int channels, unsigned int sample_rate, lmp_data_cb cb, void* user) {
    ma_device_config cfg;
    struct lmp_device* self = (struct lmp_device*)calloc(1, sizeof(*self));
    if (self == NULL) return NULL;

    self->cb = cb;
    self->user = user;

    cfg = ma_device_config_init(ma_device_type_playback);
    cfg.playback.format = ma_format_f32;
    cfg.playback.channels = channels;
    cfg.sampleRate = sample_rate;
    cfg.dataCallback = lmp_on_data;
    cfg.pUserData = self;

    if (ma_device_init(NULL, &cfg, &self->dev) != MA_SUCCESS) {
        free(self);
        return NULL;
    }
    return self;
}

int lmp_device_start(lmp_device* dev) {
    return ma_device_start(&dev->dev) == MA_SUCCESS;
}

int lmp_device_stop(lmp_device* dev) {
    return ma_device_stop(&dev->dev) == MA_SUCCESS;
}

void lmp_device_close(lmp_device* dev) {
    if (dev == NULL) return;
    ma_device_uninit(&dev->dev);
    free(dev);
}
