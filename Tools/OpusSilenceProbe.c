#include <stdint.h>
#include <stdio.h>

typedef struct OpusDecoder OpusDecoder;
OpusDecoder *opus_decoder_create(int32_t, int, int *);
int opus_decode(OpusDecoder *, const unsigned char *, int32_t, int16_t *, int, int);
const char *opus_strerror(int);
void opus_decoder_destroy(OpusDecoder *);

int main(void) {
    static const uint8_t silence[] = {0xf4, 0xff, 0xfe};
    int error = 0;
    OpusDecoder *decoder = opus_decoder_create(48000, 2, &error);
    if (!decoder || error != 0) {
        fprintf(stderr, "decoder create: %d\n", error);
        return 1;
    }

    int16_t samples[480 * 2];
    int frames = opus_decode(decoder, silence, sizeof(silence), samples, 480, 0);
    int peak = 0;
    if (frames > 0) {
        for (int index = 0; index < frames * 2; ++index) {
            int value = samples[index] < 0 ? -samples[index] : samples[index];
            if (value > peak) peak = value;
        }
    }
    printf("frames=%d peak=%d error=%s\n", frames, peak, opus_strerror(frames));
    opus_decoder_destroy(decoder);
    return frames == 480 ? 0 : 2;
}
