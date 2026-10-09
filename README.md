# Ventoy Windows VHDX Builder (Cross-Platform)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Platform-Linux%20%7C%20Windows-blue.svg)]()
[![Ventoy Compatible](https://img.shields.io/badge/Ventoy-Supported-success.svg)](https://www.ventoy.net)
[![Fault-Tolerant](https://img.shields.io/badge/Architecture-Force--Kill%20Safe-brightgreen.svg)]()

An automated, interactive, and **industrial-grade fault-tolerant** utility to generate fully configured, bootable Windows **VHDX** files for **Ventoy Native VHD Boot**, featuring automated **OOBE bypass** and pre-configured administrator account.

Runs natively on both **Linux** and **Windows** without requiring virtual machines, third-party software, or WinPE environments.

---

## 🌟 What is Ventoy & Why Boot Windows from VHDX?

### About Ventoy
[Ventoy](https://www.ventoy.net) is an open-source tool to create bootable USB drives for ISO/WIM/IMG/VHD(x)/EFI files.
* **Official Website:** [https://www.ventoy.net](https://www.ventoy.net)
* **GitHub Repository:** [ventoy/Ventoy](https://github.com/ventoy/Ventoy)
* **Ventoy VHD Boot Plugin Repo:** [ventoy/vhdiso](https://github.com/ventoy/vhdiso)

### Key Benefits of Ventoy + VHDX (Native VHD Boot)
1. **No Re-formatting Ever:** Just drop your `.vhdx` file onto the USB drive alongside your existing Linux ISOs and rescue images.
2. **True Native Performance (Bare-Metal):** Unlike a Virtual Machine, booting a VHDX runs Windows **directly on the host hardware** (CPU, GPU, RAM) with 100% native performance.
3. **Hardware Independence (Windows-To-Go Alternative):** Modern Windows 10/11 handles plug-and-play driver discovery effortlessly across different motherboards and chipsets.
4. **Dynamic Expandable Storage:** The VHDX starts small (only ~15–20 GB of actual data used) and grows dynamically up to your specified maximum (e.g. 100 GB).
5. **Instant Snapshots & Duplication:** To backup or duplicate your entire OS installation, simply copy the single `.vhdx` file.

---

## 🛡️ Industrial-Grade Fault Tolerance & Forced Termination Handling

One major flaw of naive disk scripts is that if interrupted (e.g. via `Ctrl+C`, `SIGTERM`, terminal closure, or sudden power loss), they leave virtual disks locked, NBD slots blocked, mounts inaccessible, or half-written corrupted 20GB files behind.

**This builder features an active teardown watchdog across both Linux and Windows:**

* **Subprocess Watchdog (`Active Child Killer`):**
  Monitors child background engines (`wimapply`, `dism.exe`, `qemu-img`). If an abort signal is detected, the script actively halts and terminates the child process instead of leaving background zombies running.
* **Process Locks Teardown (`fuser -km` & Lazy Unmount):**
  If any background service or file browser locks the mounted VHD partition, it terminates locking handles and applies a lazy-unmount (`umount -l`) to guarantee that disk handles are freed.
* **Dynamic Slot & Virtual Disk Reset:**
  Disconnects NBD channels (`qemu-nbd --disconnect`) and flushes block buffers (`blockdev --flushbufs`) in Linux; triggers safe `diskpart detach vdisk` in Windows.
* **Incomplete Artifact Auto-Purge:**
  If an operation fails midway or is cancelled by the user, the script deletes the partial/corrupted `.vhdx` image so you never end up with an unbootable phantom disk on your drive.
* **Complete Signal Trapping:**
  Hooks into `SIGINT (Ctrl+C)`, `SIGTERM`, `SIGHUP`, `SIGQUIT`, and PowerShell exit events.

---

## 🚀 Comparison: The Manual Way vs. With This Tool

| Step | Manual Process | With This Tool |
|---|---|---|
| **VHDX Creation** | Complex sequence of `diskpart` commands | Single interactive prompt |
| **Partitioning** | Manual GPT, NTFS formatting & volume alignment | Fully automated & verified |
| **Image Extraction** | Cumbersome command-line flags for `dism` / `wimapply` | Automated scan & menu selection |
| **Direct ISO Support** | Must manually extract or loop-mount ISO | Automatically mounts ISO and locates `.wim`/`.esd` |
| **OOBE Screen Bypass** | 15–20 minutes clicking through Microsoft, WiFi, & MSA screens | 100% bypassed straight to Desktop |
| **User Setup** | Creating account and password | Automated local admin + AutoLogon |
| **System Branding** | Manual unattend XML authoring | Injected with `"portable operating system 1"` metadata |
| **UEFI Bootloader** | Manual EFI partition manipulation / `bcdboot` | Automatically provisioned |
| **Ventoy Plugin** | Hunting for `ventoy_vhdboot.img` on GitHub | Automatically downloaded and verified |
| **Interruption Safety** | Leaves locked devices, mounts, and corrupted disks | **100% Graceful Force-Kill & Cleanup** |

---

## 📁 Repository Structure

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
Install the required packages:

* **Ubuntu / Debian / Pop!_OS:**
  ```bash
  sudo apt update
  sudo apt install qemu-utils wimtools parted ntfs-3g udev psmisc wget unzip
  ```
* **Arch Linux / Manjaro:**
  ```bash
  sudo pacman -S qemu-img wimlib parted ntfs-3g udev psmisc wget unzip
  ```
* **Fedora / RHEL:**
  ```bash
  sudo dnf install qemu-img wimtools parted ntfs-3g udev psmisc wget unzip
  ```

### 2. Execution
```bash
git clone https://github.com/<YOUR-USERNAME>/ventoy-vhdx-builder.git
cd ventoy-vhdx-builder
chmod +x create_ventoy_vhdx.sh
./create_ventoy_vhdx.sh
```

---

## 🪟 Instructions for Windows Users

### Option A: One-Click Launcher (Recommended)
Right-click on **`run_windows.bat`** and select **Run as administrator** (or double-click it; it will automatically prompt for elevation).

### Option B: PowerShell
Open **PowerShell as Administrator** and run:
```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\create_ventoy_vhdx.ps1
```

---

## 📦 Setting Up Your Ventoy USB Drive

Once the script completes, you will have two files in your output directory:
1. `YourImage.vhdx` (e.g., `test_oobe.vhdx`)
2. `ventoy_vhdboot.img`

### Deployment Steps:
1. Plug in your Ventoy USB drive and open its main partition in your file manager.
2. In the root of the USB drive, create a folder named `ventoy` (lowercase):
   ```text
   USB_ROOT/
   └── ventoy/
       └── ventoy_vhdboot.img   <-- Place plugin here!
   ```
3. Copy your `.vhdx` file anywhere on the Ventoy USB drive (in the root or any subfolder).
4. Reboot your computer, enter Boot Menu (F12 / F11 / F8), boot from the Ventoy USB, and select your `.vhdx` file.

> **First Boot:** On the very first boot, Windows will detect host hardware devices ("Getting devices ready..."), reboot once, process the unattended answer file, and take you directly to the desktop logged in as your configured user.

---

## 📋 The `unattend.xml` OOBE Configuration

The script generates an XML answer file placed in `\Windows\Panther\` and `\Windows\System32\Sysprep\` containing:
- **SkipMachineOOBE & SkipUserOOBE:** Suppresses consumer setup screens.
- **HideOnlineAccountScreens:** Removes forced Microsoft Account (MSA) requirement.
- **LocalAccounts:** Creates your designated local administrator with optional password.
- **AutoLogon:** Direct boot to Desktop.
- **Metadata Tagging:**
  - `RegisteredOwner`: `portable operating system 1`
  - `RegisteredOrganization`: `portable operating system 1`
  - `Description`: `portable operating system 1`

---

## 💡 Future Roadmap & Feature Proposals

- [ ] **Bypass Windows 11 Hardware Restrictions:** Automatic registry injection during provisioning to bypass TPM 2.0, SecureBoot, and 8GB RAM checks.
- [ ] **Pre-installed Drivers (VirtIO / Wi-Fi):** Option to slipstream Wi-Fi or storage drivers into the offline image via `dism` / `wimlib`.
- [ ] **Direct-to-USB Copy:** Auto-detect connected Ventoy drives and offer to copy the `.vhdx` and `ventoy_vhdboot.img` automatically after creation.
- [ ] **Compact OS Compression (`/CompactOS`):** Apply Windows using NTFS LZX compression to reduce footprint down to under 12 GB.

---

## 🤝 Contributing & Support

Contributions, bug reports, and suggestions are welcome! Feel free to open an issue or submit a Pull Request.

---

## 📄 License

This project is licensed under the [MIT License](LICENSE) - free to use, modify, and distribute.
