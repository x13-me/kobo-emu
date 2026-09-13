/* kobo-fb-shim.c — LD_PRELOAD shim for Kobo userspace under qemu-arm.
 *
 * Redirects /dev/fb0 to a regular backing file (guest $KOBO_FB_BACKING,
 * default /tmp/kobo-fb0.bin) and answers framebuffer geometry ioctls with a
 * virtual RGB565 panel: landscape 800x600 by default, portrait 600x800 when
 * $KOBO_FB_PORTRAIT=1 (upright KOReader rendering). Redirects
 * /dev/input/event1 to a backing transport (guest $KOBO_TOUCH_BACKING,
 * default /tmp/kobo-touch0.bin) and every other /dev/input/event* node to
 * its own $KOBO_BUTTON_BACKING (default /tmp/kobo-button0.bin), so the
 * button and touch readers never share one FIFO — pre-seeded by the host
 * with synthetic input_event records in file modes, and answers basic EVIOC capability ioctls. Reads past the seeded
 * data block the way a real evdev node blocks instead of reporting EOF, so
 * guests never see a disconnect ($KOBO_TOUCH_EOF=1 restores bounded-grace
 * EOF for drain-style readers like fb-test). All redirections are appended
 * to $KOBO_SHIM_LOG (default /tmp/kobo-shim.log, guest path). Repairs
 * scrubbed child environs at execve time by appending $FAKEBIN_DIR to
 * PATH, so Nickel's wifi helpers resolve the host fakebin stand-ins.
 *
 * Build (ARM guest .so): zig cc -target arm-linux-gnueabihf -shared -fPIC
 * See scripts/run-usermode.sh. Only ancient libc symbols are used so the
 * shim loads under the Kobo guest glibc 2.11.
 */
#define _GNU_SOURCE

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

/* --- panel geometry ------------------------------------------------ */
/* Landscape 800x600 is the physical N905 panel. KOBO_FB_PORTRAIT=1 reports a
 * portrait 600x800 panel instead, matching what KOReader expects after its
 * fbdepth-style portrait enforcement (upright rendering, no BB rotation). */
#define FB_WIDTH_LANDSCAPE 800
#define FB_HEIGHT_LANDSCAPE 600
#define FB_WIDTH_PORTRAIT 600
#define FB_HEIGHT_PORTRAIT 800
#define FB_BPP 16
#define FB_BACKING_DEFAULT "/tmp/kobo-fb0.bin"
#define TOUCH_BACKING_DEFAULT "/tmp/kobo-touch0.bin"
#define BUTTON_BACKING_DEFAULT "/tmp/kobo-button0.bin"
#define SHIM_LOG_DEFAULT "/tmp/kobo-shim.log"

/* linux/fb.h ioctl numbers (stable ABI) */
#define FBIOGET_VSCREENINFO 0x4600
#define FBIOPUT_VSCREENINFO 0x4601
#define FBIOGET_FSCREENINFO 0x4602
#define FBIOBLANK 0x4611

/* linux/input.h ioctl numbers (32-bit ARM ABI).
 * evdev numbers encode (dir, size, 'E', nr); decode generically instead of
 * hardcoding sizes so any Qt probing pattern is answered. */
#define EVIOCGVERSION 0x80044501
#define EVIOCGID 0x80024502
#define EVIOCGBIT_NR_BASE 0x20
#define EVIOCGABS_NR_BASE 0x40
#define EVIOCG_TYPE(request) (((request) >> 8) & 0xff)
#define EVIOCG_NR(request) ((request) & 0xff)
#define EVIOCG_SIZE(request) (((request) >> 16) & 0x3fff)
#define EVIOCG_IS_READ(request) (((request) >> 30) == 2)

#define EV_SYN 0x00
#define EV_KEY 0x01
#define EV_ABS 0x03
#define ABS_X 0x00
#define ABS_Y 0x01
#define ABS_PRESSURE 0x18
#define ABS_PRESSURE_MAX 255
#define BTN_TOUCH 0x14a
#define KEY_MENU 139
#define KEY_HOMEPAGE 172

/* Runtime orientation selected by $KOBO_FB_PORTRAIT (any value but unset,
 * empty, or "0" means portrait). Parsed once per call: getenv is cheap
 * against an ioctl, and keeps every answer consistent even mid-run. */
static int fb_is_portrait(void) {
  const char *flag = getenv("KOBO_FB_PORTRAIT");
  return flag && flag[0] != '\0' && strcmp(flag, "0") != 0;
}

static int fb_width(void) {
  return fb_is_portrait() ? FB_WIDTH_PORTRAIT : FB_WIDTH_LANDSCAPE;
}

static int fb_height(void) {
  return fb_is_portrait() ? FB_HEIGHT_PORTRAIT : FB_HEIGHT_LANDSCAPE;
}

/* Touch EOF policy: a real evdev node blocks forever when its queue is
 * empty — it never reports EOF. $KOBO_TOUCH_EOF=1 restores the legacy
 * EOF-after-grace for drain-style readers (fb-test); every real userspace
 * (Nickel, KOReader) must block, because KOReader's C input layer maps a
 * zero-length read to EPIPE ("Broken pipe" every grace period) and drops
 * all pending input handling. */
static int touch_eof_after_grace(void) {
  const char *flag = getenv("KOBO_TOUCH_EOF");
  return flag && flag[0] != '\0' && strcmp(flag, "0") != 0;
}

static int touch_debug_reads(void) {
  const char *flag = getenv("KOBO_SHIM_TOUCH_DEBUG");
  return flag && flag[0] != '\0' && strcmp(flag, "0") != 0;
}

/* 16-byte input_event records: two int32 time fields, u16 type/code,
 * int32 value (32-bit ARM layout). */
struct touch_event_record {
  int32_t seconds, useconds;
  uint16_t kind, code;
  int32_t value;
};

/* Exact 32-bit layout of struct fb_var_screeninfo (160 bytes). */
struct fb_var_screeninfo {
  uint32_t xres, yres, xres_virtual, yres_virtual, xoffset, yoffset;
  uint32_t bits_per_pixel, grayscale;
  struct { uint32_t offset, length, msb_right; } red, green, blue, transp;
  uint32_t nonstd, activate, height, width;
  uint32_t accel_flags, pixclock;
  uint32_t left_margin, right_margin, upper_margin, lower_margin;
  uint32_t hsync_len, vsync_len, sync, vmode, rotate, colorspace;
  uint32_t reserved[4];
};

/* Exact 32-bit layout of struct fb_fix_screeninfo (64 bytes). */
struct fb_fix_screeninfo {
  char id[16];
  uint32_t smem_start, smem_len;
  uint32_t type, type_aux, visual;
  uint16_t xpanstep, ypanstep, ywrapstep;
  uint32_t line_length;
  uint32_t mmio_start, mmio_len, accel;
  uint16_t capabilities, reserved[2];
};

/* --- fd bookkeeping ------------------------------------------------- */
#define MAX_TRACKED_FDS 64

static int tracked_fb_fds[MAX_TRACKED_FDS];
static int tracked_fb_count;
static int tracked_touch_fds[MAX_TRACKED_FDS];
static int tracked_touch_count;
static int shim_log_fd = -2; /* -2 = not opened yet */

/* Resolved real openers (see "redirected open" section): declared early so
 * the logger can bypass our own interposition without recursing. */
