#!/bin/sh
# Synthetic inputs only; run from any directory.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
sample() {
    printf 'INFO 1.0 fps, %s ms/frame (1.0 preparing: copies 0.0 ms 0.0 MB, textures 0.0 ms 0.0 MB; 2.0 on the GPU; 0.0 copying back 0.0 MB), 30 draws/frame, dropped %s without a host pipeline (0 being made) and 4 indirect\n' "$1" "$2"
}
{
    sample 1000 20
    printf 'dropped 7.0/frame without a host pipeline: compute 0123456789abcdef\n'
    sample 800 10
} > "$tmp/base"
{
    printf 'dropped 99.0/frame without a host pipeline: being made\n'
    sample 600 5
    printf 'dropped 3.0/frame without a host pipeline: mesh 0123456789abcdef + pixel fedcba9876543210\n'
    printf 'dropped 2.0/frame without a host pipeline: refused C:/private/path\n'
    sample 400 3
} > "$tmp/cand"
sh "$here/compare-logs.sh" "$tmp/base" "$tmp/cand" 1 2 1 2 > "$tmp/out"
grep -Eq '^ms/frame +900.000 +500.000 +-400.000' "$tmp/out"
grep -Eq '^dropped/frame +15.000 +4.000 +-11.000' "$tmp/out"
grep -Fq 'compute 0123456789abcdef; mean when listed 7.000 (1/2 samples)' "$tmp/out"
grep -Fq 'mesh 0123456789abcdef + pixel fedcba9876543210; mean when listed 3.000 (1/2 samples)' "$tmp/out"
grep -Fq 'host pipeline refused (details omitted)' "$tmp/out"
! grep -Eq 'private|99.000' "$tmp/out"
if sh "$here/compare-logs.sh" "$tmp/base" "$tmp/cand" 1 3 1 2 > /dev/null 2>&1; then
    echo 'invalid window accepted' >&2; exit 1
fi
# Same-file comparisons must not conflate counts.
sh "$here/compare-logs.sh" "$tmp/base" "$tmp/base" 1 1 2 2 > "$tmp/out"
grep -Eq '^ms/frame +1000.000 +800.000 +-200.000' "$tmp/out"
# Unequal frame counts: a fast window contributes more frames, not equal weight.
{ sample 1000 20 | sed 's/$/ sample_frames=1/'; sample 100 2 | sed 's/^/sample_frames=9 /'; } > "$tmp/wbase"
{ sample 500 4 | sed 's/$/ sample_frames=2/'; sample 250 2 | sed 's/$/ sample_frames=4/'; } > "$tmp/wcand"
sh "$here/compare-logs.sh" "$tmp/wbase" "$tmp/wcand" 1 2 1 2 > "$tmp/out"
grep -Fq 'Frame-weighted estimates' "$tmp/out"
grep -Eq '^ms/frame +190.000 +333.333 +\+143.333' "$tmp/out"
grep -Eq '^fps +5.263 +3.000 +-2.263' "$tmp/out"
grep -Eq '^dropped/frame +3.800 +2.667 +-1.133' "$tmp/out"
sh "$here/compare-logs.sh" "$tmp/wbase" "$tmp/cand" 1 2 1 2 > "$tmp/out"
grep -Fq 'frame counts missing' "$tmp/out"
grep -Eq '^ms/frame +550.000 +500.000 +-50.000' "$tmp/out"
echo '14 checks passed'
