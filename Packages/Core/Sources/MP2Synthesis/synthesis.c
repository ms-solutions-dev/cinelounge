#include "include/mp2synthesis.h"

void mp2_synthesize_granule(
    int32_t *v, int32_t *voffset, const int32_t *samples,
    const int32_t *n, const int32_t *window, int16_t *pcm) {

    int offset = *voffset;
    int32_t u[512];

    for (int nr = 0; nr < 3; ++nr) {
        offset = (offset - 64) & 1023;

        for (int ch = 0; ch < 2; ++ch) {
            int32_t *vch = v + (ch << 10);
            const int32_t *sch = samples + ch * 96;

            // Matrizierung: N (9 Bit) mal Wert (~17 Bit), Summe über 32 —
            // bleibt unter 31 Bit, wie in der Referenz mit `int` gerechnet.
            const int32_t *row = n;
            for (int i = 0; i < 64; ++i) {
                int32_t sum = 0;
                for (int j = 0; j < 32; ++j)
                    sum += row[j] * sch[j * 3 + nr];
                vch[(offset + i) & 1023] = (sum + 8192) >> 14;
                row += 32;
            }

            // Fenster über das Register: Werte 14 Bit, Fenster 17 Bit —
            // das Produkt bleibt unter 31 Bit.
            for (int i = 0; i < 8; ++i) {
                int lower = i << 6;
                int src = offset + (i << 7);
                for (int j = 0; j < 32; ++j) {
                    u[lower + j] = vch[(src + j) & 1023];
                    u[lower + j + 32] = vch[(src + j + 96) & 1023];
                }
            }
            for (int i = 0; i < 512; ++i)
                u[i] = (u[i] * window[i] + 32) >> 6;

            for (int j = 0; j < 32; ++j) {
                int32_t sum = 0;
                for (int i = 0; i < 16; ++i)
                    sum -= u[(i << 5) + j];
                sum = (sum + 8) >> 4;
                if (sum < -32768) sum = -32768;
                if (sum > 32767) sum = 32767;
                pcm[((nr * 32 + j) << 1) | ch] = (int16_t)sum;
            }
        }
    }
    *voffset = offset;
}
