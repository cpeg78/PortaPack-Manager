#include "GPSTrackKernel.h"
#include <math.h>

// Der Träger-NCO dreht einen Zeiger per Rekursion (komplexe Multiplikation
// je Abtastwert) statt sin/cos zu rechnen; zu Beginn jedes Aufrufs wird er
// exakt aus der Phase neu gesetzt, damit sich kein Rundungsfehler aufbaut.
// Bewusst schlichtes, portables C (ARM64 und x86_64 gleich): Die Schleife
// ist kurz genug, dass zwölf Kanäle bei 4 MS/s auf einem Kern laufen.

int gps_correlate(gps_corr_state *s, const int8_t *code_ext, const float *iq, int n,
                  double half_spacing, int *epoch_done) {
    *epoch_done = 0;
    if (n <= 0) return 0;
    // Nicht endliche oder unsinnige Zustände (z. B. nach einer entgleisten
    // Schleife) würden Indizes außerhalb der Codetabelle ergeben: zurücksetzen.
    if (!isfinite(s->code_phase) || s->code_phase < 0 || s->code_phase >= 1023.0) s->code_phase = 0;
    // Unbrauchbarer Codeschritt: Block verwerfen (n zurückgeben, sonst hinge der Aufrufer).
    if (!isfinite(s->code_step) || s->code_step <= 0 || s->code_step > 1023.0) return n;
    if (!isfinite(s->carr_phase)) s->carr_phase = 0;
    if (!isfinite(s->carr_step)) s->carr_step = 0;
    if (!isfinite(half_spacing) || half_spacing < 0 || half_spacing > 1) half_spacing = 0.5;
    double noff = s->noise_offset;
    if (!isfinite(noff) || noff <= 0 || noff >= 1023.0) noff = 511.0;
    const double cp = s->code_phase, step = s->code_step;
    // Abtastwerte bis zum Periodenende: alle i mit cp + i·step < 1023.
    double remaining = ceil((1023.0 - cp) / step);
    if (remaining < 1) remaining = 1;
    int k;
    if (remaining <= (double)n) {
        k = (int)remaining;
        *epoch_done = 1;
    } else {
        k = n;
    }

    double c = cos(2.0 * M_PI * s->carr_phase), sn = sin(2.0 * M_PI * s->carr_phase);
    const double dc = cos(2.0 * M_PI * s->carr_step), ds = sin(2.0 * M_PI * s->carr_step);
    float ie = 0, qe = 0, ip = 0, qp = 0, il = 0, ql = 0, in = 0, qn = 0;
    for (int i = 0; i < k; i++) {
        const float re = iq[2 * i], im = iq[2 * i + 1];
        // Träger entfernen: (re + j·im)·(c − j·sn)
        const float bi = (float)(re * c + im * sn);
        const float bq = (float)(im * c - re * sn);
        const double x = cp + (double)i * step;
        int pe = (int)(x + half_spacing + 1.0);
        int pl = (int)(x - half_spacing + 1.0);
        int pp = (int)(x + 1.0);
        // Alle drei Indizes auf die erweiterte Tabelle (0…1024) klemmen.
        if (pe > 1024) pe = 1024;
        if (pe < 0) pe = 0;
        if (pp > 1024) pp = 1024;
        if (pp < 0) pp = 0;
        if (pl > 1024) pl = 1024;
        if (pl < 0) pl = 0;
        // Rauscharm: Chip (x + Versatz) mod 1023, Tabelleneintrag +1.
        int pn = (int)(x + noff);
        if (pn >= 1023) pn -= 1023;
        if (pn < 0) pn = 0;
        if (pn > 1022) pn = 1022;
        const float e = code_ext[pe], p = code_ext[pp], l = code_ext[pl], nz = code_ext[pn + 1];
        in += nz * bi; qn += nz * bq;
        ie += e * bi; qe += e * bq;
        ip += p * bi; qp += p * bq;
        il += l * bi; ql += l * bq;
        const double nc = c * dc - sn * ds;
        sn = sn * dc + c * ds;
        c = nc;
    }
    s->ie += ie; s->qe += qe; s->ip += ip; s->qp += qp; s->il += il; s->ql += ql;
    s->in += in; s->qn += qn;
    s->count += k;
    double next = cp + (double)k * step;
    if (*epoch_done) next -= 1023.0;
    if (next < 0) next = 0;
    s->code_phase = next;
    const double ph = s->carr_phase + (double)k * s->carr_step;
    s->carr_phase = ph - floor(ph);
    return k;
}

void gps_synth_add(float *iq, int n, const int8_t *code, const int8_t *bits, int bit_count,
                   double chip, double chip_step, double carr_phase, double carr_step,
                   float amplitude) {
    double c = cos(2.0 * M_PI * carr_phase), sn = sin(2.0 * M_PI * carr_phase);
    const double dc = cos(2.0 * M_PI * carr_step), ds = sin(2.0 * M_PI * carr_step);
    for (int i = 0; i < n; i++) {
        const double x = chip + (double)i * chip_step;
        const int64_t whole = (int64_t)floor(x);
        int64_t bit = whole / 20460;
        if (whole < 0) bit = -1;
        int64_t ci = whole % 1023;
        if (ci < 0) ci += 1023;
        float d = 1;
        if (bit >= 0 && bit < bit_count) d = bits[bit];
        const float v = amplitude * d * code[ci];
        iq[2 * i] += (float)(v * c);
        iq[2 * i + 1] += (float)(v * sn);
        const double nc = c * dc - sn * ds;
        sn = sn * dc + c * ds;
        c = nc;
    }
}

static inline double uniform(uint64_t *state) {
    // xorshift64*
    uint64_t x = *state;
    x ^= x >> 12; x ^= x << 25; x ^= x >> 27;
    *state = x;
    return ((double)((x * 0x2545F4914F6CDD1DULL) >> 11) + 0.5) * (1.0 / 9007199254740992.0);
}

void gps_synth_noise(float *iq, int n, float sigma, uint64_t *state) {
    for (int i = 0; i < n; i++) {
        const double r = sqrt(-2.0 * log(uniform(state))) * sigma;
        const double a = 2.0 * M_PI * uniform(state);
        iq[2 * i] += (float)(r * cos(a));
        iq[2 * i + 1] += (float)(r * sin(a));
    }
}
