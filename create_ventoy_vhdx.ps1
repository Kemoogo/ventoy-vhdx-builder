<#
.SYNOPSIS
    Interactive & Bulletproof Windows VHDX Builder for Ventoy (Windows Native).
.DESCRIPTION
    Creates a bootable VHDX, mounts it, applies install.wim/install.esd/ISO via DISM,
    injects unattended answer file (portable operating system 1) to bypass OOBE,
    generates UEFI boot files via bcdboot, and downloads ventoy_vhdboot.img.
.NOTES
    Requires Administrator privileges.
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

function Write-Color([string]$text, [ConsoleColor]$color) {
    $prev = [Console]::ForegroundColor
    [Console]::ForegroundColor = $color
    Write-Host $text
    [Console]::ForegroundColor = $prev
}

function Show-Header {
    Clear-Host
    Write-Color "==========================================================" Cyan
    Write-Color "    Bulletproof Windows VHDX Builder for Ventoy (Windows) " Cyan
    Write-Color "==========================================================" Cyan
    Write-Host ""
}

# 1. Check Administrator Privileges
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Color "[ERROR] This script must be run as Administrator (Elevated PowerShell)." Red
    Write-Host "Please right-click PowerShell and choose 'Run as Administrator'."
    exit 1
}

Show-Header

# Helper for XML Escaping
function Escape-Xml([string]$str) {
    if ([string]::IsNullOrEmpty($str)) { return "" }
    return [System.Security.SecurityElement]::Escape($str)
}

# 2. Get Image Source (.iso, .wim, .esd)
Write-Color "[1/5] Image Source (.iso / .wim / .esd)" Green
$mountedIsoDrive = $null
$imagePath = ""

while ($true) {
    $inputPath = Read-Host "Enter path to Windows ISO, install.wim, or install.esd"
    $inputPath = $inputPath.Trim('"', "'", " ")
    
    if (Test-Path -Path $inputPath -PathType Leaf) {
        $ext = [System.IO.Path]::GetExtension($inputPath).ToLower()
        if ($ext -eq ".iso") {
            Write-Color "[*] Mounting ISO image..." Cyan
            $mountResult = Mount-DiskImage -ImagePath $inputPath -PassThru
            $volume = $mountResult | Get-Volume
            $mountedIsoDrive = "$($volume.DriveLetter):"
            
            $wimCandidate = Join-Path $mountedIsoDrive "sources\install.wim"
            $esdCandidate = Join-Path $mountedIsoDrive "sources\install.esd"
            
            if (Test-Path $wimCandidate) {
                $imagePath = $wimCandidate
                break
            } elseif (Test-Path $esdCandidate) {
                $imagePath = $esdCandidate
                break
            } else {
                Dismount-DiskImage -ImagePath $inputPath | Out-Null
                Write-Color "[ERROR] Neither install.wim nor install.esd found inside the ISO." Red
            }
        } elseif ($ext -in @(".wim", ".esd")) {
            $imagePath = $inputPath
            break
        } else {
            Write-Color "[ERROR] Unsupported file extension. Please select .iso, .wim, or .esd." Red
        }
    } else {
        Write-Color "[ERROR] File not found: '$inputPath'. Please try again." Red
    }
}

Write-Color "`n[*] Querying available editions in image..." Cyan
$wimInfo = & dism.exe /Get-WimInfo /WimFile:"$imagePath"
$wimInfo | Out-String | Write-Host

# Get Image Index
$selectedWimIndex = 1
while ($true) {
    $idxInput = Read-Host "`nEnter Image Index to apply [default: 1]"
    if ([string]::IsNullOrWhiteSpace($idxInput)) {
        $selectedWimIndex = 1
        break
    }
    if ($idxInput -match '^\d+$') {
        $selectedWimIndex = [int]$idxInput
        break
    }
    Write-Color "Invalid numeric index." Red
}

# 3. VHDX Settings
Write-Color "`n[2/5] VHDX Configuration" Green

