#include "T2LDPCKernel.h"
#include <stdlib.h>

// Prüfknoten: geschichtetes Sum-Product mit stückweise linearer Korrektur.
// x ⊞ y = sign·(min(|x|,|y|) + log(1+e^{−(|x|+|y|)}) − log(1+e^{−||x|−|y||})),
// log(1+e^{−z}) ≈ max(0, 5/8 − z/4) (in LLR-Einheiten). Die Ausgaben je Kante
// entstehen vorwärts-rückwärts aus den übrigen Kanten der Prüfung.
// Gemessen (Zellebene, 64-QAM 1/2, 64K, 50 Iterationen): AWGN 10,2 dB statt
// 10,45 dB mit Offset-Min-Sum, 0-dB-Echo 12,1 dB statt 13,1 dB – dabei mit
// kalibrierten Log-MAP-LLR (siehe T2BitMapper).
//
// Kein Sättigen der A-posteriori-Summen: Kanal-LLR und Prüfnachrichten sind auf
// `limit` begrenzt, und limit·(größter Variablengrad + 1) < 32767. Mit einer
// geklemmten Summe kippte `Summe − Nachricht` bei hohem Störabstand das Vorzeichen,
// und gar nichts dekodierte mehr (Fund im Simulationsprüfstand ab 34 dB).

#if defined(__ARM_NEON)
#include <arm_neon.h>

// Erfüllt jede Spur alle Prüfungen? Ergebnis: Bitmaske der verletzten Spuren.
static uint16x8_t failed_lanes(const int16_t *totals, const int32_t *offsets, const int32_t *variables, int checks) {
    int16x8_t failed = vdupq_n_s16(0);
    for (int c = 0; c < checks; c++) {
        int16x8_t parity = vdupq_n_s16(0);
        for (int32_t e = offsets[c]; e < offsets[c + 1]; e++) {
            parity = veorq_s16(parity, vld1q_s16(totals + 8 * variables[e]));
        }
        failed = vorrq_s16(failed, parity);
    }
    // Vorzeichenbit gesetzt = mindestens eine Prüfung verletzt.
    return vreinterpretq_u16_s16(vshrq_n_s16(failed, 15));
}

// |x| ⊞ |y| für nichtnegative Beträge.
static inline int16x8_t boxplus(int16x8_t x, int16x8_t y, int16x8_t c) {
    const int16x8_t zero = vdupq_n_s16(0);
    const int16x8_t m = vminq_s16(x, y);
    const int16x8_t plus = vmaxq_s16(zero, vsubq_s16(c, vshrq_n_s16(vqaddq_s16(x, y), 2)));
    const int16x8_t minus = vmaxq_s16(zero, vsubq_s16(c, vshrq_n_s16(vabdq_s16(x, y), 2)));
    return vmaxq_s16(zero, vaddq_s16(m, vsubq_s16(plus, minus)));
}

int t2_ldpc_decode8(int16_t *totals, int16_t *messages, const int32_t *offsets, const int32_t *variables,
                    int checks, int max_degree, int max_iterations, int16_t correction, int16_t limit, uint8_t *done) {
    const int16x8_t c = vdupq_n_s16(correction);
    const int16x8_t bound = vdupq_n_s16(limit);
    int16x8_t *q = malloc(sizeof(int16x8_t) * (size_t)max_degree * 3);
    int16x8_t *forward = q + max_degree, *backward = q + 2 * max_degree;
    int iteration = 0;
    while (iteration < max_iterations) {
        iteration++;
        for (int k = 0; k < checks; k++) {
            const int32_t start = offsets[k];
            const int d = offsets[k + 1] - start;
            int16x8_t signs = vdupq_n_s16(0);
            for (int j = 0; j < d; j++) {
                const int16x8_t x = vqsubq_s16(vld1q_s16(totals + 8 * variables[start + j]), vld1q_s16(messages + 8 * (start + j)));
                q[j] = x;
                signs = veorq_s16(signs, x);
            }
            forward[0] = vqabsq_s16(q[0]);
            for (int j = 1; j < d - 1; j++) forward[j] = boxplus(forward[j - 1], vqabsq_s16(q[j]), c);
            backward[d - 1] = vqabsq_s16(q[d - 1]);
            for (int j = d - 2; j > 0; j--) backward[j] = boxplus(backward[j + 1], vqabsq_s16(q[j]), c);
            for (int j = 0; j < d; j++) {
                const int16x8_t x = q[j];
                int16x8_t out = j == 0 ? backward[1] : (j == d - 1 ? forward[d - 2] : boxplus(forward[j - 1], backward[j + 1], c));
                out = vminq_s16(out, bound);
                const int16x8_t negative = vshrq_n_s16(veorq_s16(signs, x), 15);   // −1 oder 0
                out = vsubq_s16(veorq_s16(out, negative), negative);
                vst1q_s16(messages + 8 * (start + j), out);
                vst1q_s16(totals + 8 * variables[start + j], vqaddq_s16(x, out));
            }
        }
        if ((iteration & 1) == 0 || iteration == max_iterations) {
            uint16_t lanes[8];
            vst1q_u16(lanes, failed_lanes(totals, offsets, variables, checks));
            int all = 1;
            for (int w = 0; w < 8; w++) {
                if (!done[w]) {
                    if (lanes[w] == 0) done[w] = 1; else all = 0;
                }
            }
            if (all) break;
        }
    }
    free(q);
    return iteration;
}

