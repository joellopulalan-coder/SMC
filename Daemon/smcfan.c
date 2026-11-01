// smcfan: fan curve control for Apple Silicon MacBooks (developed on an M5 Max, Mac17,7).
//
//   smcfan status               show temperatures and fans (no root needed)
//   smcfan keys [prefix]        list readable SMC keys, e.g. "smcfan keys F" (for hardware reports)
//   sudo smcfan run             keep the default curve active; Ctrl-C hands the fans back to macOS
//   sudo smcfan daemon <config> like run, but reads profile and curve from <config> (used by launchd)
//   sudo smcfan auto            hand the fans back to macOS right away
//
// Below the takeover threshold smcfan lets macOS control the fans. Above it, smcfan takes over
// and interpolates linearly between the curve points.
//
// Config file, one setting per line (unknown lines are ignored):
//   mode=curve        off | curve | max
//   takeover=65       take over the fans at or above this temperature (°C)
//   release=60        hand them back to macOS below this temperature (°C)
//   point=65:30       temperature (°C) : fan percentage between F*Mn and F*Mx
//   point=75:60
//   point=85:100

#include "smc.h"
#include <fcntl.h>
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef SMCFAN_VERSION
#define SMCFAN_VERSION "dev"
#endif

#define MAX_POINTS 8

typedef enum { MODE_OFF, MODE_CURVE, MODE_MAX } Mode;

typedef struct {
    Mode mode;
    double takeover, release; // take over at or above takeover, back to macOS below release
    int n;
    double temp[MAX_POINTS], pct[MAX_POINTS]; // pct: 0..1 between F*Mn and F*Mx
} Config;

static const Config DEFAULT_CONFIG = {
    .mode = MODE_CURVE,
    .takeover = 65,
    .release = 60,
    .n = 3,
    .temp = {65, 75, 85},
    .pct = {0.30, 0.60, 1.00},
};

static const double SMOOTHING = 0.3; // EMA factor; higher = reacts faster
static const unsigned INTERVAL_S = 2;
static const char *LOCK_PATH = "/var/run/smcfan.lock";

#define MAX_SENSORS 256
static char cpu_keys[MAX_SENSORS][5], gpu_keys[MAX_SENSORS][5];
static int n_cpu, n_gpu, n_fans;
static volatile sig_atomic_t stop;

// Manual-mode key suffix: "md" on M5-generation Macs, "Md" on earlier Apple Silicon.
static const char *mode_suffix = "md";
// Earlier Apple Silicon may only accept manual mode after "Ftst" (force test) is set to 1.
static bool has_ftst, ftst_set;

static void find_sensors(void) {
    uint32_t n = smc_key_count();
    for (uint32_t i = 0; i < n; i++) {
        char k[5];
        double t;
        if (!smc_key_at(i, k) || k[0] != 'T') continue;
        if (!smc_read_double(k, &t) || t < 10 || t > 130) continue;
        if (k[1] == 'p' && n_cpu < MAX_SENSORS) strcpy(cpu_keys[n_cpu++], k);
        if (k[1] == 'g' && n_gpu < MAX_SENSORS) strcpy(gpu_keys[n_gpu++], k);
    }
    double f;
    n_fans = smc_read_double("FNum", &f) ? (int)f : 0;
    if (!smc_read_double("F0md", &f) && smc_read_double("F0Md", &f)) mode_suffix = "Md";
    has_ftst = smc_read_double("Ftst", &f);
}

static void read_group(char keys[][5], int n, double *avg, double *max) {
    double sum = 0, hi = 0, t;
    int ok = 0;
    for (int i = 0; i < n; i++) {
        if (!smc_read_double(keys[i], &t) || t < 10 || t > 130) continue;
        sum += t;
        ok++;
        if (t > hi) hi = t;
    }
    *avg = ok ? sum / ok : 0;
    *max = hi;
}

// Reads path into c; a missing or invalid file leaves c unchanged.
static bool load_config(const char *path, Config *c) {
    FILE *fp = fopen(path, "r");
    if (!fp) return false;
    Config next = *c;
    next.n = 0;
    char line[128];
    while (fgets(line, sizeof line, fp)) {
        double a, b;
        char mode[16];
        if (sscanf(line, "mode=%15s", mode) == 1) {
            next.mode = !strcmp(mode, "off") ? MODE_OFF : !strcmp(mode, "max") ? MODE_MAX : MODE_CURVE;
        } else if (sscanf(line, "takeover=%lf", &a) == 1) {
            next.takeover = a;
        } else if (sscanf(line, "release=%lf", &a) == 1) {
            next.release = a;
        } else if (sscanf(line, "point=%lf:%lf", &a, &b) == 2 && next.n < MAX_POINTS) {
            next.temp[next.n] = a;
            next.pct[next.n] = fmin(fmax(b / 100.0, 0), 1);
            next.n++;
        }
    }
    fclose(fp);
    if (next.n == 0) {
        memcpy(next.temp, c->temp, sizeof next.temp);
        memcpy(next.pct, c->pct, sizeof next.pct);
        next.n = c->n;
    }
    if (next.release > next.takeover) next.release = next.takeover;
    *c = next;
    return true;
}

