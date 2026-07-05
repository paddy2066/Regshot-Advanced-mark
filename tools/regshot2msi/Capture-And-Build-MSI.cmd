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
endlocal
