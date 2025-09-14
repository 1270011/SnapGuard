#!/bin/bash
### View backup contents:
### tar -tzf /mnt/usb/proxmox-host-20250902_1430.tar.gz | head -20
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# IMPROVED Proxmox Host Backup with LVM Snapshots + Separate PVE Config     #
# Runs online without server restart!                                        #
# NOW PROPERLY BACKS UP /etc/pve/ CONFIGURATION                             #
# Recovery:                                                                   #
# 1. Individual files:                                                        #
#     tar -xzf /mnt/usb/proxmox-host-20250902_1430.tar.gz -C /tmp/ etc/pve/   #
# 2. Complete disaster recovery:                                              #
#     # First restore main system:                                            #
#     mount /dev/sdb3 /mnt/usb                                                #
#     mount /dev/pve/root /mnt/restore                                        #
#     tar -xzf /mnt/usb/proxmox-host-20250902_1430.tar.gz -C /mnt/restore/    #
#     # Then restore PVE config:                                              #
#     tar -xzf /mnt/usb/pve-config-20250902_1430.tar.gz -C /mnt/restore/      #
#     # Boot and initialize cluster                                           #
#                                                                             #
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

set -e  # Exit on errors

# === Set PATH for cronjob ===
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# === CONFIGURATION ===
RETENTION_COUNT=9  # Number of backups to keep
SOURCE_LV="/dev/pve/root"  # The logical volume to backup

BACKUP_DATE=$(date +%Y%m%d_%H%M)
USB_MOUNT="/mnt/usb"
SNAPSHOT_NAME="pve-root-backup-${BACKUP_DATE}"
SNAPSHOT_MOUNT="/mnt/snapshot"
BACKUP_FILE="${USB_MOUNT}/proxmox-host-${BACKUP_DATE}.tar.gz"
PVE_CONFIG_BACKUP="${USB_MOUNT}/pve-config-${BACKUP_DATE}.tar.gz"

echo "=== IMPROVED Proxmox Host Backup started: $(date) ==="

# Check if USB is mounted, if not mount automatically
if ! mountpoint -q "${USB_MOUNT}"; then
    echo "USB not mounted, trying to mount..."
    systemctl start usb-backup-mount.service || true
    sleep 5
    if ! mountpoint -q "${USB_MOUNT}"; then
        echo "ERROR: USB could not be mounted under ${USB_MOUNT}!"
        exit 1
    fi
fi

# === NEW: Check if PVE cluster filesystem is available ===
echo "0. Checking Proxmox cluster filesystem..."
if ! mountpoint -q /etc/pve 2>/dev/null; then
    echo "ERROR: /etc/pve cluster filesystem not mounted!"
    echo "Start pve-cluster service first: systemctl start pve-cluster"
    exit 1
fi
echo "Cluster filesystem check: OK"

# === NEW: Backup PVE configuration FIRST (before snapshot) ===
echo "1. Backing up Proxmox configuration..."
tar -czf "${PVE_CONFIG_BACKUP}" \
    --warning=no-file-changed \
    --warning=no-file-removed \
    /etc/pve/ \
    /etc/postfix/ \
    /etc/systemd/system/multi-user.target.wants/ \
    /root/.bashrc \
    /root/.bash_history \
    /root/scripts/ 2>/dev/null || {
        echo "WARNING: Some files in PVE config backup had issues, continuing..."
    }

echo "PVE configuration backup saved: ${PVE_CONFIG_BACKUP}"

# Check if enough space in Volume Group
VG_FREE=$(/sbin/vgs --noheadings -o vg_free --units g pve | tr -d ' G' | cut -d. -f1)
if [ "${VG_FREE}" -lt 5 ]; then
    echo "WARNING: Low free space in VG (${VG_FREE}G). Reducing snapshot size."
    SNAP_SIZE="2G"
else
    SNAP_SIZE="5G"
fi

echo "2. Create LVM snapshot (${SNAP_SIZE})..."
/sbin/lvcreate -L ${SNAP_SIZE} -s -n "${SNAPSHOT_NAME}" "${SOURCE_LV}"

