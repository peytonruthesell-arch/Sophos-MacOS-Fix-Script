#!/bin/bash
# Sophos KBA-000043746 - macOS Recovery Mode tamper-protection fix
# v5: adds fallback search for Sophos product-info.plist.

set -e

if [[ "$1" == "--debug" ]]; then
  set -x
fi

TS="$(date +%Y%m%d_%H%M%S)"
LOGFILE="/tmp/sophos_recovery_${TS}.log"
exec > >(tee -a "$LOGFILE") 2>&1

log() { echo "[$(date '+%H:%M:%S')] $1"; }

trap 'log "[ERROR] Script failed at line $LINENO. Last command: $BASH_COMMAND"; log "Log saved at: $LOGFILE"; exit 1' ERR

log "=== Sophos Tamper Recovery Script v5 starting ==="
log "Log file: $LOGFILE"

echo ""
echo "----- Environment -----"
sw_vers || true
echo ""
diskutil list
echo "------------------------"
echo ""

log "== Scanning APFS volumes =="
APFS_OUTPUT=$(diskutil apfs list)
echo "$APFS_OUTPUT"

DATA_COUNT=$(echo "$APFS_OUTPUT" | grep -cE "\(Data\)")
log "Found $DATA_COUNT volume(s) tagged (Data)"

DATAVOL=""
FV_RAW=""

