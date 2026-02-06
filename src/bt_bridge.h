#ifndef BT_BRIDGE_H
#define BT_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

typedef void (*DataCallback)(const uint8_t *data, size_t len);

void start_bluetooth_connection(const char *mac_addr, int channel,
                                DataCallback callback);

void cleanup_bluetooth_connection(const char *mac_addr);

void stop_bluetooth_loop();

#endif