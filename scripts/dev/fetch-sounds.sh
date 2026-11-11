#!/bin/sh
# Rebuilds Resources/Sounds from Google's Material Design sound resources (CC BY 4.0), as mirrored
# in github.com/nana-4/materia-sound-theme: downloads the ogg files, makes them mono, levels each
# to -20 LUFS integrated (a plain gain from the measured level, then a limiter at -3.2 dB so the
# AAC stays under -3 dB true peak; loudnorm's own linear mode gives up on peaky clips), adds a short fade in
# and out so nothing clicks, and writes AAC (.m4a). Prints each file's duration and its level
# before and after. Needs ffmpeg and curl (brew install ffmpeg). The downloads are only ever decoded.
#   scripts/dev/fetch-sounds.sh [output-dir]      default: Resources/Sounds
set -eu
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:-$ROOT/Resources/Sounds}"
BASE="https://raw.githubusercontent.com/nana-4/materia-sound-theme/master/material_product_sounds"
# Keep in step with EventSound.file in Sources/AINotch/SoundPlayer.swift.
NAMES="notification_simple-01 state-change_confirm-up alert_error-01 alert_simple alert_high-intensity alert_error-03 hero_simple-celebration-02 notification_decorative-02 notification_high-intensity"
command -v ffmpeg >/dev/null || { echo "ffmpeg not found" >&2; exit 1; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ai-notch-sounds.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM
mkdir -p "$OUT"

measure() { # file -> "integrated truepeak" of the file's first audio stream
  ffmpeg -hide_banner -nostats -i "$1" -af "loudnorm=I=-20:TP=-3:LRA=11:print_format=json" -f null - 2>&1 |
    python3 -I -c '
import sys, json, re
t = sys.stdin.read()
d = json.loads(t[t.rindex("{"):t.rindex("}") + 1])
print(d["input_i"], d["input_tp"], d["input_lra"], d["input_thresh"], d["target_offset"])'
}

printf '%-30s %6s   %-22s %-22s\n' file secs "before (LUFS / TP dB)" "after (LUFS / TP dB)"
for name in $NAMES; do
  src="$WORK/$name.ogg"
  curl -sfL --max-time 60 -o "$src" "$BASE/$name.ogg" || { echo "download failed: $name" >&2; exit 1; }
  # Mono first, then measured: a stereo pair of equal channels and its mono sum differ by 3 LU.
  ffmpeg -hide_banner -loglevel error -y -i "$src" -ac 1 -c:a pcm_f32le "$WORK/$name.wav"
  read -r i tp lra thresh offset <<EOM
$(measure "$WORK/$name.wav")
EOM
  dur="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$src")"
  fadeout="$(python3 -I -c "print(max(0, $dur - 0.04))")"
  # Peaky, quiet clips cannot reach -20 LUFS under -3 dB true peak by gain alone: a light
  # compressor and the limiter shave the peaks, and the gain is corrected up to 8 times.
  gain="$(python3 -I -c "print(round(-20 - ($i), 2))")"
  n=0
  while :; do
    ffmpeg -hide_banner -loglevel error -y -i "$WORK/$name.wav" \
      -af "volume=${gain}dB,acompressor=threshold=0.15:ratio=3:attack=2:release=60:makeup=1,alimiter=limit=0.63:attack=2:release=30:level=disabled,afade=t=in:d=0.008,afade=t=out:st=$fadeout:d=0.04" \
      -ar 44100 -c:a aac -b:a 64k "$OUT/$name.m4a"
    read -r ai atp _ <<EOM
$(measure "$OUT/$name.m4a")
EOM
    n=$((n + 1))
    off="$(python3 -I -c "print(round(-20 - ($ai), 2))")"
    [ "$n" -ge 8 ] || python3 -I -c "import sys; sys.exit(0 if abs($off) > 0.3 else 1)" || break
    [ "$n" -lt 8 ] || break
    gain="$(python3 -I -c "print(round($gain + $off, 2))")"
  done
  printf '%-30s %6.2f   %-22s %-22s\n' "$name" "$dur" "$i / $tp" "$ai / $atp"
done
cat > "$OUT/LICENSE-SOUNDS.txt" <<'TXT'
Sounds: Material Design sound resources by Google, licensed under CC BY 4.0
(https://creativecommons.org/licenses/by/4.0/). Source: https://m2.material.io/design/sound/sound-resources.html,
fetched from https://github.com/nana-4/materia-sound-theme (material_product_sounds).
Changes: converted to mono AAC, loudness-levelled to about -20 LUFS, short fade in and out.
TXT
du -ck "$OUT"/*.m4a | tail -1 | awk '{print "total " $1 " KB"}'