if [ "$DATA_COUNT" -eq 1 ]; then
  DETECTED=$(echo "$APFS_OUTPUT" | awk '
    /\(Data\)/ {
      for (i=1;i<=NF;i++) if ($i ~ /^disk[0-9]+s[0-9]+$/) id=$i
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
  ')

  DATAVOL="${DETECTED%%|*}"
  FV_RAW="${DETECTED#*|}"

  log "Auto-detected Data volume: $DATAVOL"
  log "FileVault status: $FV_RAW"

  read -p "Does this look correct? [Y/n]: " CONFIRM
  log "User confirmation response: $CONFIRM"

  if [[ "$CONFIRM" =~ ^[Nn]$ ]]; then
    DATA_COUNT=0
    DATAVOL=""
  fi
fi

if [ "$DATA_COUNT" -ne 1 ] || [ -z "$DATAVOL" ]; then
  log "Falling back to manual identification"
  echo "$APFS_OUTPUT"
  echo ""
  echo "Find the line: APFS Volume Disk (Role): <disk-identifier> (Data)"
  echo "It must be the (Data) role - NOT the Container line at the top of each block."

  read -p "Enter that Data volume's disk identifier exactly as shown, e.g. disk3s5: " DATAVOL
  log "User-entered disk identifier: $DATAVOL"

  FV_RAW=$(echo "$APFS_OUTPUT" | grep -A 12 "$DATAVOL" | grep "FileVault:" | head -1)
  log "FileVault status detected: ${FV_RAW:-could not determine - check manually above}"
fi

LOCKED="no"

if echo "$FV_RAW" | grep -qi "Yes *(Locked)"; then
  LOCKED="yes"
fi

log "Locked status: $LOCKED"

if [ "$LOCKED" == "yes" ]; then
  ATTEMPT=1

  while true; do
    log "== Unlock attempt #$ATTEMPT for $DATAVOL =="
    echo ""
    echo "IMPORTANT:"
    echo "Type the Mac administrator password at the Passphrase prompt."
    echo "Nothing will appear while typing. This is normal."
    echo "Press Return when finished."
    echo ""

    if ! diskutil apfs unlockVolume "$DATAVOL"; then
      CURRENT_MOUNT=$(diskutil info "$DATAVOL" | awk -F': +' '/Mount Point/{print $2}')

      if [[ -n "$CURRENT_MOUNT" && "$CURRENT_MOUNT" != "Not Mounted" && "$CURRENT_MOUNT" != "Not applicable"* ]]; then
        log "Volume already appears unlocked/mounted at: $CURRENT_MOUNT"
        break
      else
        log "[ERROR] Unlock failed and volume does not appear mounted."
        exit 1
      fi
    fi

    NEW_STATUS=$(diskutil apfs list | grep -A 12 "$DATAVOL" | grep "FileVault:" | head -1)
    log "Status after unlock attempt #$ATTEMPT: $NEW_STATUS"

    if echo "$NEW_STATUS" | grep -qi "Yes *(Locked)"; then
      log "Still locked after attempt #$ATTEMPT - retrying per KB steps 7-8."
      log "If this repeats, the admin password may not be the FileVault-authorized user."
      ATTEMPT=$((ATTEMPT+1))
      continue
    else
      log "Unlock succeeded after $ATTEMPT attempt(s)."
      break
    fi
  done
fi

log "== Mounting $DATAVOL =="

CURRENT_MOUNT=$(diskutil info "$DATAVOL" | awk -F': +' '/Mount Point/{print $2}')
log "Mount point before action: '$CURRENT_MOUNT'"

if [[ -z "$CURRENT_MOUNT" || "$CURRENT_MOUNT" == "Not Mounted" || "$CURRENT_MOUNT" == "Not applicable"* ]]; then
  log "Not currently mounted - mounting now."
  diskutil mount "$DATAVOL"
  CURRENT_MOUNT=$(diskutil info "$DATAVOL" | awk -F': +' '/Mount Point/{print $2}')
else
  log "Already mounted - skipping explicit mount."
fi

log "Mount point: $CURRENT_MOUNT"

if [[ -z "$CURRENT_MOUNT" || "$CURRENT_MOUNT" == "Not Mounted" || "$CURRENT_MOUNT" == "Not applicable"* ]]; then
  log "[ERROR] Could not determine a valid mount point for $DATAVOL."
  exit 1
fi

SOPHOS_PLIST="$CURRENT_MOUNT/Library/Sophos Anti-Virus/product-info.plist"
log "Expected plist path: $SOPHOS_PLIST"

if [ ! -f "$SOPHOS_PLIST" ]; then
  log "Expected plist was not found. Searching for Sophos product-info.plist elsewhere on the Data volume."

  SOPHOS_PLIST=$(find "$CURRENT_MOUNT" \
    -type f \
    -name "product-info.plist" \
    -path "*Sophos*" \
    2>/dev/null | head -1)

  if [ -n "$SOPHOS_PLIST" ] && [ -f "$SOPHOS_PLIST" ]; then
    log "Found alternate Sophos plist: $SOPHOS_PLIST"
  else
    log "[ERROR] Could not find any Sophos product-info.plist on the mounted Data volume."
    log "This Mac may have a newer Sophos Endpoint layout, a partial/corrupt install, or Sophos may already be partially removed."
    log "Directory listing of $CURRENT_MOUNT/Library, if accessible:"
    ls -la "$CURRENT_MOUNT/Library" 2>&1 | head -60 || true
    echo ""
    echo "Take a photo of this screen and send it to IT."
    exit 1
  fi
fi

log "Found plist. Backing up and patching."

BACKUP="$SOPHOS_PLIST.bak.${TS}"
cp "$SOPHOS_PLIST" "$BACKUP"
log "Backup saved: $BACKUP"

if plutil -p "$SOPHOS_PLIST" | grep -q '"HomeVersion"'; then
  log "HomeVersion already exists - replacing value."
  plutil -replace "HomeVersion" -string "10.7.3" "$SOPHOS_PLIST"
else
  log "HomeVersion does not exist - inserting value."
  plutil -insert "HomeVersion" -string "10.7.3" "$SOPHOS_PLIST"
fi

log "Patch applied. Verifying:"
plutil -p "$SOPHOS_PLIST" | grep -i HomeVersion || log "[WARN] Could not verify HomeVersion key after patch."

PERSIST_LOG="$CURRENT_MOUNT/Library/sophos_recovery_${TS}.log"
cp "$LOGFILE" "$PERSIST_LOG" 2>/dev/null && log "Log also copied to: $PERSIST_LOG" || log "[WARN] Could not copy log to Data volume."

log "=== Done ==="

echo ""
echo "Next steps:"
echo "  1. Restart into normal macOS."
echo "  2. Run Remove Sophos Anti-Virus or the Sophos Removal Tool."
echo "  3. Use the administrator password when prompted."
echo "  4. Reinstall Sophos if needed."
echo ""
echo "Troubleshooting logs:"
echo "  $LOGFILE"
echo "  $PERSIST_LOG"