static double curve_pct(const Config *c, double t) {
    if (t <= c->temp[0]) {
        // Between the release threshold and the first point, ramp down to 0% (= minimum speed),
        // so the fans settle gradually after a spike instead of staying at the first point.
        if (c->temp[0] <= c->release) return c->pct[0];
        double f = (t - c->release) / (c->temp[0] - c->release);
        return c->pct[0] * fmin(fmax(f, 0), 1);
    }
    for (int i = 1; i < c->n; i++) {
        if (t <= c->temp[i]) {
            double f = (t - c->temp[i - 1]) / (c->temp[i] - c->temp[i - 1]);
            return c->pct[i - 1] + f * (c->pct[i] - c->pct[i - 1]);
        }
    }
    return c->pct[c->n - 1];
}

static void fan_key(char out[5], int fan, const char *suffix) {
    snprintf(out, 5, "F%d%s", fan, suffix);
}

static bool set_manual(int fan, bool manual) {
    char k[5];
    fan_key(k, fan, mode_suffix);
    if (smc_write_u8(k, manual ? 1 : 0)) return true;
    if (manual && has_ftst && !ftst_set && smc_write_u8("Ftst", 1)) {
        ftst_set = true;
        return smc_write_u8(k, 1);
    }
    return false;
}

static bool set_target(int fan, double pct) {
    char kmn[5], kmx[5], ktg[5];
    double mn, mx;
    fan_key(kmn, fan, "Mn");
    fan_key(kmx, fan, "Mx");
    fan_key(ktg, fan, "Tg");
    if (!smc_read_double(kmn, &mn) || !smc_read_double(kmx, &mx)) return false;
    return smc_write_float(ktg, (float)(mn + pct * (mx - mn)));
}

static void release_all(void) {
    for (int f = 0; f < n_fans; f++) set_manual(f, false);
    if (ftst_set && smc_write_u8("Ftst", 0)) ftst_set = false;
}

static void print_status(void) {
    double cavg, cmax, gavg, gmax;
    read_group(cpu_keys, n_cpu, &cavg, &cmax);
    read_group(gpu_keys, n_gpu, &gavg, &gmax);
    printf("CPU  avg %5.1f °C  max %5.1f °C  (%d sensors)\n", cavg, cmax, n_cpu);
    printf("GPU  avg %5.1f °C  max %5.1f °C  (%d sensors)\n", gavg, gmax, n_gpu);
    for (int f = 0; f < n_fans; f++) {
        char k[5];
        double ac = 0, tg = 0, mn = 0, mx = 0, md = 0;
        fan_key(k, f, "Ac"); smc_read_double(k, &ac);
        fan_key(k, f, "Tg"); smc_read_double(k, &tg);
        fan_key(k, f, "Mn"); smc_read_double(k, &mn);
        fan_key(k, f, "Mx"); smc_read_double(k, &mx);
        fan_key(k, f, mode_suffix); smc_read_double(k, &md);
        printf("Fan %d  %4.0f rpm  (target %4.0f, range %4.0f-%4.0f)  %s\n",
               f, ac, tg, mn, mx, md ? "manual" : "macOS");
    }
}

static void print_keys(const char *prefix) {
    size_t plen = prefix ? strlen(prefix) : 0;
    uint32_t n = smc_key_count();
    for (uint32_t i = 0; i < n; i++) {
        char k[5];
        SMCValue v;
        double d;
        if (!smc_key_at(i, k) || (plen && strncmp(k, prefix, plen) != 0) || !smc_read(k, &v)) continue;
        if (smc_to_double(&v, &d)) printf("%s  [%s]  %.3f\n", k, v.type, d);
        else printf("%s  [%s]  (%u bytes)\n", k, v.type, v.size);
    }
}

static void on_signal(int sig) {
    (void)sig;
    stop = 1;
}

static time_t config_mtime(const char *path) {
    struct stat st;
    return stat(path, &st) == 0 ? st.st_mtime : 0;
}

