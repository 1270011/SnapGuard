#!/bin/bash
### Backup-Inhalt anschauen:
### tar -tzf /mnt/usb/proxmox-host-20250902_1430.tar.gz | head -20
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Proxmox Host Backup mit LVM-Snapshots                                       #
# Läuft online ohne Server-Neustart!                                          #
# Recovery:                                                                   #
# 1. Einzelne Dateien:                                                        #
#     tar -xzf /mnt/usb/proxmox-host-20250902_1430.tar.gz -C /tmp/ etc/pve/   #
# 2. Komplette disaster (live sys with pve chroot recommendet) recovery:      #
#     mount /dev/sdb3 /mnt/usb                                                #
#     cd /                                                                    #
#     tar -xzf /mnt/usb/proxmox-host-20250902_1430.tar.gz                     #
#                                                                             #
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

set -e  # Exit bei Fehlern

# === PATH für Cronjob setzen ===
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# === KONFIGURATION ===
RETENTION_COUNT=9  # Anzahl der Backups die behalten werden sollen
SOURCE_LV="/dev/pve/root"  # Das zu sichernde Logical Volume

BACKUP_DATE=$(date +%Y%m%d_%H%M)
USB_MOUNT="/mnt/usb"
SNAPSHOT_NAME="pve-root-backup-${BACKUP_DATE}"
SNAPSHOT_MOUNT="/mnt/snapshot"
BACKUP_FILE="${USB_MOUNT}/proxmox-host-${BACKUP_DATE}.tar.gz"

echo "=== Proxmox Host Backup gestartet: $(date) ==="

# Prüfen ob USB gemountet ist, falls nicht automatisch mounten
if ! mountpoint -q "${USB_MOUNT}"; then
    echo "USB nicht gemountet, versuche zu mounten..."
    systemctl start usb-backup-mount.service
    sleep 5
    if ! mountpoint -q "${USB_MOUNT}"; then
        echo "FEHLER: USB konnte nicht unter ${USB_MOUNT} gemountet werden!"
        exit 1
    fi
fi

# Prüfen ob genug Platz im Volume Group
VG_FREE=$(/sbin/vgs --noheadings -o vg_free --units g pve | tr -d ' G' | cut -d. -f1)
if [ "${VG_FREE}" -lt 5 ]; then
    echo "WARNUNG: Wenig freier Speicher in VG (${VG_FREE}G). Reduziere Snapshot-Größe."
    SNAP_SIZE="2G"
else
    SNAP_SIZE="5G"
fi

echo "1. Erstelle LVM-Snapshot (${SNAP_SIZE})..."
/sbin/lvcreate -L ${SNAP_SIZE} -s -n "${SNAPSHOT_NAME}" "${SOURCE_LV}"

# Cleanup-Funktion für den Fall eines Fehlers
cleanup() {
    echo "Cleanup wird ausgeführt..."
    
    # Sicherstellen, dass wir nicht im Snapshot-Verzeichnis sind
    cd /
    
    # Forciertes Unmount mit mehreren Versuchen
    for i in {1..3}; do
        if mountpoint -q "${SNAPSHOT_MOUNT}" 2>/dev/null; then
            echo "Versuch $i: Unmounte ${SNAPSHOT_MOUNT}..."
            # Erst normal versuchen
            umount "${SNAPSHOT_MOUNT}" 2>/dev/null && break || true
            # Bei Bedarf lazy unmount verwenden
            umount -l "${SNAPSHOT_MOUNT}" 2>/dev/null && break || true
            sleep 2
        fi
    done
    
    # LV entfernen falls vorhanden
    if /sbin/lvs "/dev/pve/${SNAPSHOT_NAME}" >/dev/null 2>&1; then
        echo "Entferne Snapshot ${SNAPSHOT_NAME}..."
        /sbin/lvremove -f "/dev/pve/${SNAPSHOT_NAME}" 2>/dev/null || true
    fi
    
    # Verzeichnis entfernen
    rmdir "${SNAPSHOT_MOUNT}" 2>/dev/null || true
}
trap cleanup EXIT

echo "2. Mounte Snapshot..."
mkdir -p "${SNAPSHOT_MOUNT}"
mount -o ro "/dev/pve/${SNAPSHOT_NAME}" "${SNAPSHOT_MOUNT}"

echo "3. Erstelle komprimiertes Backup..."
echo "   Ziel: ${BACKUP_FILE}"

# Sicherstellen, dass wir nicht im Snapshot-Verzeichnis arbeiten
cd /

