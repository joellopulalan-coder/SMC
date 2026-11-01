#include "smc.h"
#include <string.h>

enum {
    KERNEL_INDEX_SMC = 2,
    CMD_READ_BYTES = 5,
    CMD_WRITE_BYTES = 6,
    CMD_READ_INDEX = 8,
    CMD_READ_KEYINFO = 9,
};

static io_connect_t conn;

static uint32_t str_to_key(const char *s) {
    return ((uint32_t)s[0] << 24) | ((uint32_t)s[1] << 16) | ((uint32_t)s[2] << 8) | (uint32_t)s[3];
}

static void key_to_str(uint32_t k, char out[5]) {
    out[0] = (char)(k >> 24);
    out[1] = (char)(k >> 16);
    out[2] = (char)(k >> 8);
    out[3] = (char)k;
    out[4] = 0;
}

kern_return_t smc_open(void) {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return kIOReturnNotFound;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
    IOObjectRelease(svc);
    return kr;
}

void smc_close(void) {
    if (conn) IOServiceClose(conn);
    conn = 0;
}

static bool call(SMCParam *in, SMCParam *out) {
    size_t outSize = sizeof(SMCParam);
    memset(out, 0, sizeof(*out));
    kern_return_t kr = IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, in, sizeof(SMCParam), out, &outSize);
    return kr == kIOReturnSuccess && out->result == 0;
}

// Key info never changes at runtime; caching it halves the number of SMC calls per read.
// Not thread-safe: use the SMC from one thread/queue.
#define INFO_CACHE_SIZE 1024 // power of 2
static struct { uint32_t key; SMCKeyInfo info; } info_cache[INFO_CACHE_SIZE];

static bool key_info(uint32_t key, SMCKeyInfo *info) {
    uint32_t slot = (key * 2654435761u) & (INFO_CACHE_SIZE - 1);
    for (uint32_t i = 0; i < 8; i++) {
        uint32_t s = (slot + i) & (INFO_CACHE_SIZE - 1);
        if (info_cache[s].key == key) {
            *info = info_cache[s].info;
            return true;
        }
        if (info_cache[s].key == 0) break;
    }

    SMCParam in = {0}, out;
    in.key = key;
    in.data8 = CMD_READ_KEYINFO;
    if (!call(&in, &out)) return false;
    *info = out.keyInfo;

    for (uint32_t i = 0; i < 8; i++) {
        uint32_t s = (slot + i) & (INFO_CACHE_SIZE - 1);
        if (info_cache[s].key == 0) {
            info_cache[s].key = key;
            info_cache[s].info = *info;
            break;
        }
    }
    return true;
}

uint32_t smc_key_count(void) {
    double n;
    return smc_read_double("#KEY", &n) ? (uint32_t)n : 0;
}

bool smc_key_at(uint32_t index, char out_key[5]) {
    SMCParam in = {0}, out;
    in.data8 = CMD_READ_INDEX;
    in.data32 = index;
    if (!call(&in, &out)) return false;
    key_to_str(out.key, out_key);
    return true;
}

bool smc_read(const char *key, SMCValue *val) {
    memset(val, 0, sizeof(*val));
    strncpy(val->key, key, 4);
    SMCKeyInfo info;
    if (!key_info(str_to_key(key), &info)) return false;

    SMCParam in = {0}, out;
    in.key = str_to_key(key);
    in.keyInfo.dataSize = info.dataSize;
    in.data8 = CMD_READ_BYTES;
    if (!call(&in, &out)) return false;

    val->size = info.dataSize > 32 ? 32 : info.dataSize;
    key_to_str(info.dataType, val->type);
    memcpy(val->bytes, out.bytes, val->size);
    return true;
}

bool smc_write(const char *key, const uint8_t *bytes, uint32_t size) {
    SMCKeyInfo info;
    if (!key_info(str_to_key(key), &info) || info.dataSize != size) return false;

    SMCParam in = {0}, out;
    in.key = str_to_key(key);
    in.keyInfo.dataSize = size;
    in.data8 = CMD_WRITE_BYTES;
    memcpy(in.bytes, bytes, size);
    return call(&in, &out);
}

bool smc_to_double(const SMCValue *v, double *out) {
    const uint8_t *b = v->bytes;
    if (!strcmp(v->type, "flt ") && v->size == 4) {
        float f;
        memcpy(&f, b, 4); // little-endian on Apple Silicon
        *out = f;
    } else if (!strcmp(v->type, "ui8 ") || !strcmp(v->type, "flag")) {
        *out = b[0];
    } else if (!strcmp(v->type, "ui16")) {
        *out = (b[0] << 8) | b[1];
    } else if (!strcmp(v->type, "ui32")) {
        *out = ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3];
    } else if (!strcmp(v->type, "sp78")) {
        *out = (int16_t)((b[0] << 8) | b[1]) / 256.0;
    } else if (!strcmp(v->type, "fpe2")) {
        *out = ((b[0] << 8) | b[1]) / 4.0;
    } else {
        return false;
    }
    return true;
}

bool smc_read_double(const char *key, double *out) {
    SMCValue v;
    return smc_read(key, &v) && smc_to_double(&v, out);
}

bool smc_write_float(const char *key, float f) {
    uint8_t b[4];
    memcpy(b, &f, 4);
    return smc_write(key, b, 4);
}

bool smc_write_u8(const char *key, uint8_t v) {
    return smc_write(key, &v, 1);
}
