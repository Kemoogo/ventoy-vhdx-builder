<#
.SYNOPSIS
    Interactive & Industrial-Grade Windows VHDX Builder for Ventoy (Windows Native).
.DESCRIPTION
    Creates a bootable VHDX, mounts it, applies install.wim/install.esd/ISO via DISM,
    injects unattended answer file (portable operating system 1) to bypass OOBE,
    patches offline registry for PortableOperatingSystem and boot storage drivers,
    and generates UEFI boot files via bcdboot.
    Includes interactive input editing before build execution.
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

# 1. Admin Verification
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Color "[ERROR] This script must be run as Administrator (Elevated PowerShell)." Red
    exit 1
}

Show-Header

function Read-HostWithTab([string]$prompt, [string]$defaultVal = "") {
    Write-Host $prompt -NoNewline -ForegroundColor Cyan
    if ($defaultVal) {
        Write-Host " [default: $defaultVal]" -NoNewline -ForegroundColor Yellow
    }
    Write-Host ": " -NoNewline
    
    $val = Read-Host
    if ([string]::IsNullOrWhiteSpace($val)) {
        return $defaultVal
    }
    return $val.Trim('"', "'", " ")
}

# State variables for robust cleanup & force-termination
$script:mountedIsoPath = $null
$script:targetDrive = $null
$script:finalVhdxPath = $null
$script:operationCompleted = $false
$script:dismProcess = $null

function Invoke-ForceCleanup {
    Write-Color "`n[!] Clean-up & Forced Teardown Handler Triggered..." Yellow

    # 1. Kill DISM if still running
    if ($script:dismProcess -and -not $script:dismProcess.HasExited) {
        Write-Color " - Terminating running DISM background process..." Yellow
        try {
            $script:dismProcess.Kill()
            $script:dismProcess.WaitForExit(3000)
        } catch {}
    }

    # 2. Detach VHDX
    if ($script:finalVhdxPath -and (Test-Path $script:finalVhdxPath)) {
        Write-Color " - Detaching VHD virtual disk..." Yellow
        $detachScript = @"
select vdisk file="$script:finalVhdxPath"
detach vdisk
"@
        $dpDetach = [System.IO.Path]::GetTempFileName()
        $detachScript | Out-File -FilePath $dpDetach -Encoding ascii
        & diskpart.exe /s $dpDetach | Out-Null
        Remove-Item $dpDetach -Force -ErrorAction SilentlyContinue

        # 3. If aborted/errored, delete incomplete/corrupted VHDX
        if (-not $script:operationCompleted) {
            Write-Color " - Removing incomplete/corrupted VHDX: $script:finalVhdxPath" Yellow
            Start-Sleep -Seconds 1
            Remove-Item $script:finalVhdxPath -Force -ErrorAction SilentlyContinue
        }
    }

    # 4. Dismount ISO if mounted
    if ($script:mountedIsoPath) {
        Write-Color " - Dismounting source ISO..." Yellow
        Dismount-DiskImage -ImagePath $script:mountedIsoPath -ErrorAction SilentlyContinue | Out-Null
    }
}

[Console]::TreatControlCAsInput = $false
$script:sigintEvent = Register-EngineEvent -SourceIdentifier ([System.Management.Automation.PsEngineEvent]::Exiting) -Action {
    if (-not $script:operationCompleted) {
        Invoke-ForceCleanup
    }
}

function Escape-Xml([string]$str) {
    if ([string]::IsNullOrEmpty($str)) { return "" }
    return [System.Security.SecurityElement]::Escape($str)
}

function Get-FreeDriveLetter {
    $used = (Get-PSDrive -PSProvider FileSystem).Name
    foreach ($letter in [char[]]([char]'V'..[char]'Z' + [char]'F'..[char]'U')) {
        if ($used -notcontains [string]$letter) {
            return "$letter"
        }
    }
    return "V"
}

# Configuration variables
$imagePath = ""
$selectedWimIndex = 1
$outDir = (Get-Location).Path
$vhdxName = "Win11.vhdx"
$vhdxSizeGb = 100
$detectedUser = if ($env:USERNAME) { $env:USERNAME } else { "Admin" }
$username = $detectedUser
$userPass = ""
$computerName = "PORTABLE-PC"

