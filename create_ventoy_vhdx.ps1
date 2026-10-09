<#
.SYNOPSIS
    Interactive & Industrial-Grade Windows VHDX Builder for Ventoy (Windows Native).
.DESCRIPTION
    Creates a bootable VHDX, mounts it, applies install.wim/install.esd/ISO via DISM,
    injects unattended answer file (portable operating system 1) to bypass OOBE,
    generates UEFI boot files via bcdboot, and downloads ventoy_vhdboot.img.
    Includes advanced Forced Termination & Tab Completion.
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

# Helper for Tab-Completion in PowerShell Read-Host
function Read-HostWithTab([string]$prompt) {
    Write-Host $prompt -NoNewline -ForegroundColor Cyan
    Write-Host " (Tab auto-complete enabled): " -NoNewline -ForegroundColor Yellow
    
    # Check if PSReadLine is available (standard in PowerShell 5.1+)
    if (Get-Module -Name PSReadLine) {
        return (Read-Host)
    } else {
        try {
            Import-Module PSReadLine -ErrorAction SilentlyContinue
            return (Read-Host)
        } catch {
            return (Read-Host)
        }
    }
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

try {
    # 2. Image Selection with Tab-Complete
    Write-Color "[1/5] Image Source (.iso / .wim / .esd)" Green
    $imagePath = ""

    while ($true) {
        $inputPath = Read-HostWithTab "Enter path to Windows ISO, install.wim, or install.esd"
        $inputPath = $inputPath.Trim('"', "'", " ")
        
        if (Test-Path -Path $inputPath -PathType Leaf) {
            $ext = [System.IO.Path]::GetExtension($inputPath).ToLower()
            if ($ext -eq ".iso") {
                Write-Color "[*] Mounting ISO image..." Cyan
                $script:mountedIsoPath = $inputPath
                $mountResult = Mount-DiskImage -ImagePath $inputPath -PassThru
                $volume = $mountResult | Get-Volume
                $isoDrive = "$($volume.DriveLetter):"
                
                $wimCandidate = Join-Path $isoDrive "sources\install.wim"
                $esdCandidate = Join-Path $isoDrive "sources\install.esd"
                
                if (Test-Path $wimCandidate) {
                    $imagePath = $wimCandidate
                    break
                } elseif (Test-Path $esdCandidate) {
                    $imagePath = $esdCandidate
                    break
                } else {
                    Dismount-DiskImage -ImagePath $inputPath | Out-Null
                    $script:mountedIsoPath = $null
                    Write-Color "[ERROR] Neither install.wim nor install.esd found inside the ISO." Red
                }
            } elseif ($ext -in @(".wim", ".esd")) {
                $imagePath = $inputPath
                break
            } else {
                Write-Color "[ERROR] Unsupported extension. Please choose .iso, .wim, or .esd." Red
            }
        } else {
            Write-Color "[ERROR] File not found: '$inputPath'. Try again." Red
        }
    }

    Write-Color "`n[*] Scanning image editions..." Cyan
    $wimInfo = & dism.exe /Get-WimInfo /WimFile:"$imagePath"
    $wimInfo | Out-String | Write-Host

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
        Write-Color "Please enter a valid numeric index." Red
    }

    # 3. VHDX Options with Tab-Complete
    Write-Color "`n[2/5] VHDX Configuration" Green
    $defaultOutDir = (Get-Location).Path
    $outDirInput = Read-HostWithTab "Enter output directory [default: $defaultOutDir]"
    $outDir = if ([string]::IsNullOrWhiteSpace($outDirInput)) { $defaultOutDir } else { $outDirInput.Trim('"', "'", " ").TrimEnd('/\') }
    if (-not (Test-Path $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }

    $outDriveRoot = [System.IO.Path]::GetPathRoot($outDir)
    $driveInfo = Get-PSDrive ($outDriveRoot.TrimEnd(':\')) -ErrorAction SilentlyContinue
    if ($driveInfo) {
        $freeGb = [math]::Round($driveInfo.Free / 1GB, 2)
        if ($freeGb -lt 25) {
            Write-Color "[WARNING] Target drive has only $freeGb GB free space (25+ GB recommended)." Yellow
            $continueSpace = Read-Host "Proceed anyway? [y/N]"
            if ($continueSpace -notmatch '^[Yy]$') {
                exit 1
            }
        }
    }

    $vhdxNameInput = Read-Host "Enter VHDX filename [default: Win11.vhdx]"
    $vhdxName = if ([string]::IsNullOrWhiteSpace($vhdxNameInput)) { "Win11.vhdx" } else { $vhdxNameInput.Trim() }
    if (-not $vhdxName.ToLower().EndsWith(".vhdx")) { $vhdxName += ".vhdx" }
    $script:finalVhdxPath = Join-Path $outDir $vhdxName

    if (Test-Path $script:finalVhdxPath) {
        Write-Color "[WARNING] '$script:finalVhdxPath' already exists." Yellow
        $overwrite = Read-Host "Overwrite existing file? [y/N]"
        if ($overwrite -notmatch '^[Yy]$') {
            Write-Color "Aborted by user." Red
            exit 1
        }
        Remove-Item $script:finalVhdxPath -Force
    }

    $vhdxSizeInput = Read-Host "Enter VHDX max expandable size in GB [default: 100]"
    $vhdxSizeGb = if ([string]::IsNullOrWhiteSpace($vhdxSizeInput)) { 100 } else { [int]$vhdxSizeInput }
    $vhdxSizeMb = $vhdxSizeGb * 1024

    # 4. User and OOBE Settings
    Write-Color "`n[3/5] User & System Configuration" Green
    $detectedUser = if ($env:USERNAME) { $env:USERNAME } else { "Admin" }
    $usernameInput = Read-Host "Enter Local Username [default: $detectedUser]"
    $username = if ([string]::IsNullOrWhiteSpace($usernameInput)) { $detectedUser } else { $usernameInput.Trim() }

    $userPass = Read-Host "Enter Password for '$username' (leave blank for none)"

    $computerNameInput = Read-Host "Enter Computer Name [default: PORTABLE-PC]"
    $computerName = if ([string]::IsNullOrWhiteSpace($computerNameInput)) { "PORTABLE-PC" } else { $computerNameInput.Trim() }

    $xmlUser = Escape-Xml $username
    $xmlPass = Escape-Xml $userPass
    $xmlComp = Escape-Xml $computerName

    Write-Color "`nSettings Summary:" Cyan
    Write-Host " - Image Path    : $imagePath (Index: $selectedWimIndex)"
    Write-Host " - Target VHDX   : $script:finalVhdxPath ($vhdxSizeGb GB Dynamic)"
    Write-Host " - Username      : $username"
    Write-Host " - Password      : $(if ([string]::IsNullOrEmpty($userPass)) { '(None)' } else { '********' })"
    Write-Host " - Metadata Tag  : portable operating system 1"
    Write-Host ""

    $confirm = Read-Host "Start build? [Y/n]"
    if (-not [string]::IsNullOrWhiteSpace($confirm) -and $confirm -notmatch '^[Yy]$') {
        Write-Color "Cancelled by user." Yellow
        exit 0
    }

    # 5. Diskpart create
    Write-Color "`n[*] Step 1: Creating and mounting VHDX via diskpart..." Cyan
    $script:targetDrive = Get-FreeDriveLetter
    $diskpartScript = @"
create vdisk file="$script:finalVhdxPath" maximum=$vhdxSizeMb type=expandable
select vdisk file="$script:finalVhdxPath"
attach vdisk
convert gpt
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

    # 6. Apply DISM with process tracking for cancellation
    Write-Color "`n[*] Step 2: Applying Windows image to $vhdDriveRoot via DISM..." Cyan
    $pinfo = New-Object System.Diagnostics.ProcessStartInfo
    $pinfo.FileName = "dism.exe"
    $pinfo.Arguments = "/Apply-Image /ImageFile:`"$imagePath`" /Index:$selectedWimIndex /ApplyDir:`"$vhdDriveRoot`""
    $pinfo.UseShellExecute = $false
    $script:dismProcess = [System.Diagnostics.Process]::Start($pinfo)
    $script:dismProcess.WaitForExit()
    
    if ($script:dismProcess.ExitCode -ne 0) {
        throw "DISM execution failed with exit code $($script:dismProcess.ExitCode)"
    }
    $script:dismProcess = $null

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
    [System.IO.File]::WriteAllText((Join-Path $pantherDir "unattend.xml"), $unattendXmlContent, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText((Join-Path $sysprepDir "unattend.xml"), $unattendXmlContent, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText((Join-Path $vhdDriveRoot "autounattend.xml"), $unattendXmlContent, [System.Text.Encoding]::UTF8)

    # 8. Configure BCD
    Write-Color "`n[*] Step 4: Generating BCD Bootloader via bcdboot..." Cyan
    $winDir = Join-Path $vhdDriveRoot "Windows"
    & bcdboot.exe "$winDir" /s "$($script:targetDrive):" /f ALL | Out-Null

    $script:operationCompleted = $true

} catch {
    Write-Color "[EXCEPTION] $($_.Exception.Message)" Red
} finally {
    Invoke-ForceCleanup
}

if ($script:operationCompleted) {
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
                Write-Color "[+] Prepared ventoy_vhdboot.img." Green
            }
        } catch {
            Write-Color "[WARNING] Auto-download failed. You can download manually from https://github.com/ventoy/vhdiso/releases" Yellow
        } finally {
            if (Test-Path $zipTemp) { Remove-Item $zipTemp -Force }
            if (Test-Path $extractTemp) { Remove-Item $extractTemp -Recurse -Force }
        }
    }

    Write-Color "`n==========================================================" Green
    Write-Color "                 PROCESS COMPLETED SUCCESSFULLY!          " Green
    Write-Color "==========================================================" Green
    Write-Host "Generated VHDX : $script:finalVhdxPath"
    Write-Host "Ventoy Plugin  : $pluginDest"
    Write-Host ""
    Write-Color "Ventoy Deployment Instructions:" Yellow
    Write-Host "1. On your Ventoy USB drive, create a folder named 'ventoy' in root."
    Write-Host "2. Copy 'ventoy_vhdboot.img' into that '\ventoy\' folder."
    Write-Host "3. Copy '$vhdxName' anywhere on the Ventoy USB drive."
    Write-Host "4. Boot from Ventoy and choose your Windows VHDX!"
    Write-Color "==========================================================" Green
} else {
    Write-Color "`n[!] Build was aborted or encountered errors. System was restored cleanly." Red
    exit 1
}
