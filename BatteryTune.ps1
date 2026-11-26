#Requires -Version 5.1
<#
    BatteryTune — универсальный тюнер автономности для Windows-ноутбуков.

    Сам определяет железо, батарею и дискретную видеокарту, показывает отчёт
    и переключает режимы: экономия (лимит CPU + отключение дискретки) и максимум.

    Запуск без параметров открывает меню.
#>
[CmdletBinding()]
param(
    [ValidateSet('menu', 'eco', 'max', 'status', 'report')]
    [string]$Action = 'menu',

    [ValidateRange(10, 100)]
    [int]$EcoCpu = 60,

    [switch]$NoGpu,
    [switch]$Force,
    [switch]$NoElevate,
    [switch]$Pause
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$script:SubProcessor     = 'SUB_PROCESSOR'
$script:SubProcessorGuid = '54533251-82be-4824-96c1-47b60b740d00'
$script:MaxStateGuid     = 'bc5038f7-23e0-4960-96da-33abaf5935ec'
$script:BoostGuid        = 'be337238-0d82-4146-a960-4f3749d470c7'

$script:BatteryCache     = $null
$script:BatteryCacheTime = [datetime]::MinValue

# ---------------------------------------------------------------- служебное

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Restart-Elevated {
    $argList = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $PSCommandPath),
        '-Action', $Action
    )
    if ($EcoCpu -ne 60) { $argList += @('-EcoCpu', $EcoCpu) }
    if ($NoGpu)  { $argList += '-NoGpu' }
    if ($Force)  { $argList += '-Force' }
    if ($Action -in @('eco', 'max')) { $argList += '-Pause' }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList | Out-Null
}

function Get-ActiveSchemeGuid {
    $text = (powercfg /getactivescheme) -join "`n"
    [regex]::Match($text, '[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}').Value
}

function Get-CpuDcValue([string]$settingGuid) {
    $scheme = Get-ActiveSchemeGuid
    if (-not $scheme) { return $null }
    $key = "HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\$scheme\$($script:SubProcessorGuid)\$settingGuid"
    if (Test-Path $key) {
        $v = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if ($null -ne $v.DCSettingIndex) { return [int]$v.DCSettingIndex }
    }
    return $null
}

function Set-CpuDcValue([string]$settingGuid, [int]$value) {
    powercfg /setdcvalueindex SCHEME_CURRENT $script:SubProcessor $settingGuid $value | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "powercfg не смог применить $settingGuid = $value" }
}

function Get-PowerSource {
    $b = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $b) { return 'неизвестно' }
    if ($b.BatteryStatus -eq 2) { return 'сеть (AC)' } else { return 'батарея' }
}

function Format-Wh([int]$mWh) {
    if ($null -eq $mWh -or $mWh -le 0) { return '—' }
    return ('{0:0.0} Вт·ч' -f ($mWh / 1000))
}

function Format-W([int]$mW) {
    if ($null -eq $mW -or $mW -le 0) { return '—' }
    return ('{0:0.0} Вт' -f ($mW / 1000))
}

# ---------------------------------------------------------------- батарея

function Get-BatteryReport {
    $path = Join-Path $env:TEMP ('BatteryTune-{0}.html' -f [guid]::NewGuid().ToString('N'))
    try {
        & powercfg /batteryreport /output $path 2>$null | Out-Null
        if (-not (Test-Path -LiteralPath $path)) { return $null }

        $html = [IO.File]::ReadAllText($path)
        $text = [regex]::Replace($html, '<[^>]+>', ' ')
        $text = $text -replace [char]0x00A0, ' '
        $text = [regex]::Replace($text, '\s+', ' ')

        $design = $null; $full = $null; $cycles = $null; $chem = $null
        $m = [regex]::Match($text, 'DESIGN CAPACITY\s+([\d ]+)\s*mWh', 'IgnoreCase')
        if ($m.Success) { $design = [int](($m.Groups[1].Value -replace '\s', '')) }
        $m = [regex]::Match($text, 'FULL CHARGE CAPACITY\s+([\d ]+)\s*mWh', 'IgnoreCase')
        if ($m.Success) { $full = [int](($m.Groups[1].Value -replace '\s', '')) }
        $m = [regex]::Match($text, 'CYCLE COUNT\s+(\d+)', 'IgnoreCase')
        if ($m.Success) { $cycles = [int]$m.Groups[1].Value }
        $m = [regex]::Match($text, 'CHEMISTRY\s+([A-Za-z]+)', 'IgnoreCase')
        if ($m.Success) { $chem = $m.Groups[1].Value }

        return [pscustomobject]@{
            Design    = $design
            Full      = $full
            Cycles    = $cycles
            Chemistry = $chem
        }
    }
    catch { return $null }
    finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
}

