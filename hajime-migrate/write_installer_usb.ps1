<#
.SYNOPSIS
    Write the FreeBSD installer image to a USB stick, destroying what is on it.

.DESCRIPTION
    This overwrites a physical disk. There is no undo and no recycle bin, and
    the usual way this goes wrong is a number typed one digit off, so the
    script refuses more than it accepts:

      - the target must be a USB disk, not the system or boot disk
      - it must not be disk 0
      - it prints what is currently on it and stops unless -Yes is passed

    Needs an elevated PowerShell. Opening \\.\PhysicalDriveN for writing is
    not something an ordinary user account can do, and the failure without
    elevation is an unhelpful access-denied halfway through.

.PARAMETER Image
    The decompressed .img. Not the .xz -- decompress it first.

.PARAMETER Disk
    Disk number from Get-Disk. Look before you type it.

.PARAMETER Yes
    Actually write. Without it the script reports and exits.

.EXAMPLE
    # Look first, always.
    Get-Disk

    .\write_installer_usb.ps1 -Image C:\hajime-vm\FreeBSD-14.4-RELEASE-amd64-memstick.img -Disk 1
    .\write_installer_usb.ps1 -Image C:\hajime-vm\FreeBSD-14.4-RELEASE-amd64-memstick.img -Disk 1 -Yes
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Image,
    [Parameter(Mandatory = $true)][int]$Disk,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'

function Say { param($m) Write-Host "   $m" }
function Die { param($m) Write-Host "`n   REFUSED: $m" -ForegroundColor Red; exit 1 }

Write-Host "Write a FreeBSD installer to USB"

# --- elevation --------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Die "this needs an elevated PowerShell. Right-click, Run as administrator."
}

# --- the image --------------------------------------------------------------
if (-not (Test-Path $Image)) { Die "no image at $Image" }
if ($Image -like '*.xz') {
    Die "that is still compressed. Decompress it first: xz -dk $Image"
}
$imageBytes = (Get-Item $Image).Length
Say ("image: {0}  ({1:N1} GB)" -f $Image, ($imageBytes / 1GB))

# --- the target, and every reason not to write to it ------------------------
$target = Get-Disk -Number $Disk -ErrorAction SilentlyContinue
if (-not $target) { Die "there is no disk $Disk. Run Get-Disk and look." }

if ($Disk -eq 0)        { Die "disk 0 is where Windows lives. Not this one." }
if ($target.IsSystem)   { Die "disk $Disk is the system disk." }
if ($target.IsBoot)     { Die "disk $Disk is the boot disk." }
if ($target.BusType -ne 'USB') {
    Die ("disk {0} is on the {1} bus, not USB. This script only writes to USB " +
         "disks, because the number being one digit off is how the wrong disk " +
         "gets erased." -f $Disk, $target.BusType)
}
if ($target.Size -lt $imageBytes) {
    Die ("disk {0} holds {1:N1} GB and the image is {2:N1} GB." -f
         $Disk, ($target.Size / 1GB), ($imageBytes / 1GB))
}

Write-Host "`n   This disk will be completely erased:" -ForegroundColor Yellow
Say ("disk {0}: {1}, {2:N1} GB, {3}" -f $Disk, $target.FriendlyName,
     ($target.Size / 1GB), $target.BusType)

# Name what is on it. "ESD-USB" is a Windows installer; someone should see
# that before it goes away.
$vols = Get-Partition -DiskNumber $Disk -ErrorAction SilentlyContinue |
        Get-Volume -ErrorAction SilentlyContinue
if ($vols) {
    foreach ($v in $vols) {
        Say ("  contains: {0}: [{1}] {2}, {3:N1} GB" -f $v.DriveLetter,
             $v.FileSystemLabel, $v.FileSystem, ($v.Size / 1GB))
    }
} else {
    Say "  no readable volumes on it"
}

if (-not $Yes) {
    Write-Host "`n   Nothing was written. Re-run with -Yes to go ahead." -ForegroundColor Cyan
    exit 0
}

# --- write ------------------------------------------------------------------
# Offline first. Windows holds open handles on mounted volumes and the write
# fails partway through with a sharing violation, leaving a half-written stick
# that still looks bootable.
Say "taking the disk offline"
Set-Disk -Number $Disk -IsOffline $true
Start-Sleep -Seconds 1

$in = $null; $out = $null
try {
    $in  = [System.IO.File]::OpenRead($Image)
    $out = New-Object System.IO.FileStream("\\.\PhysicalDrive$Disk",
              [System.IO.FileMode]::Open,
              [System.IO.FileAccess]::Write,
              [System.IO.FileShare]::None)

    $buffer = New-Object byte[] (4MB)
    $written = 0L
    $started = Get-Date
    while (($read = $in.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $out.Write($buffer, 0, $read)
        $written += $read
        Write-Progress -Activity "Writing $Image" `
            -Status ("{0:N0} MB of {1:N0} MB" -f ($written / 1MB), ($imageBytes / 1MB)) `
            -PercentComplete ([int](100 * $written / $imageBytes))
    }
    $out.Flush()
    $elapsed = [int]((Get-Date) - $started).TotalSeconds
    Say ("wrote {0:N0} MB in {1}s" -f ($written / 1MB), $elapsed)
} catch {
    Die "the write failed: $($_.Exception.Message)"
} finally {
    if ($out) { $out.Close() }
    if ($in)  { $in.Close() }
    Set-Disk -Number $Disk -IsOffline $false -ErrorAction SilentlyContinue
}

Write-Host @"

   Done. The stick now holds a FreeBSD 14.4 installer.

   Windows will offer to format it when you plug it back in. Say no: it
   cannot read UFS and the offer means nothing about whether the stick works.

   Next, from hajime-migrate/INSTALL_PLAN.md: boot the server from it, and
   note that the repository does not need to be on this stick. Once sshd is
   running on the new system you can copy it across the network.
"@ -ForegroundColor Green
