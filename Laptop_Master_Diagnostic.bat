@echo off
setlocal EnableDelayedExpansion

:: ============================================================
:: Laptop Diagnostic Toolkit - Launcher
:: Version: 7.0.0
:: Architecture: Single-module (Laptop_Diagnostic_Suite.ps1)
:: ============================================================

title Laptop Diagnostic Toolkit v7.0.0

:: ============================================================
:: PATH DETECTION
:: ============================================================
set "SCRIPT_DRIVE=%~d0"
set "SCRIPT_DIR=%~dp0"
set "PS1_FILE=%SCRIPT_DIR%Laptop_Diagnostic_Suite.ps1"
set "CONFIG_FILE=%SCRIPT_DIR%Config\config.ini"
set "LOGS_DIR=%SCRIPT_DIR%Logs"
set "REPORTS_DIR=%SCRIPT_DIR%Reports"
set "RESULTS_DIR=%SCRIPT_DIR%Results"
set "TEMP_DIR=%SCRIPT_DIR%Temp"
set "TOOLS_DIR=%SCRIPT_DIR%Tools"

:: Create directories if needed
if not exist "%LOGS_DIR%" mkdir "%LOGS_DIR%"
if not exist "%REPORTS_DIR%" mkdir "%REPORTS_DIR%"
if not exist "%RESULTS_DIR%" mkdir "%RESULTS_DIR%"
if not exist "%TEMP_DIR%" mkdir "%TEMP_DIR%"

:: Generate timestamp using PowerShell (wmic deprecated on Win11)
for /f "tokens=*" %%T in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss"') do set "TIMESTAMP=%%T"
set "LOG_FILE=%LOGS_DIR%\launcher_%TIMESTAMP%.log"

