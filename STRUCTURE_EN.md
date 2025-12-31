# Secret NAS Directory Structure

**Language**: [日本語](STRUCTURE.md) | English

## 📁 Overall Project Structure

```
secret_nas/
├── 📄 README.md                    # Project documentation
├── 📄 STRUCTURE.md                 # This file (directory structure explanation)
│
├── 🚀 Deployment files (Deploy to Raspberry Pi)
│   ├── setup.sh                    # Main setup script
│   ├── src/                        # Python source code
│   │   ├── monitor.py              # Monitoring daemon
│   │   ├── access_tracker.py       # Access tracking
│   │   ├── secure_wipe.py          # Secure erasure
│   │   ├── notifier.py             # Email notifications
│   │   ├── config_loader.py        # Configuration management
│   │   └── logger.py               # Logging
│   ├── config/                     # Configuration templates
│   │   └── smb.conf.template       # Samba configuration
│   ├── systemd/                    # systemd units
│   │   ├── nas-monitor.service     # Monitor service definition
│   │   └── smbd-wait-mount.service # Samba mount wait service
│   └── scripts/                    # Test scripts for Raspberry Pi
│       ├── quick-test.sh           # Quick test
│       └── test-all.sh             # Integration test
│
├── 🛠️ Development/test files (Local environment only)
│   ├── deploy.sh                   # Deploy package creation script
│   ├── Dockerfile                  # Docker test environment
│   ├── docker-compose.yml          # Docker Compose configuration
│   ├── .dockerignore               # Exclude from Docker build
│   ├── .gitignore                  # Exclude from Git
│   └── scripts/                    # Development test scripts
│       ├── test-docker.sh          # Docker test launcher
│       ├── test-local.sh           # Loopback device test
│       └── test-modules.sh         # Python module unit test
│
└── 📦 Generated directories (excluded by .gitignore)
    ├── deploy/                     # Deploy package temporary directory
    ├── test-storage/               # Docker test storage
    ├── test-local/                 # Local test data
    └── *.tar.gz                    # Deploy archive
```

---

## 🚀 Files to Deploy to Raspberry Pi

Only the following files are needed on Raspberry Pi:

### Required Files
```
setup.sh                            # Setup script
README.md                           # Usage instructions
src/monitor.py                      # Monitoring daemon
src/access_tracker.py               # Access tracking
src/secure_wipe.py                  # Secure erasure
src/notifier.py                     # Notifications
src/config_loader.py                # Configuration loader
src/logger.py                       # Logging
config/smb.conf.template            # Samba configuration template
systemd/nas-monitor.service         # systemd service
systemd/smbd-wait-mount.service     # Samba mount wait service
scripts/quick-test.sh               # Quick test
scripts/test-all.sh                 # Integration test
```

### Deployment Size
- **Compressed**: ~15-20KB
- **Extracted**: ~50-60KB

---

## 🛠️ Files Used Only in Development Environment

The following are not needed on Raspberry Pi:

### Test/Development Tools
```
deploy.sh                           # Deploy package creation
Dockerfile                          # Docker test environment
docker-compose.yml                  # Docker Compose configuration
.dockerignore                       # Docker exclusions
.gitignore                          # Git exclusions
scripts/test-docker.sh              # Docker test
scripts/test-local.sh               # Loopback device test
scripts/test-modules.sh             # Module unit test
```

---

## 📦 Deployment Methods

### Method 1: Using deploy.sh (Recommended)

```bash
# On development machine
./deploy.sh

# Transfer to Raspberry Pi
scp secret_nas_deploy.tar.gz pi@pi.local:~/

# On Raspberry Pi
ssh pi@pi.local
mkdir -p ~/secret_nas
tar -xzf secret_nas_deploy.tar.gz -C ~/secret_nas
cd ~/secret_nas
sudo ./setup.sh
```

### Method 2: Direct Transfer

```bash
# On development machine (only necessary files)
scp -r setup.sh src config systemd scripts README.md pi@pi.local:~/secret_nas/

# On Raspberry Pi
ssh pi@pi.local
cd ~/secret_nas
sudo ./setup.sh
```

---

## 🧪 Test Environments

### Local Testing (Development Machine)

```bash
# Python module test (fastest)
./scripts/test-modules.sh

# Complete test with Docker
./scripts/test-docker.sh

# Loopback device test (Linux/Mac)
sudo ./scripts/test-local.sh
```

### Raspberry Pi Testing

```bash
# Quick test
sudo ./scripts/quick-test.sh

# Integration test
sudo ./scripts/test-all.sh
```

---

## 🗂️ Files Generated on Raspberry Pi

After setup, the following files are created on Raspberry Pi:

```
/opt/nas-monitor/                   # Installation directory
├── src/                            # Python modules
│   ├── monitor.py
│   ├── access_tracker.py
│   ├── secure_wipe.py
│   ├── notifier.py
│   ├── config_loader.py
│   └── logger.py

/etc/nas-monitor/                   # Configuration directory
└── config.json                     # Runtime configuration

/var/lib/nas-monitor/               # State directory
├── last_access.json                # Access history
└── notification_state.json         # Notification state

/etc/systemd/system/                # systemd service
└── nas-monitor.service

/etc/samba/                         # Samba configuration
└── smb.conf                        # Samba configuration file

/var/log/samba/                     # Log directory
└── audit.log                       # Audit log

/root/.nas-keyfile                  # LUKS encryption key (IMPORTANT!)

/mnt/secure_nas/                    # Mount point
└── (Encrypted USB storage)
```

---

## 🔒 Security Notes

### Recommended Backups
- `/root/.nas-keyfile` - Encryption key (unrecoverable if lost)

### No Backup Needed
- `/var/lib/nas-monitor/` - State files (can be regenerated)
- `/var/log/samba/` - Log files

---

## 📊 File Size Estimates

| Category | File Count | Size |
|----------|-----------|------|
| Deploy files (compressed) | 1 | 15-20KB |
| Deploy files (extracted) | 13 | 50-60KB |
| After installation | - | ~100KB |
| Config/state files | - | 1-5KB |
| Log files (daily) | - | 10-50KB |

**Total**: Under 200KB on Raspberry Pi
