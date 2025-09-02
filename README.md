# 🚀 SnapGuard - Advanced Proxmox Host Backup

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Bash](https://img.shields.io/badge/Shell-Bash-green.svg)](https://www.gnu.org/software/bash/)
[![Proxmox](https://img.shields.io/badge/Platform-Proxmox_VE-orange.svg)](https://proxmox.com/)

**SnapGuard** is a professional-grade and customizable backup solution for Proxmox hosts that creates consistent, reliable backups using LVM snapshots without requiring downtime or server restarts.

## ✨ Features

- 🔄 **Zero-Downtime Backups** - Runs online without interrupting services
- 📸 **LVM Snapshot Technology** - Creates consistent point-in-time backups
- 🗜️ **Intelligent Compression** - Optimized tar.gz compression for space efficiency
- 🔄 **Automatic Retention** - Configurable backup rotation with automatic cleanup
- 💾 **Smart Storage Management** - Dynamic snapshot sizing based on available space
- 🛡️ **Error Recovery** - Robust cleanup mechanisms for failed operations
- 📊 **Backup Metadata** - Creates info files with backup details
- ⚡ **Reliable Operation** - Tested bash script with error handling

## 🔧 Requirements

- Proxmox VE server with LVM storage
- USB/External storage device for backups
- Bash shell environment
- Root privileges

## 🚀 Quick Start

### 1. Download SnapGuard

```bash
git clone https://github.com/yourusername/SnapGuard.git
cd SnapGuard
chmod +x pve-backup.sh
```

### 2. Configure Your Backup

Edit the script configuration section:

```bash
nano pve-backup.sh
```

### 3. Setup USB Mount Service (Optional)

Create a systemd service for automatic USB mounting:

```bash
# Create mount service
sudo nano /etc/systemd/system/usb-backup-mount.service
```

Add the following content:

```ini
[Unit]
Description=Mount USB Backup Drive
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/mount /dev/disk/by-label/BACKUP /mnt/usb
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

Enable the service:

```bash
sudo systemctl enable usb-backup-mount.service
```

### 4. Run Your First Backup

```bash
sudo ./pve-backup.sh
```

## ⚙️ Configuration Parameters

### Core Settings

| Parameter | Default | Description |
|-----------|---------|-------------|
| `RETENTION_COUNT` | `2` | Number of backup files to keep |
| `SOURCE_LV` | `/dev/pve/root` | Source logical volume to backup |
| `USB_MOUNT` | `/mnt/usb` | USB mount point for backup storage |

### Advanced Configuration

```bash
# === CONFIGURATION ===
RETENTION_COUNT=2              # Keep 2 most recent backups
SOURCE_LV="/dev/pve/root"      # Source logical volume
USB_MOUNT="/mnt/usb"           # USB backup destination
```

### Snapshot Sizing

The script automatically adjusts snapshot size based on available Volume Group space:
- **5GB+** free space: Uses 5GB snapshot
- **<5GB** free space: Uses 2GB snapshot (with warning)

## 🔄 Automation with Cron

### Daily Backups at 2 AM

```bash
# Daily backup with logging to file
0 2 * * * /path/to/snapguard/pve-backup.sh >> /var/log/proxmox-backup.log 2>&1
```

### Weekly Backups on Sundays

```bash
# Weekly backup every Sunday at 3:00 AM with logging
0 3 * * 0 /path/to/snapguard/pve-backup.sh >> /var/log/proxmox-backup.log 2>&1
```

## 📁 File Structure

After running, SnapGuard creates the following files:

```
/mnt/usb/
├── proxmox-host-20250902_1430.tar.gz    # Compressed backup
├── backup-info-20250902_1430.txt        # Backup metadata
├── proxmox-host-20250901_1430.tar.gz    # Previous backup
└── backup-info-20250901_1430.txt        # Previous metadata
```

## 🔄 Recovery Procedures

### 1. Restore Individual Files

```bash
# Extract specific files (e.g., Proxmox configuration)
tar -xzf /mnt/usb/proxmox-host-20250902_1430.tar.gz -C /tmp/ etc/pve/

# Copy restored files to their location
cp -r /tmp/etc/pve/* /etc/pve/
```

### 2. Complete Disaster Recovery

**⚠️ Warning: This will overwrite your entire system!**

```bash
# Boot from live system (Proxmox installer or rescue system)
# Mount your backup drive
mount /dev/sdb3 /mnt/usb

# Extract everything to root filesystem
cd /
tar -xzf /mnt/usb/proxmox-host-20250902_1430.tar.gz

# Recommended: Use chroot for safer recovery
# mount /dev/your-root-device /mnt/recovery
# cd /mnt/recovery
# tar -xzf /mnt/usb/proxmox-host-20250902_1430.tar.gz
```

### 3. View Backup Contents

```bash
# List all files in backup
tar -tzf /mnt/usb/proxmox-host-20250902_1430.tar.gz

# View first 20 files
tar -tzf /mnt/usb/proxmox-host-20250902_1430.tar.gz | head -20

# Search for specific files
tar -tzf /mnt/usb/proxmox-host-20250902_1430.tar.gz | grep -i "config"
```

## 🔍 Monitoring and Output

### Check Backup Status

```bash
# View recent backup information
cat /mnt/usb/backup-info-*.txt

# Check what the script outputs (no built-in logging)
# Use shell redirection when running manually:
./pve-backup.sh 2>&1 | tee backup-run.log
```

### Monitor Cron Jobs

```bash
# View cron job output (if you redirect to log file)
tail -f /var/log/proxmox-backup.log

# Check cron job status
grep CRON /var/log/syslog | grep proxmox-snapshot-backup
```

### Backup Verification

```bash
# Manual backup integrity check
tar -tzf /mnt/usb/proxmox-host-20250902_1430.tar.gz > /dev/null && echo "Backup OK" || echo "Backup CORRUPTED"

# Check backup size and date
ls -lah /mnt/usb/proxmox-host-*.tar.gz

# Note: The script doesn't include automatic verification
# Consider adding manual checks to your workflow
```

## 🛠️ Troubleshooting

### Common Issues

**USB Mount Failed**
```bash
# Check if USB device is detected
lsblk
fdisk -l

# Manual mount
mount /dev/sdb1 /mnt/usb
```

**Insufficient Space**
```bash
# Check volume group space
vgs

# Check USB space
df -h /mnt/usb

# Clean old backups manually
rm /mnt/usb/proxmox-host-old-date.tar.gz
```

**Snapshot Creation Failed**
```bash
# Check existing snapshots
lvs

# Remove stuck snapshots
lvremove /dev/pve/old-snapshot-name
```

### Debug Mode

Run with verbose bash output:

```bash
# Show all commands being executed
bash -x ./pve-backup.sh

# Capture all output to file
./pve-backup.sh 2>&1 | tee debug-output.log
```

## 🔒 Security Considerations

- Store backup USB drives securely
- Consider encrypting sensitive backup data
- Regularly test recovery procedures
- Monitor backup logs for errors
- Ensure proper file permissions (root access required)

## 📋 Best Practices

1. **Test Recovery Regularly** - Verify backups can be restored
2. **Monitor Disk Space** - Ensure adequate space for snapshots  
3. **Rotate Storage Media** - Use multiple USB drives for redundancy
4. **Add Logging** - Redirect output to log files when using cron
5. **Manual Verification** - Periodically check backup integrity
6. **Document Changes** - Keep notes of system modifications

## 🤝 Contributing

Contributions are welcome! Please feel free to submit issues, feature requests, or pull requests.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## 📝 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 💡 Support

- 📖 **Documentation**: Check this README and inline comments
- 🐛 **Bug Reports**: Use GitHub Issues
- 💬 **Discussions**: Use GitHub Discussions for questions
- 📧 **Contact**: Open an issue for support requests

## 🌟 Show Your Support

If SnapGuard helps you secure your Proxmox environment, please give it a ⭐️ on GitHub!

---

**Made with ❤️ for the Proxmox community**

*SnapGuard - Because your data deserves professional protection.*