static int (*real_open_func)(const char *pathname, int flags, ...) = NULL;

/* Non-static: shared with the rescan-trigger TU (kobo-sync-trigger.cpp),
 * so all shim logging funnels through this one lazily-opened fd and the
 * trigger adds zero fd-numbering delta versus baseline. */
void shim_log_line(const char *message) {
  if (shim_log_fd == -2) {
    const char *path = getenv("KOBO_SHIM_LOG");
    if (!path)
      path = SHIM_LOG_DEFAULT;
    /* Bypass our own open() interposition: the log path can never be a
     * redirected device, and this keeps logging recursion-free. */
    if (!real_open_func)
      real_open_func = dlsym(RTLD_NEXT, "open");
    shim_log_fd = real_open_func(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
  }
  if (shim_log_fd < 0)
    return;
  size_t length = strlen(message);
  /* Best effort: never fail the guest because logging failed. */
  (void)write(shim_log_fd, message, length);
  (void)write(shim_log_fd, "\n", 1);
}

static int is_fd_tracked(int fd, int *table, int count) {
  for (int i = 0; i < count; i++)
    if (table[i] == fd)
      return 1;
  return 0;
}

static void track_fd(int fd, int *table, int *count) {
  if (*count >= MAX_TRACKED_FDS) {
    shim_log_line("kobo-shim: FATAL: tracked-fd table exhausted");
    _exit(99);
  }
  table[*count] = fd;
  (*count)++;
}

static void untrack_fd(int fd) {
  for (int i = 0; i < tracked_fb_count; i++)
    if (tracked_fb_fds[i] == fd) {
      tracked_fb_fds[i] = tracked_fb_fds[--tracked_fb_count];
      return;
    }
  for (int i = 0; i < tracked_touch_count; i++)
    if (tracked_touch_fds[i] == fd) {
      tracked_touch_fds[i] = tracked_touch_fds[--tracked_touch_count];
      return;
    }
}

static int is_fb_fd(int fd) { return is_fd_tracked(fd, tracked_fb_fds, tracked_fb_count); }

static int is_touch_fd(int fd) {
  return is_fd_tracked(fd, tracked_touch_fds, tracked_touch_count);
}

static int is_fb_path(const char *pathname) {
  return pathname && strcmp(pathname, "/dev/fb0") == 0;
}

static int is_touch_path(const char *pathname) {
  /* Prefix match: "/dev/input/event" is 16 chars; any eventN device qualifies. */
  return pathname && strncmp(pathname, "/dev/input/event", 16) == 0;
}

/* On the N905 (Trilogy) event1 is the zForce touch controller and event0
 * the NTX button/switch node. Each evdev node gets its own backing transport:
 * sharing one FIFO between two readers breaks single-reader discipline (a
 * tap is delivered to exactly one reader, so the button poll can steal the
 * touch stream the Lua loop is waiting on). */
static int is_touch_screen_path(const char *pathname) {
  return pathname && strcmp(pathname, "/dev/input/event1") == 0;
}

/* --- redirected open ------------------------------------------------ */
/* File-scope resolved pointers: filled on first post-bootstrap use.
 * Nothing here may run from a constructor: on the Kobo guest glibc 2.11,
 * calling dlsym (or any interposed function) while the loader is still
 * bootstrapping segfaults. Interception only fires for guest code, which
 * always runs after bootstrap completes. */
static int (*real_open64_func)(const char *pathname, int flags, ...) = NULL;
static int (*real_openat_func)(int dirfd, const char *pathname, int flags, ...) = NULL;

/* Touch transport: a real evdev node is pollable — select/poll block when
 * the queue is empty and wake on arrival — which KOReader's input layer
 * needs for its gesture timers (a lone tap is only emitted after the
 * double-tap window expires). A regular backing file can never do that:
 * it is always "ready", so the guest either spins on EOF (mapped to EPIPE
 * warnings) or blocks in read past its deadline (timers never fire).
 * $KOBO_TOUCH_FIFO=1 instead serves event nodes from a FIFO: natively
 * blocking, natively pollable, with atomic sub-PIPE_BUF tap writes from
 * the host waking the guest exactly like hardware IRQs would. The FIFO is
 * opened O_RDWR so the open itself never blocks and the read side never
 * sees EOF while the guest lives. Drain-style readers (fb-test) keep the
 * regular-file backing, where $KOBO_TOUCH_EOF=1 restores bounded-grace EOF. */
static int use_touch_fifo(void) {
  const char *flag = getenv("KOBO_TOUCH_FIFO");
  return flag && flag[0] != '\0' && strcmp(flag, "0") != 0;
}

static int open_backing_file(const char *backing_path, size_t min_size) {
  if (!real_open_func)
    real_open_func = dlsym(RTLD_NEXT, "open");
  int fd = real_open_func(backing_path, O_RDWR | O_CREAT, 0644);
  if (fd < 0)
    return -1;
  if (min_size > 0) {
    off_t end = lseek(fd, 0, SEEK_END);
    if (end < 0 || (size_t)end < min_size) {
      if (ftruncate(fd, (off_t)min_size) != 0) {
        close(fd);
        return -1;
      }
    }
  }
  return fd;
}

static int open_touch_backing(const char *backing_path, int guest_flags) {
  if (!real_open_func)
    real_open_func = dlsym(RTLD_NEXT, "open");
  /* Honor the guest's blocking mode: KOReader opens evdev nodes
   * O_NONBLOCK and drains them to EAGAIN inside select-gated
   * waitForInput; a blocking stand-in would hang the drain after the
   * queued events. Blocking opens (fb-test, Qt) keep true device
   * semantics via the read wrapper below. */
  int host_flags = O_RDWR | (guest_flags & O_NONBLOCK);
  if (use_touch_fifo()) {
    /* mkfifo first: the host stager usually creates it, but a hand-rolled
     * launch must not fail on its absence. EEXIST (or a regular file left
     * by another mode) falls through to the open, which reports the truth. */
    if (mkfifo(backing_path, 0644) != 0 && errno != EEXIST) {
      char noted[128];
      snprintf(noted, sizeof(noted),
               "kobo-shim: touch fifo %s not created: %s",
               backing_path, strerror(errno));
      shim_log_line(noted);
    }
    /* O_RDWR: the open never blocks (unlike O_RDONLY/O_WRONLY on a FIFO
     * without a peer), and the guest holding the write side means
     * blocking reads wait on empty instead of reporting EOF. */
    return real_open_func(backing_path, host_flags, 0);
  }
  return real_open_func(backing_path, host_flags, 0);
}

static int maybe_redirect_open(const char *pathname, int guest_flags) {
  if (is_fb_path(pathname)) {
    const char *backing = getenv("KOBO_FB_BACKING");
    if (!backing)
      backing = FB_BACKING_DEFAULT;
    int fd = open_backing_file(backing, (size_t)(fb_width() * fb_height() * (FB_BPP / 8)));
    if (fd < 0)
      return -1;
    track_fd(fd, tracked_fb_fds, &tracked_fb_count);
    {
      char logged[96];
      snprintf(logged, sizeof(logged),
               "kobo-shim: redirected /dev/fb0 to backing file (fd=%d, %dx%d)",
               fd, fb_width(), fb_height());
      shim_log_line(logged);
    }
    return fd;
  }
  if (is_touch_path(pathname)) {
    /* Touch controller (event1) keeps $KOBO_TOUCH_BACKING — the path
     * scripts/kobo-tap.sh injects into. Every other eventN node (NTX
     * buttons on event0, accelerometer where present) gets its own
     * $KOBO_BUTTON_BACKING so no two readers ever share one FIFO. */
    const char *backing;
    if (is_touch_screen_path(pathname)) {
      backing = getenv("KOBO_TOUCH_BACKING");
      if (!backing)
        backing = TOUCH_BACKING_DEFAULT;
    } else {
      backing = getenv("KOBO_BUTTON_BACKING");
      if (!backing)
        backing = BUTTON_BACKING_DEFAULT;
    }
    int fd = open_touch_backing(backing, guest_flags);
    if (fd < 0)
      return -1;
    track_fd(fd, tracked_touch_fds, &tracked_touch_count);
    {
      char logged[128];
      snprintf(logged, sizeof(logged),
               "kobo-shim: redirected %s to backing %s (fd=%d)",
               pathname, use_touch_fifo() ? "fifo" : "file", fd);
      shim_log_line(logged);
    }
    return fd;
  }
  return -100; /* not ours */
}

int open(const char *pathname, int flags, ...) {
  mode_t mode;
  va_list mode_args;
  va_start(mode_args, flags);
  mode = va_arg(mode_args, mode_t);
  va_end(mode_args);
  if (!real_open_func)
    real_open_func = dlsym(RTLD_NEXT, "open");
  int redirected = maybe_redirect_open(pathname, flags);
  if (redirected != -100)
    return redirected;
  /* Always forwarded with mode: the kernel ignores it without O_CREAT,
   * and threading it through keeps O_CREAT callers correct. */
  return real_open_func(pathname, flags, mode);
}

int open64(const char *pathname, int flags, ...) {
  mode_t mode;
  va_list mode_args;
  va_start(mode_args, flags);
  mode = va_arg(mode_args, mode_t);
  va_end(mode_args);
  if (!real_open64_func)
    real_open64_func = dlsym(RTLD_NEXT, "open64");
  int redirected = maybe_redirect_open(pathname, flags);
  if (redirected != -100)
    return redirected;
  return real_open64_func(pathname, flags, mode);
}

int openat(int dirfd, const char *pathname, int flags, ...) {
  mode_t mode;
  va_list mode_args;
  va_start(mode_args, flags);
  mode = va_arg(mode_args, mode_t);
  va_end(mode_args);
  if (!real_openat_func)
    real_openat_func = dlsym(RTLD_NEXT, "openat");
  if (dirfd == AT_FDCWD) {
    int redirected = maybe_redirect_open(pathname, flags);
    if (redirected != -100)
      return redirected;
  }
  return real_openat_func(dirfd, pathname, flags, mode);
}

int close(int fd) {
  static int (*real_close)(int) = NULL;
  if (!real_close)
    real_close = dlsym(RTLD_NEXT, "close");
  untrack_fd(fd);
  return real_close(fd);
}

/* --- sysroot unlink redirect ------------------------------------------ */
/* qemu-arm -L translates stat/open-existing/read/write into the sysroot
 * but O_CREAT-missing + unlink fall through to the host (proven: busybox
 * rm of an existing sysroot file under -L -> ENOENT on host /mnt/...).
 * Nickel journals /mnt/onboard/.kobo/*.sqlite-journal, then unlink(journal)
 * misses the host, leaves a stale hot journal, and SQLite rolls back the
 * just-written schema via ftruncate64(main,0) forever — DBs stay 0B.
 * Interpose unlink/unlinkat: on ENOENT, re-attempt against the
 * $KOBO_SYSROOT-prefixed guest path. Fail-open everywhere: without
 * $KOBO_SYSROOT, on non-absolute paths, or when the retry also fails, the
 * original result (and errno) pass through untouched. */
static int sysroot_prefixed_path(const char *guest_path, char *out,
                                 size_t out_len) {
  const char *sysroot = getenv("KOBO_SYSROOT");
  size_t sysroot_len, guest_len;
  if (!guest_path || guest_path[0] != '/')
    return 0;
  if (!sysroot || sysroot[0] == '\0')
    return 0;
  if (!out || out_len == 0)
    return 0;
  sysroot_len = strlen(sysroot);
  guest_len = strlen(guest_path);
  while (sysroot_len > 1 && sysroot[sysroot_len - 1] == '/')
    sysroot_len--; /* strip trailing slashes, keep root "/" intact */
  if (sysroot_len + guest_len + 1 > out_len)
    return 0;
  memcpy(out, sysroot, sysroot_len);
  memcpy(out + sysroot_len, guest_path, guest_len + 1);
  return 1;
}

int unlink(const char *pathname) {
  static int (*real_unlink)(const char *) = NULL;
  int saved_errno, retry_result, first_result;
  char redirected[1024];
  if (!real_unlink)
    real_unlink = dlsym(RTLD_NEXT, "unlink");
  first_result = real_unlink(pathname);
  if (first_result == 0)
    return 0;
  if (errno != ENOENT)
    return first_result;
  if (!sysroot_prefixed_path(pathname, redirected, sizeof(redirected)))
    return first_result;
  saved_errno = errno;
  retry_result = real_unlink(redirected);
  if (retry_result == 0) {
    char logged[160];
    snprintf(logged, sizeof(logged),
             "kobo-shim: unlink redirected %s -> sysroot",
             pathname ? pathname : "?");
    shim_log_line(logged);
    return 0;
  }
  errno = saved_errno;
  return first_result;
}

int unlinkat(int dirfd, const char *pathname, int flags) {
  static int (*real_unlinkat)(int, const char *, int) = NULL;
  int saved_errno, retry_result, first_result;
  char redirected[1024];
  if (!real_unlinkat)
    real_unlinkat = dlsym(RTLD_NEXT, "unlinkat");
  if (dirfd != AT_FDCWD)
    return real_unlinkat(dirfd, pathname, flags);
  first_result = real_unlinkat(dirfd, pathname, flags);
  if (first_result == 0)
    return first_result;
  if (errno != ENOENT)
    return first_result;
  if (!sysroot_prefixed_path(pathname, redirected, sizeof(redirected)))
    return first_result;
  saved_errno = errno;
  retry_result = real_unlinkat(AT_FDCWD, redirected, flags);
  if (retry_result == 0) {
    char logged[160];
    snprintf(logged, sizeof(logged),
             "kobo-shim: unlinkat redirected %s -> sysroot",
             pathname ? pathname : "?");
    shim_log_line(logged);
    return 0;
  }
  errno = saved_errno;
  return first_result;
}

/* --- wifi-helper env repair ----------------------------------------- */
/* Nickel spawns wifi bring-up through QProcess with a scrubbed environ
 * that drops PATH (observed: every wifi helper fails with "command not
 * found" — pidof, syslogd, ifconfig, wlarm_le — while the early full-env
 * `killall -9 on-animator.sh` reaches scripts/fakebin/; qemu-user runs
 * these `sh -c` children on the host, where bash falls back to bare
 * host dirs with no Kobo tools. On-device this self-heals through
 * busybox sh's compiled-in /sbin:/bin defaults; under emulation it
 * dead-ends). Repair at the boundary: when the guest execs anything,
 * ensure the child environ carries a PATH covering the host-absolute
 * fakebin dir ($FAKEBIN_DIR, exported by scripts/run-usermode.sh) plus a
 * FAKEBIN_LOG pointer ($FAKEBIN_LOG_PATH) when the scrub dropped them.
 * Helper lookup then resolves the stand-ins through qemu's host-fallback
 * open — the same vehicle the early killall already uses. Fail-open:
 * without $FAKEBIN_DIR, or when PATH already covers it, or when memory
 * runs out, the original environ passes through untouched. */
static int path_already_covers_dir(const char *path_value,
                                   const char *fakebin_dir) {
  return path_value && fakebin_dir && strstr(path_value, fakebin_dir) != NULL;
}

static char *merged_path_with_fakebin(const char *path_value,
                                      const char *fakebin_dir) {
  static const char fallback_path[] = "/bin:/sbin:/usr/bin:/usr/sbin";
  const char *base = (path_value && path_value[0] != '\0') ? path_value : fallback_path;
  size_t length = strlen("PATH=") + strlen(base) + 1 + strlen(fakebin_dir) + 1;
  char *merged = malloc(length);
  if (!merged)
    return NULL;
  strcpy(merged, "PATH=");
  strcat(merged, base);
  strcat(merged, ":");
  strcat(merged, fakebin_dir);
  return merged;
}

/* Returns the index of the first "VAR=" entry in envp, or -1 when absent
 * (or when envp itself is NULL). */
static int find_env_entry(char *const envp[], const char *var_prefix) {
  size_t i = 0;
  size_t prefix_length = strlen(var_prefix);
  if (!envp)
    return -1;
  while (envp[i]) {
    if (strncmp(envp[i], var_prefix, prefix_length) == 0)
      return (int)i;
    i++;
  }
  return -1;
}

int execve(const char *pathname, char *const argv[], char *const envp[]) {
  static int (*real_execve)(const char *, char *const[], char *const[]) = NULL;
  const char *fakebin_dir = getenv("FAKEBIN_DIR");
  const char *fakebin_log = getenv("FAKEBIN_LOG_PATH");
  size_t env_count = 0;
  int path_index, log_index;
  char *merged_path = NULL;
  char *log_entry = NULL;
  char **child_env;
  size_t slots;
  int result;

  if (!real_execve)
    real_execve = dlsym(RTLD_NEXT, "execve");
  if ((!fakebin_dir || fakebin_dir[0] == '\0') &&
      (!fakebin_log || fakebin_log[0] == '\0'))
    return real_execve(pathname, argv, envp);
  if (envp)
    while (envp[env_count])
      env_count++;
  path_index = find_env_entry(envp, "PATH=");
  log_index = find_env_entry(envp, "FAKEBIN_LOG=");
  if (fakebin_dir && fakebin_dir[0] != '\0' &&
      !path_already_covers_dir(path_index >= 0 ? envp[path_index] + 5 : NULL,
                               fakebin_dir))
    merged_path = merged_path_with_fakebin(
        path_index >= 0 ? envp[path_index] + 5 : NULL, fakebin_dir);
  if (fakebin_log && fakebin_log[0] != '\0' && log_index < 0) {
    size_t length = strlen("FAKEBIN_LOG=") + strlen(fakebin_log) + 1;
    log_entry = malloc(length);
    if (log_entry) {
      strcpy(log_entry, "FAKEBIN_LOG=");
      strcat(log_entry, fakebin_log);
    }
  }
  if (!merged_path && !log_entry)
    return real_execve(pathname, argv, envp);
  slots = env_count + 1 /* merged PATH */ + 1 /* log entry */ + 1 /* NULL */;
  child_env = malloc(slots * sizeof(*child_env));
  if (!child_env) {
    free(merged_path);
    free(log_entry);
    return real_execve(pathname, argv, envp);
  }
  for (size_t i = 0; i < env_count; i++)
    child_env[i] = envp[i];
  if (merged_path) {
    if (path_index >= 0)
      child_env[path_index] = merged_path;
    else
      child_env[env_count++] = merged_path;
  }
  if (log_entry)
    child_env[env_count++] = log_entry;
  child_env[env_count] = NULL;
  {
    char logged[160];
    snprintf(logged, sizeof(logged),
             "kobo-shim: repaired child env for %s", pathname ? pathname : "?");
    shim_log_line(logged);
  }
  result = real_execve(pathname, argv, child_env);
  free(merged_path);
  free(log_entry);
  free(child_env);
  return result;
}

/* --- blocking touch reads ------------------------------------------- */
/* A real /dev/input/event* node blocks when no events are queued. Our
 * backing is a regular file, so reads past the pre-seeded data return EOF
 * (0) — and KOReader's input layer maps a zero-length read to EPIPE, warns
 * "Broken pipe", and processes nothing, once per grace period. Emulate
 * device semantics: on EOF, sleep in small steps and retry, picking up any
 * data the host appends meanwhile. By default the grace never exhausts
 * (block like a real device); $KOBO_TOUCH_EOF=1 restores the bounded grace
 * for drain-style readers (fb-test relies on EOF to stop). A close from
 * another thread surfaces as EBADF on the next step, so blocked readers
 * still terminate. */
#define TOUCH_EOF_GRACE_STEPS 200
#define TOUCH_EOF_STEP_MS 10

ssize_t read(int fd, void *buf, size_t count) {
  static ssize_t (*real_read)(int, void *, size_t) = NULL;
  if (!real_read)
    real_read = dlsym(RTLD_NEXT, "read");
  if (count == 0)
    return 0;
  if (!is_touch_fd(fd))
    return real_read(fd, buf, count);
  /* A real evdev node opened O_NONBLOCK reports EAGAIN when its queue is
   * empty; our regular-file backing is instead always poll-readable, so a
   * Qt socket notifier fires continuously and parks here forever when the
   * retry loop below papers over the empty queue. Honor the fd's blocking
   * mode: non-blocking fds fail fast with EAGAIN, blocking fds keep the
   * device-like wait below. Fail-open: when the flag lookup itself fails,
   * keep the legacy blocking behavior. */
  {
    int read_flags = fcntl(fd, F_GETFL);
    if (read_flags >= 0 && (read_flags & O_NONBLOCK)) {
      ssize_t got = real_read(fd, buf, count);
      if (got == 0) {
        errno = EAGAIN;
        return -1;
      }
      return got; /* data, short read, or a real error: pass through */
    }
  }
  int bounded = touch_eof_after_grace();
  int debug = touch_debug_reads();
  for (int attempt = 0;; attempt++) {
    ssize_t got = real_read(fd, buf, count);
    if (got != 0) {
      if (debug && got > 0) {
        /* Log whole input_event records only; a short tail means the
         * caller asked for fewer bytes than one record. */
        size_t records = (size_t)got / sizeof(struct touch_event_record);
        for (size_t i = 0; i < records; i++) {
          struct touch_event_record *event =
              (struct touch_event_record *)((const char *)buf +
                                            i * sizeof(struct touch_event_record));
          char logged[128];
          snprintf(logged, sizeof(logged),
                   "kobo-shim: touch read fd=%d: type=%u code=%u value=%d time=%d.%06d",
                   fd, event->kind, event->code, event->value,
                   event->seconds, event->useconds);
          shim_log_line(logged);
        }
      }
      return got; /* data, or an error (-1): pass through immediately */
    }    if (bounded && attempt >= TOUCH_EOF_GRACE_STEPS)
      return 0; /* grace exhausted: genuine EOF for drain-style readers */
    struct timespec step = {0, TOUCH_EOF_STEP_MS * 1000000L};
    nanosleep(&step, NULL);
  }
}

/* --- ioctl answers -------------------------------------------------- */
static void fill_var_screeninfo(struct fb_var_screeninfo *var) {
  memset(var, 0, sizeof(*var));
  var->xres = (uint32_t)fb_width();
  var->yres = (uint32_t)fb_height();
  var->xres_virtual = (uint32_t)fb_width();
  var->yres_virtual = (uint32_t)fb_height();
  var->bits_per_pixel = FB_BPP;
  var->red.offset = 11;
  var->red.length = 5;
  var->green.offset = 5;
  var->green.length = 6;
  var->blue.offset = 0;
  var->blue.length = 5;
  var->width = 90;   /* physical panel size, mm (portrait-consistent) */
  var->height = 120; /* physical panel size, mm */
  var->activate = 0; /* FB_ACTIVATE_NOW */
  var->vmode = 0;    /* FB_VMODE_NONINTERLACED */
}

static void fill_fix_screeninfo(struct fb_fix_screeninfo *fix) {
  memset(fix, 0, sizeof(*fix));
  memcpy(fix->id, "kobo-fb-shim", 12);
  fix->smem_len = (uint32_t)(fb_width() * fb_height() * (FB_BPP / 8));
  fix->type = 0;   /* FB_TYPE_PACKED_PIXELS */
  fix->visual = 2; /* FB_VISUAL_TRUECOLOR */
  fix->line_length = (uint32_t)(fb_width() * (FB_BPP / 8));
}

/* MXCFB (i.MX EPDC) ioctl family: type 'F', numbers 0x2e-0x32. Matched by
 * (type, nr) rather than full request code so any size/dir variant hits.
 * struct mxcfb_update_data (72 bytes on 32-bit ARM): update_region
 * (4 x u32 at 0), waveform_mode (16), update_mode (20), update_marker (24).
 * struct mxcfb_update_marker_data (8 bytes): update_marker (0),
 * collision_test (4). */
#define MXCFB_TYPE 'F'
#define MXCFB_NR_SEND_UPDATE 0x2e
#define MXCFB_NR_WAIT_FOR_UPDATE_COMPLETE 0x2f
#define MXCFB_NR_SET_PWRDOWN_DELAY 0x30
#define MXCFB_UPDATE_MARKER_OFFSET 24

static uint32_t last_update_marker;

/* Rescan-trigger arming (kobo-sync-trigger.cpp): the watcher thread is
 * spawned from the first MXCFB_SEND_UPDATE, never from a constructor and
 * never during boot. Rationale, proven by bisection: a preloaded thread
 * that polls dlsym during Nickel's ~0.5s dlopen storm deterministically
 * kills the guest (SIGSEGV on a worker thread in QtCore, null+0x44),
 * while the identical thread spawned post-paint is harmless. First paint
 * proves the GUI thread is fully constructed and pumping, so every Qt
 * call the watcher (and its helper) makes from then on is safe. */
static int sync_watcher_armed;
static void sync_trigger_arm(void);

/* --- Nickel auto-paint ------------------------------------------------ */
/* Qt 5.2.1's Kobo platform plugin renders Nickel widgets into a 600x800
 * RGB32 heap QImage owned by its QBackingStore, then issues
 * MXCFB_SEND_UPDATE with zero pixel transfer into the fb mmap (proven:
 * single 960000B shared map, zero writes; blit#2 received
 * QRegion::shared_empty while SU#2 still fired 600x600, so damage does
 * not flow through blit's argument — the SU rect is authoritative for
 * dest geometry and the QImage for pixels). Automate the proven-offline
 * pipeline here: capture the frame in the flush hook, rotate+downconvert
 * it into the panel mapping on each SEND_UPDATE.
 *
 * Rotation default: CW (portrait-top toward the right edge), per the
 * offline proof. One-line flip: set NICKEL_ROTATE_CW to 0 for CCW.
 * Fail-open throughout: any unexpected geometry, missing mapping, or
 * unresolved Qt symbol skips the copy and keeps the blank panel — never
 * crashes the guest. */
#define NICKEL_ROTATE_CW 1
#define NICKEL_SRC_WIDTH 600
#define NICKEL_SRC_HEIGHT 800
#define NICKEL_DST_WIDTH 800
#define NICKEL_DST_HEIGHT 600
/* Full mxcfb_update_data footprint for the alt_buffer correlation probe:
 * region(16) + waveform/update/marker/temp/flags(20) + alt-buffer tail. */
#define MXCFB_UPDATE_DATA_WORDS 18

static void *fb_map_base;
static size_t fb_map_len;

static void *nickel_cached_bits;
static int nickel_cached_width, nickel_cached_height, nickel_cached_bpl;
static int nickel_paint_logged;

static void nickel_transfer_on_update(void) {
  const uint32_t *src_pixels;
  size_t src_stride_words;
  uint16_t *dst_pixels;
  int dst_x, dst_y;

  if (fb_is_portrait())
    return; /* KOReader paints its own portrait panel directly */
  if (!nickel_cached_bits || !fb_map_base)
    return; /* no frame captured yet, or fb never mmaped: nothing to copy */
  if (nickel_cached_width != NICKEL_SRC_WIDTH ||
      nickel_cached_height != NICKEL_SRC_HEIGHT ||
      nickel_cached_bpl < NICKEL_SRC_WIDTH * 4)
    return; /* unexpected frame geometry: keep the blank panel */
  if (fb_width() != NICKEL_DST_WIDTH || fb_height() != NICKEL_DST_HEIGHT ||
      fb_map_len < (size_t)(NICKEL_DST_WIDTH * NICKEL_DST_HEIGHT * 2))
    return; /* unexpected panel mapping: keep the blank panel */
  /* Full-frame copy (a superset of any partial SU rect, so partial
   * updates converge without mapping landscape rects back to portrait
   * source regions). 480k pixels of plain integer ops per SEND_UPDATE;
   * updates are rare (a handful per boot), so this never hot-spins. */
  src_pixels = (const uint32_t *)nickel_cached_bits;
  src_stride_words = (size_t)nickel_cached_bpl / 4;
  dst_pixels = (uint16_t *)fb_map_base;
  for (dst_y = 0; dst_y < NICKEL_DST_HEIGHT; dst_y++) {
    for (dst_x = 0; dst_x < NICKEL_DST_WIDTH; dst_x++) {
#if NICKEL_ROTATE_CW
      int src_x = dst_y;
      int src_y = (NICKEL_SRC_HEIGHT - 1) - dst_x;
#else
      int src_x = (NICKEL_SRC_WIDTH - 1) - dst_y;
      int src_y = dst_x;
#endif
      uint32_t pixel =
          src_pixels[(size_t)src_y * src_stride_words + (size_t)src_x];
      unsigned red = (pixel >> 16) & 0xff;
      unsigned green = (pixel >> 8) & 0xff;
      unsigned blue = pixel & 0xff;
      dst_pixels[(size_t)dst_y * NICKEL_DST_WIDTH + (size_t)dst_x] =
          (uint16_t)(((red >> 3) << 11) | ((green >> 2) << 5) | (blue >> 3));
    }
  }
  if (!nickel_paint_logged) {
    nickel_paint_logged = 1;
#if NICKEL_ROTATE_CW
    shim_log_line("kobo-shim: nickel auto-paint 600x800 RGB32 -> 800x600 RGB565 (CW)");
#else
    shim_log_line("kobo-shim: nickel auto-paint 600x800 RGB32 -> 800x600 RGB565 (CCW)");
#endif
  }
}

static int answer_mxcfb_ioctl(unsigned long request, void *arg) {
  unsigned int ioctl_type = (request >> 8) & 0xff;
  unsigned int ioctl_nr = request & 0xff;
  if (ioctl_type != MXCFB_TYPE)
    return -100; /* not ours */
  if (ioctl_nr == MXCFB_NR_SEND_UPDATE && arg) {
    uint32_t marker = 0;
    uint32_t region[4] = {0, 0, 0, 0};
    uint32_t payload[MXCFB_UPDATE_DATA_WORDS];
    int word;
    memcpy(&marker, (const char *)arg + MXCFB_UPDATE_MARKER_OFFSET, 4);
    memcpy(region, arg, sizeof(region));
    memcpy(payload, arg, sizeof(payload));
    last_update_marker = marker;
    if (!sync_watcher_armed) {
      sync_watcher_armed = 1;
      sync_trigger_arm();
    }
    {
      char logged[128];
      snprintf(logged, sizeof(logged),
               "kobo-shim: MXCFB_SEND_UPDATE marker=%u region=%ux%u+%u+%u",
               marker, region[2], region[3], region[0], region[1]);
      shim_log_line(logged);
    }
    /* Alt_buffer correlation probe: dump the whole update struct so a
     * host-side run can diff every word against the gdb-known QImage
     * constBits address. A match means the ioctl payload carries the
     * source pointer (offset = matching word index); no match means the
     * flush-hook cache below stays the pixel source. */
    for (word = 0; word < MXCFB_UPDATE_DATA_WORDS; word += 6) {
      char dumped[160];
      snprintf(dumped, sizeof(dumped),
               "kobo-shim: SEND_UPDATE payload w%02d-w%02d: %08x %08x %08x %08x %08x %08x (cached-bits=%p)",
               word, word + 5, payload[word], payload[word + 1],
               payload[word + 2], payload[word + 3], payload[word + 4],
               payload[word + 5], nickel_cached_bits);
      shim_log_line(dumped);
    }
    nickel_transfer_on_update();
    return 0;
  }
  if (ioctl_nr == MXCFB_NR_WAIT_FOR_UPDATE_COMPLETE && arg) {
    /* The caller passes the marker to wait for in word 0; report it
     * completed with no collision in word 1, like a real EPDC would once
     * the update hits the panel. Never touch word 0: it is the caller's
     * input, not ours to rewrite. */
    ((uint32_t *)arg)[1] = 0;
    shim_log_line("kobo-shim: MXCFB_WAIT_FOR_UPDATE_COMPLETE ok");
    return 0;
  }
  {
    char accepted[80];
    snprintf(accepted, sizeof(accepted),
             "kobo-shim: MXCFB ioctl 0x%lx accepted", request);
    shim_log_line(accepted);
  }
  return 0;
}

static int answer_touch_ioctl(int fd, unsigned long request, void *arg) {
  (void)fd;
  if (request == EVIOCGVERSION) {
    *(int *)arg = 0x010001;
    return 0;
  }
  if (request == EVIOCGID) {
    memset(arg, 0, 8);
    return 0;
  }
  if (EVIOCG_TYPE(request) == 'E' && EVIOCG_IS_READ(request)) {
    unsigned int nr = EVIOCG_NR(request);
    unsigned int size = EVIOCG_SIZE(request);
    if (size > 128)
      size = 128; /* never overflow the caller's buffer */
    if (nr >= EVIOCGBIT_NR_BASE && nr < EVIOCGBIT_NR_BASE + 0x20) {
      /* EVIOCGBIT(ev, len): capability bitmask for event type ev. */
      unsigned int ev = nr - EVIOCGBIT_NR_BASE;
      memset(arg, 0, size);
      /* EVIOCGBIT(0, len): like the real evdev handler, answer with the
       * supported event-TYPE mask (EV_SYN | EV_KEY | EV_ABS), not the
       * SYN-code mask — capability probers gate on these bits. */
      if (ev == EV_SYN && size >= 1)
        ((unsigned char *)arg)[0] = 0x0b;
      if (ev == EV_KEY && size >= BTN_TOUCH / 8 + 1)
        ((unsigned char *)arg)[BTN_TOUCH / 8] |= (unsigned char)(1u << (BTN_TOUCH % 8));
      /* Button node (event0) also carries KEY_MENU/KEY_HOMEPAGE: advertise
       * them alongside BTN_TOUCH so Qt delivers 139/172 instead of
       * filtering them as unsupported. Answered on every event node —
       * harmless for the touch controller, which never emits these codes —
       * to keep the change minimal and fail-open (size-guarded per bit). */
      if (ev == EV_KEY && size >= KEY_MENU / 8 + 1)
        ((unsigned char *)arg)[KEY_MENU / 8] |= (unsigned char)(1u << (KEY_MENU % 8));
      if (ev == EV_KEY && size >= KEY_HOMEPAGE / 8 + 1)
        ((unsigned char *)arg)[KEY_HOMEPAGE / 8] |= (unsigned char)(1u << (KEY_HOMEPAGE % 8));
      if (ev == EV_ABS && size >= 1) {
        /* Single-touch zForce stream: X, Y, and the pressure channel
         * KOReader's Kobo handler requires to confirm contact. */
        ((unsigned char *)arg)[0] = 0x03; /* ABS_X | ABS_Y */
        if (size >= ABS_PRESSURE / 8 + 1)
          ((unsigned char *)arg)[ABS_PRESSURE / 8] |= (unsigned char)(1u << (ABS_PRESSURE % 8));
      }
      shim_log_line("kobo-shim: answered EVIOCGBIT");
      return 0;
    }
    if (nr >= EVIOCGABS_NR_BASE && nr < EVIOCGABS_NR_BASE + 0x40 && size >= 24) {
      /* EVIOCGABS(abs): struct input_absinfo = 6 x int32. Ranges follow
       * the reported panel orientation so portrait taps stay in range. */
      unsigned int abs = nr - EVIOCGABS_NR_BASE;
      int32_t *info = (int32_t *)arg;
      info[0] = 0;
      info[1] = 0;
      if (abs == ABS_X)
        info[2] = fb_width() - 1;
      else if (abs == ABS_Y)
        info[2] = fb_height() - 1;
      else if (abs == ABS_PRESSURE)
        info[2] = ABS_PRESSURE_MAX;
      else
        info[2] = 0;
      info[3] = info[4] = info[5] = 0;
      shim_log_line("kobo-shim: answered EVIOCGABS");
      return 0;
    }
  }
  {
    char unhandled[80];
    snprintf(unhandled, sizeof(unhandled),
             "kobo-shim: touch ioctl 0x%lx unhandled, answered 0", request);
    shim_log_line(unhandled);
  }
  return 0;
}

int ioctl(int fd, unsigned long request, ...) {
  static int (*real_ioctl)(int, unsigned long, ...) = NULL;
  va_list args;
  void *arg;
  if (!real_ioctl)
    real_ioctl = dlsym(RTLD_NEXT, "ioctl");
  va_start(args, request);
  arg = va_arg(args, void *);
  va_end(args);

  if (is_fb_fd(fd)) {
    if (request == FBIOGET_VSCREENINFO) {
      fill_var_screeninfo((struct fb_var_screeninfo *)arg);
      {
        char logged[80];
        snprintf(logged, sizeof(logged),
                 "kobo-shim: answered FBIOGET_VSCREENINFO %dx%d RGB565",
                 fb_width(), fb_height());
        shim_log_line(logged);
      }
      return 0;
    }
    if (request == FBIOGET_FSCREENINFO) {
      fill_fix_screeninfo((struct fb_fix_screeninfo *)arg);
      shim_log_line("kobo-shim: answered FBIOGET_FSCREENINFO");
      return 0;
    }
    if (request == FBIOPUT_VSCREENINFO || request == FBIOBLANK) {
      shim_log_line("kobo-shim: accepted FBIOPUT_VSCREENINFO/FBIOBLANK");
      return 0;
    }
    if (answer_mxcfb_ioctl(request, arg) == 0)
      return 0;
    {
      char unhandled[80];
      snprintf(unhandled, sizeof(unhandled),
              "kobo-shim: fb ioctl 0x%lx unhandled, answered 0", request);
      shim_log_line(unhandled);
    }
    return 0;
  }
  if (is_touch_fd(fd))
    return answer_touch_ioctl(fd, request, arg);
  return real_ioctl(fd, request, arg);
}

/* --- fb mmap tracking ------------------------------------------------- */
/* The panel mapping is the transfer destination: record the guest's mmap
 * of the fb backing fd so nickel_transfer_on_update() can write the
 * rotated frame into it (writes through a MAP_SHARED mapping land in the
 * host backing file, exactly how KOReader already paints). A munmap
 * overlapping the tracked range clears it, so a stale base can never
 * point at unmapped memory. */
static void track_fb_map(void *result, int fd, size_t len, off_t off) {
  char logged[128];
  if (result == MAP_FAILED || !is_fb_fd(fd))
    return;
  if (off != 0) {
    shim_log_line("kobo-shim: fb mmap nonzero offset, not tracked");
    return;
  }
  fb_map_base = result;
  fb_map_len = len;
  snprintf(logged, sizeof(logged),
           "kobo-shim: tracked fb mmap base=%p len=%zu", result, len);
  shim_log_line(logged);
}

void *mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off) {
  static void *(*real_mmap)(void *, size_t, int, int, int, off_t) = NULL;
  void *result;
  if (!real_mmap)
    real_mmap = dlsym(RTLD_NEXT, "mmap");
  result = real_mmap(addr, len, prot, flags, fd, off);
  track_fb_map(result, fd, len, off);
  return result;
}