# Tar mit besserer Fehlerbehandlung
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
    --warning=no-file-changed \
    --warning=no-file-removed \
    -C "${SNAPSHOT_MOUNT}" . || {
        echo "WARNUNG: tar hatte Probleme (Exit-Code: $?), aber Backup wurde erstellt"
    }

# Sync um sicherzustellen, dass alle Daten geschrieben wurden
sync

echo "4. Unmounte und lösche Snapshot..."

# Sicherstellen, dass wir nicht im Snapshot-Verzeichnis sind
cd /

# Warte kurz, falls noch Prozesse aktiv sind
sleep 2

# Unmount mit mehreren Versuchen
UNMOUNT_SUCCESS=false
for i in {1..5}; do
    if mountpoint -q "${SNAPSHOT_MOUNT}"; then
        echo "Unmount-Versuch $i..."
        if umount "${SNAPSHOT_MOUNT}" 2>/dev/null; then
            UNMOUNT_SUCCESS=true
            break
        fi
        # Falls normal unmount fehlschlägt, warte und versuche es erneut
        sleep 3
        # Prüfe ob noch Prozesse das Verzeichnis verwenden
        lsof "${SNAPSHOT_MOUNT}" 2>/dev/null || true
    else
        UNMOUNT_SUCCESS=true
        break
    fi
done

if [ "$UNMOUNT_SUCCESS" = false ]; then
    echo "WARNUNG: Konnte ${SNAPSHOT_MOUNT} nicht normal unmounten, verwende lazy unmount..."
    umount -l "${SNAPSHOT_MOUNT}"
fi

# LV entfernen
/sbin/lvremove -f "/dev/pve/${SNAPSHOT_NAME}"
rmdir "${SNAPSHOT_MOUNT}" 2>/dev/null || true

# Backup-Informationen speichern
echo "=== Backup Info ===" > "${USB_MOUNT}/backup-info-${BACKUP_DATE}.txt"
echo "Datum: $(date)" >> "${USB_MOUNT}/backup-info-${BACKUP_DATE}.txt"
echo "Host: $(hostname)" >> "${USB_MOUNT}/backup-info-${BACKUP_DATE}.txt"
echo "Proxmox Version: $(pveversion)" >> "${USB_MOUNT}/backup-info-${BACKUP_DATE}.txt"
echo "Backup-Datei: $(basename ${BACKUP_FILE})" >> "${USB_MOUNT}/backup-info-${BACKUP_DATE}.txt"
echo "Größe: $(ls -lh ${BACKUP_FILE} | awk '{print $5}')" >> "${USB_MOUNT}/backup-info-${BACKUP_DATE}.txt"

# Trap zurücksetzen (erfolgreich beendet)
trap - EXIT

echo "=== Backup erfolgreich beendet: $(date) ==="
echo "Backup gespeichert: ${BACKUP_FILE}"
echo "Größe: $(ls -lh ${BACKUP_FILE} | awk '{print $5}')"

echo "5. Prüfe Retention (behalte ${RETENTION_COUNT} Backups)..."

# Alte Backups löschen (behalte nur die neuesten RETENTION_COUNT)
cd "${USB_MOUNT}"

# Lösche alte tar.gz Backup-Dateien
if ls proxmox-host-*.tar.gz >/dev/null 2>&1; then
    ls -t proxmox-host-*.tar.gz | tail -n +$((RETENTION_COUNT + 1)) | while read backup_file; do
        echo "Lösche altes Backup: ${backup_file}"
        rm -f "${backup_file}"
    done
fi

# Lösche entsprechende Info-Dateien
if ls backup-info-*.txt >/dev/null 2>&1; then
    ls -t backup-info-*.txt | tail -n +$((RETENTION_COUNT + 1)) | while read info_file; do
        echo "Lösche alte Info-Datei: ${info_file}"
        rm -f "${info_file}"
    done
fi

echo "Verbleibende Backups:"
ls -lht proxmox-host-*.tar.gz 2>/dev/null || echo "Keine Backup-Dateien gefunden"

# Abschließende Prüfung ob noch Snapshots existieren
echo ""
echo "6. Prüfe auf verwaiste Snapshots..."
ORPHANED_SNAPSHOTS=$(/sbin/lvs --noheadings -o lv_name | grep "pve-root-backup-" 2>/dev/null || true)
if [ -n "$ORPHANED_SNAPSHOTS" ]; then
    echo "WARNUNG: Folgende verwaiste Snapshots gefunden:"
    echo "$ORPHANED_SNAPSHOTS"
    echo "Diese können mit 'lvremove -f /dev/pve/[snapshot-name]' entfernt werden"
else
    echo "Keine verwaisten Snapshots gefunden - alles sauber!"
fi
