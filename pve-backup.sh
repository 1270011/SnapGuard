#!/bin/bash
### View backup content:
### tar -tzf /mnt/usb/proxmox-host-20250902_1430.tar.gz | head -20
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Proxmox Host Backup with LVM Snapshots                                      #
# Runs online without server restart!                                         #
# Recovery:                                                                   #
# 1. Individual files:                                                        #
#     tar -xzf /mnt/usb/proxmox-host-20250902_1430.tar.gz -C /tmp/ etc/pve/   #
# 2. Complete disaster recovery (live system with pve chroot recommended):    #
#     mount /dev/sdb3 /mnt/usb                                                #
#     cd /                                                                    #
#     tar -xzf /mnt/usb/proxmox-host-20250902_1430.tar.gz                     #
#                                                                             #
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

set -e  # Exit on errors

# === Set PATH for cronjob ===
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# === CONFIGURATION ===
RETENTION_COUNT=2  # Number of backups to keep
SOURCE_LV="/dev/pve/root"  # The logical volume to backup

BACKUP_DATE=$(date +%Y%m%d_%H%M)
USB_MOUNT="/mnt/usb"
SNAPSHOT_NAME="pve-root-backup-${BACKUP_DATE}"
SNAPSHOT_MOUNT="/mnt/snapshot"
BACKUP_FILE="${USB_MOUNT}/proxmox-host-${BACKUP_DATE}.tar.gz"

echo "=== Proxmox Host Backup started: $(date) ==="

# Check if USB is mounted, if not mount automatically
if ! mountpoint -q "${USB_MOUNT}"; then
    echo "USB not mounted, trying to mount..."
    systemctl start usb-backup-mount.service
    sleep 5
    if ! mountpoint -q "${USB_MOUNT}"; then
        echo "ERROR: USB could not be mounted at ${USB_MOUNT}!"
        exit 1
    fi
fi

# Check if enough space in Volume Group
VG_FREE=$(/sbin/vgs --noheadings -o vg_free --units g pve | tr -d ' G' | cut -d. -f1)
if [ "${VG_FREE}" -lt 5 ]; then
    echo "WARNING: Low free storage in VG (${VG_FREE}G). Reducing snapshot size."
    SNAP_SIZE="2G"
else
    SNAP_SIZE="5G"
fi

echo "1. Creating LVM snapshot (${SNAP_SIZE})..."
/sbin/lvcreate -L ${SNAP_SIZE} -s -n "${SNAPSHOT_NAME}" "${SOURCE_LV}"

# Cleanup function in case of error
cleanup() {
    echo "Running cleanup..."
    umount "${SNAPSHOT_MOUNT}" 2>/dev/null || true
    /sbin/lvremove -f "/dev/pve/${SNAPSHOT_NAME}" 2>/dev/null || true
    rmdir "${SNAPSHOT_MOUNT}" 2>/dev/null || true
}
trap cleanup EXIT

echo "2. Mounting snapshot..."
mkdir -p "${SNAPSHOT_MOUNT}"
mount "/dev/pve/${SNAPSHOT_NAME}" "${SNAPSHOT_MOUNT}"

echo "3. Creating compressed backup..."
echo "   Target: ${BACKUP_FILE}"
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
    -C "${SNAPSHOT_MOUNT}" .

echo "4. Unmounting and removing snapshot..."
umount "${SNAPSHOT_MOUNT}"
/sbin/lvremove -f "/dev/pve/${SNAPSHOT_NAME}"
rmdir "${SNAPSHOT_MOUNT}"

# Save backup information
echo "=== Backup Info ===" > "${USB_MOUNT}/backup-info-${BACKUP_DATE}.txt"
echo "Date: $(date)" >> "${USB_MOUNT}/backup-info-${BACKUP_DATE}.txt"
echo "Host: $(hostname)" >> "${USB_MOUNT}/backup-info-${BACKUP_DATE}.txt"
echo "Proxmox Version: $(pveversion)" >> "${USB_MOUNT}/backup-info-${BACKUP_DATE}.txt"
echo "Backup File: $(basename ${BACKUP_FILE})" >> "${USB_MOUNT}/backup-info-${BACKUP_DATE}.txt"
echo "Size: $(ls -lh ${BACKUP_FILE} | awk '{print $5}')" >> "${USB_MOUNT}/backup-info-${BACKUP_DATE}.txt"

# Reset trap (successfully completed)
trap - EXIT

echo "=== Backup successfully completed: $(date) ==="
echo "Backup saved: ${BACKUP_FILE}"
echo "Size: $(ls -lh ${BACKUP_FILE} | awk '{print $5}')"

echo "5. Checking retention (keeping ${RETENTION_COUNT} backups)..."

# Delete old backups (keep only the newest RETENTION_COUNT)
cd "${USB_MOUNT}"

# Delete old tar.gz backup files
if ls proxmox-host-*.tar.gz >/dev/null 2>&1; then
    ls -t proxmox-host-*.tar.gz | tail -n +$((RETENTION_COUNT + 1)) | while read backup_file; do
        echo "Deleting old backup: ${backup_file}"
        rm -f "${backup_file}"
    done
fi

# Delete corresponding info files
if ls backup-info-*.txt >/dev/null 2>&1; then
    ls -t backup-info-*.txt | tail -n +$((RETENTION_COUNT + 1)) | while read info_file; do
        echo "Deleting old info file: ${info_file}"
        rm -f "${info_file}"
    done
fi

echo "Remaining backups:"
ls -lht proxmox-host-*.tar.gz 2>/dev/null || echo "No backup files found"
