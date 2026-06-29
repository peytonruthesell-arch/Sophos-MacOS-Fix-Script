#!/bin/bash

set -e

TS="$(date +%Y%m%d_%H%M%S)"
LOGFILE="/tmp/sophos_recovery_${TS}.log"
exec > >(tee -a "$LOGFILE") 2>&1

log() {
  echo "[$(date '+%H:%M:%S')] $1"
}

fail() {
  echo ""
  echo "ERROR: $1"
  echo ""
  echo "Take a photo of this screen and send it to IT."
  echo "Log file: $LOGFILE"
  exit 1
}

trap 'fail "Script stopped unexpectedly."' ERR

clear
echo "=================================================="
echo " Sophos Removal Recovery Tool"
echo "=================================================="
echo ""
echo "This tool prepares Sophos so it can be removed."
echo ""
echo "Important password note:"
echo "When asked for a Passphrase, type your Mac admin"
echo "password. Nothing will appear while typing."
echo "That is normal. Press Return when done."
echo ""
echo "=================================================="
echo ""

log "Starting Sophos recovery script"
log "Log file: $LOGFILE"

APFS_OUTPUT="$(diskutil apfs list)"

DATA_COUNT="$(echo "$APFS_OUTPUT" | grep -cE "\(Data\)")"

if [ "$DATA_COUNT" -ne 1 ]; then
  echo "$APFS_OUTPUT"
  fail "Could not safely auto-detect exactly one Data volume."
fi

DETECTED="$(echo "$APFS_OUTPUT" | awk '
  /\(Data\)/ {
    for (i=1;i<=NF;i++) {
      if ($i ~ /^disk[0-9]+s[0-9]+$/) id=$i
    }
    collecting=1
    next
  }
  collecting && /FileVault:/ {
    line=$0
    sub(/^[ \t]*FileVault:[ \t]*/, "", line)
    print id "|" line
    collecting=0
    exit
  }
')"

DATAVOL="${DETECTED%%|*}"
FV_RAW="${DETECTED#*|}"

[ -n "$DATAVOL" ] || fail "Could not identify the Data volume."

log "Detected Data volume: $DATAVOL"
log "Detected FileVault status: $FV_RAW"

if echo "$FV_RAW" | grep -qi "Yes *(Locked)"; then
  echo ""
  echo "The Mac's Data volume is locked by FileVault."
  echo ""
  echo "At the Passphrase prompt:"
  echo "  1. Type the Mac admin password"
  echo "  2. Nothing will show while typing"
  echo "  3. Press Return"
  echo ""

  diskutil apfs unlockVolume "$DATAVOL" || fail "Could not unlock the Data volume. The password may have been blank or incorrect."
fi

CURRENT_MOUNT="$(diskutil info "$DATAVOL" | awk -F': +' '/Mount Point/{print $2}')"

if [[ -z "$CURRENT_MOUNT" || "$CURRENT_MOUNT" == "Not Mounted" || "$CURRENT_MOUNT" == "Not applicable"* ]]; then
  log "Mounting Data volume"
  diskutil mount "$DATAVOL" || fail "Could not mount the Data volume."
  CURRENT_MOUNT="$(diskutil info "$DATAVOL" | awk -F': +' '/Mount Point/{print $2}')"
fi

[ -n "$CURRENT_MOUNT" ] || fail "Could not determine the Data volume mount point."

log "Data volume mounted at: $CURRENT_MOUNT"

SOPHOS_PLIST="$CURRENT_MOUNT/Library/Sophos Anti-Virus/product-info.plist"

if [ ! -f "$SOPHOS_PLIST" ]; then
  fail "Could not find the Sophos product-info.plist file."
fi

log "Found Sophos plist: $SOPHOS_PLIST"

BACKUP="$SOPHOS_PLIST.bak.${TS}"
cp "$SOPHOS_PLIST" "$BACKUP" || fail "Could not back up the Sophos plist."

log "Backup created: $BACKUP"

if plutil -p "$SOPHOS_PLIST" | grep -q '"HomeVersion"'; then
  plutil -replace "HomeVersion" -string "10.7.3" "$SOPHOS_PLIST"
else
  plutil -insert "HomeVersion" -string "10.7.3" "$SOPHOS_PLIST"
fi

VERIFY="$(plutil -p "$SOPHOS_PLIST" | grep -i HomeVersion || true)"

echo ""
echo "=================================================="
echo " SUCCESS"
echo "=================================================="
echo ""
echo "Sophos is now prepared for removal."
echo ""
echo "Next steps:"
echo "1. Restart the Mac normally."
echo "2. Open Remove Sophos Endpoint."
echo "3. When prompted, enter the Mac admin password."
echo ""
echo "Verification:"
echo "$VERIFY"
echo ""

PERSIST_LOG="$CURRENT_MOUNT/Library/sophos_recovery_${TS}.log"
cp "$LOGFILE" "$PERSIST_LOG" 2>/dev/null || true

log "Completed successfully"
