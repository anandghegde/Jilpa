#!/bin/zsh
# Spike 8 follow-up: does the file system's own number for a folder survive a rename, a move and
# a remount on volumes without persistent identifiers? Scratch disk images only, hidden from Finder.
set -u
S=${JILPA_SCRATCH:?set JILPA_SCRATCH to an empty scratch folder on the boot volume}
IMG=$S/s8/img; MNT=$S/s8/mnt
ino() { stat -f '%i' $1 }
for label in apfs exfat fat32; do
  m=$MNT/$label-ids
  mkdir -p $m
  hdiutil attach -nobrowse -noautoopen -mountpoint $m $IMG/$label.dmg > /dev/null || { echo "attach failed $label"; continue }
  for trial in 1 2 3 4 5; do
    p=$m/ids-$trial; rm -rf $p; mkdir -p $p/sub $p/a
    echo x > $p/a/f.txt
    start=$(ino $p/a)
    mv $p/a $p/b;            renamed=$(ino $p/b)
    mv $p/b $p/sub/b;        moved=$(ino $p/sub/b)
    echo y > $p/sub/b/g.txt; grown=$(ino $p/sub/b)
    hdiutil detach $m > /dev/null
    hdiutil attach -nobrowse -noautoopen -mountpoint $m $IMG/$label.dmg > /dev/null
    remounted=$(ino $p/sub/b)
    rm -rf $p/sub/b; mkdir $p/sub/b; recreated=$(ino $p/sub/b)
    echo "$label trial $trial: start $start renamed $renamed moved $moved child-added $grown remounted $remounted | removed-and-recreated $recreated"
  done
  hdiutil detach $m > /dev/null || hdiutil detach -force $m > /dev/null
done
echo "left mounted under scratch: $(mount | grep -c "$MNT")"
