# Secret NAS

Secure NAS system with auto-wipe functionality for Raspberry Pi

**Language**: [日本語](README.md) | English

> 📁 **Directory Structure and Deployment**: See [STRUCTURE_EN.md](STRUCTURE_EN.md) for details

## Overview

Secret NAS is a network storage system that automatically and completely erases data after a configurable period of inactivity (default: 30 days).

### Key Features

- **LUKS Encryption**: Entire USB storage encrypted with AES-256
- **Auto-Wipe**: Encryption key automatically deleted after configurable days (default: 30) of inactivity (data becomes permanently unrecoverable)
- **Progressive Warnings**: Email notifications 7, 3, and 1 days before erasure (automatically adjusted based on configured days)
- **Fast Erasure**: Only deletes keyfile (completes in seconds even for large storage)
- **Physical Theft Protection**: Encrypted USB remains unreadable even if removed

### Technology Stack

- **OS**: Raspberry Pi OS (Debian-based)
- **Encryption**: LUKS (dm-crypt)
- **NAS**: Samba (SMB/CIFS)
- **Monitoring**: Python 3 + systemd
- **Notifications**: SMTP (Gmail compatible)

## Requirements

### Hardware

- Raspberry Pi (Zero W/WH, 3, 4, 5, etc.)
- microSD card (16GB+ recommended)
- USB external storage (USB HDD/SSD/flash drive)
- Power adapter
- (Optional) Network connection (Wi-Fi or USB-Ethernet)

### Software

- Raspberry Pi OS Lite (latest version)
- Internet connection (for setup)

## Setup

### 1. Install Raspberry Pi OS

1. Write Raspberry Pi OS Lite to microSD card using Raspberry Pi Imager
2. Enable SSH (create `/boot/ssh` file)
3. Configure Wi-Fi (`/boot/wpa_supplicant.conf`)
4. Boot Raspberry Pi

### 2. Install Secret NAS

#### Method 1: Direct Install from GitHub (Most Recommended) ⭐

```bash
# SSH to Raspberry Pi
ssh pi@raspberrypi.local

# Install Git
sudo apt update
sudo apt install -y git

# Clone repository
git clone https://github.com/cathandnya/secret_nas.git
cd secret_nas

# Run setup
sudo ./setup.sh
```

**Benefits**:
- Get latest version directly
- Easy updates (`git pull`)
- Simplest procedure

#### Method 2: Download with curl (Without Git)

```bash
# SSH to Raspberry Pi
ssh pi@raspberrypi.local

# Download repository
curl -L https://github.com/cathandnya/secret_nas/archive/refs/heads/main.tar.gz -o secret_nas.tar.gz

# Extract
tar -xzf secret_nas.tar.gz
cd secret_nas-main

# Run setup
sudo ./setup.sh
```

#### Method 3: Use Deploy Package (For Local Development)

```bash
# On development machine, create deploy package
cd /path/to/secret_nas
./deploy.sh

# Transfer to Raspberry Pi (~20KB)
scp secret_nas_deploy.tar.gz pi@raspberrypi.local:~/

# SSH to Raspberry Pi
ssh pi@raspberrypi.local

# Extract and setup
tar -xzf secret_nas_deploy.tar.gz
cd secret_nas
sudo ./setup.sh
```

### 3. Interactive Setup

The setup script will interactively ask for:

1. **USB Device Selection**: USB storage to encrypt
2. **NAS Username**: Username for Samba access
3. **Samba Password**: Password for network access
4. **Days Until Deletion**: Inactivity period before auto-deletion (default: 30 days)
   - Warning days are automatically calculated based on input
   - Example: 30 days → warnings on days 23, 27, 29
   - Example: 14 days → warnings on days 7, 11, 13
   - Example: 7 days → warnings on days 1, 4, 6
5. **Email Notification Settings** (Optional):
   - Recipient email address
   - Sender email address
   - SMTP server (Gmail: `smtp.gmail.com`)
   - SMTP port (587)
   - SMTP username
   - SMTP password (app-specific password for Gmail)

### 4. Get Gmail App Password (If Using Email Notifications)

