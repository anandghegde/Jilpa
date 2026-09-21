#!/bin/zsh
# Spike 8, the part that needs other volumes. Creates scratch disk images, attaches them hidden
# from Finder under the scratch folder, runs the tool on each, and detaches them again.
# The tool itself never mounts or unmounts anything.
set -u
S=${JILPA_SCRATCH:?set JILPA_SCRATCH to an empty scratch folder on the boot volume}
BIN=${S8_BIN:-$(cd "$(dirname "$0")/../../../.." && swift build --show-bin-path)/s8-destinations}
OUT=${S8_OUT:-$(cd "$(dirname "$0")/../../data" && pwd)/s8}
IMG=$S/s8/img
MNT=$S/s8/mnt
mkdir -p $IMG $MNT $OUT $S/s8/boot-other $S/s8/stored

typeset -A FS
FS=(apfs "APFS" apfscs "Case-sensitive APFS" hfs "HFS+J" exfat "ExFAT" fat32 "MS-DOS FAT32")
if (( $# )); then LABELS=("$@"); else LABELS=(apfs apfscs hfs exfat fat32); fi

attach() {  # label mountpoint
  mkdir -p $2
  hdiutil attach -nobrowse -noautoopen -mountpoint $2 $IMG/$1.dmg > /dev/null || echo "attach failed: $1 at $2"
}
detach() {  # mountpoint
  hdiutil detach $1 > /dev/null 2>&1 || hdiutil detach -force $1 > /dev/null 2>&1 || echo "detach failed: $1"
}
# If a resolve that was allowed to mount did mount the image, it sits under /Volumes. Report and undo.
strays() {  # label
  local found
  found=$(mount | grep -i "/Volumes/S8$1" | awk '{print $3}')
  if [[ -n "$found" ]]; then
    echo "STRAY MOUNT after probe: $1"
    for m in ${(f)found}; do detach $m; done
  fi
}

for label in $LABELS; do
  echo "=== $label $(date +%H:%M:%S)"
  rm -f $OUT/$label.jsonl
  hdiutil create -size 64m -fs "${FS[$label]}" -volname "S8$label" -ov $IMG/$label.dmg > /dev/null || { echo "create failed: $label"; continue }
  attach $label $MNT/$label

  # Changes inside one mounted volume, and a move to the boot volume.
  mkdir -p $MNT/$label/work
  $BIN identity --base $MNT/$label/work --volume $label --other $S/s8/boot-other --repeats 5 --with-trash --out $OUT/$label.jsonl
  $BIN variants --base $MNT/$label/work --volume $label --out $OUT/$label.jsonl
  $BIN bench --path $MNT/$label/work > $OUT/bench-$label.md

  # Unmount and remount. The stored record is made once, while mounted.
  mkdir -p $MNT/$label/keep/dest
  echo marker > $MNT/$label/keep/dest/marker.txt
  stored=$S/s8/stored/$label.json
  $BIN store --path $MNT/$label/keep/dest --out $stored
  for trial in 1 2 3 4 5; do
    $BIN check --stored $stored --label mounted --expected available --truth $MNT/$label/keep/dest \
      --volume $label --trial $trial --out $OUT/$label.jsonl
    detach $MNT/$label
    $BIN check --stored $stored --label volume-unmounted --expected unavailable-not-mounted \
      --volume $label --trial $trial --probe-mounting --out $OUT/$label.jsonl
    strays $label
    # A folder with the stored path on the boot volume, as a stale /Volumes/Name folder would be.
    mkdir -p $MNT/$label/keep/dest
    $BIN check --stored $stored --label unmounted-with-ghost-folder --expected unavailable-not-mounted \
      --impostor $MNT/$label/keep/dest --volume $label --trial $trial --out $OUT/$label.jsonl
    rm -rf $MNT/$label/keep
    attach $label $MNT/$label-elsewhere
    $BIN check --stored $stored --label remounted-elsewhere --expected available \
      --truth $MNT/$label-elsewhere/keep/dest --volume $label --trial $trial --out $OUT/$label.jsonl
    detach $MNT/$label-elsewhere
    attach $label $MNT/$label
    $BIN check --stored $stored --label remounted-same-place --expected available \
      --truth $MNT/$label/keep/dest --volume $label --trial $trial --out $OUT/$label.jsonl
  done

  # The boot volume's move to another volume, with this image as the other one (APFS only).
  if [[ $label == apfs ]]; then
    mkdir -p $MNT/$label/from-boot
    $BIN identity --base $S/s8/boot --volume boot --other $MNT/$label/from-boot --repeats 5 \
      --only moved-to-other-volume --out $OUT/boot.jsonl
  fi
  detach $MNT/$label
done
echo "=== done $(date +%H:%M:%S)"
mount | grep -c "$S/s8/mnt" | sed 's/^/still mounted under scratch: /'
