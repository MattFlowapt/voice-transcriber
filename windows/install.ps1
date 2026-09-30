# Installs Voice Transcriber for Windows: Python (if missing), its packages, the app,
# your settings, and a Start-up shortcut so it runs at every login.
#
#   Double-click Install.cmd, or:
#   powershell -ExecutionPolicy Bypass -File install.ps1 [-Key sk-...]
#   ($env:OPENAI_KEY also works; with neither, you're asked, and can skip it)
param([string]$Key = $env:OPENAI_KEY)
$ErrorActionPreference = 'Stop'

function Step($msg) { Write-Host "  -> $msg" }
Write-Host ""
Write-Host "  Voice Transcriber for Windows - installer"
Write-Host "  ========================================="
Write-Host ""

# 1. Python 3.9+. Uses the 'py' launcher: plain 'python' may be the Microsoft Store stub.
function Find-Python {
    $probe = "import sys; print(sys.executable if sys.version_info >= (3, 9) else '')"
    $found = @()
    if (Get-Command py -ErrorAction SilentlyContinue) {
        try { $found += @(& py -3 -c $probe 2>$null) } catch { }
    }
    if (Get-Command python -ErrorAction SilentlyContinue) {
        try { $found += @(& python -c $probe 2>$null) } catch { }
    }
    foreach ($exe in $found) {
        if ($exe -and (Test-Path "$exe".Trim())) { return "$exe".Trim() }
    }
    return $null
}
$python = Find-Python
if (-not $python) {
    Step "Installing Python 3.12 (winget)"
    winget install -e --id Python.Python.3.12 --scope user --accept-package-agreements --accept-source-agreements | Out-Host
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    $python = Find-Python
    if (-not $python) { throw "Python didn't install. Install it from https://www.python.org/downloads/ (tick 'Add to PATH'), then run this again." }
}
Step "Using Python: $python"

# 2. Packages
Step "Installing packages (numpy, sounddevice, keyboard, pystray, pillow)"
& $python -m pip install --user --upgrade --quiet -r (Join-Path $PSScriptRoot 'requirements.txt')
if ($LASTEXITCODE -ne 0) { throw "pip install failed (see above)." }

# 3. The app itself lives in %LOCALAPPDATA%\VoiceTranscriber
$dest = Join-Path $env:LOCALAPPDATA 'VoiceTranscriber'
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Get-CimInstance Win32_Process -Filter "Name = 'pythonw.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*voice_transcriber.py*' } |
    ForEach-Object { Invoke-CimMethod -InputObject $_ -MethodName Terminate | Out-Null }
Copy-Item (Join-Path $PSScriptRoot 'voice_transcriber.py') $dest -Force
Step "App copied to $dest"

# 4. Settings (kept if they already exist)
$cfgDir = Join-Path $env:APPDATA 'voice-transcriber'
$cfg = Join-Path $cfgDir 'config.json'
New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
if (Test-Path $cfg) {
    Step "Existing settings kept ($cfg)"
} else {
    if (-not $Key -and [Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
        Write-Host ""
        Write-Host "  The app transcribes with OpenAI, so it needs your OpenAI API key"
        Write-Host "  (README.md explains how to get one). It is stored only on this PC."
        $Key = Read-Host "  Paste it and press Enter (or just press Enter to add it later in Settings)"
    }
    $settings = [ordered]@{
        openaiKey    = "$Key".Trim()
        model        = 'gpt-4o-transcribe'
        language     = ''
        autoPaste    = $true
        maxSeconds   = 300
        vocabulary   = @('Claude', 'ChatGPT', 'OpenAI')
        replacements = @{ 'Chat GPT' = 'ChatGPT' }
        hotkey       = 'ctrl+alt+space'
        noteHotkey   = 'ctrl+alt+n'
        microphone   = ''
    }
    # UTF-8 without BOM so Python's json reads it cleanly.
    [IO.File]::WriteAllText($cfg, ($settings | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding $false))
    if ($settings.openaiKey) { Step "Key saved" } else { Step "No key yet: add it in Settings (tray icon > Settings)" }
}

# 5. Start at login + start now (pythonw = no console window)
$pythonw = Join-Path (Split-Path $python) 'pythonw.exe'
if (-not (Test-Path $pythonw)) { $pythonw = $python }
$app = Join-Path $dest 'voice_transcriber.py'
$startup = [Environment]::GetFolderPath('Startup')
$shell = New-Object -ComObject WScript.Shell
$lnk = $shell.CreateShortcut((Join-Path $startup 'Voice Transcriber.lnk'))
$lnk.TargetPath = $pythonw
$lnk.Arguments = "`"$app`""
$lnk.WorkingDirectory = $dest
$lnk.Description = 'Voice Transcriber'
$lnk.Save()
Step "Set to start at login"
Start-Process -FilePath $pythonw -ArgumentList "`"$app`"" -WorkingDirectory $dest
Step "Started"

Write-Host ""
Write-Host "  Installed and running. The microphone icon is in the system tray (bottom-right;"
Write-Host "  it may be hidden under the ^ arrow - drag it onto the taskbar to keep it visible)."
Write-Host ""
Write-Host "  Press  Ctrl + Alt + Space  in any app, talk, press it again."
Write-Host "  If Windows asks about microphone access, allow it (Settings > Privacy > Microphone >"
Write-Host "  'Let desktop apps access your microphone')."
Write-Host ""
Write-Host "  Test everything:  `"$python`" `"$app`" --check"
Write-Host ""