void *mmap64(void *addr, size_t len, int prot, int flags, int fd, off64_t off) {
  static void *(*real_mmap64)(void *, size_t, int, int, int, off64_t) = NULL;
  void *result;
  if (!real_mmap64)
    real_mmap64 = dlsym(RTLD_NEXT, "mmap64");
  result = real_mmap64(addr, len, prot, flags, fd, off);
  if (result != MAP_FAILED && is_fb_fd(fd)) {
    if (off != 0) {
      shim_log_line("kobo-shim: fb mmap64 nonzero offset, not tracked");
    } else {
      char logged[128];
      fb_map_base = result;
      fb_map_len = len;
      snprintf(logged, sizeof(logged),
               "kobo-shim: tracked fb mmap64 base=%p len=%zu", result, len);
      shim_log_line(logged);
    }
  }
  return result;
}

int munmap(void *addr, size_t len) {
  static int (*real_munmap)(void *, size_t) = NULL;
  int result;
  if (!real_munmap)
    real_munmap = dlsym(RTLD_NEXT, "munmap");
  result = real_munmap(addr, len);
  if (result == 0 && fb_map_base) {
    uintptr_t unmapped = (uintptr_t)addr;
    uintptr_t tracked = (uintptr_t)fb_map_base;
    if (unmapped < tracked + fb_map_len && tracked < unmapped + len) {
      fb_map_base = NULL;
      fb_map_len = 0;
      shim_log_line("kobo-shim: fb mapping released, tracking cleared");
    }
  }
  return result;
}

