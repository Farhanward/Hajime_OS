<#
.SYNOPSIS
    Build a throwaway FreeBSD VM and prove the backup restores into it.

.DESCRIPTION
    A backup nobody has restored is a rumour. This builds a machine that has
    never seen the production server, installs Hajime on it, restores a real
    backup, and reports what came back and what did not.

    Nothing here touches the production server. It reads a backup directory that
    was already pulled off it.

    The VM boots FreeBSD's official ZFS image rather than running an installer,
    for two reasons: the install is not what is being rehearsed, and Hajime
    needs a ZFS pool -- its whole rollback story is boot environments, and the
    UFS image would stop at the installer's first refusal.

.PARAMETER Backup
    A directory produced by hajime-migrate/backup.sh.

.PARAMETER Vhd
    The decompressed FreeBSD-14.4-RELEASE-amd64-zfs.vhd. It is copied, never
    used in place, so the rehearsal can be repeated from a clean disk.

.PARAMETER Name
    VM name. An existing VM with this name is removed first -- it is a
    rehearsal, and a stale one is worse than none.

.EXAMPLE
    .\rehearse.ps1 -Backup C:\hajime-backups\carbonflow-20260806-155116 `
                   -Vhd C:\hajime-vm\hajime-rehearsal.vhd

.NOTES
    Needs Hyper-V rights: either an elevated shell, or membership of the
    "Hyper-V Administrators" group. Without them New-VM refuses and this script
    says so rather than failing halfway through.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Backup,
    [Parameter(Mandatory = $true)][string]$Vhd,
    [string]$Name = 'hajime-rehearsal',
    [int]$MemoryMB = 4096,
    [int]$Cpus = 2,
    [string]$Switch = 'Default Switch',
    [switch]$KeepExisting
)

$ErrorActionPreference = 'Stop'

function Say  { param($m) Write-Host "   $m" }
function Step { param($m) Write-Host "`n== $m" -ForegroundColor Cyan }
function Die  { param($m) Write-Host "`n   REFUSED: $m" -ForegroundColor Red; exit 1 }

Write-Host "Hajime restore rehearsal"

# --- 1. can this shell drive Hyper-V at all? -------------------------------
Step 'permissions'
try {
    Get-VM -ErrorAction Stop | Out-Null
} catch {
    Die @"
Hyper-V is not reachable from this shell.
       Run PowerShell as administrator, or grant the account once:
         Add-LocalGroupMember -Group "Hyper-V Administrators" -Member `$env:USERNAME
       then sign out and back in.
"@
}
# Reading is often allowed where creating is not, so prove the one that matters
# before spending ten minutes copying a six gigabyte disk.
try {
    New-VM -Name "$Name-probe" -MemoryStartupBytes 512MB -Generation 2 -NoVHD -ErrorAction Stop | Out-Null
    Remove-VM -Name "$Name-probe" -Force -ErrorAction Stop
    Say 'this shell may create virtual machines'
} catch {
    Die @"
This shell can read virtual machines but not create them.
       $($_.Exception.Message)
       Run PowerShell as administrator, or:
         Add-LocalGroupMember -Group "Hyper-V Administrators" -Member `$env:USERNAME
       then sign out and back in.
"@
}

# --- 2. inputs -------------------------------------------------------------
Step 'inputs'
if (-not (Test-Path $Backup)) { Die "no backup directory at $Backup" }
foreach ($required in 'SHA256SUMS', 'MANIFEST.txt', 'configs/opt.tar.gz') {
    if (-not (Test-Path (Join-Path $Backup $required))) {
        Die "$Backup does not look like a hajime backup: $required is missing"
    }
}
$size = (Get-ChildItem $Backup -Recurse -File | Measure-Object Length -Sum).Sum / 1MB
Say ("backup: {0}  ({1:N0} MB)" -f $Backup, $size)

if (-not (Test-Path $Vhd)) { Die "no disk image at $Vhd" }
Say ("image:  {0}  ({1:N1} GB)" -f $Vhd, ((Get-Item $Vhd).Length / 1GB))

if (-not (Get-VMSwitch -Name $Switch -ErrorAction SilentlyContinue)) {
    Die "no virtual switch named '$Switch'. Available: $((Get-VMSwitch).Name -join ', ')"
}

