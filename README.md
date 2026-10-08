# Ventoy VHDX Builder for Windows (Linux Native)

A powerful, interactive, and bulletproof Bash script to create a bootable Windows VHDX directly inside Linux for use with **Ventoy** (Native VHD Boot).

It automates image applying (`install.wim` / `install.esd` / directly from `.iso`), partition creation, UEFI boot files configuration, OOBE bypass with an unattended answer file (`portable operating system 1`), and automatic setup of the required Ventoy VHD plugin.

---

## Features

- **100% Linux Native:** No Windows VM or WinPE needed.
- **Direct ISO Support:** Accepts `.iso`, `.wim`, or `.esd` files directly.
- **Interactive & Smart:** Scans and lists available Windows editions (Index), and suggests sensible defaults.
- **Bypasses Windows OOBE:** Automatically skips Microsoft account creation, telemetry, questions, and sets up a local administrator account with AutoLogon.
- **Branded & Tagged:** Injects `"portable operating system 1"` metadata into Windows setup.
- **Kernel-Safe & Bulletproof:**
  - Dynamically finds available `/dev/nbd*` devices.
  - Mitigates kernel partition table race conditions using `udevadm` and `partx`.
  - XML escaping for special characters in usernames/passwords.
  - Safe error trapping and cleanup on exit/interruption.
  - Pre-flight free disk space checks.
- **Ventoy Ready:** Auto-downloads and prepares `ventoy_vhdboot.img`.

---

## Prerequisites

Install required Linux utilities:

### Ubuntu / Debian:
```bash
sudo apt update
sudo apt install qemu-utils wimtools parted ntfs-3g udev wget unzip
```

### Arch Linux:
```bash
sudo pacman -S qemu-img wimlib parted ntfs-3g udev wget unzip
```

### Fedora:
```bash
sudo dnf install qemu-img wimtools parted ntfs-3g udev wget unzip
```

---

## How to Use

1. Clone this repository:
   ```bash
   git clone https://github.com/<your-username>/ventoy-vhdx-builder.git
   cd ventoy-vhdx-builder
   ```

2. Make the script executable and run:
   ```bash
   chmod +x create_ventoy_vhdx.sh
   ./create_ventoy_vhdx.sh
   ```

3. Follow the interactive prompts:
   - Provide the path to your Windows ISO or `install.wim`.
   - Choose the Windows edition index.
   - Specify VHDX filename, expandable size, username, and password.

---

## Ventoy Setup

Once the script completes, you will have two files:
1. `YourImage.vhdx`
2. `ventoy_vhdboot.img`

### On your Ventoy USB drive:
1. Create a directory named `ventoy` in the root of the Ventoy partition if it doesn't already exist.
2. Copy `ventoy_vhdboot.img` into `/ventoy/ventoy_vhdboot.img`.
3. Copy your `.vhdx` file anywhere on the Ventoy USB drive.
4. Reboot, choose the `.vhdx` file in Ventoy, and boot into Windows!

---

## License
MIT License.
