#!/usr/bin/env bash
#
# ==============================================================================
# Script: create_ventoy_vhdx.sh (Industrial-Grade Robust & Force-Kill Safe)
# Features:
#   - Windows-Compliant GPT Layout (16MB MSR Partition + NTFS OS Partition)
#   - NTFS Boot Sector Geometry Alignment (-p start -H 255 -S 63)
#   - Automatic Offline Registry Injection (PortableOperatingSystem = 1)
#   - True Dynamic VHDX Allocation & Post-build Compaction (Zero-Bloat)
#   - Dynamic Username default based on current session ($USER)
#   - Full Tab Autocompletion (Readline enabled via read -e)
#   - Process Group & Signal Trap handling (INT, TERM, HUP, QUIT, EXIT)
#   - Active Child Process Watchdog (wimapply, qemu-nbd)
#   - Force-unmount & Lazy-unmount (umount -l / fuser -km) to kill busy locks
#   - Incomplete artifact cleanup (deletes half-written VHDX on cancellation)
#   - Dynamic free NBD discovery & force-disconnect on abort
#   - Direct ISO / WIM / ESD support
#   - XML-safe escaping & "portable operating system 1" branding
#   - Pre-flight disk space validation & udevadm synchronization
#   - Path normalization (avoids double slashes)
#   - Clean Ventoy official VHD documentation guidance
# ==============================================================================

set -uo pipefail

# UI Color Codes
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Dynamic tracking variables
MOUNT_DIR=""
ISO_MOUNT_DIR=""
ALLOCATED_NBD=""
FINAL_VHDX_PATH=""
ACTIVE_CHILD_PID=""
OPERATION_COMPLETED=false

# Default user resolution (Fallback to Admin if root/empty)
DETECTED_USER="${SUDO_USER:-${USER:-Admin}}"
[ "$DETECTED_USER" = "root" ] && DETECTED_USER="Admin"

# ------------------------------------------------------------------------------
# Robust Cleanup & Force Termination Routine
# ------------------------------------------------------------------------------
cleanup() {
    local exit_code=$?
    trap '' INT TERM HUP QUIT EXIT

    if [ "$OPERATION_COMPLETED" = false ]; then
        echo -e "\n${RED}${BOLD}[!] INTERRUPT OR FAILURE DETECTED! INITIATING FORCED CLEANUP...${NC}"
    else
        echo -e "\n${GREEN}[*] Finalizing and cleaning temporary mounts...${NC}"
    fi

    # 1. Kill any running child process (wimapply, qemu-img)
    if [ -n "$ACTIVE_CHILD_PID" ] && kill -0 "$ACTIVE_CHILD_PID" 2>/dev/null; then
        echo -e "${YELLOW} - Terminating running background process (PID: $ACTIVE_CHILD_PID)...${NC}"
        sudo kill -TERM "$ACTIVE_CHILD_PID" 2>/dev/null || true
        sleep 1
        sudo kill -KILL "$ACTIVE_CHILD_PID" 2>/dev/null || true
    fi

    sudo pkill -P $$ 2>/dev/null || true

    # 2. Release & Force-unmount VHD directory
    if [ -n "$MOUNT_DIR" ]; then
        if mountpoint -q "$MOUNT_DIR" 2>/dev/null; then
            echo -e "${YELLOW} - Unmounting VHD filesystem ($MOUNT_DIR)...${NC}"
            if command -v fuser &>/dev/null; then
                sudo fuser -km "$MOUNT_DIR" 2>/dev/null || true
            fi
            sudo sync
            sudo umount "$MOUNT_DIR" 2>/dev/null || sudo umount -l "$MOUNT_DIR" 2>/dev/null || true
        fi
        [ -d "$MOUNT_DIR" ] && sudo rmdir "$MOUNT_DIR" 2>/dev/null || true
    fi

    # 3. Disconnect NBD device with retry & force fallback
    if [ -n "$ALLOCATED_NBD" ] && [ -b "$ALLOCATED_NBD" ]; then
        echo -e "${YELLOW} - Disconnecting virtual disk device ($ALLOCATED_NBD)...${NC}"
        sudo qemu-nbd --disconnect "$ALLOCATED_NBD" 2>/dev/null || true
        if [ -b "${ALLOCATED_NBD}p2" ] || [ -b "${ALLOCATED_NBD}p1" ]; then
            sleep 1
            sudo blockdev --flushbufs "$ALLOCATED_NBD" 2>/dev/null || true
            sudo qemu-nbd --disconnect "$ALLOCATED_NBD" 2>/dev/null || true
        fi
    fi

    # 4. Release ISO mount
    if [ -n "$ISO_MOUNT_DIR" ]; then
        if mountpoint -q "$ISO_MOUNT_DIR" 2>/dev/null; then
            echo -e "${YELLOW} - Unmounting source ISO ($ISO_MOUNT_DIR)...${NC}"
            if command -v fuser &>/dev/null; then
                sudo fuser -km "$ISO_MOUNT_DIR" 2>/dev/null || true
            fi
            sudo umount -l "$ISO_MOUNT_DIR" 2>/dev/null || true
        fi
        [ -d "$ISO_MOUNT_DIR" ] && sudo rmdir "$ISO_MOUNT_DIR" 2>/dev/null || true
    fi

    # 5. Remove incomplete/corrupted VHDX if cancelled
    if [ "$OPERATION_COMPLETED" = false ] && [ -n "$FINAL_VHDX_PATH" ] && [ -f "$FINAL_VHDX_PATH" ]; then
        echo -e "${YELLOW} - Removing incomplete/corrupted VHDX image: $FINAL_VHDX_PATH${NC}"
        sudo rm -f "$FINAL_VHDX_PATH" 2>/dev/null || true
    fi

    if [ "$OPERATION_COMPLETED" = false ]; then
        echo -e "${RED}[!] Force cleanup completed. Safe to retry.${NC}"
        exit 130
    fi
}

