@echo off
setlocal enabledelayedexpansion

echo.
echo === OrcKit Installer ===
echo.

:: --- Find game installation ---
set "GAME_PATH="

:: Check common Steam locations
for %%P in (
    "%ProgramFiles%\Steam\steamapps\common\Sir, We Have an Orc Problem Playtest"
    "%ProgramFiles(x86)%\Steam\steamapps\common\Sir, We Have an Orc Problem Playtest"
    "C:\Steam\steamapps\common\Sir, We Have an Orc Problem Playtest"
    "D:\Steam\steamapps\common\Sir, We Have an Orc Problem Playtest"
    "E:\Steam\steamapps\common\Sir, We Have an Orc Problem Playtest"
    "C:\SteamLibrary\steamapps\common\Sir, We Have an Orc Problem Playtest"
    "D:\SteamLibrary\steamapps\common\Sir, We Have an Orc Problem Playtest"
    "E:\SteamLibrary\steamapps\common\Sir, We Have an Orc Problem Playtest"
    "F:\SteamLibrary\steamapps\common\Sir, We Have an Orc Problem Playtest"
) do (
    if exist "%%~P\swhaop_playtest.exe" (
        set "GAME_PATH=%%~P"
        goto :found
    )
)

:: Not found - ask user
echo Could not find OrcKit automatically.
echo Please enter the path to your game folder (containing swhaop_playtest.exe):
set /p "GAME_PATH=Game path: "

if not exist "%GAME_PATH%\swhaop_playtest.exe" (
    echo ERROR: swhaop_playtest.exe not found at "%GAME_PATH%"
    goto :error
)

:found
echo Found game at: %GAME_PATH%

:: --- Set up paths ---
set "SCRIPT_DIR=%~dp0"
set "LOCAL_MODLOADER=%SCRIPT_DIR%OrcLoader.gd"
set "LOCAL_OVERRIDE=%SCRIPT_DIR%override.cfg"
set "MODLOADER_DEST=%GAME_PATH%\OrcLoader.gd"
set "OVERRIDE_PATH=%GAME_PATH%\override.cfg"
set "MODS_PATH=%GAME_PATH%\mods"

if not exist "%LOCAL_MODLOADER%" (
    echo ERROR: OrcLoader.gd not found next to this installer:
    echo   %LOCAL_MODLOADER%
    goto :error
)
if not exist "%LOCAL_OVERRIDE%" (
    echo ERROR: override.cfg not found next to this installer:
    echo   %LOCAL_OVERRIDE%
    goto :error
)

:: --- Install OrcLoader.gd ---
copy /y "%LOCAL_MODLOADER%" "%MODLOADER_DEST%" >nul
if not exist "%MODLOADER_DEST%" (
    echo ERROR: Could not copy OrcLoader.gd into game folder.
    echo   Likely cause: game is running, missing write permission, or AV quarantine.
    goto :error
)
echo Installed OrcLoader.gd to game folder

:: --- Load repo's override.cfg template ---
:: The local override.cfg is the single source of truth for what mod loader
:: expects in [autoload]. We merge its entries into the user's existing
:: override.cfg so their other customizations ([display], [input], etc.) stay.
set "OVERRIDE_TMP=%OVERRIDE_PATH%.template"
if exist "%OVERRIDE_TMP%" del "%OVERRIDE_TMP%" >nul 2>&1
copy /y "%LOCAL_OVERRIDE%" "%OVERRIDE_TMP%" >nul
if not exist "%OVERRIDE_TMP%" (
    echo ERROR: Failed to stage override.cfg template
    goto :error
)