/* --- QBackingStore::flush capture -------------------------------------- */
/* NOTE: version-fragile by construction. The Kobo platform plugin in
 * this firmware (Qt 5.2.1) flushes through
 * _ZN13QBackingStore5flushERK7QRegionP7QWindowRK6QPointRK5QListI5QPairI5QRectjEE
 * (NOT the arity-0 _ZN12QBackingStore5flushEv spelling); a Qt upgrade
 * that renames this symbol can only lose Nickel auto-paint, never crash
 * the guest, because every lookup below is NULL-guarded and failures
 * skip the capture (fail-open). The prototype mirrors the ARM EABI
 * call convention (this + 4 args: r0-r3 plus one stack slot) so the
 * call-through forwards every argument untouched. */
void _ZN13QBackingStore5flushERK7QRegionP7QWindowRK6QPointRK5QListI5QPairI5QRectjEE(
    void *store, void *region, void *window, void *offset, void *pairs) {
  static void (*real_flush)(void *, void *, void *, void *, void *) = NULL;
  static void *(*paint_device)(void *) = NULL;
  static int (*image_width)(const void *) = NULL;
  static int (*image_height)(const void *) = NULL;
  static int (*image_format)(const void *) = NULL;
  static int (*image_bpl)(const void *) = NULL;
  static const void *(*image_bits)(const void *) = NULL;
  static int capture_logged;
  const void *image;
  int width, height, format, bpl;
  const void *bits;

  if (!real_flush)
    real_flush = dlsym(RTLD_NEXT,
        "_ZN13QBackingStore5flushERK7QRegionP7QWindowRK6QPointRK5QListI5QPairI5QRectjEE");
  if (!real_flush)
    return; /* fail-open: without the real flush there is nothing to do */
  real_flush(store, region, window, offset, pairs);
  if (!store)
    return;
  /* Resolve the read-only QImage accessors once; any miss disables the
   * capture while the real flush above keeps painting semantics intact. */
  if (!paint_device)
    paint_device = dlsym(RTLD_NEXT, "_ZN13QBackingStore11paintDeviceEv");
  if (!image_width)
    image_width = dlsym(RTLD_NEXT, "_ZNK6QImage5widthEv");
  if (!image_height)
    image_height = dlsym(RTLD_NEXT, "_ZNK6QImage6heightEv");
  if (!image_format)
    image_format = dlsym(RTLD_NEXT, "_ZNK6QImage6formatEv");
  if (!image_bpl)
    image_bpl = dlsym(RTLD_NEXT, "_ZNK6QImage12bytesPerLineEv");
  if (!image_bits)
    image_bits = dlsym(RTLD_NEXT, "_ZNK6QImage9constBitsEv");
  if (!paint_device || !image_width || !image_height || !image_format ||
      !image_bpl || !image_bits)
    return;
  image = paint_device(store);
  if (!image)
    return;
  width = image_width(image);
  height = image_height(image);
  format = image_format(image);
  bpl = image_bpl(image);
  bits = image_bits(image);
  if (!bits || width <= 0 || height <= 0 || bpl < width * 4 || format != 4)
    return; /* not the 600x800 RGB32 frame we know how to rotate */
  if (bits == nickel_cached_bits && width == nickel_cached_width &&
      height == nickel_cached_height && bpl == nickel_cached_bpl)
    return; /* same frame already cached: stay quiet */
  nickel_cached_bits = (void *)bits;
  nickel_cached_width = width;
  nickel_cached_height = height;
  nickel_cached_bpl = bpl;
  if (!capture_logged) {
    char logged[160];
    capture_logged = 1;
    snprintf(logged, sizeof(logged),
             "kobo-shim: captured QBackingStore frame %dx%d fmt=%d bpl=%d bits=%p",
             width, height, format, bpl, bits);
    shim_log_line(logged);
  }
}