function Get-BatteryInfo {
    param([switch]$Fresh)

    if (-not $Fresh -and $script:BatteryCache -and
        ((Get-Date) - $script:BatteryCacheTime).TotalSeconds -lt 15) {
        return $script:BatteryCache
    }

    $info = [ordered]@{
        Present   = $false
        Design    = $null
        Full      = $null
        Remaining = $null
        Rate      = $null
        Voltage   = $null
        Online    = $null
        Cycles    = $null
        Chemistry = $null
        Health    = $null
    }

    $st = Get-CimInstance -Namespace root\wmi -ClassName BatteryStatus -ErrorAction SilentlyContinue |
          Select-Object -First 1
    if ($st) {
        $info.Present   = $true
        $info.Remaining = [int]$st.RemainingCapacity
        $info.Rate      = [int]$st.DischargeRate
        $info.Voltage   = [int]$st.Voltage
        $info.Online    = [bool]$st.PowerOnline
    }
    else {
        $wb = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($wb) {
            $info.Present = $true
            $info.Online  = ($wb.BatteryStatus -eq 2)
        }
    }

    if ($info.Present) {
        $full = Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction SilentlyContinue |
                Select-Object -First 1
        if ($full -and $full.FullChargedCapacity -gt 0) { $info.Full = [int]$full.FullChargedCapacity }

        $rep = Get-BatteryReport
        if ($rep) {
            if (-not $info.Design -and $rep.Design) { $info.Design = $rep.Design }
            if (-not $info.Full -and $rep.Full)     { $info.Full = $rep.Full }
            if ($rep.Cycles)                        { $info.Cycles = $rep.Cycles }
            if ($rep.Chemistry)                     { $info.Chemistry = $rep.Chemistry }
        }

        if ($info.Design -and $info.Full -and $info.Design -gt 0) {
            $info.Health = [math]::Round(100 * $info.Full / $info.Design)
        }
    }

    $script:BatteryCache = [pscustomobject]$info
    $script:BatteryCacheTime = Get-Date
    return $script:BatteryCache
}

# ---------------------------------------------------------------- видео

function Get-DisplayAdapters {
    Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch 'Basic Display|Remote Display|Virtual' } |
        ForEach-Object {
            $vendor = switch -Regex ([string]$_.AdapterCompatibility) {
                'NVIDIA'                              { 'NVIDIA' }
                'Advanced Micro Devices|^AMD'         { 'AMD' }
                'Intel'                               { 'Intel' }
                default                               { [string]$_.AdapterCompatibility }
            }
            $discrete = ($vendor -eq 'NVIDIA') -or ($_.Name -match 'Radeon RX|Radeon Pro|Arc [AB]\d')
            $dev = Get-PnpDevice -InstanceId $_.PNPDeviceID -ErrorAction SilentlyContinue
            [pscustomobject]@{
                Name       = $_.Name
                Vendor     = $vendor
                IsDiscrete = $discrete
                PnpId      = $_.PNPDeviceID
                Status     = if ($dev) { $dev.Status } else { 'Unknown' }
                Refresh    = $_.CurrentRefreshRate
                Resolution = if ($_.CurrentHorizontalResolution) {
                                 "$($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution)"
                             } else { $null }
            }
        }
}

function Get-DiscreteGpu {
    $gpus = @(Get-DisplayAdapters | Where-Object { $_.IsDiscrete })
    if ($gpus.Count -eq 0) { return $null }
    return $gpus[0]
}

function Set-GpuState([bool]$Enable) {
    if ($NoGpu) { return 'skipped' }
    if (-not (Test-Admin)) { return 'no-admin' }

    $battery = Get-BatteryInfo
    if (-not $battery.Present) { return 'no-battery' }

    $adapters = @(Get-DisplayAdapters)
    $gpu = Get-DiscreteGpu
    if (-not $gpu) { return 'no-discrete' }
    if ($adapters.Count -lt 2) { return 'only-adapter' }

    $integrated = @($adapters | Where-Object { -not $_.IsDiscrete })
    if ($integrated.Count -eq 0) { return 'no-integrated' }

    $dev = Get-PnpDevice -InstanceId $gpu.PnpId -ErrorAction SilentlyContinue
    if (-not $dev) { return 'not-found' }

    if ($Enable) {
        if ($dev.Status -ne 'OK') { Enable-PnpDevice -InstanceId $gpu.PnpId -Confirm:$false }
        return 'enabled'
    }
    else {
        if ($dev.Status -eq 'OK') { Disable-PnpDevice -InstanceId $gpu.PnpId -Confirm:$false }
        return 'disabled'
    }
}

