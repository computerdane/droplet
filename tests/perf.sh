#!/usr/bin/env bash
# Performance gate: plays a real loop (KTLX, the Moore tornado, an hour of volumes) with the
# flake's Mesa (llvmpipe) under Xvfb and fails on hitches: frames far slower than the median
# (a stall while streaming loop frames or uploading textures). Software rendering makes absolute
# times depend on the runner's cores, so the budgets are ratios to the median. Fetches the
# volumes (and builds the basemap) first if data/ lacks them, which needs network.
#   tests/perf.sh            every case
#   tests/perf.sh 2d_play    only these cases
# .github/workflows/perf.yml runs it nightly.
set -euo pipefail
cd "$(dirname "$0")/.."

FROM=2013-05-20T19:30Z
TO=2013-05-20T20:30Z
COMMON="site=KTLX time=20130520_193407 basemap=1 warnings=0 live=0 hover=0 fps=15 play=1"
# case -> main.gd options and budgets (tests/frametimes.gd): p99 within max_p99_ratio × the
# median, at most max_spikes frames over 4 × the median. Ratios, so a slow runner still passes.
declare -A CASES=(
	[2d_play]="frames=900 field=REF zoom=2 max_p99_ratio=3 max_spikes=10"
	[2d_dvel_mosaic]="frames=900 field=DVEL srm=auto mosaic=1 zoom=1.5 max_p99_ratio=3 max_spikes=10"
	[3d_play]="frames=300 view=3d field=REF max_p99_ratio=3 max_spikes=6"
)

: "${DROPLET_GL_LIBS:?run inside nix develop}"
export LD_LIBRARY_PATH="$DROPLET_GL_LIBS" __GLX_VENDOR_LIBRARY_NAME=mesa LIBGL_ALWAYS_SOFTWARE=1
export LIBGL_DRIVERS_PATH="${DROPLET_GL_LIBS##*:}/dri"
if [[ -z "${PERF_INNER:-}" ]]; then
	[[ -f data/basemap/basemap.json ]] || nexrad basemap
	if ! ls -d data/volumes/KTLX_20130520_19* >/dev/null 2>&1; then
		nexrad update KTLX --from "$FROM" --to "$TO"
	fi
	PERF_INNER=1 exec xvfb-run -a -s "-screen 0 1280x800x24" "$0" "$@"
fi

names=("$@")
((${#names[@]})) || mapfile -t names < <(printf '%s\n' "${!CASES[@]}" | sort)
failed=()
for name in "${names[@]}"; do
	opts=${CASES[$name]:?unknown case $name}
	echo "== $name"
	# shellcheck disable=SC2086
	godot --rendering-driver opengl3 --resolution 1280x800 --path . \
		--script res://tests/frametimes.gd -- $COMMON $opts 2>&1 | grep -v "^  spike" || failed+=("$name")
done
if ((${#failed[@]})); then
	echo "failed: ${failed[*]}"
	exit 1
fi