#else

// Ohne NEON (Intel-Macs): dieselbe Rechnung Spur für Spur.
#include <limits.h>

static int16_t saturate(int value) { return value > INT16_MAX ? INT16_MAX : (value < INT16_MIN ? INT16_MIN : (int16_t)value); }

static inline int boxplus(int x, int y, int c) {
    const int m = x < y ? x : y;
    int plus = c - ((x + y) >> 2), minus = c - ((x > y ? x - y : y - x) >> 2);
    if (plus < 0) plus = 0;
    if (minus < 0) minus = 0;
    const int r = m + plus - minus;
    return r > 0 ? r : 0;
}

int t2_ldpc_decode8(int16_t *totals, int16_t *messages, const int32_t *offsets, const int32_t *variables,
                    int checks, int max_degree, int max_iterations, int16_t correction, int16_t limit, uint8_t *done) {
    int *q = malloc(sizeof(int) * (size_t)max_degree * 3);
    int *forward = q + max_degree, *backward = q + 2 * max_degree;
    int iteration = 0;
    while (iteration < max_iterations) {
        iteration++;
        for (int k = 0; k < checks; k++) {
            const int32_t start = offsets[k];
            const int d = offsets[k + 1] - start;
            for (int w = 0; w < 8; w++) {
                int sign = 0;
                for (int j = 0; j < d; j++) {
                    const int x = saturate(totals[8 * variables[start + j] + w] - messages[8 * (start + j) + w]);
                    q[j] = x;
                    sign ^= x < 0;
                }
                forward[0] = q[0] < 0 ? -q[0] : q[0];
                for (int j = 1; j < d - 1; j++) forward[j] = boxplus(forward[j - 1], q[j] < 0 ? -q[j] : q[j], correction);
                backward[d - 1] = q[d - 1] < 0 ? -q[d - 1] : q[d - 1];
                for (int j = d - 2; j > 0; j--) backward[j] = boxplus(backward[j + 1], q[j] < 0 ? -q[j] : q[j], correction);
                for (int j = 0; j < d; j++) {
                    const int x = q[j];
                    int out = j == 0 ? backward[1] : (j == d - 1 ? forward[d - 2] : boxplus(forward[j - 1], backward[j + 1], correction));
                    if (out > limit) out = limit;
                    if (sign ^ (x < 0)) out = -out;
                    messages[8 * (start + j) + w] = (int16_t)out;
                    totals[8 * variables[start + j] + w] = saturate(x + out);
                }
            }
        }
        if ((iteration & 1) == 0 || iteration == max_iterations) {
            int all = 1;
            for (int w = 0; w < 8; w++) {
                if (done[w]) continue;
                int failed = 0;
                for (int c = 0; c < checks && !failed; c++) {
                    int parity = 0;
                    for (int32_t e = offsets[c]; e < offsets[c + 1]; e++) parity ^= totals[8 * variables[e] + w] < 0;
                    failed = parity;
                }
                if (!failed) done[w] = 1; else all = 0;
            }
            if (all) break;
        }
    }
    free(q);
    return iteration;
}

#endif
