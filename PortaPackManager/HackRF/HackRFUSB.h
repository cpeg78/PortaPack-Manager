// Schlanker USB-Zugriff auf einen HackRF (bzw. ein PortaPack im
// HackRF-Modus) über IOKit – ohne libusb, damit die App keine Fremd-
// bibliothek braucht und mit Hardened Runtime läuft.
#ifndef HACKRF_USB_H
#define HACKRF_USB_H

#include <stdint.h>
#include <stddef.h>

typedef struct hrf_usb hrf_usb;

/// Öffnet das erste Gerät mit einer der Produkt-IDs. `error` erhält einen
/// IOKit-Fehlercode (0 = Gerät nicht gefunden).
hrf_usb *hrf_usb_open(uint16_t vendor_id, const uint16_t *product_ids, size_t count, int32_t *error);
void hrf_usb_close(hrf_usb *handle);

/// Vendor-Control-Transfer. Liefert übertragene Bytes oder einen negativen Fehler.
int32_t hrf_usb_control_in(hrf_usb *handle, uint8_t request, uint16_t value, uint16_t index,
                           void *data, uint16_t length, uint32_t timeout_ms);
int32_t hrf_usb_control_out(hrf_usb *handle, uint8_t request, uint16_t value, uint16_t index,
                            const void *data, uint16_t length, uint32_t timeout_ms);

/// Empfangener Block; läuft auf dem Streaming-Thread und muss die Daten
/// sofort kopieren – der Puffer wird gleich danach neu vergeben.
typedef void (*hrf_rx_callback)(void *context, const uint8_t *data, uint32_t length);

/// Startet den Dauerempfang: `transfers` asynchrone Bulk-Transfers zu je
/// `size` Bytes bleiben ständig offen (wie libhackrf), damit der kleine
/// Puffer des HackRF nie überläuft. Liefert 0 oder einen IOKit-Fehler.
int32_t hrf_usb_stream_start(hrf_usb *handle, uint32_t transfers, uint32_t size, hrf_rx_callback callback,
                             void *context);
/// Beendet den Dauerempfang und wartet, bis kein Rückruf mehr läuft.
void hrf_usb_stream_stop(hrf_usb *handle);

/// USB-Gerät neu enumerieren lassen (entspricht Ab- und Anstecken).
/// Hilft, wenn der serielle Treiber von macOS hängt.
int32_t hrf_usb_reenumerate(uint16_t vendor_id, uint16_t product_id);

#endif