:: ============================================================
:: ADMIN CHECK
:: ============================================================
net session >nul 2>&1
if !errorlevel! neq 0 (
    echo.
    echo ============================================================
    echo  ADMINISTRATOR PRIVILEGES REQUIRED
    echo ============================================================
    echo.
    echo  This tool requires elevated privileges.
    echo  Right-click the BAT file and select "Run as administrator".
    echo.
    echo  Press any key to attempt UAC elevation...
    pause >nul
    powershell -NoProfile -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:: ============================================================
:: VERIFY PS1 MODULE EXISTS
:: ============================================================
:verify_scripts
if not exist "%PS1_FILE%" (
    echo.
    echo ============================================================
    echo  ERROR: Laptop_Diagnostic_Suite.ps1 not found!
    echo ============================================================
    echo.
    echo  Expected location: %PS1_FILE%
    echo  Please ensure the PS1 file is in the same directory as this BAT.
    echo.
    call :log_message "CRITICAL: PS1 module not found at %PS1_FILE%"
    pause
    exit /b 1
)

:: Log startup
call :log_message "Laptop Diagnostic Toolkit v6.0 started"
call :log_message "Script drive: %SCRIPT_DRIVE%"
call :log_message "PS1 module: %PS1_FILE%"

:: ============================================================
:: EXECUTION POLICY CHECK
:: ============================================================
:check_policy
for /f "tokens=*" %%P in ('powershell -NoProfile -Command Get-ExecutionPolicy') do set "EXEC_POLICY=%%P"
call :log_message "Current execution policy: %EXEC_POLICY%"

if /I "%EXEC_POLICY%"=="Restricted" (
    echo.
    echo  Execution policy is Restricted. Setting to Bypass for this session...
    set "PS_POLICY=-ExecutionPolicy Bypass"
) else (
    set "PS_POLICY="
)

:: ============================================================
:: MAIN MENU
:: ============================================================
:main_menu
cls
echo ============================================================
echo   Laptop Diagnostic Toolkit v7.0.0
echo   Location: %SCRIPT_DRIVE%\
echo ============================================================
echo.
echo   QUICK START
echo   -----------
echo   51. Auto-Discover          (Scan machine, show dashboard)
echo   52. Quick Fix by Symptom   (Pick symptom, run targeted fixes)
echo   53. Score This Machine     (Health score 0-100 + grade)
echo.
echo   DIAGNOSTICS
echo   -----------
echo    1. Advanced Diagnostic      (Full system scan)
echo    2. BSOD Analysis            (Crash dump analysis)
echo    3. Enhanced Hardware Test    (CPU, memory, disk, network)
echo    4. Custom Tests             (Select test categories)
echo    5. Diagnostic Analyzer      (Analyze previous logs)
echo.
echo   REPAIR TOOLS
echo   ------------
echo    6. Boot Repair              (BCD, SFC, DISM)
echo    7. BIOS Repair              (Version check, recommendations)
echo    8. Driver Repair            (Problem/unsigned drivers)
echo    9. Software Cleanup         (Temp, cache, startup)
echo.
echo   FLEET MANAGEMENT
echo   ----------------
echo   10. Fleet Report             (System inventory + CSV)
echo   11. Verify Scripts           (Module integrity check)
echo   12. Compatibility Checker    (PS version, .NET, admin)
echo   13. Hardware Inventory       (Full CIM enumeration)
echo.
echo   HARDWARE TESTS
echo   --------------
echo   14. Battery Health           (Wear, cycles, capacity)
echo   15. Network Diagnostic       (Adapters, DNS, latency)
echo   16. Performance Analyzer     (CPU/mem/disk benchmarks)
echo   17. Thermal Analysis         (Temperature monitoring)
echo   18. Display Calibration      (GPU, resolution, pixels)
echo   19. Audio Diagnostic         (Sound devices, service)
echo   20. Keyboard Test            (Key detection, hotkeys)
echo   21. TrackPoint Calibration   (TrackPoint/touchpad)
echo   22. Power Settings           (Plans, sleep, lid)
echo.
echo   SYSTEM MANAGEMENT
echo   -----------------
echo   23. Secure Wipe              (Privacy cleanup)
echo   24. Deployment Prep          (Pre-deploy checklist)
echo   25. Update Manager           (Windows Update, Lenovo)
echo   26. BIOS Update              (Version check, flash)
echo   27. Security Check           (Defender, TPM, BitLocker)
echo.
echo   REFURBISHMENT
echo   -------------
echo   28. Refurb Battery Analysis  (Battery score for resale)
echo   29. Refurb Quality Check     (10-point QA checklist)
echo   30. Refurb Thermal Analysis  (CPU stress + thermal test)
echo.
echo   TROUBLESHOOTERS (Auto-Fix)
echo   --------------------------
echo   31. Security Hardening       (Fix Defender, Firewall, UAC, WU)
echo   32. Network Troubleshooter   (Fix Wi-Fi, Bluetooth, VPN, Mobile)
echo   33. BSOD Troubleshooter      (Fix crash-causing drivers + repair)
echo   34. Input Troubleshooter     (Fix keyboard, trackpoint, touchpad)
echo   35. Driver Auto-Update       (Update outdated/problem drivers)
echo.
echo   ADVANCED DIAGNOSTICS
echo   --------------------
echo   39. POST Error Reader        (ThinkPad POST/BIOS error codes)
echo   40. SMART Disk Analysis      (Deep SMART attributes)
echo   41. CMOS Battery Check       (RTC coin cell health)
echo   42. Machine Identity Check   (Serial, UUID, Asset Tag)
echo   43. TPM Health Check         (TPM 2.0, ROCA, BitLocker)
echo   44. Win11 Readiness Check    (Full hardware compatibility)
echo   45. Lenovo Vantage Check     (Vantage/SystemUpdate stack)
echo   46. Memory Error Log Check   (WHEA, WMD, BugCheck)
echo   47. Display Pixel Check      (LCD policy, GPU, backlight)
echo   48. Enterprise Readiness     (Master health scorecard)
echo.
echo   TEAM TOOLS
echo   ----------
echo   49. Team Issue Detector      (BSOD + Resets + VPN scan + auto-fix)
echo   50. Fleet CSV Aggregator     (merge all USB CSV data + deduplicate)
echo   54. Smart Diagnosis Engine   (9-phase root cause analysis + auto-fix)
echo   55. OEM Validation Mode     (Read-only hardware baseline check)
echo.
echo   OTHER
echo   -----
echo   36. Run Interactive Menu     (PS1 built-in menu)
echo   37. Open Logs Folder
echo   38. Open Reports Folder
echo    0. Exit
echo.
echo ============================================================
set /p "CHOICE=  Select option (0-55): "

:: Validate input
if "%CHOICE%"=="" goto main_menu
if "%CHOICE%"=="0" goto exit_tool

:: Map menu choices to function names
if "%CHOICE%"=="1"  ( set "FUNC=AdvancedDiagnostic" & goto run_function )
if "%CHOICE%"=="2"  ( set "FUNC=BSODAnalysis" & goto run_function )
if "%CHOICE%"=="3"  ( set "FUNC=EnhancedHardwareTest" & goto run_function )
if "%CHOICE%"=="4"  ( set "FUNC=CustomTests" & goto run_function )
if "%CHOICE%"=="5"  ( set "FUNC=DiagnosticAnalyzer" & goto run_function )
if "%CHOICE%"=="6"  ( set "FUNC=BootRepair" & goto run_function )
if "%CHOICE%"=="7"  ( set "FUNC=BIOSRepair" & goto run_function )
if "%CHOICE%"=="8"  ( set "FUNC=DriverRepair" & goto run_function )
if "%CHOICE%"=="9"  ( set "FUNC=SoftwareCleanup" & goto run_function )
if "%CHOICE%"=="10" ( set "FUNC=FleetReport" & goto run_function )
if "%CHOICE%"=="11" ( set "FUNC=VerifyScripts" & goto run_function )
if "%CHOICE%"=="12" ( set "FUNC=CompatibilityChecker" & goto run_function )
if "%CHOICE%"=="13" ( set "FUNC=HardwareInventory" & goto run_function )
if "%CHOICE%"=="14" ( set "FUNC=BatteryHealth" & goto run_function )
if "%CHOICE%"=="15" ( set "FUNC=NetworkDiagnostic" & goto run_function )
if "%CHOICE%"=="16" ( set "FUNC=PerformanceAnalyzer" & goto run_function )
if "%CHOICE%"=="17" ( set "FUNC=ThermalAnalysis" & goto run_function )
if "%CHOICE%"=="18" ( set "FUNC=DisplayCalibration" & goto run_function )
if "%CHOICE%"=="19" ( set "FUNC=AudioDiagnostic" & goto run_function )
if "%CHOICE%"=="20" ( set "FUNC=KeyboardTest" & goto run_function )
if "%CHOICE%"=="21" ( set "FUNC=TrackPointCalibration" & goto run_function )
if "%CHOICE%"=="22" ( set "FUNC=PowerSettings" & goto run_function )
if "%CHOICE%"=="23" ( set "FUNC=SecureWipe" & goto run_function )
if "%CHOICE%"=="24" ( set "FUNC=DeploymentPrep" & goto run_function )
if "%CHOICE%"=="25" ( set "FUNC=UpdateManager" & goto run_function )
if "%CHOICE%"=="26" ( set "FUNC=BIOSUpdate" & goto run_function )
if "%CHOICE%"=="27" ( set "FUNC=SecurityCheck" & goto run_function )
if "%CHOICE%"=="28" ( set "FUNC=RefurbBatteryAnalysis" & goto run_function )
if "%CHOICE%"=="29" ( set "FUNC=RefurbQualityCheck" & goto run_function )
if "%CHOICE%"=="30" ( set "FUNC=RefurbThermalAnalysis" & goto run_function )
if "%CHOICE%"=="31" ( set "FUNC=SecurityHardening" & goto run_function )
if "%CHOICE%"=="32" ( set "FUNC=NetworkTroubleshooter" & goto run_function )
if "%CHOICE%"=="33" ( set "FUNC=BSODTroubleshooter" & goto run_function )
if "%CHOICE%"=="34" ( set "FUNC=InputTroubleshooter" & goto run_function )
if "%CHOICE%"=="35" ( set "FUNC=DriverAutoUpdate" & goto run_function )
if "%CHOICE%"=="36" goto run_interactive
if "%CHOICE%"=="37" goto open_logs
if "%CHOICE%"=="38" goto open_reports
if "%CHOICE%"=="39" ( set "FUNC=POSTErrorReader" & goto run_function )
if "%CHOICE%"=="40" ( set "FUNC=SMARTDiskAnalysis" & goto run_function )
if "%CHOICE%"=="41" ( set "FUNC=CMOSBatteryCheck" & goto run_function )
if "%CHOICE%"=="42" ( set "FUNC=MachineIdentityCheck" & goto run_function )
if "%CHOICE%"=="43" ( set "FUNC=TPMHealthCheck" & goto run_function )
if "%CHOICE%"=="44" ( set "FUNC=Win11ReadinessCheck" & goto run_function )
if "%CHOICE%"=="45" ( set "FUNC=LenovoVantageCheck" & goto run_function )
if "%CHOICE%"=="46" ( set "FUNC=MemoryErrorLogCheck" & goto run_function )
if "%CHOICE%"=="47" ( set "FUNC=DisplayPixelCheck" & goto run_function )
if "%CHOICE%"=="48" ( set "FUNC=EnterpriseReadinessReport" & goto run_function )
if "%CHOICE%"=="49" goto run_detector
if "%CHOICE%"=="50" goto run_aggregator
if "%CHOICE%"=="51" ( set "QS_MODE=AutoDiscover" & goto run_quickstart )
if "%CHOICE%"=="52" ( set "QS_MODE=SymptomFix" & goto run_quickstart )
if "%CHOICE%"=="53" ( set "QS_MODE=ScoreMachine" & goto run_quickstart )
if "%CHOICE%"=="54" goto run_smartdiag
if "%CHOICE%"=="55" goto run_oemvalidation

echo.
echo  Invalid selection. Press any key to try again...
pause >nul
goto main_menu

:: ============================================================
:: RUN A SPECIFIC FUNCTION
:: ============================================================
:run_function
cls
echo ============================================================
echo  Running: !FUNC!
echo ============================================================
echo.
call :log_message "Running function: !FUNC!"

powershell -NoProfile %PS_POLICY% -File "%PS1_FILE%" -RunFunction "!FUNC!" -LogPath "%LOGS_DIR%" -ReportPath "%REPORTS_DIR%" -ConfigPath "%SCRIPT_DIR%Config" -BackupPath "%SCRIPT_DIR%Backups" -TempPath "%TEMP_DIR%" -DataPath "%SCRIPT_DIR%Data"

if !errorlevel! neq 0 (
    call :log_message "Function !FUNC! completed with error code !errorlevel!"
    type nul > "%LOGS_DIR%\error_detected.flag"
    echo.
    echo  Function completed with warnings or errors. Check logs for details.
) else (
    call :log_message "Function !FUNC! completed successfully"
)

echo.
echo  Press any key to return to the main menu...
pause >nul
goto main_menu

:: ============================================================
:: RUN TEAM ISSUE DETECTOR (Option 49)
:: ============================================================
:run_detector
cls
echo ============================================================
echo  Running: Team Issue Detector (BSOD + Resets + VPN)
echo ============================================================
echo.
call :log_message "Running Team Issue Detector"

set "DETECTOR_FILE=%SCRIPT_DIR%Team_Issue_Detector.ps1"
if not exist "%DETECTOR_FILE%" (
    echo.
    echo  ERROR: Team_Issue_Detector.ps1 not found!
    echo  Expected: %DETECTOR_FILE%
    echo.
    call :log_message "CRITICAL: Team_Issue_Detector.ps1 not found"
    pause
    goto main_menu
)

powershell -NoProfile %PS_POLICY% -File "%DETECTOR_FILE%" -LogPath "%LOGS_DIR%" -ReportPath "%REPORTS_DIR%" -ConfigPath "%SCRIPT_DIR%Config" -BackupPath "%SCRIPT_DIR%Backups" -TempPath "%TEMP_DIR%" -DataPath "%SCRIPT_DIR%Data" -ScriptRoot "%SCRIPT_DIR:~0,-1%"

if !errorlevel! neq 0 (
    call :log_message "Team Issue Detector completed with error code !errorlevel!"
) else (
    call :log_message "Team Issue Detector completed successfully"
)

echo.
echo  Press any key to return to the main menu...
pause >nul
goto main_menu

:: ============================================================
:: RUN FLEET AGGREGATOR (Option 50)
:: ============================================================
:run_aggregator
cls
echo ============================================================
echo  Running: Fleet CSV Aggregator
echo ============================================================
echo.
call :log_message "Running Fleet CSV Aggregator"

set "AGGREGATOR_FILE=%SCRIPT_DIR%Fleet_Aggregator.ps1"
if not exist "%AGGREGATOR_FILE%" (
    echo.
    echo  ERROR: Fleet_Aggregator.ps1 not found!
    echo  Expected: %AGGREGATOR_FILE%
    echo.
    call :log_message "CRITICAL: Fleet_Aggregator.ps1 not found"
    pause
    goto main_menu
)

powershell -NoProfile %PS_POLICY% -File "%AGGREGATOR_FILE%" -InputPath "%SCRIPT_DIR%Results" -OutputPath "%SCRIPT_DIR%Results"

if !errorlevel! neq 0 (
    call :log_message "Fleet Aggregator completed with error code !errorlevel!"
) else (
    call :log_message "Fleet Aggregator completed successfully"
)

echo.
echo  Press any key to return to the main menu...
pause >nul
goto main_menu

:: ============================================================
:: RUN QUICK START (Options 51-53)
:: ============================================================
:run_quickstart
cls
echo ============================================================
echo  Running: Quick Start - !QS_MODE!
echo ============================================================
echo.
call :log_message "Running Quick Start: !QS_MODE!"

set "QUICKSTART_FILE=%SCRIPT_DIR%Quick_Start.ps1"
if not exist "%QUICKSTART_FILE%" (
    echo.
    echo  ERROR: Quick_Start.ps1 not found!
    echo  Expected: %QUICKSTART_FILE%
    echo.
    call :log_message "CRITICAL: Quick_Start.ps1 not found"
    pause
    goto main_menu
)

powershell -NoProfile %PS_POLICY% -File "%QUICKSTART_FILE%" -Mode "!QS_MODE!" -LogPath "%LOGS_DIR%" -ReportPath "%REPORTS_DIR%" -ConfigPath "%SCRIPT_DIR%Config" -BackupPath "%SCRIPT_DIR%Backups" -TempPath "%TEMP_DIR%" -DataPath "%SCRIPT_DIR%Data" -ResultsPath "%RESULTS_DIR%" -ScriptRoot "%SCRIPT_DIR:~0,-1%"

if !errorlevel! neq 0 (
    call :log_message "Quick Start completed with error code !errorlevel!"
) else (
    call :log_message "Quick Start completed successfully"
)

echo.
echo  Press any key to return to the main menu...
pause >nul
goto main_menu

:: ============================================================
:: RUN SMART DIAGNOSIS ENGINE (Option 54)
:: ============================================================
:run_smartdiag
cls
echo ============================================================
echo  Running: Smart Diagnosis Engine (9-Phase Root Cause Analysis)
echo ============================================================
echo.
call :log_message "Running Smart Diagnosis Engine"

set "SMARTDIAG_FILE=%SCRIPT_DIR%Smart_Diagnosis_Engine.ps1"
if not exist "%SMARTDIAG_FILE%" (
    echo.
    echo  ERROR: Smart_Diagnosis_Engine.ps1 not found!
    echo  Expected: %SMARTDIAG_FILE%
    echo.
    call :log_message "CRITICAL: Smart_Diagnosis_Engine.ps1 not found"
    pause
    goto main_menu
)

powershell -NoProfile %PS_POLICY% -File "%SMARTDIAG_FILE%" -LogPath "%LOGS_DIR%" -ReportPath "%REPORTS_DIR%" -ConfigPath "%SCRIPT_DIR%Config" -BackupPath "%SCRIPT_DIR%Backups" -TempPath "%TEMP_DIR%" -DataPath "%SCRIPT_DIR%Data" -ScriptRoot "%SCRIPT_DIR:~0,-1%"

if !errorlevel! neq 0 (
    call :log_message "Smart Diagnosis Engine completed with error code !errorlevel!"
) else (
    call :log_message "Smart Diagnosis Engine completed successfully"
)

echo.
echo  Press any key to return to the main menu...
pause >nul
goto main_menu

:: ============================================================
:: RUN OEM VALIDATION (Option 55)
:: ============================================================
:run_oemvalidation
cls
echo ============================================================
echo  Running: OEM Validation Mode (Read-Only Hardware Check)
echo ============================================================
echo.
call :log_message "Running OEM Validation Mode"

set "OEM_FILE=%SCRIPT_DIR%OEM_Validation.ps1"
if not exist "%OEM_FILE%" (
    echo.
    echo  ERROR: OEM_Validation.ps1 not found!
    echo  Expected: %OEM_FILE%
    echo.
    call :log_message "CRITICAL: OEM_Validation.ps1 not found"
    pause
    goto main_menu
)

powershell -NoProfile %PS_POLICY% -File "%OEM_FILE%" -OutputPath "%REPORTS_DIR%" -DataPath "%SCRIPT_DIR%Data"

if !errorlevel! neq 0 (
    call :log_message "OEM Validation completed with error code !errorlevel!"
) else (
    call :log_message "OEM Validation completed successfully"
)

echo.
echo  Press any key to return to the main menu...
pause >nul
goto main_menu

:: ============================================================
:: RUN INTERACTIVE PS1 MENU
:: ============================================================
:run_interactive
cls
echo ============================================================
echo  Running Interactive Menu
echo ============================================================
echo.
call :log_message "Running interactive PS1 menu"

powershell -NoProfile %PS_POLICY% -File "%PS1_FILE%" -LogPath "%LOGS_DIR%" -ReportPath "%REPORTS_DIR%" -ConfigPath "%SCRIPT_DIR%Config" -BackupPath "%SCRIPT_DIR%Backups" -TempPath "%TEMP_DIR%" -DataPath "%SCRIPT_DIR%Data"

if !errorlevel! neq 0 (
    call :log_message "Interactive menu exited with error code !errorlevel!"
    type nul > "%LOGS_DIR%\error_detected.flag"
)

echo.
echo  Press any key to return to the main menu...
pause >nul
goto main_menu

:: ============================================================
:: OPEN FOLDERS
:: ============================================================
:open_logs
start "" "%LOGS_DIR%"
goto main_menu

:open_reports
start "" "%REPORTS_DIR%"
goto main_menu

:: ============================================================
:: EXIT
:: ============================================================
:exit_tool
call :log_message "Laptop Diagnostic Toolkit exiting"
echo.
echo  Thank you for using Laptop Diagnostic Toolkit.
echo  Logs saved to: %LOGS_DIR%
echo  Reports saved to: %REPORTS_DIR%
echo.
endlocal
exit /b 0

:: ============================================================
:: LOGGING SUBROUTINE
:: ============================================================
:log_message
for /f "tokens=*" %%D in ('powershell -NoProfile -Command "Get-Date -Format yyyy-MM-dd_HH:mm:ss"') do set "LOG_TS=%%D"
echo [%LOG_TS%] %~1 >> "%LOG_FILE%"
goto :eof
