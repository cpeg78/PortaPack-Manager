#include "HackRFUSB.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <unistd.h>

struct hrf_stream;

struct hrf_usb {
    IOUSBDeviceInterface650 **device;
    IOUSBInterfaceInterface650 **interface;
    uint8_t in_pipe;
    CFRunLoopSourceRef async_source;
    struct hrf_stream *stream;
};

struct hrf_transfer {
    struct hrf_stream *stream;
    uint8_t *buffer;
};

struct hrf_stream {
    hrf_usb *handle;
    hrf_rx_callback callback;
    void *context;
    uint32_t size;
    uint32_t count;
    struct hrf_transfer *transfers;
    atomic_bool stopping;
    atomic_int outstanding;
    int errors;
    CFRunLoopRef run_loop;
    pthread_t thread;
    pthread_mutex_t mutex;
    pthread_cond_t ready;
    int started;
    IOReturn start_error;
};

static io_service_t find_device(uint16_t vendor_id, uint16_t product_id) {
    CFMutableDictionaryRef matching = IOServiceMatching("IOUSBHostDevice");
    if (!matching) return 0;
    int32_t vid = vendor_id, pid = product_id;
    CFNumberRef v = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &vid);
    CFNumberRef p = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &pid);
    CFDictionarySetValue(matching, CFSTR("idVendor"), v);
    CFDictionarySetValue(matching, CFSTR("idProduct"), p);
    CFRelease(v);
    CFRelease(p);
    return IOServiceGetMatchingService(kIOMainPortDefault, matching); // verbraucht matching
}

static IOUSBDeviceInterface650 **device_interface(io_service_t service, int32_t *error) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(service, kIOUSBDeviceUserClientTypeID,
                                                         kIOCFPlugInInterfaceID, &plugin, &score);
    if (kr != KERN_SUCCESS || !plugin) {
        if (error) *error = kr;
        return NULL;
    }
    IOUSBDeviceInterface650 **dev = NULL;
    HRESULT res = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID650), (LPVOID *)&dev);
    (*plugin)->Release(plugin);
    if (res || !dev) {
        if (error) *error = (int32_t)res;
        return NULL;
    }
    return dev;
}

hrf_usb *hrf_usb_open(uint16_t vendor_id, const uint16_t *product_ids, size_t count, int32_t *error) {
    if (error) *error = 0;
    io_service_t service = 0;
    for (size_t i = 0; i < count && !service; i++) service = find_device(vendor_id, product_ids[i]);
    if (!service) return NULL;

    IOUSBDeviceInterface650 **dev = device_interface(service, error);
    IOObjectRelease(service);
    if (!dev) return NULL;

    kern_return_t kr = (*dev)->USBDeviceOpen(dev);
    if (kr != kIOReturnSuccess) {
        if (error) *error = kr;
        (*dev)->Release(dev);
        return NULL;
    }

    UInt8 config = 0;
    (*dev)->GetConfiguration(dev, &config);
    if (config != 1) {
        kr = (*dev)->SetConfiguration(dev, 1);
        if (kr != kIOReturnSuccess) {
            if (error) *error = kr;
            (*dev)->USBDeviceClose(dev);
            (*dev)->Release(dev);
            return NULL;
        }
    }

    IOUSBFindInterfaceRequest request = {
        .bInterfaceClass = kIOUSBFindInterfaceDontCare,
        .bInterfaceSubClass = kIOUSBFindInterfaceDontCare,
        .bInterfaceProtocol = kIOUSBFindInterfaceDontCare,
        .bAlternateSetting = kIOUSBFindInterfaceDontCare,
    };
    io_iterator_t iterator = 0;
    (*dev)->CreateInterfaceIterator(dev, &request, &iterator);
    io_service_t intf_service = IOIteratorNext(iterator);
    IOObjectRelease(iterator);

    IOUSBInterfaceInterface650 **intf = NULL;
    uint8_t in_pipe = 0;
    if (intf_service) {
        IOCFPlugInInterface **plugin = NULL;
        SInt32 score = 0;
        kr = IOCreatePlugInInterfaceForService(intf_service, kIOUSBInterfaceUserClientTypeID,
                                               kIOCFPlugInInterfaceID, &plugin, &score);
        IOObjectRelease(intf_service);
        if (kr == KERN_SUCCESS && plugin) {
            (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID650), (LPVOID *)&intf);
            (*plugin)->Release(plugin);
        }
        if (intf && (*intf)->USBInterfaceOpen(intf) == kIOReturnSuccess) {
            UInt8 endpoints = 0;
            (*intf)->GetNumEndpoints(intf, &endpoints);
            for (UInt8 pipe = 1; pipe <= endpoints; pipe++) {
                UInt8 direction, number, type, interval;
                UInt16 max_packet;
                if ((*intf)->GetPipeProperties(intf, pipe, &direction, &number, &type, &max_packet, &interval) ==
                        kIOReturnSuccess &&
                    direction == kUSBIn && type == kUSBBulk && number == 1) {
                    in_pipe = pipe;
                }
            }
        } else if (intf) {
            (*intf)->Release(intf);
            intf = NULL;
        }
    }

    hrf_usb *handle = calloc(1, sizeof(hrf_usb));
    if (!handle) {
        // Kein Speicher: Gerät wieder freigeben statt über NULL zu schreiben.
        if (intf) {
            (*intf)->USBInterfaceClose(intf);
            (*intf)->Release(intf);
        }
        (*dev)->USBDeviceClose(dev);
        (*dev)->Release(dev);
        return NULL;
    }
    handle->device = dev;
    handle->interface = intf;
    handle->in_pipe = in_pipe;
    return handle;
}

