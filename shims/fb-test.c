/* fb-test.c — guest-side framebuffer + touch pipeline prover (ARM).
 *
 * Opens /dev/fb0 (served by kobo-fb-shim.so), prints the reported geometry,
 * draws a deterministic test pattern into the mapping, then drains
 * /dev/input/event0 and prints any synthetic events the host pre-seeded.
 * Exit 0 on success; any unexpected state aborts with a message on stderr.
 *
 * Build (static, no guest-libc dependency):
 *   zig cc -target arm-linux-musleabihf -static -O2 fb-test.c -o fb-test
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#define FBIOGET_VSCREENINFO 0x4600
#define FB_WIDTH 800
#define FB_HEIGHT 600

struct fb_bitfield {
  uint32_t offset, length, msb_right;
};

struct fb_var_screeninfo {
  uint32_t xres, yres, xres_virtual, yres_virtual, xoffset, yoffset;
  uint32_t bits_per_pixel, grayscale;
  struct fb_bitfield red, green, blue, transp;
  uint32_t nonstd, activate, height, width;
  uint32_t accel_flags, pixclock;
  uint32_t left_margin, right_margin, upper_margin, lower_margin;
  uint32_t hsync_len, vsync_len, sync, vmode, rotate, colorspace;
  uint32_t reserved[4];
};

struct guest_input_event {
  int32_t tv_sec, tv_usec;
  uint16_t type, code;
  int32_t value;
};

static void die(const char *what) {
  fprintf(stderr, "fb-test: FATAL: %s (errno=%d)\n", what, errno);
  exit(1);
}

static uint16_t rgb565(unsigned int red, unsigned int green, unsigned int blue) {
  return (uint16_t)(((red >> 3) << 11) | ((green >> 2) << 5) | (blue >> 3));
}

static void draw_test_pattern(uint16_t *pixels) {
  for (unsigned int y = 0; y < FB_HEIGHT; y++) {
    for (unsigned int x = 0; x < FB_WIDTH; x++) {
      uint16_t pixel;
      if (y < FB_HEIGHT / 2) {
        /* Top half: 16 e-ink gray steps across the width. */
        unsigned int step = (x * 16) / FB_WIDTH;
        unsigned int gray = step * 17;
        pixel = rgb565(gray, gray, gray);
      } else if (x < FB_WIDTH / 3) {
        pixel = rgb565(255, 0, 0);
      } else if (x < 2 * FB_WIDTH / 3) {
        pixel = rgb565(0, 255, 0);
      } else {
        pixel = rgb565(0, 0, 255);
      }
      if (x == y * FB_WIDTH / FB_HEIGHT)
        pixel = rgb565(255, 255, 255); /* white diagonal */
      pixels[y * FB_WIDTH + x] = pixel;
    }
  }
}

static void drain_synthetic_touch(void) {
  int fd = open("/dev/input/event0", O_RDONLY);
  if (fd < 0) {
    printf("fb-test: touch: /dev/input/event0 unavailable, skipping\n");
    return;
  }
  int event_count = 0;
  struct guest_input_event event;
  for (;;) {
    ssize_t got = read(fd, &event, sizeof(event));
    if (got == 0)
      break; /* backing file drained: end of synthetic stream */
    if (got < 0)
      die("read touch event");
    if (got != sizeof(event))
      die("short touch event read");
    printf("fb-test: touch event %d: type=%u code=%u value=%d\n", event_count,
           event.type, event.code, event.value);
    event_count++;
    if (event_count >= 32)
      break;
  }
  printf("fb-test: touch: drained %d synthetic events\n", event_count);
  close(fd);
}

int main(void) {
  int fb_fd = open("/dev/fb0", O_RDWR);
  if (fb_fd < 0)
    die("open /dev/fb0");

  struct fb_var_screeninfo var;
  memset(&var, 0, sizeof(var));
  if (ioctl(fb_fd, FBIOGET_VSCREENINFO, &var) != 0)
    die("FBIOGET_VSCREENINFO");
  printf("fb-test: panel %ux%u virtual %ux%u bpp=%u\n", var.xres, var.yres,
         var.xres_virtual, var.yres_virtual, var.bits_per_pixel);
  if (var.xres != FB_WIDTH || var.yres != FB_HEIGHT || var.bits_per_pixel != 16) {
    fprintf(stderr, "fb-test: FATAL: unexpected panel geometry\n");
    exit(1);
  }

  size_t mapping_size = FB_WIDTH * FB_HEIGHT * sizeof(uint16_t);
  uint16_t *pixels =
      (uint16_t *)mmap(NULL, mapping_size, PROT_READ | PROT_WRITE, MAP_SHARED, fb_fd, 0);
  if (pixels == MAP_FAILED)
    die("mmap /dev/fb0");
  draw_test_pattern(pixels);
  if (msync(pixels, mapping_size, MS_SYNC) != 0)
    die("msync");

  unsigned long checksum = 0;
  for (size_t i = 0; i < FB_WIDTH * FB_HEIGHT; i++)
    checksum += pixels[i];
  printf("fb-test: pattern drawn, pixel checksum=%lu\n", checksum);
  munmap(pixels, mapping_size);
  close(fb_fd);

  drain_synthetic_touch();
  printf("fb-test: DONE\n");
  return 0;
}
