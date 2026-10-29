// Korrelator-Kern für das GPS-L1-C/A-Tracking und ein einfacher
// Signalgenerator (für Tests und Gegenproben ohne Gerät).
#ifndef GPS_TRACK_KERNEL_H
#define GPS_TRACK_KERNEL_H

#include <stdint.h>

/// Zustand eines Tracking-Kanals (Code- und Träger-NCO, Akkumulatoren).
typedef struct {
    double code_phase;   ///< Prompt-Codephase in Chips, 0 ≤ x < 1023
    double code_step;    ///< Chips je Abtastwert
    double carr_phase;   ///< Trägerphase in Zyklen, 0 ≤ x < 1
    double carr_step;    ///< Zyklen je Abtastwert (Trägerfrequenz / fs)
    float ie, qe, ip, qp, il, ql;   ///< Early/Prompt/Late, I und Q
    float in, qn;        ///< Rauscharm: Code um `noise_offset` Chips versetzt
    double noise_offset; ///< Versatz des Rauscharms in Chips (0 < x < 1023)
    int32_t count;       ///< aufsummierte Abtastwerte der laufenden Codeperiode
} gps_corr_state;

/// Korreliert höchstens `n` komplexe Abtastwerte (`iq` = re, im, re, im …)
/// bis zum Ende der laufenden Codeperiode. `code_ext` hat 1025 Einträge
/// (±1): code[1022], code[0] … code[1022], code[0] – so laufen Early/Late
/// über die Periodengrenze. `half_spacing` ist der Abstand Early→Prompt in
/// Chips (≤ 1). Liefert die Zahl verbrauchter Werte; `*epoch_done` = 1, wenn
/// die Codeperiode damit vollständig ist (Akkumulatoren dann auslesen und
/// nullen, `code_phase` beginnt wieder bei ≈ 0). Der Rauscharm korreliert
/// mit derselben Replik weit neben der Spitze (`noise_offset`, eine Stelle
/// mit Autokorrelation −1/1023) und misst so die Rauschleistung für die
/// C/N0-Schätzung – unabhängig von Phasenlage und Datenbits.
int gps_correlate(gps_corr_state *s, const int8_t *code_ext, const float *iq, int n,
                  double half_spacing, int *epoch_done);

/// Addiert ein GPS-Signal: Amplitude · Datenbit · Code · exp(j2π·Trägerphase).
/// `chip` zählt die Chips seit Beginn von Bit 0 (Bit = chip / 20460),
/// `bits` sind ±1. Außerhalb der Bitfolge wird +1 angenommen.
void gps_synth_add(float *iq, int n, const int8_t *code, const int8_t *bits, int bit_count,
                   double chip, double chip_step, double carr_phase, double carr_step,
                   float amplitude);

/// Addiert komplexes weißes Gaußrauschen (Standardabweichung `sigma` je
/// Komponente). `state` ist der Zustand des Zufallsgenerators (≠ 0).
void gps_synth_noise(float *iq, int n, float sigma, uint64_t *state);

#endif
