# Универсальная настройка Windows-клиента tailnet (Tailscale -> свой Headscale).
# Запуск в PowerShell ОТ АДМИНИСТРАТОРА: .\setup-windows.ps1
# Интерактивный и идемпотентный: при повторном запуске видит установленное и не переспрашивает лишнего.

$ErrorActionPreference = "Stop"
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Запусти PowerShell от имени администратора"
}

# ---------- чтение/запись состояния ----------
$StateFile = Join-Path $PSScriptRoot ".setup-state.ps1"
$ServerUrl = ""
if (Test-Path $StateFile) { . $StateFile }

function Save-State {
    param($s)
    "ServerUrl='$($s -replace "'","''")'" | Set-Content -Encoding UTF8 $StateFile
}

# ---------- диалоги ----------
if (-not $ServerUrl) {
    Write-Host "1) Адрес control plane — это DNS-имя твоего VPS с Headscale." -ForegroundColor Cyan
    Write-Host "   (то самое, что указывал при настройке сервера; например https://lan.example.com)" -ForegroundColor DarkGray
    $ServerUrl = Read-Host "   Адрес сервера"
    if (-not $ServerUrl.StartsWith("http")) { $ServerUrl = "https://$ServerUrl" }
    Save-State $ServerUrl
} else {
    Write-Host "Найдена конфигурация: сервер $ServerUrl" -ForegroundColor Green
    $reconf = Read-Host "   Изменить адрес сервера? [y/N]"
    if ($reconf -eq "y" -or $reconf -eq "Y") {
        $ServerUrl = Read-Host "   Новый адрес сервера"
        if (-not $ServerUrl.StartsWith("http")) { $ServerUrl = "https://$ServerUrl" }
        Save-State $ServerUrl
    }
}

# ---------- установка tailscale ----------
$ts = "C:\Program Files\Tailscale\tailscale.exe"
if (-not (Test-Path $ts)) {
    Write-Host "[1/4] Устанавливаю Tailscale..." -ForegroundColor Green
    winget install --id Tailscale.Tailscale --accept-package-agreements --accept-source-agreements --silent
    if (-not (Test-Path $ts)) { throw "tailscale.exe не найден после установки" }
} else { Write-Host "[1/4] Tailscale уже установлен" -ForegroundColor Green }

# ---------- подключение ----------
Write-Host "[2/4] Подключение к $ServerUrl ..." -ForegroundColor Green
$upArgs = @("up", "--login-server=$ServerUrl", "--accept-dns=true")
& $ts @upArgs
& $ts status

# ---------- DNS-проверка ----------
Write-Host "[3/4] DNS-проверка..." -ForegroundColor Green
ipconfig /flushdns | Out-Null; Start-Sleep 1
# любое имя из tailnet: возьмём имя сервера из URL
$hostName = ([Uri]$ServerUrl).Host
$ok = & Resolve-DnsName $hostName -Type A -QuickTimeout -ErrorAction SilentlyContinue
if (-not $ok) {
    Write-Host "DNS не резолвится." -ForegroundColor Yellow
    Write-Host "Частая причина: параллельный VPN перехватывает DNS-запросы." -ForegroundColor Yellow
    Write-Host "Два способа лечения:" -ForegroundColor Yellow
    Write-Host "  A) В настройках твоего VPN добавить tailnet-подсеть 100.64.0.0/10 в исключения (split-tunneling)" -ForegroundColor Yellow
    Write-Host "  B) Внести запись в hosts (спросит сейчас): $hostName -> IP сервера в tailnet" -ForegroundColor Yellow
    $fix = Read-Host "   Внести запись в hosts? [Y/n]"
    if ($fix -ne "n" -and $fix -ne "N") {
        $ip = Read-Host "   Tailnet-IP сервера (например 100.64.0.4)"
        $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
        $existing = Select-String -Path $hostsPath -Pattern ([regex]::Escape($hostName)) -SimpleMatch -ErrorAction SilentlyContinue
        if ($existing) { Write-Host "   Запись уже есть, пропускаю" -ForegroundColor Green }
        else { Add-Content -Path $hostsPath -Value "$ip $hostName"; Write-Host "   Добавлено: $ip $hostName" -ForegroundColor Green }
        ipconfig /flushdns | Out-Null; Start-Sleep 1
        $ok = & Resolve-DnsName $hostName -Type A -QuickTimeout -ErrorAction SilentlyContinue
    }
}
if ($ok) { Write-Host "OK: $hostName -> $($ok.IPAddress)" -ForegroundColor Green }
else { Write-Host "FAIL: проверь 'tailscale status' и split-tunneling VPN" -ForegroundColor Red; exit 1 }

# ---------- связность ----------
Write-Host "[4/4] Проверка связности..." -ForegroundColor Green
& $ts ping --c 1 $hostName
Write-Host "`nГотово. Админка: $ServerUrl/admin" -ForegroundColor Green
