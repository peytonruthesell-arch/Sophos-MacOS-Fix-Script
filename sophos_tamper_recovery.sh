#!/bin/bash
# Helper for Sophos KBA-000043746: "Sophos Endpoint for macOS: Recover a tamper protected system"
# Run this INSIDE Recovery Mode Terminal (Utilities > Terminal) on the stuck Mac, AFTER you've
# already selected Options > Continue and logged in with an administrator account.
#
# This automates steps 5-12 of the KB article. It does NOT push remotely - it just
# saves you typing/transcribing disk identifiers and paths by hand.

set -e

echo "== Step 5: Listing APFS volumes =="
diskutil apfs list
echo ""
echo "Find the line: APFS Volume Disk (Role): <disk-identifier> (Data)"
echo "It must be the one with Role \"(Data)\" - not the System/boot volume."
read -p "Enter that Data volume's disk identifier (e.g. disk3s5): " DATAVOL

echo ""
echo "== Step 5 (cont): FileVault status for $DATAVOL =="
diskutil apfs list | grep -A 6 "$DATAVOL" || true
echo ""

while true; do
  read -p "Does FileVault show as 'Yes (Locked)' for this volume? [y/N]: " LOCKED
  if [[ "$LOCKED" =~ ^[Yy]$ ]]; then
    echo ""
    echo "== Step 7: Unlocking $DATAVOL =="
    echo "You'll be prompted for a password - use the ADMINISTRATOR password."
    diskutil apfs unlockVolume "$DATAVOL"

    echo ""
    echo "== Step 8: Re-checking FileVault status =="
    diskutil apfs list | grep -A 6 "$DATAVOL" || true
    echo ""
    read -p "Does it now show 'No' (unlocked)? [y/N]: " UNLOCKED
    if [[ "$UNLOCKED" =~ ^[Yy]$ ]]; then
      break
    else
      echo "Still locked - per the KB, repeat steps 7 and 8."
      continue
    fi
  else
    echo "FileVault is off for this volume - skipping to mount step."
    break
  fi
done

echo ""
echo "== Step 10: Mounting $DATAVOL =="
diskutil mount "$DATAVOL"

MOUNT_POINT=$(diskutil info "$DATAVOL" | awk -F': +' '/Mount Point/{print $2}')
echo "Mount point: $MOUNT_POINT"

SOPHOS_PLIST="$MOUNT_POINT/Library/Sophos Anti-Virus/product-info.plist"

if [ ! -f "$SOPHOS_PLIST" ]; then
  echo ""
  echo "Could not find: $SOPHOS_PLIST"
  echo "Double-check the mount point above against the KB article before continuing -"
  echo "stopping rather than guessing, since this is the step that patches the file."
  exit 1
fi

echo ""
echo "Found: $SOPHOS_PLIST"
echo "== Step 12: Patching product-info.plist =="
cp "$SOPHOS_PLIST" "$SOPHOS_PLIST.bak.$(date +%Y%m%d%H%M%S)"
plutil -insert "HomeVersion" -string "10.7.3" "$SOPHOS_PLIST"

echo ""
echo "Done. Verify with:"
echo "  plutil -p \"$SOPHOS_PLIST\""
echo ""
echo "A backup of the original plist was saved alongside it (.bak.<timestamp>)."
echo ""
echo "Next steps (manual, per the KB):"
echo "  13. Restart into normal macOS (Apple icon > Restart)."
echo "  14. Run 'Remove Sophos Anti-Virus', or the Removal tool (KBA-000003260):"
echo "      https://support.sophos.com/support/s/article/KBA-000003260"
echo "      Use the administrator password when prompted."
echo "  15. (Optional) Reinstall Sophos Anti-Virus."