void hrf_usb_close(hrf_usb *handle) {
    if (!handle) return;
    hrf_usb_stream_stop(handle);
    if (handle->async_source) CFRelease(handle->async_source);
    if (handle->interface) {
        (*handle->interface)->USBInterfaceClose(handle->interface);
        (*handle->interface)->Release(handle->interface);
    }
    if (handle->device) {
        (*handle->device)->USBDeviceClose(handle->device);
        (*handle->device)->Release(handle->device);
    }
    free(handle);
}

static int32_t control(hrf_usb *handle, uint8_t direction, uint8_t request, uint16_t value, uint16_t index,
                       void *data, uint16_t length, uint32_t timeout_ms) {
    if (!handle || !handle->device) return -1;
    IOUSBDevRequestTO req = {
        .bmRequestType = USBmakebmRequestType(direction, kUSBVendor, kUSBDevice),
        .bRequest = request,
        .wValue = value,
        .wIndex = index,
        .wLength = length,
        .pData = data,
        .wLenDone = 0,
        .noDataTimeout = timeout_ms,
        .completionTimeout = timeout_ms,
    };
    IOReturn kr = (*handle->device)->DeviceRequestTO(handle->device, &req);
    if (kr != kIOReturnSuccess) return (int32_t)kr < 0 ? (int32_t)kr : -(int32_t)kr;
    return (int32_t)req.wLenDone;
}

int32_t hrf_usb_control_in(hrf_usb *handle, uint8_t request, uint16_t value, uint16_t index, void *data,
                           uint16_t length, uint32_t timeout_ms) {
    return control(handle, kUSBIn, request, value, index, data, length, timeout_ms);
}

int32_t hrf_usb_control_out(hrf_usb *handle, uint8_t request, uint16_t value, uint16_t index, const void *data,
                            uint16_t length, uint32_t timeout_ms) {
    return control(handle, kUSBOut, request, value, index, (void *)data, length, timeout_ms);
}

int32_t hrf_usb_reenumerate(uint16_t vendor_id, uint16_t product_id) {
    io_service_t service = find_device(vendor_id, product_id);
    if (!service) return -1;
    int32_t error = 0;
    IOUSBDeviceInterface650 **dev = device_interface(service, &error);
    IOObjectRelease(service);
    if (!dev) return error ? error : -1;
    IOReturn kr = (*dev)->USBDeviceOpenSeize(dev);
    if (kr == kIOReturnSuccess) {
        kr = (*dev)->USBDeviceReEnumerate(dev, 0);
        (*dev)->USBDeviceClose(dev);
    }
    (*dev)->Release(dev);
    return kr;
}

// MARK: - Dauerempfang mit asynchronen Transfers

static IOReturn submit(struct hrf_transfer *transfer);

static void completed(void *refcon, IOReturn result, void *arg0) {
    struct hrf_transfer *transfer = refcon;
    struct hrf_stream *stream = transfer->stream;
    uint32_t length = (uint32_t)(uintptr_t)arg0;
    if (!atomic_load(&stream->stopping)) {
        if (result == kIOReturnSuccess && length > 0) {
            stream->errors = 0;
            stream->callback(stream->context, transfer->buffer, length);
        } else if (result == kIOUSBPipeStalled) {
            (*stream->handle->interface)->ClearPipeStallBothEnds(stream->handle->interface, stream->handle->in_pipe);
        } else if (result != kIOReturnSuccess) {
            stream->errors++;
        }
        // Gleich wieder vergeben, solange nicht dauernd Fehler kommen.
        if (stream->errors < 100 && submit(transfer) == kIOReturnSuccess) return;
    }
    if (atomic_fetch_sub(&stream->outstanding, 1) == 1) CFRunLoopStop(stream->run_loop);
}

static IOReturn submit(struct hrf_transfer *transfer) {
    hrf_usb *handle = transfer->stream->handle;
    return (*handle->interface)->ReadPipeAsync(handle->interface, handle->in_pipe, transfer->buffer,
                                               transfer->stream->size, completed, transfer);
}

