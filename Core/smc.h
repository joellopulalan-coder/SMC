// Minimal AppleSMC access via IOKit (Apple Silicon).
#pragma once
#include <IOKit/IOKitLib.h>
#include <stdint.h>
#include <stdbool.h>

typedef struct {
    char major, minor, build, reserved;
    uint16_t release;
} SMCVers;

typedef struct {
    uint16_t version, length;
    uint32_t cpuPLimit, gpuPLimit, memPLimit;
} SMCPLimit;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t dataAttributes;
} SMCKeyInfo;

typedef struct {
    uint32_t key;
    SMCVers vers;
    SMCPLimit pLimit;
    SMCKeyInfo keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCParam;

typedef struct {
    char key[5];
    char type[5];
    uint32_t size;
    uint8_t bytes[32];
} SMCValue;

kern_return_t smc_open(void);
void smc_close(void);
uint32_t smc_key_count(void);
bool smc_key_at(uint32_t index, char out[5]);
bool smc_read(const char *key, SMCValue *val);
bool smc_write(const char *key, const uint8_t *bytes, uint32_t size);

// Decodes common numeric types (flt, ui8, ui16, ui32, sp78, fpe2). Returns false if unknown.
bool smc_to_double(const SMCValue *val, double *out);
bool smc_read_double(const char *key, double *out);
bool smc_write_float(const char *key, float v);
bool smc_write_u8(const char *key, uint8_t v);