# Cleanup function in case of error
cleanup() {
    echo "Cleanup is being executed..."
    
    # Make sure we're not in the snapshot directory
    cd /
    
    # Forced unmount with multiple attempts
    for i in {1..3}; do
        if mountpoint -q "${SNAPSHOT_MOUNT}" 2>/dev/null; then
            echo "Attempt $i: Unmounting ${SNAPSHOT_MOUNT}..."
            # Try normal unmount first
            umount "${SNAPSHOT_MOUNT}" 2>/dev/null && break || true
            # Use lazy unmount if needed
            umount -l "${SNAPSHOT_MOUNT}" 2>/dev/null && break || true
            sleep 2
        fi
    done
    
    # Remove LV if it exists
    if /sbin/lvs "/dev/pve/${SNAPSHOT_NAME}" >/dev/null 2>&1; then
        echo "Removing snapshot ${SNAPSHOT_NAME}..."
        /sbin/lvremove -f "/dev/pve/${SNAPSHOT_NAME}" 2>/dev/null || true
    fi
    
    # Remove directory
    rmdir "${SNAPSHOT_MOUNT}" 2>/dev/null || true
}
trap cleanup EXIT

echo "3. Mount snapshot..."
mkdir -p "${SNAPSHOT_MOUNT}"
mount -o ro "/dev/pve/${SNAPSHOT_NAME}" "${SNAPSHOT_MOUNT}"

echo "4. Create compressed system backup (without /etc/pve - already backed up separately)..."
echo "   Target: ${BACKUP_FILE}"

# Make sure we're not working in the snapshot directory
cd /

# Tar with better error handling - EXCLUDING /etc/pve since it's backed up separately
tar -czf "${BACKUP_FILE}" \
    --exclude="${SNAPSHOT_MOUNT}/dev/*" \
    --exclude="${SNAPSHOT_MOUNT}/proc/*" \
    --exclude="${SNAPSHOT_MOUNT}/sys/*" \
    --exclude="${SNAPSHOT_MOUNT}/tmp/*" \
    --exclude="${SNAPSHOT_MOUNT}/run/*" \
    --exclude="${SNAPSHOT_MOUNT}/mnt/*" \
    --exclude="${SNAPSHOT_MOUNT}/media/*" \
    --exclude="${SNAPSHOT_MOUNT}/var/lib/vz/*" \
    --exclude="${SNAPSHOT_MOUNT}/var/log/*" \
    --exclude="${SNAPSHOT_MOUNT}/etc/pve/*" \
    --warning=no-file-changed \
    --warning=no-file-removed \
    -C "${SNAPSHOT_MOUNT}" . || {
        echo "WARNING: tar had problems (Exit code: $?), but backup was created"
    }

# Sync to ensure all data is written
sync

echo "5. Unmount and delete snapshot..."

# Make sure we're not in the snapshot directory
cd /

# Wait briefly in case processes are still active
sleep 2

# Unmount with multiple attempts
UNMOUNT_SUCCESS=false
for i in {1..5}; do
    if mountpoint -q "${SNAPSHOT_MOUNT}"; then
        echo "Unmount attempt $i..."
        if umount "${SNAPSHOT_MOUNT}" 2>/dev/null; then
            UNMOUNT_SUCCESS=true
            break
        fi
        # If normal unmount fails, wait and try again
        sleep 3
        # Check if processes are still using the directory
        lsof "${SNAPSHOT_MOUNT}" 2>/dev/null || true
    else
        UNMOUNT_SUCCESS=true
        break
    fi
done

if [ "$UNMOUNT_SUCCESS" = false ]; then
    echo "WARNING: Could not unmount ${SNAPSHOT_MOUNT} normally, using lazy unmount..."
    umount -l "${SNAPSHOT_MOUNT}"
fi

# Remove LV
/sbin/lvremove -f "/dev/pve/${SNAPSHOT_NAME}"
rmdir "${SNAPSHOT_MOUNT}" 2>/dev/null || true