static void *stream_thread(void *argument) {
    struct hrf_stream *stream = argument;
    hrf_usb *handle = stream->handle;
    pthread_setname_np("HackRF RX");
    stream->run_loop = CFRunLoopGetCurrent();
    CFRunLoopAddSource(stream->run_loop, handle->async_source, kCFRunLoopDefaultMode);

    IOReturn error = kIOReturnSuccess;
    for (uint32_t i = 0; i < stream->count; i++) {
        atomic_fetch_add(&stream->outstanding, 1);
        error = submit(&stream->transfers[i]);
        if (error != kIOReturnSuccess) {
            atomic_fetch_sub(&stream->outstanding, 1);
            break;
        }
    }
    pthread_mutex_lock(&stream->mutex);
    stream->start_error = error;
    stream->started = 1;
    pthread_cond_signal(&stream->ready);
    pthread_mutex_unlock(&stream->mutex);

    if (error != kIOReturnSuccess) {
        atomic_store(&stream->stopping, true);
        (*handle->interface)->AbortPipe(handle->interface, handle->in_pipe);
    }
    // Läuft, bis der letzte Transfer nach dem Abbruch zurückgekommen ist.
    if (atomic_load(&stream->outstanding) > 0) CFRunLoopRun();
    CFRunLoopRemoveSource(stream->run_loop, handle->async_source, kCFRunLoopDefaultMode);
    return NULL;
}

static void free_stream(struct hrf_stream *stream) {
    for (uint32_t i = 0; i < stream->count; i++) free(stream->transfers[i].buffer);
    free(stream->transfers);
    pthread_mutex_destroy(&stream->mutex);
    pthread_cond_destroy(&stream->ready);
    free(stream);
}

int32_t hrf_usb_stream_start(hrf_usb *handle, uint32_t transfers, uint32_t size, hrf_rx_callback callback,
                             void *context) {
    if (!handle || !handle->interface || !handle->in_pipe || handle->stream) return -1;
    if (!handle->async_source) {
        IOReturn kr = (*handle->interface)->CreateInterfaceAsyncEventSource(handle->interface, &handle->async_source);
        if (kr != kIOReturnSuccess) return kr < 0 ? kr : -kr;
    }
    if (transfers == 0 || size == 0) return -1;
    struct hrf_stream *stream = calloc(1, sizeof(struct hrf_stream));
    if (!stream) return -1;
    stream->handle = handle;
    stream->callback = callback;
    stream->context = context;
    stream->size = size;
    stream->count = transfers;
    // Mutex/Bedingung zuerst, damit free_stream auch nach einem Fehlschlag gilt.
    atomic_init(&stream->stopping, false);
    atomic_init(&stream->outstanding, 0);
    pthread_mutex_init(&stream->mutex, NULL);
    pthread_cond_init(&stream->ready, NULL);
    stream->transfers = calloc(transfers, sizeof(struct hrf_transfer));
    if (!stream->transfers) {
        stream->count = 0;
        free_stream(stream);
        return -1;
    }
    for (uint32_t i = 0; i < transfers; i++) {
        stream->transfers[i].stream = stream;
        stream->transfers[i].buffer = malloc(size);
        if (!stream->transfers[i].buffer) {
            // free_stream gibt alle (auch die noch leeren) Puffer frei – free(NULL) ist erlaubt.
            free_stream(stream);
            return -1;
        }
    }

    pthread_attr_t attributes;
    pthread_attr_init(&attributes);
    pthread_attr_set_qos_class_np(&attributes, QOS_CLASS_USER_INTERACTIVE, 0);
    int failed = pthread_create(&stream->thread, &attributes, stream_thread, stream);
    pthread_attr_destroy(&attributes);
    if (failed) {
        free_stream(stream);
        return -1;
    }
    pthread_mutex_lock(&stream->mutex);
    while (!stream->started) pthread_cond_wait(&stream->ready, &stream->mutex);
    IOReturn error = stream->start_error;
    pthread_mutex_unlock(&stream->mutex);
    if (error != kIOReturnSuccess) {
        pthread_join(stream->thread, NULL);
        free_stream(stream);
        return error < 0 ? error : -error;
    }
    handle->stream = stream;
    return 0;
}

void hrf_usb_stream_stop(hrf_usb *handle) {
    if (!handle || !handle->stream) return;
    struct hrf_stream *stream = handle->stream;
    atomic_store(&stream->stopping, true);
    // Ein Rückruf, der `stopping` gerade noch als false gelesen hat, kann einen
    // Transfer erst nach dem Abbruch neu vergeben – der käme nie zurück, und
    // pthread_join hinge für immer (gesehen beim schnellen Kanalwechsel).
    // Deshalb abbrechen, bis wirklich alle Transfers zurück sind.
    for (int attempt = 0; atomic_load(&stream->outstanding) > 0 && attempt < 250; attempt++) {
        (*handle->interface)->AbortPipe(handle->interface, handle->in_pipe);
        usleep(20000);
    }
    pthread_join(stream->thread, NULL);
    handle->stream = NULL;
    free_stream(stream);
}