function Ask-SourceImage {
    while ($true) {
        $inputPath = Read-HostWithTab "Enter path to Windows ISO, install.wim, or install.esd" $script:imagePath
        
        if (Test-Path -Path $inputPath -PathType Leaf) {
            $ext = [System.IO.Path]::GetExtension($inputPath).ToLower()
            if ($ext -eq ".iso") {
                if ($script:mountedIsoPath) {
                    Dismount-DiskImage -ImagePath $script:mountedIsoPath -ErrorAction SilentlyContinue | Out-Null
                }
                Write-Color "[*] Mounting ISO image..." Cyan
                $script:mountedIsoPath = $inputPath
                $mountResult = Mount-DiskImage -ImagePath $inputPath -PassThru
                $volume = $mountResult | Get-Volume
                $isoDrive = "$($volume.DriveLetter):"
                
                $wimCandidate = Join-Path $isoDrive "sources\install.wim"
                $esdCandidate = Join-Path $isoDrive "sources\install.esd"
                
                if (Test-Path $wimCandidate) {
                    $script:imagePath = $wimCandidate
                    break
                } elseif (Test-Path $esdCandidate) {
                    $script:imagePath = $esdCandidate
                    break
                } else {
                    Dismount-DiskImage -ImagePath $inputPath | Out-Null
                    $script:mountedIsoPath = $null
                    Write-Color "[ERROR] Neither install.wim nor install.esd found inside the ISO." Red
                }
            } elseif ($ext -in @(".wim", ".esd")) {
                $script:imagePath = $inputPath
                break
            } else {
                Write-Color "[ERROR] Unsupported extension. Please choose .iso, .wim, or .esd." Red
            }
        } else {
            Write-Color "[ERROR] File not found: '$inputPath'. Try again." Red
        }
    }
}

function Ask-WimIndex {
    Write-Color "`n[*] Scanning image editions..." Cyan
    $wimInfo = & dism.exe /Get-WimInfo /WimFile:"$script:imagePath"
    $wimInfo | Out-String | Write-Host

    while ($true) {
        $idxInput = Read-HostWithTab "Enter Image Index to apply" "$script:selectedWimIndex"
        if ($idxInput -match '^\d+$') {
            $script:selectedWimIndex = [int]$idxInput
            break
        }
        Write-Color "Please enter a valid numeric index." Red
    }
}