# ---------------------------------------------------------------- яркость

function Get-Brightness {
    $m = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBrightness -ErrorAction SilentlyContinue |
         Select-Object -First 1
    if ($m) { return [int]$m.CurrentBrightness }
    return $null
}

function Set-Brightness([int]$value) {
    $value = [math]::Max(0, [math]::Min(100, $value))
    $methods = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBrightnessMethods -ErrorAction SilentlyContinue
    foreach ($m in $methods) {
        Invoke-CimMethod -InputObject $m -MethodName WmiSetBrightness -Arguments @{
            Timeout    = 1
            Brightness = [byte]$value
        } | Out-Null
    }
}

# ---------------------------------------------------------------- режимы

function Get-CpuMode {
    [pscustomobject]@{
        Max   = Get-CpuDcValue $script:MaxStateGuid
        Boost = Get-CpuDcValue $script:BoostGuid
    }
}

function Set-CpuMode([int]$percent, [int]$boost) {
    Set-CpuDcValue $script:MaxStateGuid $percent
    Set-CpuDcValue $script:BoostGuid $boost
    $scheme = Get-ActiveSchemeGuid
    if ($scheme) { powercfg /setactive $scheme | Out-Null }
}

function Invoke-Eco {
    Set-CpuMode $EcoCpu 0
    $gpu = Set-GpuState $false

    Write-Host ''
    Write-Host '  Экономный режим включён.' -ForegroundColor Green
    Write-Host "  CPU на батарее: до $EcoCpu%, Turbo Boost выключен."
    switch ($gpu) {
        'disabled'     { Write-Host '  Дискретная видеокарта выключена.' }
        'enabled'      { Write-Host '  Дискретная видеокарта уже была выключена.' }
        'no-discrete'  { Write-Host '  Дискретная видеокарта не найдена — пропускаю.' -ForegroundColor DarkGray }
        'no-battery'   { Write-Host '  Батарея не найдена — GPU не трогаю.' -ForegroundColor DarkGray }
        'no-admin'     { Write-Host '  Нет прав администратора — GPU не трогаю.' -ForegroundColor Yellow }
        'skipped'      { Write-Host '  GPU пропущена (флаг -NoGpu).' -ForegroundColor DarkGray }
        'only-adapter' { Write-Host '  GPU — единственный адаптер, выключать нельзя.' -ForegroundColor Yellow }
        'no-integrated'{ Write-Host '  Встроенная графика не найдена — GPU не трогаю.' -ForegroundColor Yellow }
        default        { Write-Host "  GPU: $gpu" -ForegroundColor DarkGray }
    }
}

function Invoke-Max {
    Set-CpuMode 100 1
    $gpu = Set-GpuState $true

    Write-Host ''
    Write-Host '  Режим максимум включён.' -ForegroundColor Yellow
    Write-Host '  CPU: 100%, Turbo Boost включён.'
    switch ($gpu) {
        'enabled'      { Write-Host '  Дискретная видеокарта включена.' }
        'disabled'     { Write-Host '  Дискретная видеокарта уже была включена.' }
        'no-discrete'  { Write-Host '  Дискретная видеокарта не найдена.' -ForegroundColor DarkGray }
        'no-admin'     { Write-Host '  Нет прав администратора — GPU не включена.' -ForegroundColor Yellow }
        'skipped'      { Write-Host '  GPU пропущена (флаг -NoGpu).' -ForegroundColor DarkGray }
        default        { Write-Host "  GPU: $gpu" -ForegroundColor DarkGray }
    }
}

# ---------------------------------------------------------------- отчёт

