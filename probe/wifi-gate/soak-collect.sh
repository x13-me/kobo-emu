#!/usr/bin/env bash
set -uo pipefail
cd /home/user/kobo-emu
echo '--- driver tail ---'
tail -8 artifacts/soak-driver.log
echo '--- SEND_UPDATEs ---'
grep -a -c MXCFB_SEND_UPDATE build/rootfs-4.38.23684/tmp/kobo-shim.log || true
grep -a MXCFB_SEND_UPDATE build/rootfs-4.38.23684/tmp/kobo-shim.log || true
echo '--- backing ---'
python3 -c "
d = open('build/rootfs-4.38.23684/tmp/kobo-fb0.bin','rb').read()
import hashlib
print('size=', len(d), 'nonzero=', sum(1 for b in d if b != 0), 'md5=', hashlib.md5(d).hexdigest())
"
echo '--- png ---'
md5sum artifacts/fb-4.38.23684-nickel.png
echo '--- fakebin ---'
cat artifacts/fakebin-4.38.23684-nickel.log
echo '--- stdout tail ---'
tail -15 artifacts/usermode-4.38.23684-nickel.log
echo '--- DB sizes ---'
ls -la mnt/onboard/.kobo/KoboReader.sqlite mnt/onboard/.kobo/BookReader.sqlite 2>/dev/null || ls -la build/rootfs-4.38.23684/mnt/onboard/.kobo/KoboReader.sqlite build/rootfs-4.38.23684/mnt/onboard/.kobo/BookReader.sqlite
echo '--- menu/spawn markers ---'
grep -a -i -E 'nickelmenu|cmd_spawn|hello' artifacts/usermode-4.38.23684-nickel.log build/rootfs-4.38.23684/tmp/kobo-shim.log || echo NO_MENU_MARKERS