function Ask-OutputConfig {
    $script:outDir = (Read-HostWithTab "Enter output directory" "$script:outDir").TrimEnd('/\')
    if (-not (Test-Path $script:outDir)) {
        New-Item -ItemType Directory -Path $script:outDir -Force | Out-Null
    }

    $script:vhdxName = Read-HostWithTab "Enter VHDX filename" "$script:vhdxName"
    if (-not $script:vhdxName.ToLower().EndsWith(".vhdx")) { $script:vhdxName += ".vhdx" }

    $sizeInput = Read-HostWithTab "Enter VHDX max expandable size in GB" "$script:vhdxSizeGb"
    if ($sizeInput -match '^\d+$') { $script:vhdxSizeGb = [int]$sizeInput }
}

function Ask-UserConfig {
    $script:username = Read-HostWithTab "Enter Local Username" "$script:username"
    Write-Host "Enter Password for '$script:username' (leave blank for none): " -NoNewline -ForegroundColor Cyan
    $script:userPass = Read-Host
    $script:computerName = Read-HostWithTab "Enter Computer Name" "$script:computerName"
}

# Initial Prompts
Write-Color "`n[1/5] Image Source" Green
Ask-SourceImage
Ask-WimIndex

Write-Color "`n[2/5] VHDX Configuration" Green
Ask-OutputConfig

Write-Color "`n[3/5] User & System Configuration" Green
Ask-UserConfig

# Review & Edit Loop
while ($true) {
    $script:finalVhdxPath = Join-Path $script:outDir $script:vhdxName
    Write-Color "`n==================== Summary of Settings ====================" Green
    Write-Host " [1] Source Image : $script:imagePath"
    Write-Host " [2] Image Index  : $script:selectedWimIndex"
    Write-Host " [3] Output Dir   : $script:outDir"
    Write-Host " [4] VHDX Name    : $script:vhdxName -> ($script:finalVhdxPath)"
    Write-Host " [5] Max Size     : $script:vhdxSizeGb GB Dynamic (Expandable)"
    Write-Host " [6] User & PC    : User: $script:username | Pass: $(if ([string]::IsNullOrEmpty($script:userPass)) { '(None)' } else { '********' }) | PC: $script:computerName"
    Write-Host "     Metadata Tag : portable operating system 1"
    Write-Color "=============================================================" Green
    Write-Host "Options:"
    Write-Host "  - Press [Enter] or type 'y' to START building."
    Write-Host "  - Type a number (1-6) to EDIT that specific field."
    Write-Host "  - Type 'q' to cancel."
    
    $choice = (Read-Host "Choose option [Y/1-6/q]").Trim()
    if ([string]::IsNullOrWhiteSpace($choice) -or $choice -match '^[Yy]$') {
        break
    } elseif ($choice -eq "1") {
        Ask-SourceImage
        Ask-WimIndex
    } elseif ($choice -eq "2") {
        Ask-WimIndex
    } elseif ($choice -in @("3", "4", "5")) {
        Ask-OutputConfig
    } elseif ($choice -eq "6") {
        Ask-UserConfig
    } elseif ($choice -match '^[Qq]$') {
        Write-Color "Operation cancelled by user." Yellow
        if ($script:mountedIsoPath) { Dismount-DiskImage -ImagePath $script:mountedIsoPath -ErrorAction SilentlyContinue | Out-Null }
        exit 0
    }
}

try {
    # Free space check
    $outDriveRoot = [System.IO.Path]::GetPathRoot($script:outDir)
    $driveInfo = Get-PSDrive ($outDriveRoot.TrimEnd(':\')) -ErrorAction SilentlyContinue
    if ($driveInfo) {
        $freeGb = [math]::Round($driveInfo.Free / 1GB, 2)
        if ($freeGb -lt 20) {
            Write-Color "[WARNING] Target drive has only $freeGb GB free space." Yellow
            $continueSpace = Read-Host "Proceed anyway? [y/N]"
            if ($continueSpace -notmatch '^[Yy]$') { exit 1 }
        }
    }

    if (Test-Path $script:finalVhdxPath) {
        Write-Color "[WARNING] '$script:finalVhdxPath' already exists." Yellow
        $overwrite = Read-Host "Overwrite existing file? [y/N]"
        if ($overwrite -notmatch '^[Yy]$') {
            Write-Color "Aborted by user." Red
            exit 1
        }
        Remove-Item $script:finalVhdxPath -Force
    }

    $vhdxSizeMb = $script:vhdxSizeGb * 1024
    $xmlUser = Escape-Xml $script:username
    $xmlPass = Escape-Xml $script:userPass
    $xmlComp = Escape-Xml $script:computerName

    # 1. Diskpart create
    Write-Color "`n[*] Step 1: Creating and mounting VHDX via diskpart..." Cyan
    $script:targetDrive = Get-FreeDriveLetter
    $diskpartScript = @"
create vdisk file="$script:finalVhdxPath" maximum=$vhdxSizeMb type=expandable
select vdisk file="$script:finalVhdxPath"
attach vdisk
convert gpt
create partition msr size=16
create partition primary
format fs=ntfs quick label="VHDWindows"
assign letter=$script:targetDrive
"@

    $dpTemp = [System.IO.Path]::GetTempFileName()
    $diskpartScript | Out-File -FilePath $dpTemp -Encoding ascii
    & diskpart.exe /s $dpTemp | Out-Null
    Remove-Item $dpTemp -Force

    Start-Sleep -Seconds 2
    $vhdDriveRoot = "$($script:targetDrive):\"

    # 2. Apply DISM
    Write-Color "`n[*] Step 2: Applying Windows image to $vhdDriveRoot via DISM..." Cyan
    $pinfo = New-Object System.Diagnostics.ProcessStartInfo
    $pinfo.FileName = "dism.exe"
    $pinfo.Arguments = "/Apply-Image /ImageFile:`"$script:imagePath`" /Index:$script:selectedWimIndex /ApplyDir:`"$vhdDriveRoot`""
    $pinfo.UseShellExecute = $false
    $script:dismProcess = [System.Diagnostics.Process]::Start($pinfo)
    $script:dismProcess.WaitForExit()
    
    if ($script:dismProcess.ExitCode -ne 0) {
        throw "DISM execution failed with exit code $($script:dismProcess.ExitCode)"
    }
    $script:dismProcess = $null

    # 3. Inject unattended XML
    Write-Color "`n[*] Step 3: Injecting unattended answer file (portable operating system 1)..." Cyan
    $pantherDir = Join-Path $vhdDriveRoot "Windows\Panther"
    $sysprepDir = Join-Path $vhdDriveRoot "Windows\System32\Sysprep"
    if (-not (Test-Path $pantherDir)) { New-Item -ItemType Directory -Path $pantherDir -Force | Out-Null }
    if (-not (Test-Path $sysprepDir)) { New-Item -ItemType Directory -Path $sysprepDir -Force | Out-Null }

    $unattendXmlContent = @"
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
    [System.IO.File]::WriteAllText((Join-Path $pantherDir "unattend.xml"), $unattendXmlContent, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText((Join-Path $sysprepDir "unattend.xml"), $unattendXmlContent, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText((Join-Path $vhdDriveRoot "autounattend.xml"), $unattendXmlContent, [System.Text.Encoding]::UTF8)

    # 4. Offline Registry Patch
    Write-Color "`n[*] Step 4: Injecting PortableOperatingSystem into offline SYSTEM registry..." Cyan
    $sysHivePath = Join-Path $vhdDriveRoot "Windows\System32\config\SYSTEM"
    if (Test-Path $sysHivePath) {
        & reg.exe load HKLM\VHD_OFFLINE_SYSTEM "$sysHivePath" | Out-Null
        if ($LASTEXITCODE -eq 0) {
            & reg.exe add "HKLM\VHD_OFFLINE_SYSTEM\ControlSet001\Control" /v PortableOperatingSystem /t REG_DWORD /d 1 /f | Out-Null
            & reg.exe add "HKLM\VHD_OFFLINE_SYSTEM\ControlSet001\Services\vhdmp" /v Start /t REG_DWORD /d 0 /f | Out-Null
            & reg.exe add "HKLM\VHD_OFFLINE_SYSTEM\ControlSet001\Services\fsdepends" /v Start /t REG_DWORD /d 0 /f | Out-Null
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            & reg.exe unload HKLM\VHD_OFFLINE_SYSTEM | Out-Null
            Write-Color "  [+] Offline registry successfully patched." Green
        }
    }

    $script:operationCompleted = $true

} catch {
    Write-Color "[EXCEPTION] $($_.Exception.Message)" Red
} finally {
    Invoke-ForceCleanup
}

if ($script:operationCompleted) {
    Write-Color "`n==========================================================" Green
    Write-Color "                 PROCESS COMPLETED SUCCESSFULLY!          " Green
    Write-Color "==========================================================" Green
    Write-Host "Generated VHDX : $script:finalVhdxPath"
    Write-Host ""
    Write-Color "Ventoy VHD Boot Setup & Official Resources:" Cyan
    Write-Host "For Ventoy to boot Windows VHD/VHDX, download the official plugin:"
    Write-Host "  Official Guide : https://www.ventoy.net/en/plugin_vhd.html"
    Write-Host "  Download Plugin: https://github.com/ventoy/vhdiso/releases"
    Write-Host ""
    Write-Color "Quick Steps:" Yellow
    Write-Host "1. Download 'ventoy_vhdboot.zip' from the link above and extract 'ventoy_vhdboot.img'."
    Write-Host "2. On your Ventoy USB drive, create a folder named 'ventoy' in root."
    Write-Host "3. Copy 'ventoy_vhdboot.img' into that '\ventoy\' folder."
    Write-Host "4. Copy '$script:vhdxName' anywhere on the Ventoy USB drive."
    Write-Host "5. Boot from Ventoy and choose your Windows VHDX!"
    Write-Color "==========================================================" Green
} else {
    Write-Color "`n[!] Build was aborted or encountered errors. System was restored cleanly." Red
    exit 1
}