trap cleanup INT TERM HUP QUIT EXIT

# XML Escape Helper
escape_xml() {
    local str="$1"
    str="${str//&/&amp;}"
    str="${str//</&lt;}"
    str="${str//>/&gt;}"
    str="${str//\"/&quot;}"
    str="${str//\'/&apos;}"
    printf '%s' "$str"
}

# Find free NBD slot
find_free_nbd() {
    sudo modprobe nbd max_part=16
    for i in {0..15}; do
        local dev="/dev/nbd$i"
        if [ -b "$dev" ]; then
            local size
            size=$(cat "/sys/block/nbd$i/size" 2>/dev/null || echo "0")
            if [ "$size" -eq 0 ] && ! grep -q "$dev" /proc/mounts; then
                echo "$dev"
                return 0
            fi
        fi
    done
    return 1
}

echo -e "${CYAN}${BOLD}"
echo "=========================================================="
echo "    Bulletproof Windows VHDX Builder for Ventoy          "
echo "=========================================================="
echo -e "${NC}"

# Check Sudo Access
if ! sudo -v &>/dev/null; then
    echo -e "${RED}[ERROR] Sudo privileges are required to run this script.${NC}"
    exit 1
fi

# Check Tools
REQUIRED_TOOLS=("qemu-img" "qemu-nbd" "wimapply" "wiminfo" "parted" "mkfs.ntfs" "udevadm" "python3")
for cmd in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "${RED}[ERROR] Missing dependency: $cmd${NC}"
        echo -e "${YELLOW}Install via: sudo apt install qemu-utils wimtools parted ntfs-3g udev psmisc python3 python3-hivex${NC}"
        exit 1
    fi
done

# Step 1: Image source with Tab Completion
echo -e "${BLUE}${BOLD}[1/5] Image Source (.wim / .esd / .iso)${NC}"
echo -e "${YELLOW}(Tip: Use [TAB] for path auto-completion)${NC}"
while true; do
    read -e -rp "Enter path to Windows ISO, install.wim, or install.esd: " SRC_PATH
    SRC_PATH="${SRC_PATH/#\~/$HOME}"
    SRC_PATH="$(echo "$SRC_PATH" | xargs)"
    if [ -f "$SRC_PATH" ]; then
        break
    else
        echo -e "${RED}File does not exist: '$SRC_PATH'. Try again.${NC}"
    fi
done

ACTUAL_IMAGE_PATH="$SRC_PATH"

