#!/usr/bin/env bash
# Golden screenshots: renders each case below from the synthetic fixtures (nexrad synth) with
# the flake's Mesa (llvmpipe) under Xvfb and compares it against tests/golden/<case>.png.
#   tests/golden.sh              compare every case (exit 1 on any difference)
#   tests/golden.sh --update     re-render the goldens (commit them after looking at them)
#   tests/golden.sh ppi_ref ...  only these cases
# Needs the dev shell (DROPLET_GL_LIBS, xvfb-run) and an imported project (godot --import).
# Output and diff images go to $GOLDEN_OUT (default: a temporary directory, printed).
set -euo pipefail
cd "$(dirname "$0")/.."

COMMON="volumes=res://tests/fixtures/volumes basemap=0 prefetch=0 live=0 hover=0 site=KTST time=20240501_220500"
declare -A CASES=(
	[ppi_ref]="field=REF zoom=3"
	[ppi_dvel_srm_mosaic]="field=DVEL srm=auto mosaic=1 zoom=2"
	[cones_mosaic]="view=3d mosaic=1 field=REF dist=300 pitch=35"
	[volume_render]="view=3d render=volume field=REF dist=90 pitch=20 yaw=-30 density=0.3"
	[section_vwp]="field=REF zoom=3 section=-10,-15,50,45 vwp=1"
	[hodograph_hover]="field=VEL srm=auto winds=1 zoom=3 hover=700,360"
	[cref_mosaic]="field=CREF mosaic=1 zoom=2 hover=760,330"
	[echo_tops]="field=ET zoom=3"
	[azshr]="field=AZSHR zoom=4 pan=15,15"
)

: "${DROPLET_GL_LIBS:?run inside nix develop}"
# The flake's libglvnd + Mesa for Godot, and Mesa's DRI drivers for Xvfb's own GLX (its built-in
# path is /run/opengl-driver, which only NixOS has).
export LD_LIBRARY_PATH="$DROPLET_GL_LIBS" __GLX_VENDOR_LIBRARY_NAME=mesa LIBGL_ALWAYS_SOFTWARE=1
export LIBGL_DRIVERS_PATH="${DROPLET_GL_LIBS##*:}/dri"
if [[ -z "${GOLDEN_INNER:-}" ]]; then
	GOLDEN_INNER=1 exec xvfb-run -a -s "-screen 0 1280x800x24" "$0" "$@"
fi

update=0
names=()
for a in "$@"; do
	if [[ $a == --update ]]; then update=1; else names+=("$a"); fi
done
((${#names[@]})) || mapfile -t names < <(printf '%s\n' "${!CASES[@]}" | sort)
out=${GOLDEN_OUT:-$(mktemp -d)}
mkdir -p "$out"

failed=()
for name in "${names[@]}"; do
	opts=${CASES[$name]:?unknown case $name}
	png="$out/$name.png"
	# shellcheck disable=SC2086
	godot --rendering-driver opengl3 --resolution 1280x800 --path . \
		--script res://tests/screenshot.gd -- "$png" frames=40 $COMMON $opts >"$out/$name.log" 2>&1 ||
		{ cat "$out/$name.log"; failed+=("$name"); continue; }
	if ((update)); then
		cp "$png" "tests/golden/$name.png"
		echo "updated  $name"
		continue
	fi
	rm -f "$out/$name.diff.png"
	printf '%-22s ' "$name"
	godot --headless --path . --script res://tests/compare.gd -- \
		"tests/golden/$name.png" "$png" "$out/$name.diff.png" 2>&1 | grep -E '^(ok|DIFF|size)|ERROR' ||
		true
	[[ -f "$out/$name.diff.png" || ! -f "tests/golden/$name.png" ]] && failed+=("$name")
done
echo "output: $out"
if ((${#failed[@]})); then
	echo "failed: ${failed[*]}"
	exit 1
fi
