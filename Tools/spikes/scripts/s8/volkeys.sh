#!/bin/zsh
set -u
S=${JILPA_SCRATCH:?set JILPA_SCRATCH to an empty scratch folder on the boot volume}
IMG=$S/s8/img; MNT=$S/s8/mnt
swiftc -O -o $S/volkeys "$(dirname "$0")/volkeys.swift" 2>&1 | tail -3
paths=(/)
for label in apfs apfscs hfs exfat fat32; do
  mkdir -p $MNT/$label-keys
  hdiutil attach -nobrowse -noautoopen -mountpoint $MNT/$label-keys $IMG/$label.dmg > /dev/null && paths+=($MNT/$label-keys)
done
$S/volkeys $paths
for label in apfs apfscs hfs exfat fat32; do hdiutil detach $MNT/$label-keys > /dev/null || hdiutil detach -force $MNT/$label-keys > /dev/null; done
echo "left mounted under scratch: $(mount | grep -c "$MNT")"
