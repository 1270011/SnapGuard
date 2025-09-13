#!/bin/bash
OUTPUT=$(/bin/bash /root/scripts/pve-backup.sh 2>&1)
echo "$OUTPUT" | tee -a /var/log/pve-backup.log
echo "$OUTPUT" | mail -s "Proxmox VE Backup $(date +%Y-%m-%d)" pvemonitoring@example.com  # adjust your mail accordingly