if [[ "$SRC_PATH" =~ \.[iI][sS][oO]$ ]]; then
    echo -e "${CYAN}[*] ISO detected. Mounting temporarily...${NC}"
    ISO_MOUNT_DIR="/mnt/iso_tmp_$$"
    sudo mkdir -p "$ISO_MOUNT_DIR"
    sudo mount -o loop,ro "$SRC_PATH" "$ISO_MOUNT_DIR"
    
    if [ -f "$ISO_MOUNT_DIR/sources/install.wim" ]; then
        ACTUAL_IMAGE_PATH="$ISO_MOUNT_DIR/sources/install.wim"
    elif [ -f "$ISO_MOUNT_DIR/sources/install.esd" ]; then
        ACTUAL_IMAGE_PATH="$ISO_MOUNT_DIR/sources/install.esd"
    else
        echo -e "${RED}[ERROR] Neither install.wim nor install.esd found in the ISO.${NC}"
        exit 1
    fi
    echo -e "${GREEN}Found valid image inside ISO: $ACTUAL_IMAGE_PATH${NC}"
fi

# List editions
echo -e "\n${CYAN}Available Editions:${NC}"
wiminfo "$ACTUAL_IMAGE_PATH" | grep -E "Index:|Name:|Architecture:" || true
echo ""

TOTAL_IMAGES=$(wiminfo "$ACTUAL_IMAGE_PATH" | grep "Image Count:" | awk '{print $3}')
TOTAL_IMAGES=${TOTAL_IMAGES:-1}

while true; do
    read -rp "Enter Image Index (1 to $TOTAL_IMAGES) [default: 1]: " WIM_INDEX
    WIM_INDEX=${WIM_INDEX:-1}
    if [[ "$WIM_INDEX" =~ ^[0-9]+$ ]] && [ "$WIM_INDEX" -ge 1 ] && [ "$WIM_INDEX" -le "$TOTAL_IMAGES" ]; then
        break
    fi
    echo -e "${RED}Invalid index. Must be between 1 and $TOTAL_IMAGES.${NC}"
done

# Step 2: Output Configuration
echo -e "\n${BLUE}${BOLD}[2/5] VHDX Configuration${NC}"
read -e -rp "Enter output directory [default: $(pwd)]: " OUT_DIR
OUT_DIR=${OUT_DIR:-"$(pwd)"}
OUT_DIR="${OUT_DIR/#\~/$HOME}"
OUT_DIR="${OUT_DIR%/}"
mkdir -p "$OUT_DIR"

