// LDPC-Dekodierkern für DVB-T2: geschichtetes Sum-Product mit stückweise
// linearer Korrektur über acht Kodewörter gleichzeitig (eine NEON-Spur je
// Wort, int16).
#ifndef T2_LDPC_KERNEL_H
#define T2_LDPC_KERNEL_H

#include <stdint.h>

/// `totals`: n × 8 Werte (Kanal-LLR, positiv = 0), werden zu A-posteriori-Werten.
/// `messages`: Kanten × 8, vor dem ersten Aufruf mit 0 belegt.
/// Prüfung c umfasst `variables[offsets[c] ..< offsets[c+1]]`.
/// `done[w]` (8 Einträge) wird 1, sobald Wort w alle Prüfungen erfüllt;
/// Spuren mit done = 1 beim Aufruf zählen als fertig (z. B. unbenutzt).
/// `correction`: 5/8 LLR in Quantisierungsstufen (Konstante der Korrektur
/// log(1+e^{−z}) ≈ max(0, 5/8 − z/4)); die LLR müssen kalibriert sein.
/// `limit`: Höchstbetrag der Kanal-LLR (vom Aufrufer begrenzt) und der
/// Prüfnachrichten; limit·(größter Variablengrad + 1) muss unter 32767 bleiben.
/// Liefert die Zahl der Iterationen.
int t2_ldpc_decode8(int16_t *totals, int16_t *messages, const int32_t *offsets, const int32_t *variables,
                    int checks, int max_degree, int max_iterations, int16_t correction, int16_t limit, uint8_t *done);

#endif
