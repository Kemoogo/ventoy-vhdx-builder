# Ventoy Windows VHDX Builder (Cross-Platform: Linux & Windows)

An automated, interactive, and bulletproof utility to create bootable Windows VHDX files for **Ventoy (Native VHD Boot)** with a fully automated OOBE bypass.

Works seamlessly on both **Linux** (using Bash, QEMU, and wimlib) and **Windows** (using PowerShell, Diskpart, and DISM).

---

## 🚀 Key Features

- **Cross-Platform Support:** Native scripts for both **Linux** (`.sh`) and **Windows** (`.ps1` / `.bat`).
- **Direct ISO Support:** Accepts `.iso`, `.wim`, or `.esd` files directly. If an ISO is provided, it automatically mounts and finds the image inside.
- **Interactive & Smart:** Scans and displays available Windows editions (Index), and suggests sensible defaults.
- **Bypasses Windows OOBE Completely:**
  - Injects `unattend.xml` into Panther and Sysprep.
  - Automatically creates a local administrator user.
  - Enables **AutoLogon** straight to desktop.
  - Skips Microsoft account requirement, WiFi setup, privacy toggles, and EULA screens.
- **Branded & Tagged:** Injects `"portable operating system 1"` metadata into Windows setup (Organization, Owner, and Account Description).
- **Safe & Resilient (Bulletproof):**
  - **Linux:** Dynamic free NBD device allocation (`/dev/nbd*`), `udevadm`/`partx` kernel partition sync, and full signal trap cleanup (`Ctrl+C`).
  - **Windows:** Auto-elevation prompt, dynamic free drive letter allocation, native `diskpart` & `bcdboot` integration.
  - XML escaping for special characters in usernames/passwords.
  - Pre-flight free disk space checks.
- **Ventoy Ready:** Automatically downloads and prepares `ventoy_vhdboot.img` for your USB drive.

---

## 🐧 Usage on Linux

### 1. Prerequisites
Install the required packages:

**Ubuntu / Debian:**
```bash
sudo apt update
sudo apt install qemu-utils wimtools parted ntfs-3g udev wget unzip
```

**Arch Linux:**
```bash
sudo pacman -S qemu-img wimlib parted ntfs-3g udev wget unzip
```

**Fedora:**
```bash
sudo dnf install qemu-img wimtools parted ntfs-3g udev wget unzip
```

### 2. Run
```bash
chmod +x create_ventoy_vhdx.sh
./create_ventoy_vhdx.sh
```

---

## 🪟 Usage on Windows

### Option A: One-Click (Recommended)
Right-click on **`run_windows.bat`** and select **Run as administrator** (or double-click it; it will automatically request elevation).

### Option B: PowerShell
Open **PowerShell as Administrator** and run:
```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\create_ventoy_vhdx.ps1
```

---

## 📁 Ventoy USB Setup

After running the script, you will have two files in your output directory:
1. `YourImage.vhdx` (e.g., `Win11.vhdx` or `test_oobe.vhdx`)
2. `ventoy_vhdboot.img`

### Deployment Steps:
1. Open your Ventoy USB drive partition (the main storage partition).
2. Create a folder named **`ventoy`** at the root of the USB drive (if it does not already exist).
3. Copy **`ventoy_vhdboot.img`** into the **`\ventoy\`** folder:
   ```text
   X:\ventoy\ventoy_vhdboot.img
   ```
4. Copy your **`.vhdx`** file anywhere on the Ventoy USB drive.
5. Reboot your machine, boot from Ventoy, and select your `.vhdx` file!

---

## ⚙️ Parameters & Customization

The script interactively asks for:
- **Image Source:** Path to `.iso`, `.wim`, or `.esd`.
- **Edition Index:** Choice of edition (e.g., Pro, Home, Enterprise).
- **VHDX Name & Max Size:** e.g., `Win11.vhdx`, 100GB expandable (grows on demand).
- **User Account:** Desired local username, optional password, and PC name.

---

## 📜 License
MIT License. Free to use, modify, and distribute.