# --- 3. a clean machine ----------------------------------------------------
Step 'the machine'
$existing = Get-VM -Name $Name -ErrorAction SilentlyContinue
if ($existing) {
    if ($KeepExisting) { Die "a VM named $Name already exists and -KeepExisting was given" }
    Say "removing the previous $Name"
    if ($existing.State -ne 'Off') { Stop-VM -Name $Name -TurnOff -Force }
    $old = (Get-VMHardDiskDrive -VMName $Name -ErrorAction SilentlyContinue).Path
    Remove-VM -Name $Name -Force
    foreach ($p in $old) { if ($p -and (Test-Path $p)) { Remove-Item $p -Force } }
}

$vmDir = Join-Path (Split-Path $Vhd -Parent) $Name
New-Item -ItemType Directory -Path $vmDir -Force | Out-Null
$disk = Join-Path $vmDir "$Name.vhd"

# Copied, not used in place: the rehearsal has to be repeatable from a disk
# that has never been booted, and a rehearsal that mutates its own source is a
# rehearsal you get one of.
Say 'copying the disk image (this is the slow part)'
Copy-Item $Vhd $disk -Force
Say ("disk: {0}" -f $disk)

# Generation 1. FreeBSD's VM images boot BIOS, and Generation 2 is UEFI with
# Secure Boot -- which is a longer argument than this rehearsal needs.
New-VM -Name $Name -MemoryStartupBytes ($MemoryMB * 1MB) -Generation 1 `
       -VHDPath $disk -SwitchName $Switch | Out-Null
Set-VM -Name $Name -ProcessorCount $Cpus -AutomaticCheckpointsEnabled $false
Say ("{0}: {1} MB, {2} vCPU, switch '{3}'" -f $Name, $MemoryMB, $Cpus, $Switch)

# --- 4. the second disk, carrying the backup and the repository ------------
# Handed over as a disk rather than copied in over the network: the VM has no
# credentials, no key and no reason to trust this host, and a rehearsal should
# not start by inventing a trust relationship it will not have in production.
Step 'the payload disk'
$payload = Join-Path $vmDir 'payload.vhdx'
$payloadDir = Join-Path $vmDir 'payload'
if (Test-Path $payloadDir) { Remove-Item $payloadDir -Recurse -Force }
New-Item -ItemType Directory -Path $payloadDir | Out-Null

$repo = Split-Path $PSScriptRoot -Parent
Say 'staging the repository and the backup'
robocopy $repo (Join-Path $payloadDir 'Hajime_OS') /E /NFL /NDL /NJH /NJS /NP `
    /XD target .git node_modules | Out-Null
robocopy $Backup (Join-Path $payloadDir 'backup') /E /NFL /NDL /NJH /NJS /NP | Out-Null

$payloadMB = [math]::Ceiling((Get-ChildItem $payloadDir -Recurse -File |
    Measure-Object Length -Sum).Sum / 1MB) + 512
Say ("payload: {0} MB" -f $payloadMB)

New-VHD -Path $payload -SizeBytes ($payloadMB * 1MB) -Dynamic | Out-Null
$mounted = Mount-VHD -Path $payload -Passthru | Initialize-Disk -PartitionStyle MBR -PassThru |
           New-Partition -UseMaximumSize -AssignDriveLetter |
           Format-Volume -FileSystem FAT32 -NewFileSystemLabel 'HAJIME' -Confirm:$false
$letter = $mounted.DriveLetter
Say ("mounted as {0}:" -f $letter)
robocopy $payloadDir "${letter}:\" /E /NFL /NDL /NJH /NJS /NP | Out-Null
Dismount-VHD -Path $payload
Add-VMHardDiskDrive -VMName $Name -Path $payload
Say 'payload disk attached'

# --- 5. start it, where it can be watched ----------------------------------
Step 'starting'
Start-VM -Name $Name
Say 'opening the console window'
Start-Process vmconnect.exe -ArgumentList "localhost", $Name

Write-Host @"

   The virtual machine is running and its window is open.

   Log in as root (the official image has no password set), then:

     mkdir -p /mnt/hajime && mount -t msdosfs /dev/ada1s1 /mnt/hajime
     cd /mnt/hajime/Hajime_OS
     sh install_hajime_os.sh --dry-run
     sh install_hajime_os.sh
     sh hajime-migrate/restore_data.sh /mnt/hajime/backup

   Then the question the rehearsal exists to answer:

     hajimectl check
     sh hajime-brand/verify_theme.sh

   Nothing here has touched the production server.
"@ -ForegroundColor Green