/* Deliberately empty: on guest glibc 2.11, calling dlsym or any
 * interposed libc function from a constructor segfaults inside the loader
 * bootstrap. All state initializes lazily on first intercepted call, which
 * can only come from guest code running after bootstrap. */
__attribute__((constructor)) static void shim_announce(void) {
}

/* --- Nickel library-rescan trigger -------------------------------------- */
/* In-process rescan through the REAL PlugWorkflowManager::sync() slot.
 * Ground truth (parsed from libnickel.so.1.0.0's QMetaObject: revision 7,
 * 27 methods): method [13] is `sync`, argc=0, flags=0x0a (Public|Slot) —
 * so a string invokeMethod(singleton, "sync", QueuedConnection) resolves
 * unambiguously (no other sync overload in the metaobject) and lands the
 * raw C++ rescan on the GUI thread. No helper QObject, no hand-built
 * metaobject, no vtables: the receiver is Nickel's own object with its
 * genuine thread affinity. Fallback: onSdMounted() (method [11], also a
 * public zero-arg slot) if the sync invoke ever reports false.
 *
 * Arming: the watcher thread is spawned from the first MXCFB_SEND_UPDATE
 * (see sync_trigger_arm, called above) — never from a constructor, never
 * during boot. First paint proves the GUI thread is fully constructed and
 * pumping, so the queued invoke is safe from then on. Trigger source: a
 * host FIFO ($KOBO_SYNC_FIFO, default /tmp/kobo-sync.fifo — one line =
 * one rescan), debounced to one rescan per 2s. Fail-open everywhere: any
 * missing symbol, null singleton, or absent FIFO leaves the helper
 * dormant and shim behavior unchanged. */
