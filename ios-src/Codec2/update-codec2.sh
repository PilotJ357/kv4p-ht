#!/bin/bash
# Re-vendors the Codec2 sources needed for CODEC2_MODE_1300 from upstream.
#
# Upstream generates codebook*.c at build time from text files, so this script
# runs upstream CMake once and copies the generated files alongside the
# hand-picked sources. Requires git + cmake.
#
# Usage: ./update-codec2.sh [tag]   (default 1.2.0, matching codec2-android)
set -euo pipefail

TAG="${1:-1.2.0}"
HERE="$(cd "$(dirname "$0")" && pwd)"
DST="$HERE/Sources/CCodec2"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git clone -q --depth 1 --branch "$TAG" https://github.com/drowe67/codec2.git "$WORK/codec2"
cmake -S "$WORK/codec2" -B "$WORK/build" -DUNITTEST=OFF -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$WORK/build" --target codec2 -j 8 >/dev/null

SOURCES="codec2.c codec2_fft.c kiss_fft.c kiss_fftr.c lpc.c lsp.c nlp.c phase.c
  postfilter.c quantise.c sine.c interp.c pack.c mbest.c newamp1.c"
# newamp1/mbest/interp and the extra codebooks are only used by other modes,
# but codec2.c still references them in Debug (-O0) builds.
CODEBOOKS="codebook.c codebookd.c codebookjmv.c codebookge.c
  codebooknewamp1.c codebooknewamp1_energy.c"
HEADERS="_kiss_fft_guts.h bpf.h bpfb.h codec2_fft.h codec2_internal.h comp.h
  comp_prim.h debug_alloc.h defines.h dump.h interp.h kiss_fft.h kiss_fftr.h
  lpc.h lsp.h machdep.h mbest.h newamp1.h newamp2.h nlp.h os.h phase.h
  postfilter.h quantise.h sine.h"

rm -rf "$DST"
mkdir -p "$DST/include/codec2"
for f in $SOURCES $HEADERS; do cp "$WORK/codec2/src/$f" "$DST/"; done
for f in $CODEBOOKS; do cp "$WORK/build/src/$f" "$DST/"; done
cp "$WORK/codec2/src/codec2.h" "$DST/include/"
cp "$WORK/build/codec2/version.h" "$DST/include/codec2/"
cp "$WORK/codec2/COPYING" "$HERE/LICENSE"

echo "Vendored codec2 $TAG into $DST"
echo "Run 'swift test' in $HERE; update matchesUpstreamEncoder if the bitstream changed."