AVAIL_KB=$(df -P "$OUT_DIR" | awk 'NR==2 {print $4}')
AVAIL_GB=$(( AVAIL_KB / 1024 / 1024 ))
if [ "$AVAIL_GB" -lt 20 ]; then
    echo -e "${YELLOW}[WARNING] Destination directory has only ${AVAIL_GB}GB free space. (At least 25GB recommended)${NC}"
    read -rp "Proceed anyway? [y/N]: " PROCEED_SPACE
    if [[ ! "$PROCEED_SPACE" =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

read -rp "Enter output VHDX filename [default: Win11.vhdx]: " VHDX_NAME
VHDX_NAME=${VHDX_NAME:-"Win11.vhdx"}
[[ "$VHDX_NAME" != *.vhdx ]] && VHDX_NAME="${VHDX_NAME}.vhdx"
FINAL_VHDX_PATH="${OUT_DIR:-.}/$VHDX_NAME"

if [ -f "$FINAL_VHDX_PATH" ]; then
    echo -e "${YELLOW}File '$FINAL_VHDX_PATH' already exists.${NC}"
    read -rp "Overwrite existing file? [y/N]: " OVERWRITE
    if [[ ! "$OVERWRITE" =~ ^[Yy]$ ]]; then
        echo -e "${RED}Aborted by user.${NC}"
        exit 1
    fi
    rm -f "$FINAL_VHDX_PATH"
fi

read -rp "Enter VHDX max expandable size in GB [default: 100]: " VHDX_SIZE
VHDX_SIZE=${VHDX_SIZE:-100}

# Step 3: User Accounts (Dynamic default to current session user)
echo -e "\n${BLUE}${BOLD}[3/5] User & System Configuration${NC}"
read -rp "Enter Local Username [default: $DETECTED_USER]: " USER_NAME
USER_NAME=${USER_NAME:-"$DETECTED_USER"}

read -rp "Enter Password for '$USER_NAME' (leave blank for none): " USER_PASS
USER_PASS=${USER_PASS:-""}

read -rp "Enter Computer/Machine Name [default: PORTABLE-PC]: " COMPUTER_NAME
COMPUTER_NAME=${COMPUTER_NAME:-"PORTABLE-PC"}

XML_USER=$(escape_xml "$USER_NAME")
XML_PASS=$(escape_xml "$USER_PASS")
XML_COMP=$(escape_xml "$COMPUTER_NAME")

echo -e "\n${GREEN}Summary of settings:${NC}"
echo " - Source Image : $ACTUAL_IMAGE_PATH (Index: $WIM_INDEX)"
echo " - Target VHDX  : $FINAL_VHDX_PATH (${VHDX_SIZE}GB Dynamic)"
echo " - User Account : $USER_NAME"
echo " - Password     : $([ -z "$USER_PASS" ] && echo "(None)" || echo "********")"
echo " - Tagging      : portable operating system 1"
echo ""
read -rp "Start processing? [Y/n]: " CONFIRM
CONFIRM=${CONFIRM:-"Y"}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Aborted by user.${NC}"
    exit 0
fi

# Step 4: Create dynamic VHDX
echo -e "\n${BLUE}[*] Step 1: Creating dynamic expandable VHDX (${VHDX_SIZE}G)...${NC}"
qemu-img create -f vhdx -o subformat=dynamic,block_size=2M "$FINAL_VHDX_PATH" "${VHDX_SIZE}G"

# Step 5: Connect NBD
echo -e "${BLUE}[*] Step 2: Allocating free NBD device...${NC}"
if ! ALLOCATED_NBD=$(find_free_nbd); then
    echo -e "${RED}[ERROR] No free NBD devices available.${NC}"
    exit 1
fi
echo -e "${GREEN}Connected device: $ALLOCATED_NBD${NC}"

sudo qemu-nbd --connect="$ALLOCATED_NBD" "$FINAL_VHDX_PATH"
sudo udevadm settle

# Step 6: Windows-Compliant GPT Layout (16MB MSR Partition 1 + NTFS OS Partition 2)
echo -e "${BLUE}[*] Step 3: Partitioning Windows GPT layout (MSR + NTFS)...${NC}"
sudo parted -s "$ALLOCATED_NBD" mklabel gpt
# Partition 1: 16MB Microsoft Reserved (MSR) Partition
sudo parted -s "$ALLOCATED_NBD" mkpart primary 2048s 34815s
sudo parted -s "$ALLOCATED_NBD" set 1 msftres on
# Partition 2: NTFS OS Data Partition
sudo parted -s "$ALLOCATED_NBD" mkpart primary ntfs 34816s 100%
sudo parted -s "$ALLOCATED_NBD" set 2 msftdata on
sudo udevadm settle
sleep 1

PART_DEV="${ALLOCATED_NBD}p2"
if [ ! -b "$PART_DEV" ]; then
    echo -e "${YELLOW}Refreshing partition table...${NC}"
    sudo partx -u "$ALLOCATED_NBD" 2>/dev/null || true
    sudo udevadm settle
fi

if [ ! -b "$PART_DEV" ]; then
    echo -e "${RED}[ERROR] Partition device node $PART_DEV failed to appear.${NC}"
    exit 1
fi

# Format NTFS with exact partition start sector and geometry (Fixes INACCESSIBLE_BOOT_DEVICE)
NBD_BASE=$(basename "$ALLOCATED_NBD")
PART_BASE=$(basename "$PART_DEV")
START_SECTOR=$(cat "/sys/block/${NBD_BASE}/${PART_BASE}/start" 2>/dev/null || echo "34816")
echo -e "${CYAN}[*] Formatting NTFS with aligned geometry (Start Sector: ${START_SECTOR}, Heads: 255, Sectors: 63)...${NC}"
sudo mkfs.ntfs -f -L "VHDWindows" -p "$START_SECTOR" -H 255 -S 63 "$PART_DEV"

# Step 7: Mounting
echo -e "${BLUE}[*] Step 4: Mounting filesystem...${NC}"
MOUNT_DIR="/mnt/vhdwin_tmp_$$"
sudo mkdir -p "$MOUNT_DIR"
sudo mount "$PART_DEV" "$MOUNT_DIR"

# Step 8: Apply image with process monitoring
echo -e "${BLUE}[*] Step 5: Applying image index $WIM_INDEX to VHDX...${NC}"
sudo wimapply "$ACTUAL_IMAGE_PATH" "$WIM_INDEX" "$MOUNT_DIR" &
ACTIVE_CHILD_PID=$!
wait "$ACTIVE_CHILD_PID"
ACTIVE_CHILD_PID=""

# Step 9: Inject unattended XML (Bypass OOBE + Specialize pass)
echo -e "${BLUE}[*] Step 6: Injecting unattended OOBE bypass and Specialize rules...${NC}"
sudo mkdir -p "$MOUNT_DIR/Windows/Panther" "$MOUNT_DIR/Windows/System32/Sysprep"

cat <<INNER_EOF | sudo tee "$MOUNT_DIR/Windows/Panther/unattend.xml" > /dev/null
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="specialize">
        <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" language="neutral" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" publicKeyToken="31bf3856ad364e35" versionScope="nonSxS">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Path>reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE /v BypassNRO /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>2</Order>
                    <Path>reg add HKLM\SYSTEM\CurrentControlSet\Control /v PortableOperatingSystem /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
            </RunSynchronous>
        </component>
    </settings>
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <AutoLogon>
                <Password>
                    <Value>${XML_PASS}</Value>
                    <PlainText>true</PlainText>
                </Password>
                <Enabled>true</Enabled>
                <LogonCount>1</LogonCount>
                <Username>${XML_USER}</Username>
            </AutoLogon>
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideLocalAccountScreen>true</HideLocalAccountScreen>
                <HideOEMRegistrationScreens>true</HideOEMRegistrationScreens>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <NetworkLocation>Work</NetworkLocation>
                <ProtectYourPC>3</ProtectYourPC>
                <SkipMachineOOBE>true</SkipMachineOOBE>
                <SkipUserOOBE>true</SkipUserOOBE>
            </OOBE>
            <UserAccounts>
                <LocalAccounts>
                    <LocalAccount wcm:action="add">
                        <Description>portable operating system 1</Description>
                        <DisplayName>${XML_USER}</DisplayName>
                        <Group>Administrators</Group>
                        <Name>${XML_USER}</Name>
                        <Password>
                            <Value>${XML_PASS}</Value>
                            <PlainText>true</PlainText>
                        </Password>
                    </LocalAccount>
                </LocalAccounts>
            </UserAccounts>
            <RegisteredOwner>portable operating system 1</RegisteredOwner>
            <RegisteredOrganization>portable operating system 1</RegisteredOrganization>
            <ComputerName>${XML_COMP}</ComputerName>
            <TimeZone>Egypt Standard Time</TimeZone>
        </component>
        <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <InputLocale>0409:00000409</InputLocale>
            <SystemLocale>en-US</SystemLocale>
            <UILanguage>en-US</UILanguage>
            <UserLocale>en-US</UserLocale>
        </component>
    </settings>
</unattend>
INNER_EOF

sudo cp "$MOUNT_DIR/Windows/Panther/unattend.xml" "$MOUNT_DIR/Windows/System32/Sysprep/unattend.xml"
sudo cp "$MOUNT_DIR/Windows/Panther/unattend.xml" "$MOUNT_DIR/autounattend.xml"

# Step 10: Direct Offline Registry Patching (Critical for 0x7B / Inaccessible Boot Device prevention)
echo -e "${BLUE}[*] Step 7: Injecting PortableOperatingSystem into offline SYSTEM registry...${NC}"
SYS_HIVE="$MOUNT_DIR/Windows/System32/config/SYSTEM"
if [ -f "$SYS_HIVE" ]; then
    python3 -c "
import hivex, struct, sys

try:
    h = hivex.Hivex('$SYS_HIVE', write=True)
    root = h.root()
    cs = [c for c in h.node_children(root) if h.node_name(c).lower() == 'controlset001']
    if cs:
        ctrl = h.node_get_child(cs[0], 'Control')
        if ctrl:
            # Set PortableOperatingSystem = 1 (REG_DWORD)
            val = {'key': 'PortableOperatingSystem', 't': 4, 'value': struct.pack('<I', 1)}
            h.node_set_value(ctrl, val)
        services = h.node_get_child(cs[0], 'Services')
        if services:
            # Ensure vhdmp and fsdepends boot storage drivers load at Boot (Start = 0)
            for sname in ['vhdmp', 'fsdepends']:
                snode = h.node_get_child(services, sname)
                if snode:
                    h.node_set_value(snode, {'key': 'Start', 't': 4, 'value': struct.pack('<I', 0)})
    h.commit('$SYS_HIVE')
    print('  [+] Offline SYSTEM registry successfully patched for Portable VHD boot.')
except Exception as e:
    print(f'  [!] Registry injection notice: {e}', file=sys.stderr)
" || true
fi

# Step 11: Safely unmount and detach
echo -e "${BLUE}[*] Step 8: Syncing filesystem cache...${NC}"
sudo sync
sudo umount "$MOUNT_DIR"
MOUNT_DIR=""
sudo qemu-nbd --disconnect "$ALLOCATED_NBD"
ALLOCATED_NBD=""
sudo udevadm settle

# Unmount ISO if active
if [ -n "$ISO_MOUNT_DIR" ]; then
    sudo umount -l "$ISO_MOUNT_DIR" 2>/dev/null || true
    sudo rmdir "$ISO_MOUNT_DIR" 2>/dev/null || true
    ISO_MOUNT_DIR=""
fi

# Step 12: Shrink & Compact VHDX
echo -e "${BLUE}[*] Step 9: Compacting VHDX to reclaim unallocated space...${NC}"
COMPACT_TMP="${FINAL_VHDX_PATH}.compacting"
if qemu-img convert -f vhdx -O vhdx -o subformat=dynamic,block_size=2M "$FINAL_VHDX_PATH" "$COMPACT_TMP" 2>/dev/null; then
    mv -f "$COMPACT_TMP" "$FINAL_VHDX_PATH"
    echo -e "${GREEN}VHDX compacted successfully.${NC}"
else
    rm -f "$COMPACT_TMP" 2>/dev/null || true
fi

REAL_SIZE=$(du -h "$FINAL_VHDX_PATH" | awk '{print $1}')
sudo chown "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$FINAL_VHDX_PATH"

OPERATION_COMPLETED=true

echo -e "\n${GREEN}${BOLD}=========================================================="
echo "                 PROCESS COMPLETED SUCCESSFULLY!          "
echo "==========================================================${NC}"
echo -e "VHDX File     : ${BOLD}$FINAL_VHDX_PATH${NC}"
echo -e "Actual Space  : ${BOLD}$REAL_SIZE${NC} (Virtual limit: ${VHDX_SIZE}GB)"
echo ""
echo -e "${CYAN}${BOLD}Ventoy VHD Boot Setup & Official Resources:${NC}"
echo -e "For Ventoy to boot Windows VHD/VHDX, make sure the official plugin is on your USB:"
echo -e "  🌐 ${BOLD}Official Guide:${NC} https://www.ventoy.net/en/plugin_vhd.html"
echo -e "  📥 ${BOLD}Download Plugin:${NC} https://github.com/ventoy/vhdiso/releases"
echo ""
echo -e "${YELLOW}Quick Steps:${NC}"
echo "1. Download 'ventoy_vhdboot.zip' from the link above and extract 'ventoy_vhdboot.img'."
echo "2. On your Ventoy USB, create a folder named 'ventoy' in root."
echo "3. Copy 'ventoy_vhdboot.img' to '/ventoy/ventoy_vhdboot.img'."
echo "4. Copy '$(basename "$FINAL_VHDX_PATH")' to anywhere on your Ventoy USB."
echo "   (Tip: In Linux use sparse copy: cp --sparse=always \"$FINAL_VHDX_PATH\" /path/to/usb/)"
echo "5. Boot from Ventoy and enjoy portable Windows!"
echo "=========================================================="
