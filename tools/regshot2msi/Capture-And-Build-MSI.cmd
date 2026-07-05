@echo off
rem ===========================================================================
rem  Capture-And-Build-MSI.cmd
rem
rem  Double-click launcher for the Regshot -> MSI wizard. It elevates to
rem  administrator (needed so Regshot can see HKLM and Program Files changes),
rem  asks for the basic details, then runs Build-CapturedMsi.ps1 which walks you
rem  through the capture and produces a deployable .msi.
rem
rem  Advanced use: any arguments you pass are forwarded straight to the wizard,
rem  e.g.   Capture-And-Build-MSI.cmd -Title "MyApp" -InstallerPath C:\dl\a.exe
rem ===========================================================================
setlocal EnableExtensions
set "HERE=%~dp0"
set "PS1=%HERE%Build-CapturedMsi.ps1"

if not exist "%PS1%" (
    echo ERROR: Build-CapturedMsi.ps1 was not found next to this file.
    echo        Keep Capture-And-Build-MSI.cmd in the tools\regshot2msi folder.
    echo.
    pause
    exit /b 1
)

rem --- Ensure we are running as administrator -------------------------------
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    if "%~1"=="" (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    ) else (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
    )
    exit /b
)

rem --- Ensure prerequisites (Python 3 and WiX) ------------------------------
call :ensure_prereqs
if errorlevel 1 (
    echo.
    echo Prerequisite setup did not complete. See the messages above.
    echo.
    pause
    exit /b 1
)

rem --- If arguments were supplied, forward them verbatim ---------------------
if not "%~1"=="" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
    goto :done
)

rem --- Otherwise prompt for the basics --------------------------------------
echo ============================================================
echo    Regshot  -^>  MSI    capture and build
echo ============================================================
echo.
echo This will: 1) snapshot the system, 2) let you install the app,
echo            3) snapshot again, 4) build a deployable .msi for PDQ.
echo.

set "APP_TITLE=CapturedApp"
set /p "APP_TITLE=Application name [CapturedApp]: "

set "APP_VENDOR=Repackaged with regshot2msi"
set /p "APP_VENDOR=Manufacturer [Repackaged with regshot2msi]: "

set "APP_INSTALLER="
set /p "APP_INSTALLER=Installer .exe to run for you (optional; ENTER to install manually): "

set "OUT_MSI="
set /p "OUT_MSI=Output .msi path (optional; ENTER to save it on your Desktop): "

echo.

set "ARGS=-Title "%APP_TITLE%" -Manufacturer "%APP_VENDOR%""
if not "%APP_INSTALLER%"=="" set "ARGS=%ARGS% -InstallerPath "%APP_INSTALLER%""
if not "%OUT_MSI%"=="" set "ARGS=%ARGS% -OutputMsi "%OUT_MSI%""

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %ARGS%

:done
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" (
    echo The process reported an error (exit code %RC%). Review the messages above.
) else (
    echo Finished.
)
echo.
pause
endlocal & exit /b %RC%


rem ===========================================================================
rem  Subroutines
rem ===========================================================================

:ensure_prereqs
echo.
echo Checking prerequisites (Python 3 and WiX)...

rem --- Python ---------------------------------------------------------------
where python >nul 2>&1 && goto :ep_python_ok
where py >nul 2>&1     && goto :ep_python_ok
echo    Python 3 not found - installing...
call :winget_install "Python.Python.3.12" "Python 3"
if errorlevel 1 exit /b 1
call :reload_path
where python >nul 2>&1 && goto :ep_python_ok
where py >nul 2>&1     && goto :ep_python_ok
echo    Python was installed but is not on PATH in this session.
echo    Please close this window and run the batch file again.
exit /b 1
:ep_python_ok
echo    Python 3: OK

rem --- .NET SDK (needed to install WiX) -------------------------------------
where dotnet >nul 2>&1 && goto :ep_dotnet_ok
echo    .NET SDK not found - installing (needed for WiX)...
call :winget_install "Microsoft.DotNet.SDK.8" ".NET SDK 8"
if errorlevel 1 exit /b 1
call :reload_path
where dotnet >nul 2>&1 && goto :ep_dotnet_ok
echo    .NET SDK was installed but is not on PATH in this session.
echo    Please close this window and run the batch file again.
exit /b 1
:ep_dotnet_ok
echo    .NET SDK: OK

rem --- WiX (installed as a .NET global tool) --------------------------------
where wix >nul 2>&1 && goto :ep_wix_ok
echo    WiX not found - installing as a .NET global tool...
dotnet tool install --global wix
call :reload_path
where wix >nul 2>&1 && goto :ep_wix_ok
rem Maybe an older WiX tool is present; try updating instead.
dotnet tool update --global wix >nul 2>&1
call :reload_path
where wix >nul 2>&1 && goto :ep_wix_ok
echo    WiX could not be made available automatically. Install it manually with:
echo        dotnet tool install --global wix
echo    then reopen this window and run the batch file again.
exit /b 1
:ep_wix_ok
echo    WiX: OK
echo.
exit /b 0


:winget_install
rem %1 = winget package id, %2 = friendly name
where winget >nul 2>&1
if errorlevel 1 (
    echo    Automatic install needs 'winget' ^(App Installer^), which is not present.
    echo    Please install %~2 manually, then re-run this batch file.
    exit /b 1
)
winget install -e --id %1 --accept-package-agreements --accept-source-agreements --silent
rem winget's exit code is unreliable (e.g. non-zero when already installed),
rem so success is verified by the caller re-checking PATH.
exit /b 0


:reload_path
rem Append the well-known install locations of freshly installed tools so they
rem are usable in this same session without reopening the window.
set "PATH=%PATH%;%ProgramFiles%\dotnet;%USERPROFILE%\.dotnet\tools"
for /d %%D in ("%LOCALAPPDATA%\Programs\Python\Python3*") do set "PATH=%PATH%;%%D;%%D\Scripts"
for /d %%D in ("%ProgramFiles%\Python3*")                do set "PATH=%PATH%;%%D;%%D\Scripts"
exit /b 0