1. Visit [Google Account](https://myaccount.google.com/)
2. Enable Security > 2-Step Verification
3. Generate new password at Security > App Passwords
4. Enter generated password during setup

## Usage

### Accessing the NAS

#### Windows

```
# If hostname is raspberrypi
\\raspberrypi\secure_share

# If hostname is pi
\\pi\secure_share
```

Enter in Explorer address bar, then enter username and password

#### Mac

```
# If hostname is raspberrypi
smb://raspberrypi.local/secure_share

# If hostname is pi
smb://pi.local/secure_share
```

Finder > Go > Connect to Server, enter address above

#### Linux

```bash
# If hostname is raspberrypi
smb://raspberrypi.local/secure_share

# If hostname is pi
smb://pi.local/secure_share

# Command line (adjust hostname accordingly)
smbclient //raspberrypi/secure_share -U username
smbclient //pi/secure_share -U username
```

### Managing Monitor Service

```bash
# Check service status
sudo systemctl status nas-monitor

# View logs (real-time)
sudo journalctl -u nas-monitor -f

# Check last access time
sudo cat /var/lib/nas-monitor/last_access.json

# Restart service
sudo systemctl restart nas-monitor

# Stop service
sudo systemctl stop nas-monitor

# Start service
sudo systemctl start nas-monitor
```

### Changing Configuration

#### Change Deletion Days

To change deletion period during operation, edit configuration file.

**Steps**:

1. Edit configuration file:
```bash
sudo nano /etc/nas-monitor/config.json
```

2. Modify `inactivity_days` and `warning_days`:

Configuration file example: `/etc/nas-monitor/config.json`

```json
{
  "mount_point": "/mnt/secure_nas",
  "device": "/dev/sda",
  "keyfile": "/root/.nas-keyfile",
  "inactivity_days": 30,
  "warning_days": [23, 27, 29],
  "notification": {
    "enabled": true,
    "method": "email",
    "email": {
      "to": "user@example.com",
      "from": "raspberrypi@example.com",
      "smtp_server": "smtp.gmail.com",
      "smtp_port": 587,
      "username": "your-email@gmail.com",
      "password": "your-app-password",
      "use_tls": true
    }
  }
}
```

3. Restart service (to apply configuration):
```bash
sudo systemctl restart nas-monitor
```

4. Verify configuration was applied:
```bash
sudo journalctl -u nas-monitor -n 20
```

## Security Mechanism

### LUKS Encryption

1. Entire USB encrypted with AES-256
2. Encryption key stored in `/root/.nas-keyfile` (on SD card)
3. Automatically decrypted at boot using keyfile
4. Unreadable on other PCs without key

### Auto-Wipe

1. Real-time monitoring of Samba access logs
2. Updates last access time when access detected
3. Checks elapsed days every hour
4. 30 days without access → keyfile and LUKS header completely destroyed
5. After header destruction, USB is cryptographically unrecoverable (even with key backup)

### Security Constraints

**Possibility of Decryption with Physical Access**:

To enable auto-mount functionality, this system stores the encryption keyfile on the SD card (system disk) at `/root/.nas-keyfile`. Therefore, third parties can decrypt data in the following situations:

1. **Both SD card and USB storage are physically obtained**
2. Mount SD card on another Linux machine
3. Obtain `/root/.nas-keyfile`
4. Decrypt USB storage using that keyfile

**Countermeasures**:
- **Physical security** is most important (keep device in secure location)
- For higher security requirements:
  - Require passphrase input (disables auto-mount)
  - Use TPM/hardware security module (difficult on Raspberry Pi)
  - Implement 2-factor authentication (physical key + SD card)

**Important**: This system is designed for "auto-deletion after period of inactivity". If protection against physical theft is the primary goal, consider passphrase-required LUKS configuration.

### Progressive Notifications

Notification timing is automatically adjusted based on deletion period:

**30-day deletion** (default):
- **Day 23**: "Warning: Data will be erased in 7 days"
- **Day 27**: "Urgent warning: Data will be erased in 3 days"
- **Day 29**: "Final warning: Data will be erased tomorrow"
- **Day 30**: Auto-erasure executed

**14-day deletion**:
- **Day 7**: "Warning: Data will be erased in 7 days"
- **Day 11**: "Urgent warning: Data will be erased in 3 days"
- **Day 13**: "Final warning: Data will be erased tomorrow"
- **Day 14**: Auto-erasure executed

**7-day deletion**:
- **Day 1**: "Warning: Data will be erased in 6 days"
- **Day 4**: "Urgent warning: Data will be erased in 3 days"
- **Day 6**: "Final warning: Data will be erased tomorrow"
- **Day 7**: Auto-erasure executed

## Troubleshooting

### Monitor Service Won't Start

```bash
# Check detailed logs
sudo journalctl -u nas-monitor -n 100

# Verify configuration file
sudo cat /etc/nas-monitor/config.json

# Start manually to check errors
cd /opt/nas-monitor
sudo python3 src/monitor.py --config /etc/nas-monitor/config.json
```

### Cannot Access NAS

**Basic checks**:

```bash
# 1. Check Samba service status
sudo systemctl status smbd

# 2. Start service if stopped
sudo systemctl start smbd
sudo systemctl enable smbd

# 3. Check network connection
ping raspberrypi.local  # or your hostname
ping 192.168.1.X  # check with IP address

# 4. Check Samba configuration syntax
sudo testparm -s
```

### Email Notifications Not Received

```bash
# Test notifications
cd /opt/nas-monitor
python3 src/notifier.py \
  --to your-email@example.com \
  --from raspberrypi@example.com \
  --smtp-server smtp.gmail.com \
  --smtp-port 587 \
  --username your-email@gmail.com \
  --password your-app-password \
  --test-only
```

## Emergency Operations

### Reset Timer (Keep Data)

Simply access any file on the NAS to automatically reset.
Or manually reset:

```bash
sudo systemctl restart nas-monitor
```

### Test Wipe Behavior (Development/Testing)

Set last access date to the past to immediately test wipe behavior:

```bash
# Set to 31 days ago (default 30 days triggers wipe)
sudo ./scripts/force-wipe-test.sh 31

# Restart service to trigger immediate check
sudo systemctl restart nas-monitor

# Monitor logs in real-time
sudo journalctl -u nas-monitor -f
```

**Warning**:
- This script will actually delete data
- After testing, re-setup USB with `./scripts/re-encrypt-usb.sh`
- Do not use in production environment

### Manual Data Erasure

```bash
# Stop monitor service
sudo systemctl stop nas-monitor

# Execute manual erasure (WARNING: Unrecoverable!)
cd /opt/nas-monitor
sudo python3 src/secure_wipe.py \
  --device /dev/sda \
  --keyfile /root/.nas-keyfile \
  --mount-point /mnt/secure_nas
```

### Keyfile Backup

To prepare for SD card failure, you can backup the keyfile:

```bash
# Create backup (store in secure location)
sudo cp /root/.nas-keyfile /path/to/safe/location/nas-keyfile.backup

# Restore
sudo cp /path/to/safe/location/nas-keyfile.backup /root/.nas-keyfile
sudo chmod 600 /root/.nas-keyfile
```

**Warning**: Creating backups reduces security. Store backups in physically secure locations (such as another encrypted USB).

## Uninstall

```bash
# Stop and disable monitor service
sudo systemctl stop nas-monitor
sudo systemctl disable nas-monitor

# Remove service file
sudo rm /etc/systemd/system/nas-monitor.service
sudo systemctl daemon-reload

# Remove installation files
sudo rm -rf /opt/nas-monitor
sudo rm -rf /etc/nas-monitor
sudo rm -rf /var/lib/nas-monitor

# Restore Samba configuration
sudo cp /etc/samba/smb.conf.backup.* /etc/samba/smb.conf
sudo systemctl restart smbd

# Close LUKS device
sudo umount /mnt/secure_nas
sudo cryptsetup close secure_nas_crypt

# Remove entries from /etc/fstab and /etc/crypttab
sudo vi /etc/fstab
sudo vi /etc/crypttab
```

## Performance Optimization

Secret NAS is optimized to run on Raspberry Pi's limited resources:

- Samba max connections: 10
- Monitor daemon memory limit: 50MB
- CPU usage limit: 20%
- Check interval: 1 hour
- Log level: Minimal

For higher performance, use Raspberry Pi 3/4.

## License

MIT License

## Disclaimer

This software automatically and completely deletes data. Once deleted, data cannot be recovered. Use at your own risk. The author assumes no responsibility for data loss or other damages.
