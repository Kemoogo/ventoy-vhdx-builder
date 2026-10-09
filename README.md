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
* **Official VHD Plugin Documentation:** [https://www.ventoy.net/en/plugin_vhd.html](https://www.ventoy.net/en/plugin_vhd.html)
* **GitHub Repository:** [ventoy/Ventoy](https://github.com/ventoy/Ventoy)
* **Ventoy VHD Plugin Releases:** [ventoy/vhdiso Releases](https://github.com/ventoy/vhdiso/releases)

### Key Benefits of Ventoy + VHDX (Native VHD Boot)
1. **No Re-formatting Ever:** Just drop your `.vhdx` file onto the USB drive alongside your existing Linux ISOs and rescue images.
2. **True Native Performance (Bare-Metal):** Unlike a Virtual Machine, booting a VHDX runs Windows **directly on the host hardware** (CPU, GPU, RAM) with 100% native performance.
3. **Hardware Independence (Windows-To-Go Alternative):** Modern Windows 10/11 handles plug-and-play driver discovery effortlessly across different motherboards and chipsets.
4. **Dynamic Expandable Storage:** The VHDX starts small (only ~15–20 GB of actual data used) and grows dynamically up to your specified maximum (e.g. 100 GB).
5. **Instant Snapshots & Duplication:** To backup or duplicate your entire OS installation, simply copy the single `.vhdx` file.

---

## ❓ Partition Layout: Why Single NTFS Partition instead of Separate EFI?

You might wonder: *Does this script create a separate EFI System Partition (ESP) inside the VHDX?*

**Answer:** **No, by design!** 

When using **Ventoy Native VHD Boot**:
- **Ventoy’s Bootloader takes over EFI:** Ventoy itself (via its own EFI partition and the `ventoy_vhdboot` hook) acts as the UEFI loader that boots the machine and hooks the virtual disk driver into memory.
- **Ventoy expects a Single Partition:** Ventoy hooks directly into the primary NTFS partition where Windows and its BCD/boot files live. Creating a split ESP + OS partition structure inside the virtual container is redundant for Ventoy, adds unnecessary partition alignment overhead, and can interfere with the Ventoy VHD hook driver.
- The script populates the Windows boot structure (`\EFI\Boot\` and `\EFI\Microsoft\Boot\`) directly inside the root volume.

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
  sudo apt install qemu-utils wimtools parted ntfs-3g udev psmisc
  ```
* **Arch Linux / Manjaro:**
  ```bash
  sudo pacman -S qemu-img wimlib parted ntfs-3g udev psmisc
  ```
* **Fedora / RHEL:**
  ```bash
  sudo dnf install qemu-img wimtools parted ntfs-3g udev psmisc
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

Once the script completes, you will have your generated `.vhdx` file (e.g. `Win11.vhdx`).

### Deployment Steps:
1. Download the official **Ventoy VHD Boot plugin** (`ventoy_vhdboot.zip`):
   - **Download Link:** [https://github.com/ventoy/vhdiso/releases](https://github.com/ventoy/vhdiso/releases)
   - Extract the ZIP archive and get **`ventoy_vhdboot.img`** (under `Win10Based/`).
2. Open your Ventoy USB drive and create a folder named `ventoy` in the root (if it doesn't already exist):
   ```text
   USB_ROOT/
   └── ventoy/
       └── ventoy_vhdboot.img   <-- Place plugin here!
   ```
3. Copy your `.vhdx` file anywhere on the Ventoy USB drive.
   > **⚠️ CRITICAL Tip for Linux Users:**
   > Always run `sync` in your terminal after copying and wait for it to finish:
   > ```bash
   > rsync -P --sparse Win11.vhdx /media/user/Ventoy/ && sync
   > ```
   > *Why?* Linux caches large writes in RAM. If you unplug or test in a VM before the cache is flushed with `sync`, the file will be truncated at the end where the VHDX Block Allocation Table (BAT) resides, leading to `Windows Boot Manager Error 0xc0000102`.
4. Reboot your computer, choose the Ventoy USB in your BIOS Boot Menu, select your `.vhdx` file, and enjoy!

> **Testing in QEMU:**
> Windows 11 requires UEFI. When testing your Ventoy USB drive in QEMU, always pass OVMF UEFI firmware:
> ```bash
> sudo qemu-system-x86_64 -enable-kvm -m 4G -smp 4 -cpu host -bios /usr/share/ovmf/OVMF.fd -drive file=/dev/sdX,format=raw,cache=none -vga virtio -usb -device usb-tablet
> ```

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

## 📄 License

This project is licensed under the [MIT License](LICENSE) - free to use, modify, and distribute.