function Show-Report {
    $cs    = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $cpu   = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    $os    = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $bat   = Get-BatteryInfo -Fresh
    $gpus  = @(Get-DisplayAdapters)
    $mode  = Get-CpuMode
    $br    = Get-Brightness

    Write-Host ''
    Write-Host '  ============================================' -ForegroundColor DarkCyan
    Write-Host '                BATTERYTUNE' -ForegroundColor White
    Write-Host '  ============================================' -ForegroundColor DarkCyan
    Write-Host ''

    Write-Host '  Система' -ForegroundColor DarkGray
    if ($cs) { Write-Host ("    {0} {1}" -f ([string]$cs.Manufacturer).Trim(), ([string]$cs.Model).Trim()) }
    if ($cpu) { Write-Host ("    CPU: {0} ({1}C/{2}T)" -f $cpu.Name.Trim(), $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors) }
    if ($os) { Write-Host ("    ОС: {0} (build {1})" -f $os.Caption.Trim(), $os.BuildNumber) }
    Write-Host ''

    Write-Host '  Батарея' -ForegroundColor DarkGray
    if ($bat.Present) {
        Write-Host ("    Проектная ёмкость: {0}" -f (Format-Wh $bat.Design))
        Write-Host ("    Реальная ёмкость:  {0}" -f (Format-Wh $bat.Full))
        if ($null -ne $bat.Health) {
            $color = if ($bat.Health -ge 80) { 'Green' } elseif ($bat.Health -ge 60) { 'Yellow' } else { 'Red' }
            Write-Host ("    Здоровье:          {0}% (износ {1}%)" -f $bat.Health, (100 - $bat.Health)) -ForegroundColor $color
        }
        if ($bat.Cycles)    { Write-Host ("    Циклов заряда:     {0}" -f $bat.Cycles) }
        if ($bat.Chemistry) { Write-Host ("    Химия:             {0}" -f $bat.Chemistry) }
        Write-Host ("    Заряд:             {0} ({1})" -f (Format-Wh $bat.Remaining), (Get-PowerSource))
        if ($bat.Rate -gt 0) {
            Write-Host ("    Текущий расход:    {0}" -f (Format-W $bat.Rate))
            if ($bat.Remaining -gt 0) {
                $hours = $bat.Remaining / $bat.Rate
                Write-Host ("    Прогноз:           ~{0:0.0} ч" -f $hours)
            }
        }
    }
    else {
        Write-Host '    Батарея не найдена (это не ноутбук?)' -ForegroundColor Yellow
    }
    Write-Host ''

    Write-Host '  Графика' -ForegroundColor DarkGray
    foreach ($g in $gpus) {
        $kind = if ($g.IsDiscrete) { 'дискретная' } else { 'встроенная' }
        $state = if ($g.Status -eq 'OK') { 'вкл' } else { 'выкл' }
        $res = if ($g.Resolution) { $g.Resolution } else { '—' }
        Write-Host ("    {0} — {1}, {2}, {3} @ {4} Гц" -f $g.Name, $kind, $state, $res, $g.Refresh)
    }
    if ($gpus.Count -eq 0) { Write-Host '    Не найдено' -ForegroundColor Yellow }
    Write-Host ''

    Write-Host '  Экран' -ForegroundColor DarkGray
    Write-Host ("    Яркость: {0}" -f $(if ($null -ne $br) { "$br%" } else { 'недоступна' }))
    Write-Host ''

    Write-Host '  Режим' -ForegroundColor DarkGray
    $maxText = if ($null -eq $mode.Max) { 'по умолчанию' } elseif ($mode.Max -ge 100) { 'максимум (100%)' } else { "эконом ($($mode.Max)%)" }
    $boostText = switch ($mode.Boost) { 0 { 'выключен' } 1 { 'включён' } default { 'по умолчанию' } }
    Write-Host ("    CPU на батарее: {0}, Turbo: {1}" -f $maxText, $boostText)
    Write-Host ''
}

function Show-Status {
    $mode = Get-CpuMode
    $gpu  = Get-DiscreteGpu
    $maxText = if ($null -eq $mode.Max) { 'по умолчанию' } elseif ($mode.Max -ge 100) { 'МАКСИМУМ' } else { 'ЭКОНОМ' }
    $gpuText = if (-not $gpu) { 'нет' } elseif ($gpu.Status -eq 'OK') { 'включена' } else { 'выключена' }

    Write-Host ''
    Write-Host "  Режим:          $maxText" -ForegroundColor Cyan
    Write-Host "  CPU на батарее: $(if ($null -ne $mode.Max) { "$($mode.Max)%" } else { 'по умолчанию' })"
    Write-Host "  Turbo Boost:    $(switch ($mode.Boost) { 0 { 'выключен' } 1 { 'включён' } default { 'по умолчанию' } })"
    Write-Host "  Дискретная GPU: $gpuText"
    Write-Host "  Питание:        $(Get-PowerSource)"
    Write-Host ''
}

# ---------------------------------------------------------------- меню