// config_path NULL: default curve with live output (run). Otherwise daemon mode with log lines.
static int control_loop(const char *config_path) {
    if (geteuid() != 0) {
        fprintf(stderr, "Writing to the SMC requires root: sudo %s run\n", getprogname());
        return 1;
    }
    // One instance at a time; the lock is released automatically when the process exits.
    // A refused second instance never touches the fans.
    int lock = open(LOCK_PATH, O_RDWR | O_CREAT, 0644);
    if (lock < 0 || flock(lock, LOCK_EX | LOCK_NB) != 0) {
        fprintf(stderr, "smcfan is already running (lock: %s). Stop that one first.\n", LOCK_PATH);
        return 1;
    }
    fchmod(lock, 0644); // so the app can see whether the daemon runs
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGHUP, on_signal); // terminal tab closed
    // Start from a known state: a previous instance may have left the fans in manual mode.
    release_all();

    Config cfg = DEFAULT_CONFIG;
    time_t loaded_mtime = -1;
    bool manual = false, write_failed = false;
    double smooth = 0;
    bool live = config_path == NULL;

    if (live)
        printf("Curve active: takeover at %.0f °C, back to macOS below %.0f °C. Ctrl-C to stop.\n",
               cfg.takeover, cfg.release);
    else
        fprintf(stderr, "smcfan %s daemon started, config: %s\n", SMCFAN_VERSION, config_path);

    while (!stop) {
        if (config_path) {
            time_t m = config_mtime(config_path);
            if (m != loaded_mtime) {
                loaded_mtime = m;
                if (load_config(config_path, &cfg))
                    fprintf(stderr, "Config loaded: mode=%d, takeover %.0f °C, %d points\n",
                            cfg.mode, cfg.takeover, cfg.n);
            }
        }

        double cavg, cmax, gavg, gmax;
        read_group(cpu_keys, n_cpu, &cavg, &cmax);
        read_group(gpu_keys, n_gpu, &gavg, &gmax);
        double hot = fmax(cmax, gmax);
        smooth = smooth == 0 ? hot : smooth + SMOOTHING * (hot - smooth);

        bool want = cfg.mode == MODE_MAX ||
                    (cfg.mode == MODE_CURVE && (manual ? smooth >= cfg.release : smooth >= cfg.takeover));
        double pct = cfg.mode == MODE_MAX ? 1.0 : curve_pct(&cfg, smooth);

        if (want) {
            // Set again every round: after sleep/wake the SMC may fall back to automatic.
            bool ok = true;
            for (int f = 0; f < n_fans; f++) ok &= set_manual(f, true) && set_target(f, pct);
            if (!ok && !write_failed) fprintf(stderr, "The SMC refuses writes to the fans.\n");
            write_failed = !ok;
        } else if (manual) {
            release_all();
        }
        if (want != manual && !live)
            fprintf(stderr, "%.1f °C: %s\n", smooth, want ? "taken over" : "back to macOS");
        manual = want;

        if (live) {
            printf("\r%5.1f °C (CPU %5.1f, GPU %5.1f)  ->  ", smooth, cmax, gmax);
            if (manual) printf("%3.0f%%   ", pct * 100);
            else printf("macOS  ");
            fflush(stdout);
        }
        sleep(INTERVAL_S);
    }
    // Explicitly here, while the SMC connection is still open (main closes it afterwards).
    release_all();
    if (live) printf("\nFans handed back to macOS.\n");
    else fprintf(stderr, "smcfan daemon stopped, fans handed back to macOS.\n");
    return 0;
}

int main(int argc, char **argv) {
    const char *cmd = argc > 1 ? argv[1] : "status";
    if (!strcmp(cmd, "version") || !strcmp(cmd, "--version")) {
        printf("smcfan %s\n", SMCFAN_VERSION);
        return 0;
    }
    if (smc_open() != kIOReturnSuccess) {
        fprintf(stderr, "Can't open AppleSMC.\n");
        return 1;
    }
    find_sensors();

    int rc = 0;
    if (!strcmp(cmd, "status")) {
        print_status();
    } else if (!strcmp(cmd, "keys")) {
        print_keys(argc > 2 ? argv[2] : NULL);
    } else if (!strcmp(cmd, "run")) {
        rc = control_loop(NULL);
    } else if (!strcmp(cmd, "daemon") && argc > 2) {
        rc = control_loop(argv[2]);
    } else if (!strcmp(cmd, "auto")) {
        release_all();
        print_status();
    } else {
        fprintf(stderr, "Usage: %s [status | keys [prefix] | run | daemon <config> | auto | version]\n", argv[0]);
        rc = 2;
    }
    smc_close();
    return rc;
}
