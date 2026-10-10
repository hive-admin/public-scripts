# 1. Set the download destination on your personal PC (Change this if you want it saved elsewhere)
$DownloadTarget = "C:\HetznerDownload"
New-Item -ItemType Directory -Force -Path $DownloadTarget | Out-Null

# 2. Download the latest rclone for Windows directly from their official servers
Write-Host "Downloading rclone..." -ForegroundColor Cyan
$RcloneZip = "$env:TEMP\rclone-latest.zip"
Invoke-WebRequest -Uri "https://downloads.rclone.org/rclone-current-windows-amd64.zip" -OutFile $RcloneZip

# 3. Extract it to a local folder in your user profile
Write-Host "Extracting rclone..." -ForegroundColor Cyan
$ExtractPath = "$env:LOCALAPPDATA\rclone-app"
Expand-Archive -Path $RcloneZip -DestinationPath $ExtractPath -Force
$RcloneExe = Get-ChildItem -Path $ExtractPath -Filter "rclone.exe" -Recurse | Select-Object -First 1 | Select-Object -ExpandProperty FullName

# 4. Generate the encrypted password for the rclone config (encrypts 'transfer123')
$ObscuredPass = & $RcloneExe obscure "transfer123"

# 5. Create the rclone configuration file silently
Write-Host "Configuring remote connection..." -ForegroundColor Cyan
$ConfigDir = "$env:APPDATA\rclone"
New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
$ConfigText = @"
[hetzner-source]
type = ftp
host = 65.109.17.251
user = admin
port = 2121
pass = $ObscuredPass
"@
Set-Content -Path "$ConfigDir\rclone.conf" -Value $ConfigText

# 6. Start the high-speed download
Write-Host "Starting 5TB Download from Hetzner..." -ForegroundColor Green
& $RcloneExe copy hetzner-source:X $DownloadTarget -P --transfers=16 --checkers=32 --buffer-size=64M