function Show-Menu {
    try { Clear-Host } catch { }
    $mode = Get-CpuMode
    $gpu  = Get-DiscreteGpu
    $bat  = Get-BatteryInfo
    $br   = Get-Brightness

    $modeText = if ($null -eq $mode.Max) { 'по умолчанию' } elseif ($mode.Max -ge 100) { 'максимум' } else { "эконом ($($mode.Max)%)" }
    $gpuText  = if (-not $gpu) { 'нет' } elseif ($gpu.Status -eq 'OK') { 'включена' } else { 'выключена' }

    Write-Host ''
    Write-Host '  ============================================' -ForegroundColor DarkCyan
    Write-Host '                BATTERYTUNE' -ForegroundColor White
    Write-Host '  ============================================' -ForegroundColor DarkCyan
    Write-Host ''
    Write-Host '  Сейчас:' -ForegroundColor DarkGray
    Write-Host "    CPU на батарее : $modeText"
    Write-Host "    Дискретная GPU : $gpuText"
    Write-Host "    Питание        : $(Get-PowerSource)"
    if ($bat.Present -and $null -ne $bat.Health) {
        Write-Host "    Батарея        : $($bat.Health)% здоровья, $(Format-Wh $bat.Remaining) осталось"
    }
    if ($null -ne $br) { Write-Host "    Яркость        : $br%" }
    Write-Host ''
    Write-Host '  [1] ' -NoNewline -ForegroundColor Green
    Write-Host 'Эконом   ' -NoNewline -ForegroundColor White
    Write-Host "— CPU $EcoCpu%, Turbo off, дискретка off"
    Write-Host '  [2] ' -NoNewline -ForegroundColor Yellow
    Write-Host 'Максимум ' -NoNewline -ForegroundColor White
    Write-Host '— CPU 100%, Turbo on, дискретка on'
    Write-Host '  [3] ' -NoNewline -ForegroundColor Cyan
    Write-Host 'Отчёт о системе и батарее'
    Write-Host '  [4] ' -NoNewline -ForegroundColor Magenta
    Write-Host 'Яркость 50% / 100% (переключить)'
    Write-Host '  [0] ' -NoNewline -ForegroundColor DarkGray
    Write-Host 'Выход'
    Write-Host ''
}

function Wait-Key {
    Write-Host ''
    Write-Host '  Нажми Enter, чтобы вернуться в меню...' -ForegroundColor DarkGray
    [void](Read-Host)
}

function Start-Menu {
    while ($true) {
        Show-Menu
        $choice = Read-Host '  Выбор'
        if ($null -eq $choice) { return }
        $choice = $choice.Trim()

        switch ($choice) {
            '1' {
                $savedNoGpu = $NoGpu
                $gpu = Get-DiscreteGpu
                if (-not $Force -and $gpu -and $gpu.Status -eq 'OK' -and (Test-Admin)) {
                    $ans = Read-Host '  Отключить дискретную видеокарту? Экран перейдёт на встроенную [Y/n]'
                    if ($ans -and $ans.Trim() -match '^(n|no|н|нет)$') { $script:NoGpu = $true }
                }
                Invoke-Eco
                $script:NoGpu = $savedNoGpu
                Wait-Key
            }
            '2' {
                Invoke-Max
                Wait-Key
            }
            '3' {
                Show-Report
                Wait-Key
            }
            '4' {
                $cur = Get-Brightness
                if ($null -eq $cur) {
                    Write-Host ''
                    Write-Host '  Яркость недоступна (внешний монитор или нет поддержки).' -ForegroundColor Yellow
                }
                else {
                    $target = if ($cur -gt 60) { 50 } else { 100 }
                    Set-Brightness $target
                    Write-Host ''
                    Write-Host "  Яркость: $target%" -ForegroundColor Green
                }
                Wait-Key
            }
            '0' { return }
            ''  { }
            default {
                Write-Host ''
                Write-Host '  Не понял. Введи 1, 2, 3, 4 или 0.' -ForegroundColor Red
                Start-Sleep -Milliseconds 700
            }
        }
    }
}

# ---------------------------------------------------------------- запуск

$needsAdmin = $Action -in @('menu', 'eco', 'max')
if ($needsAdmin -and -not (Test-Admin) -and -not $NoElevate) {
    Restart-Elevated
    exit
}

switch ($Action) {
    'report' { Show-Report }
    'status' { Show-Status }
    'eco'    { Invoke-Eco; Show-Status }
    'max'    { Invoke-Max; Show-Status }
    default  { Start-Menu }
}

if ($Pause) {
    Write-Host ''
    Write-Host '  Нажми Enter, чтобы закрыть окно...' -ForegroundColor DarkGray
    [void](Read-Host)
}