:: --- Install/merge override.cfg ---
:: For keys the template specifies, force the template's value (overwriting
:: outdated user values like a stale OrcKit path). Keys the user has that
:: template doesn't specify are left untouched.
if exist "%OVERRIDE_PATH%" (
    echo Merging override.cfg (preserving user sections, updating template keys)
    copy "%OVERRIDE_PATH%" "%OVERRIDE_PATH%.bak" >nul
    powershell -Command "$user = '%OVERRIDE_PATH%'; $tmpl = '%OVERRIDE_TMP%'; $tmplCfg = @{}; $curSec = $null; foreach ($line in Get-Content -LiteralPath $tmpl) { $t = $line.Trim(); if ($t -match '^\[(.+)\]$') { $curSec = $Matches[1]; if (-not $tmplCfg.ContainsKey($curSec)) { $tmplCfg[$curSec] = [ordered]@{} }; continue } if ($t -eq '' -or $t.StartsWith(';') -or $t.StartsWith('#') -or $curSec -eq $null) { continue } $eq = $t.IndexOf('='); if ($eq -lt 0) { continue } $k = $t.Substring(0, $eq).Trim(); $v = $t.Substring($eq + 1); $tmplCfg[$curSec][$k] = $v } $out = New-Object System.Collections.Generic.List[string]; $seenSec = @{}; $curSec = $null; $sectionLines = New-Object System.Collections.Generic.List[string]; function Flush { param($sec, $lines, $out, $tmplCfg) $tmplKeys = @{}; if ($sec -ne $null -and $tmplCfg.ContainsKey($sec)) { foreach ($k in $tmplCfg[$sec].Keys) { $tmplKeys[$k] = $true } } $existingKeys = @{}; foreach ($ln in $lines) { $tr = $ln.Trim(); if ($tr -match '^\[.+\]$') { $out.Add($ln); continue } if ($tr -eq '' -or $tr.StartsWith(';') -or $tr.StartsWith('#')) { $out.Add($ln); continue } $eq = $tr.IndexOf('='); if ($eq -lt 0) { $out.Add($ln); continue } $k = $tr.Substring(0, $eq).Trim(); if ($tmplKeys.ContainsKey($k)) { $newVal = $tmplCfg[$sec][$k]; $out.Add(\"$k=$newVal\"); $existingKeys[$k] = $true } else { $out.Add($ln) } } if ($sec -ne $null -and $tmplCfg.ContainsKey($sec)) { foreach ($k in $tmplCfg[$sec].Keys) { if (-not $existingKeys.ContainsKey($k)) { $out.Add(\"$k=$($tmplCfg[$sec][$k])\") } } } } foreach ($line in Get-Content -LiteralPath $user) { $t = $line.Trim(); if ($t -match '^\[(.+)\]$') { Flush $curSec $sectionLines $out $tmplCfg; $sectionLines.Clear(); $curSec = $Matches[1]; $seenSec[$curSec] = $true; $sectionLines.Add($line); continue } $sectionLines.Add($line) } Flush $curSec $sectionLines $out $tmplCfg; foreach ($sec in $tmplCfg.Keys) { if (-not $seenSec.ContainsKey($sec)) { $out.Add(''); $out.Add(\"[$sec]\"); foreach ($k in $tmplCfg[$sec].Keys) { $out.Add(\"$k=$($tmplCfg[$sec][$k])\") } } } Set-Content -LiteralPath $user -Value $out"
    echo Updated override.cfg
) else (
    move /y "%OVERRIDE_TMP%" "%OVERRIDE_PATH%" >nul
    if not exist "%OVERRIDE_PATH%" (
        echo ERROR: Could not move override.cfg into game folder.
        echo   Likely cause: missing write permission, or AV quarantine.
        goto :error
    )
    echo Installed override.cfg
)
if exist "%OVERRIDE_TMP%" del "%OVERRIDE_TMP%" >nul 2>&1

:: --- Create mods directory ---
if not exist "%MODS_PATH%" (
    mkdir "%MODS_PATH%"
    echo Created mods directory
) else (
    echo Mods directory already exists
)

:: --- Clean up legacy v2 files ---
:: OrcKit v2 used %APPDATA%\OrcKit\modloader.gd as the install
:: location. v3 moved to the game folder. After a successful v3 install,
:: the v2 files in appdata are orphans that do nothing functional but
:: confuse users (and can mislead a v2-aware diagnostic into reporting
:: an old install where the live one is now in the game folder).
:: Run this only after the new files are confirmed in place above, so
:: a failed v3 install never deletes a working v2 fallback.
set "LEGACY_DIR=%APPDATA%\OrcKit"
if exist "!LEGACY_DIR!\modloader.gd" (
    del /f "!LEGACY_DIR!\modloader.gd" >nul 2>&1
    echo Removed legacy v2 modloader.gd from !LEGACY_DIR!
)
if exist "!LEGACY_DIR!\override.cfg" (
    del /f "!LEGACY_DIR!\override.cfg" >nul 2>&1
    echo Removed legacy v2 override.cfg from !LEGACY_DIR!
)

:: --- Done ---
echo.
echo === Installation Complete ===
echo.
echo The mod loader is now installed. When you launch the game,
echo a mod manager window will appear before the game loads.
echo.
echo To install mods:
echo   - Place .vmz/.zip files in: %MODS_PATH%
echo.
echo Game path:  %GAME_PATH%
echo Mods path:  %MODS_PATH%
echo.
goto :done

:error
echo.
echo Installation failed.
echo.

:done
echo Press any key to exit...
pause >nul