# Save backup information
echo "=== Backup Info ===" > "${USB_MOUNT}/backup-info-${BACKUP_DATE}.txt"
echo "Date: $(date)" >> "${USB_MOUNT}/backup-info-${BACKUP_DATE}.txt"
echo "Host: $(hostname)" >> "${USB_MOUNT}/backup-info-${BACKUP_DATE}.txt"
echo "Proxmox Version: $(pveversion)" >> "${USB_MOUNT}/backup-info-${BACKUP_DATE}.txt"
echo "System backup: $(basename ${BACKUP_FILE})" >> "${USB_MOUNT}/backup-info-${BACKUP_DATE}.txt"
echo "PVE config backup: $(basename ${PVE_CONFIG_BACKUP})" >> "${USB_MOUNT}/backup-info-${BACKUP_DATE}.txt"
echo "System backup size: $(ls -lh ${BACKUP_FILE} | awk '{print $5}')" >> "${USB_MOUNT}/backup-info-${BACKUP_DATE}.txt"
echo "PVE config size: $(ls -lh ${PVE_CONFIG_BACKUP} | awk '{print $5}')" >> "${USB_MOUNT}/backup-info-${BACKUP_DATE}.txt"

# Reset trap (successfully completed)
trap - EXIT

echo "=== Backup successfully completed: $(date) ==="
echo "System backup saved: ${BACKUP_FILE}"
echo "System backup size: $(ls -lh ${BACKUP_FILE} | awk '{print $5}')"
echo "PVE config backup saved: ${PVE_CONFIG_BACKUP}"
echo "PVE config size: $(ls -lh ${PVE_CONFIG_BACKUP} | awk '{print $5}')"

echo "6. Check retention (keep ${RETENTION_COUNT} backups)..."

# Delete old backups (keep only the newest RETENTION_COUNT)
cd "${USB_MOUNT}"

# Delete old system backup files
if ls proxmox-host-*.tar.gz >/dev/null 2>&1; then
    ls -t proxmox-host-*.tar.gz | tail -n +$((RETENTION_COUNT + 1)) | while read backup_file; do
        echo "Deleting old system backup: ${backup_file}"
        rm -f "${backup_file}"
    done
fi

# Delete old PVE config backup files
if ls pve-config-*.tar.gz >/dev/null 2>&1; then
    ls -t pve-config-*.tar.gz | tail -n +$((RETENTION_COUNT + 1)) | while read config_file; do
        echo "Deleting old config backup: ${config_file}"
        rm -f "${config_file}"
    done
fi

# Delete corresponding info files
if ls backup-info-*.txt >/dev/null 2>&1; then
    ls -t backup-info-*.txt | tail -n +$((RETENTION_COUNT + 1)) | while read info_file; do
        echo "Deleting old info file: ${info_file}"
        rm -f "${info_file}"
    done
fi

echo "Remaining system backups:"
ls -lht proxmox-host-*.tar.gz 2>/dev/null || echo "No system backup files found"
echo "Remaining config backups:"
ls -lht pve-config-*.tar.gz 2>/dev/null || echo "No config backup files found"

# Final check for remaining snapshots
echo ""
echo "7. Check for orphaned snapshots..."
ORPHANED_SNAPSHOTS=$(/sbin/lvs --noheadings -o lv_name | grep "pve-root-backup-" 2>/dev/null || true)
if [ -n "$ORPHANED_SNAPSHOTS" ]; then
    echo "WARNING: The following orphaned snapshots found:"
    echo "$ORPHANED_SNAPSHOTS"
    echo "These can be removed with 'lvremove -f /dev/pve/[snapshot-name]'"
else
    echo "No orphaned snapshots found - everything clean!"
fi

echo ""
echo "=== BACKUP SUMMARY ==="
echo "✓ System backup (OS, binaries): $(basename ${BACKUP_FILE})"
echo "✓ PVE configuration backup: $(basename ${PVE_CONFIG_BACKUP})"
echo "✓ Total backups kept: ${RETENTION_COUNT}"
echo "For recovery instructions, see script header comments."
