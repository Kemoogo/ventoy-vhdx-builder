# Ventoy Windows VHDX Builder (Cross-Platform)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Platform-Linux%20%7C%20Windows-blue.svg)]()
[![Ventoy Compatible](https://img.shields.io/badge/Ventoy-Supported-success.svg)](https://www.ventoy.net)

An automated, interactive, and bulletproof utility to generate fully configured, bootable Windows **VHDX** files designed for **Ventoy Native VHD Boot**, featuring a 100% automated **OOBE bypass** and pre-configured administrator account.

Whether you are running **Linux** or **Windows**, this tool provisions a portable, hardware-independent Windows OS directly onto a virtual disk file without needing a virtual machine (VM) or WinPE setup.

---

## 🌟 What is Ventoy & Why Boot Windows from VHDX?

### About Ventoy
[Ventoy](https://www.ventoy.net) is an open-source tool to create bootable USB drives for ISO/WIM/IMG/VHD(x)/EFI files.
* **Official Website:** [https://www.ventoy.net](https://www.ventoy.net)
* **GitHub Repository:** [ventoy/Ventoy](https://github.com/ventoy/Ventoy)
* **Ventoy VHD Boot Plugin Repo:** [ventoy/vhdiso](https://github.com/ventoy/vhdiso)

### Key Benefits of Ventoy + VHDX (Native VHD Boot)
1. **No Re-formatting Ever:** Just copy your `.vhdx` file to the USB drive alongside your existing Linux ISOs and rescue images.
2. **True Native Performance (Bare-Metal):** Unlike running a Virtual Machine, booting a VHDX runs Windows **directly on the host hardware** (CPU, GPU, RAM) with native speed.
3. **Hardware Independence (Windows-To-Go Alternative):** Modern Windows 10/11 handles plug-and-play driver discovery effortlessly across different motherboards and PCs.
4. **Dynamic Expandable Storage:** The VHDX starts small (only ~15–20 GB of actual data used) and grows dynamically up to your specified maximum (e.g. 100 GB).
5. **Instant Snapshots & Backups:** To backup or duplicate your entire OS installation, simply copy the `.vhdx` file.

---

## 🚀 What This Tool Automates

| Step | Manual Way | With This Tool |
|---|---|---|
| **VHDX Creation** | Multiple manual `diskpart` commands | One interactive question |
| **Partitioning** | Manual GPT, NTFS formatting & volume alignment | Fully automated & verified |
| **Image Extraction** | Complex `dism` or `wimapply` command line flags | Automated scan & menu selection |
| **Direct ISO Support** | Must manually extract or mount ISO | Automatically mounts ISO and finds `.wim`/`.esd` |
| **OOBE Screen Bypass** | 15–20 minutes clicking through Microsoft screens, WiFi, MSA | 100% skipped straight to Desktop |
| **User Setup** | Creating account and password | Automated local admin + AutoLogon |
| **System Branding** | Manual unattend XML crafting | Injected with `"portable operating system 1"` metadata |
| **UEFI Bootloader** | Manual EFI partition manipulation / `bcdboot` | Automatically provisioned |
| **Ventoy Plugin** | Hunting for `ventoy_vhdboot.img` on GitHub | Automatically downloaded and extracted |

---

## 🛠️ Architecture & Cross-Platform Support

This project provides native, zero-compromise implementations for both operating systems:

```
ventoy-vhdx-builder/
├── create_ventoy_vhdx.sh     # Native Linux engine (Bash, QEMU-NBD, wimlib, parted)
├── create_ventoy_vhdx.ps1    # Native Windows engine (PowerShell, Diskpart, DISM, BCDboot)
├── run_windows.bat           # Self-elevating One-Click Windows launcher
├── README.md                 # Complete documentation
├── LICENSE                   # MIT License
└── .gitignore                # Filters out heavy disk images and archives
```

---

## 🐧 Instructions for Linux Users

### 1. Prerequisites
Install the required tools for manipulating virtual disks and NTFS:

* **Ubuntu / Debian / Pop!_OS:**
  ```bash
  sudo apt update
  sudo apt install qemu-utils wimtools parted ntfs-3g udev wget unzip
  ```
* **Arch Linux / Manjaro:**
  ```bash
  sudo pacman -S qemu-img wimlib parted ntfs-3g udev wget unzip
  ```
* **Fedora / RHEL:**
  ```bash
  sudo dnf install qemu-img wimtools parted ntfs-3g udev wget unzip
  ```

### 2. Execution
```bash
git clone https://github.com/<YOUR-USERNAME>/ventoy-vhdx-builder.git
cd ventoy-vhdx-builder
chmod +x create_ventoy_vhdx.sh
./create_ventoy_vhdx.sh
```

### Linux Safety & Edge-Case Features:
* **Dynamic NBD Allocation:** Automatically searches `/dev/nbd0` through `/dev/nbd15` for the first unused slot to avoid *Device Busy* errors.
* **Kernel Sync:** Uses `udevadm settle` and `partx` to prevent partition detection race conditions.
* **Signal Trap:** Guaranteed unmounting and NBD disconnection even if interrupted via `Ctrl+C`.

---

## 🪟 Instructions for Windows Users

### Option A: One-Click Launcher (Recommended)
Simply double-click or right-click **`run_windows.bat`** and choose **Run as administrator**. It will automatically elevate privileges and launch the PowerShell builder.

### Option B: PowerShell
Open **PowerShell as Administrator** and run:
```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\create_ventoy_vhdx.ps1
```

### Windows Safety & Edge-Case Features:
* Automatic free drive letter resolution (`V:`, `W:`, etc.).
* Automated cleanup and disk detachment in a `try...finally` block.
* Direct Windows DISM and BCDboot integration.

---

## 📦 Setting Up Your Ventoy USB Drive

Once the script finishes, you will find two files in your output directory:
1. `YourImage.vhdx` (e.g., `test_oobe.vhdx`)
2. `ventoy_vhdboot.img`

### Deployment Steps:
1. Plug in your Ventoy USB drive and open its main data partition in your file manager.
2. In the root of the USB drive, create a folder named `ventoy` (lowercase):
   ```text
   USB_ROOT/
   └── ventoy/
       └── ventoy_vhdboot.img   <-- Place plugin here!
   ```
3. Copy your `.vhdx` file anywhere on the Ventoy USB drive (root or in any subfolder).
4. Reboot your computer, enter Boot Menu (F12 / F11 / F8 depending on your motherboard), boot from the Ventoy USB, and select your `.vhdx` file.

> **Note on First Boot:** On the very first boot, Windows will detect host hardware devices ("Getting devices ready..."), reboot once, process the unattended answer file, and take you directly to the desktop logged in as your configured user.

---

## 📋 The `unattend.xml` OOBE Configuration

The script generates an XML answer file placed in `\Windows\Panther\` and `\Windows\System32\Sysprep\` containing:
- **SkipMachineOOBE & SkipUserOOBE:** Suppresses consumer setup screens.
- **HideOnlineAccountScreens:** Removes forced Microsoft Account (MSA) login.
- **LocalAccounts:** Creates your designated local administrator with optional password.
- **AutoLogon:** Direct boot to Desktop.
- **Metadata Tagging:**
  - `RegisteredOwner`: `portable operating system 1`
  - `RegisteredOrganization`: `portable operating system 1`
  - `Description`: `portable operating system 1`

---

## 💡 Future Roadmap & Feature Proposals

Here are exciting enhancements that can be added:

- [ ] **Bypass Windows 11 Hardware Restrictions:** Automatic registry injection during provisioning to bypass TPM 2.0, SecureBoot, and 8GB RAM checks.
- [ ] **Pre-installed Drivers (VirtIO / Wi-Fi):** Option to slipstream Wi-Fi or storage drivers into the offline image via `dism` / `wimlib`.
- [ ] **Fixed vs Expandable Selector:** Option to toggle between dynamic allocation and fixed-size (better fragmentation performance on USB 3.0).
- [ ] **Direct-to-USB Copy:** Auto-detect connected Ventoy drives and offer to copy the `.vhdx` and `ventoy_vhdboot.img` automatically after creation.
- [ ] **Compact OS Compression (`/CompactOS`):** Apply Windows using NTFS LZX compression to reduce footprint down to under 12 GB.

---

## 🤝 Contributing

Contributions, bug reports, and suggestions are welcome!
Feel free to open an issue or submit a Pull Request.

---

## 📄 License

This project is licensed under the [MIT License](LICENSE) - feel free to use, modify, and distribute.
