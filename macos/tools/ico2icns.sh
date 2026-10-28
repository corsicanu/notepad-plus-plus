#!/bin/sh
# Builds the app icon from upstream's npp.ico (IDI_M30ICON): its 256x256 PNG
# frame, scaled down for the smaller sizes, packed by iconutil.
#   ico2icns.sh <npp.ico> <out.icns>
set -e
ICO="$1"
OUT="$2"
TMP="$(mktemp -d)"
SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"

# The largest PNG-compressed frame of the .ico.
python3 - "$ICO" "$TMP/256.png" <<'PY'
import struct, sys
data = open(sys.argv[1], "rb").read()
count = struct.unpack("<HHH", data[:6])[2]
best = None
for i in range(count):
    w, h, _, _, _, _, size, off = struct.unpack("<BBBBHHII", data[6 + 16 * i:22 + 16 * i])
    w = w or 256
    if data[off:off + 8] == b"\x89PNG\r\n\x1a\n" and (best is None or w > best[0]):
        best = (w, data[off:off + size])
if best is None:
    sys.exit("no PNG frame in " + sys.argv[1])
open(sys.argv[2], "wb").write(best[1])
PY

for s in 16 32 128 256; do
	sips -z $s $s "$TMP/256.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
done
for s in 16 32 128; do
	d=$((s * 2))
	sips -z $d $d "$TMP/256.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$OUT"
rm -rf "$TMP"
