#!/bin/bash
# Sophos KBA-000043746 - macOS Recovery Mode tamper-protection fix
# v3: verbose logging for troubleshooting across multiple machines.
#
# Usage:   bash sophos_tamper_recovery.sh           (normal run)
#          bash sophos_tamper_recovery.sh --debug    (adds full command tracing)
#
# Everything printed to screen is also written to a timestamped log file.
# After the Data volume is mounted, the log is also copied onto it so it
# survives the reboot back to normal macOS for later review.

set -e

if [[ "$1" == "--debug" ]]; then
  set -x
fi

TS="$(date +%Y%m%d_%H%M%S)"
LOGFILE="/tmp/sophos_recovery_${TS}.log"
exec > >(tee -a "$LOGFILE") 2>&1

log() { echo "[$(date '+%H:%M:%S')] $1"; }

trap 'log "[ERROR] Script failed at line $LINENO. Last command: $BASH_COMMAND"; log "Log saved at: $LOGFILE"; exit 1' ERR

log "=== Sophos Tamper Recovery Script v3 starting ==="
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
  read -p "Enter that Data volume's disk identifier exactly as shown (e.g. disk3s1): " DATAVOL
  log "User-entered disk identifier: $DATAVOL"
  FV_RAW=$(echo "$APFS_OUTPUT" | grep -A 8 "$DATAVOL" | grep "FileVault:" | head -1)
  log "FileVault status detected: ${FV_RAW:-could not determine - check manually above}"
fi

LOCKED="no"
if echo "$FV_RAW" | grep -qi "Locked"; then
  LOCKED="yes"
fi
log "Locked status: $LOCKED"

if [ "$LOCKED" == "yes" ]; then
  ATTEMPT=1
  while true; do
    log "== Unlock attempt #$ATTEMPT for $DATAVOL =="
    echo "You'll be prompted for a password - use the ADMINISTRATOR password."
    diskutil apfs unlockVolume "$DATAVOL"
    NEW_STATUS=$(diskutil apfs list | grep -A 8 "$DATAVOL" | grep "FileVault:" | head -1)
    log "Status after unlock attempt #$ATTEMPT: $NEW_STATUS"
    if echo "$NEW_STATUS" | grep -qi "Locked"; then
      log "Still locked after attempt #$ATTEMPT - retrying per KB steps 7-8."
      log "If this repeats, the admin password may not be the FileVault-authorized user - check 'fdesetup list' after reboot."
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

SOPHOS_PLIST="$CURRENT_MOUNT/Library/Sophos Anti-Virus/product-info.plist"
log "Expected plist path: $SOPHOS_PLIST"

if [ ! -f "$SOPHOS_PLIST" ]; then
  log "[ERROR] Could not find: $SOPHOS_PLIST"
  log "Double-check the mount point above against the KB article before continuing."
  log "Directory listing of $CURRENT_MOUNT/Library (if accessible):"
  ls -la "$CURRENT_MOUNT/Library" 2>&1 | head -30 || true
  exit 1
fi

log "Found plist. Backing up and patching."
BACKUP="$SOPHOS_PLIST.bak.${TS}"
cp "$SOPHOS_PLIST" "$BACKUP"
log "Backup saved: $BACKUP"
plutil -insert "HomeVersion" -string "10.7.3" "$SOPHOS_PLIST"
log "Patch applied. Verifying:"
plutil -p "$SOPHOS_PLIST" | grep -i HomeVersion || log "[WARN] Could not verify HomeVersion key after insert."

# Persist the log onto the Data volume so it survives reboot into normal macOS
PERSIST_LOG="$CURRENT_MOUNT/Library/sophos_recovery_${TS}.log"
cp "$LOGFILE" "$PERSIST_LOG" 2>/dev/null && log "Log also copied to: $PERSIST_LOG (survives reboot)" || log "[WARN] Could not copy log to Data volume."

log "=== Done ==="
echo ""
echo "Next steps (manual, per the KB):"
echo "  13. Restart into normal macOS (Apple icon > Restart)."
echo "  14. Run 'Remove Sophos Anti-Virus', or the Removal tool (KBA-000003260):"
echo "      https://support.sophos.com/support/s/article/KBA-000003260"
echo "      Use the administrator password when prompted."
echo "  15. (Optional) Reinstall Sophos Anti-Virus."
echo ""
echo "If anything needs troubleshooting later, the full log is at:"
echo "  $LOGFILE  (Recovery session only - lost on reboot)"
echo "  $PERSIST_LOG  (on the Mac itself - send this if something goes wrong)"