$defaultOutDir = (Get-Location).Path
$outDirInput = Read-Host "Enter output directory [default: $defaultOutDir]"
$outDir = if ([string]::IsNullOrWhiteSpace($outDirInput)) { $defaultOutDir } else { $outDirInput.Trim('"', "'", " ") }
if (-not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

# Pre-flight disk space check
$outDriveRoot = [System.IO.Path]::GetPathRoot($outDir)
$driveInfo = Get-PSDrive ($outDriveRoot.TrimEnd(':\')) -ErrorAction SilentlyContinue
if ($driveInfo) {
    $freeGb = [math]::Round($driveInfo.Free / 1GB, 2)
    if ($freeGb -lt 25) {
        Write-Color "[WARNING] Destination drive has only $freeGb GB free space. At least 25 GB is recommended." Yellow
        $continueSpace = Read-Host "Do you wish to continue anyway? [y/N]"
        if ($continueSpace -notmatch '^[Yy]$') {
            if ($mountedIsoDrive) { Dismount-DiskImage -ImagePath $inputPath | Out-Null }
            exit 1
        }
    }
}

$vhdxNameInput = Read-Host "Enter VHDX filename [default: Win11.vhdx]"
$vhdxName = if ([string]::IsNullOrWhiteSpace($vhdxNameInput)) { "Win11.vhdx" } else { $vhdxNameInput.Trim() }
if (-not $vhdxName.ToLower().EndsWith(".vhdx")) { $vhdxName += ".vhdx" }
$finalVhdxPath = Join-Path $outDir $vhdxName

if (Test-Path $finalVhdxPath) {
    Write-Color "[WARNING] '$finalVhdxPath' already exists." Yellow
    $overwrite = Read-Host "Overwrite existing file? [y/N]"
    if ($overwrite -notmatch '^[Yy]$') {
        Write-Color "Operation cancelled." Red
        if ($mountedIsoDrive) { Dismount-DiskImage -ImagePath $inputPath | Out-Null }
        exit 1
    }
    Remove-Item $finalVhdxPath -Force
}

$vhdxSizeInput = Read-Host "Enter VHDX max expandable size in GB [default: 100]"
$vhdxSizeGb = if ([string]::IsNullOrWhiteSpace($vhdxSizeInput)) { 100 } else { [int]$vhdxSizeInput }
$vhdxSizeMb = $vhdxSizeGb * 1024

# 4. User and OOBE configuration
Write-Color "`n[3/5] User & System Configuration" Green
$usernameInput = Read-Host "Enter Local Username [default: karim]"
$username = if ([string]::IsNullOrWhiteSpace($usernameInput)) { "karim" } else { $usernameInput.Trim() }

$userPass = Read-Host "Enter Password for '$username' (leave blank for none)"

$computerNameInput = Read-Host "Enter Computer Name [default: PORTABLE-PC]"
$computerName = if ([string]::IsNullOrWhiteSpace($computerNameInput)) { "PORTABLE-PC" } else { $computerNameInput.Trim() }

$xmlUser = Escape-Xml $username
$xmlPass = Escape-Xml $userPass
$xmlComp = Escape-Xml $computerName

Write-Color "`nConfiguration Summary:" Cyan
Write-Host " - Image Path    : $imagePath (Index: $selectedWimIndex)"
Write-Host " - Target VHDX   : $finalVhdxPath ($vhdxSizeGb GB Dynamic)"
Write-Host " - Username      : $username"
Write-Host " - Password      : $(if ([string]::IsNullOrEmpty($userPass)) { '(None)' } else { '********' })"
Write-Host " - Tagging       : portable operating system 1"
Write-Host ""

$confirm = Read-Host "Start building VHDX? [Y/n]"
if (-not [string]::IsNullOrWhiteSpace($confirm) -and $confirm -notmatch '^[Yy]$') {
    Write-Color "Aborted by user." Yellow
    if ($mountedIsoDrive) { Dismount-DiskImage -ImagePath $inputPath | Out-Null }
    exit 0
}

# 5. Create and Mount VHDX via Diskpart
Write-Color "`n[*] Step 1: Creating and partitioning VHDX via diskpart..." Cyan

# Helper to find a free drive letter
function Get-FreeDriveLetter {
    $used = (Get-PSDrive -PSProvider FileSystem).Name
    foreach ($letter in [char[]]([char]'V'..[char]'Z' + [char]'F'..[char]'U')) {
        if ($used -notcontains [string]$letter) {
            return "$letter"
        }
    }
    return "V"
}

$targetDrive = Get-FreeDriveLetter
$diskpartScript = @"
create vdisk file="$finalVhdxPath" maximum=$vhdxSizeMb type=expandable
select vdisk file="$finalVhdxPath"
attach vdisk
convert gpt
create partition primary
format fs=ntfs quick label="VHDWindows"
assign letter=$targetDrive
"@

$dpTemp = [System.IO.Path]::GetTempFileName()
$diskpartScript | Out-File -FilePath $dpTemp -Encoding ascii
& diskpart.exe /s $dpTemp | Out-Null
Remove-Item $dpTemp -Force

Start-Sleep -Seconds 2
$vhdDriveRoot = "$($targetDrive):\"

try {
    # 6. Apply Image via DISM
    Write-Color "`n[*] Step 2: Applying Windows Image (Index $selectedWimIndex) to $vhdDriveRoot via DISM..." Cyan
    & dism.exe /Apply-Image /ImageFile:"$imagePath" /Index:$selectedWimIndex /ApplyDir:$vhdDriveRoot
    if ($LASTEXITCODE -ne 0) {
        throw "DISM Apply-Image failed with exit code $LASTEXITCODE"
    }

    # 7. Inject unattended XML
    Write-Color "`n[*] Step 3: Injecting unattended answer file (portable operating system 1)..." Cyan
    $pantherDir = Join-Path $vhdDriveRoot "Windows\Panther"
    $sysprepDir = Join-Path $vhdDriveRoot "Windows\System32\Sysprep"
    if (-not (Test-Path $pantherDir)) { New-Item -ItemType Directory -Path $pantherDir -Force | Out-Null }
    if (-not (Test-Path $sysprepDir)) { New-Item -ItemType Directory -Path $sysprepDir -Force | Out-Null }

    $unattendXmlContent = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <AutoLogon>
                <Password>
                    <Value>$xmlPass</Value>
                    <PlainText>true</PlainText>
                </Password>
                <Enabled>true</Enabled>
                <LogonCount>1</LogonCount>
                <Username>$xmlUser</Username>
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
                        <DisplayName>$xmlUser</DisplayName>
                        <Group>Administrators</Group>
                        <Name>$xmlUser</Name>
                        <Password>
                            <Value>$xmlPass</Value>
                            <PlainText>true</PlainText>
                        </Password>
                    </LocalAccount>
                </LocalAccounts>
            </UserAccounts>
            <RegisteredOwner>portable operating system 1</RegisteredOwner>
            <RegisteredOrganization>portable operating system 1</RegisteredOrganization>
            <ComputerName>$xmlComp</ComputerName>
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
"@
    $xmlPath1 = Join-Path $pantherDir "unattend.xml"
    $xmlPath2 = Join-Path $sysprepDir "unattend.xml"
    $xmlPath3 = Join-Path $vhdDriveRoot "autounattend.xml"

    [System.IO.File]::WriteAllText($xmlPath1, $unattendXmlContent, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($xmlPath2, $unattendXmlContent, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($xmlPath3, $unattendXmlContent, [System.Text.Encoding]::UTF8)

    # 8. Configure Boot Files via BCDboot
    Write-Color "`n[*] Step 4: Generating BCD Bootloader via bcdboot..." Cyan
    $winDir = Join-Path $vhdDriveRoot "Windows"
    & bcdboot.exe "$winDir" /s "$($targetDrive):" /f ALL | Out-Null

} finally {
    # 9. Detach VHDX safely
    Write-Color "`n[*] Detaching VHDX virtual disk..." Cyan
    $detachScript = @"
select vdisk file="$finalVhdxPath"
detach vdisk
"@
    $dpDetach = [System.IO.Path]::GetTempFileName()
    $detachScript | Out-File -FilePath $dpDetach -Encoding ascii
    & diskpart.exe /s $dpDetach | Out-Null
    Remove-Item $dpDetach -Force

    # Unmount ISO if mounted
    if ($mountedIsoDrive) {
        Write-Color "[*] Dismounting source ISO..." Cyan
        Dismount-DiskImage -ImagePath $inputPath | Out-Null
    }
}

# 10. Download Ventoy Plugin if not present
Write-Color "`n[*] Step 5: Checking Ventoy vhdboot plugin..." Cyan
$pluginDest = Join-Path $outDir "ventoy_vhdboot.img"
if (-not (Test-Path $pluginDest)) {
    Write-Color "[*] Downloading Ventoy vhdboot plugin..." Yellow
    $zipTemp = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "ventoy_vhdboot.zip")
    $extractTemp = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "ventoy_vhdboot_extract")
    
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri "https://github.com/ventoy/vhdiso/releases/download/v3.0/ventoy_vhdboot.zip" -OutFile $zipTemp -UseBasicParsing
        Expand-Archive -Path $zipTemp -DestinationPath $extractTemp -Force
        $imgSource = Join-Path $extractTemp "ventoy_vhdboot\Win10Based\ventoy_vhdboot.img"
        if (Test-Path $imgSource) {
            Copy-Item -Path $imgSource -Destination $pluginDest -Force
            Write-Color "[+] Downloaded and prepared ventoy_vhdboot.img." Green
        }
    } catch {
        Write-Color "[WARNING] Could not auto-download ventoy_vhdboot.img ($_.Exception.Message)" Yellow
        Write-Host "You can download it manually from: https://github.com/ventoy/vhdiso/releases"
    } finally {
        if (Test-Path $zipTemp) { Remove-Item $zipTemp -Force }
        if (Test-Path $extractTemp) { Remove-Item $extractTemp -Recurse -Force }
    }
} else {
    Write-Color "[+] ventoy_vhdboot.img already present in output directory." Green
}

Write-Color "`n==========================================================" Green
Write-Color "                 PROCESS COMPLETED SUCCESSFULLY!          " Green
Write-Color "==========================================================" Green
Write-Host "Generated VHDX : $finalVhdxPath"
Write-Host "Ventoy Plugin  : $pluginDest"
Write-Host ""
Write-Color "Ventoy Deployment Instructions:" Yellow
Write-Host "1. On your Ventoy USB drive, create a folder named 'ventoy' in root."
Write-Host "2. Copy 'ventoy_vhdboot.img' into that '\ventoy\' folder."
Write-Host "3. Copy '$vhdxName' anywhere on the Ventoy USB drive."
Write-Host "4. Boot from Ventoy and choose your Windows VHDX!"
Write-Color "==========================================================" Green
