/* hello.c — homebrew hello-world for the Kobo user-mode track (ARM).
 *
 * Proves an unsigned third-party binary executes under qemu-arm alongside
 * the shim: the manual equivalent of the staged NickelMenu
 * `cmd_spawn ... /mnt/onboard/.adds/hello` entry (NickelMenu itself spawns
 * via /bin/sh -c, which under qemu-arm executes on the host, so end-to-end
 * menu pickup additionally waits on a painting Nickel).
 *
 * Build (static, no guest-libc dependency):
 *   zig cc -target arm-linux-musleabihf -static -O2 hello.c -o hello
 */
#include <stdio.h>
#include <unistd.h>

int main(void) {
  printf("hello-from-homebrew: uid=%d cmd-spawn-equivalent\n", getuid());
  printf("hello-from-homebrew: DONE\n");
  return 0;
}