#define SYNC_FIFO_DEFAULT "/tmp/kobo-sync.fifo"
#define SYNC_QUEUED_CONNECTION 2 /* Qt::QueuedConnection: post + return */
#define SYNC_DEBOUNCE_SECONDS 2
#define SYNC_POLL_MS 100

/* QGenericArgument / QGenericReturnArgument layout (Qt5 qobjectdefs.h):
 * { name, data }, 8 bytes each, passed BY VALUE (verified against the
 * invokeMethod mangling). */
struct sync_generic_arg {
  const char *name;
  void *data;
};
typedef unsigned char sync_bool_t;
typedef sync_bool_t (*sync_invoke_fn)(void *, const char *, int,
    struct sync_generic_arg, struct sync_generic_arg,
    struct sync_generic_arg, struct sync_generic_arg,
    struct sync_generic_arg, struct sync_generic_arg,
    struct sync_generic_arg, struct sync_generic_arg,
    struct sync_generic_arg, struct sync_generic_arg,
    struct sync_generic_arg);

static int sync_trigger_fifo_fd = -1; /* held open once the FIFO appears */
static time_t sync_trigger_last_fire;
static pthread_once_t sync_trigger_armed_once = PTHREAD_ONCE_INIT;

static void *sync_trigger_watcher(void *unused) {
  void *(*sharedInstance)(void);
  sync_invoke_fn invokeMethod;
  void *singleton;
  struct sync_generic_arg empty = {0, 0};
  char noted[96];
  (void)unused;
  sharedInstance = dlsym(RTLD_DEFAULT, "_ZN19PlugWorkflowManager14sharedInstanceEv");
  invokeMethod = (sync_invoke_fn)dlsym(RTLD_DEFAULT,
      "_ZN11QMetaObject12invokeMethodEP7QObjectPKcN2Qt14ConnectionTypeE22QGenericReturnArgument16QGenericArgumentS7_S7_S7_S7_S7_S7_S7_S7_S7_");
  if (!sharedInstance || !invokeMethod) {
    shim_log_line("sync-trigger: Qt symbols missing, dormant");
    return 0;
  }
  /* Post-paint the singleton provably exists (it is non-null even
   * earlier), so this is a pure pointer read — no lazy construction, no
   * race with the GUI thread's own first call. */
  singleton = sharedInstance();
  if (!singleton) {
    shim_log_line("sync-trigger: singleton null, dormant");
    return 0;
  }
  snprintf(noted, sizeof(noted),
           "sync-trigger: armed, singleton=%p", singleton);
  shim_log_line(noted);
  for (;;) {
    struct timespec cadence = {0, SYNC_POLL_MS * 1000000L};
    char pending[256];
    ssize_t pendingBytes;
    time_t now;
    sync_bool_t queued;
    nanosleep(&cadence, 0);
    if (sync_trigger_fifo_fd < 0) {
      /* Failed opens consume no fd: retrying until the host creates the
       * FIFO is free. Once open, the fd is held for the process
       * lifetime, so the steady state performs zero fd churn. */
      const char *fifoPath = getenv("KOBO_SYNC_FIFO");
      if (!fifoPath || !fifoPath[0])
        fifoPath = SYNC_FIFO_DEFAULT;
      sync_trigger_fifo_fd = open(fifoPath, O_RDONLY | O_NONBLOCK);
      if (sync_trigger_fifo_fd < 0)
        continue;
      shim_log_line("sync-trigger: FIFO opened, watching for rescans");
    }
    pendingBytes = read(sync_trigger_fifo_fd, pending, sizeof(pending));
    if (pendingBytes <= 0)
      continue;
    now = time(0);
    if (now - sync_trigger_last_fire < SYNC_DEBOUNCE_SECONDS)
      continue;
    sync_trigger_last_fire = now;
    shim_log_line("sync-trigger: FIFO fired, queueing sync()");
    queued = invokeMethod(singleton, "sync", SYNC_QUEUED_CONNECTION,
        empty, empty, empty, empty, empty, empty, empty, empty, empty,
        empty, empty);
    snprintf(noted, sizeof(noted), "sync-trigger: invoke sync() -> %s",
             queued ? "queued" : "FAILED");
    shim_log_line(noted);
    if (!queued) {
      shim_log_line("sync-trigger: falling back to onSdMounted()");
      invokeMethod(singleton, "onSdMounted", SYNC_QUEUED_CONNECTION,
          empty, empty, empty, empty, empty, empty, empty, empty, empty,
          empty, empty);
    }
  }
  return 0;
}

static void sync_trigger_spawn_watcher(void) {
  pthread_t watcher;
  pthread_attr_t detached;
  if (pthread_attr_init(&detached) != 0)
    return;
  pthread_attr_setdetachstate(&detached, PTHREAD_CREATE_DETACHED);
  pthread_create(&watcher, &detached, sync_trigger_watcher, 0);
  pthread_attr_destroy(&detached);
}

/* One-shot arming from first-paint ioctl context (GUI thread — thread
 * creation here is as safe as the interposition itself). pthread_once
 * keeps double-arm impossible even if SUs ever arrive on two threads. */
static void sync_trigger_arm(void) {
  pthread_once(&sync_trigger_armed_once, sync_trigger_spawn_watcher);
}
