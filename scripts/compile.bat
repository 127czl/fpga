@echo off
setlocal EnableExtensions
cd /d "%~dp0.."

if not defined EFINITY_HOME set "EFINITY_HOME=C:\Efinity\2026.1"

if not exist "%EFINITY_HOME%\bin\efx_run.bat" (
    echo [ERROR] Efinity runner not found:
    echo         %EFINITY_HOME%\bin\efx_run.bat
    echo Set EFINITY_HOME to the Efinity 2026.1 installation directory.
    exit /b 1
)

if exist "%EFINITY_HOME%\bin\setup.bat" call "%EFINITY_HOME%\bin\setup.bat"

if not exist "build_out" mkdir "build_out"
if not exist "build_work" mkdir "build_work"

echo [INFO] Project : %CD%
echo [INFO] Efinity : %EFINITY_HOME%
echo [INFO] Flow    : compile

call "%EFINITY_HOME%\bin\efx_run.bat" "Ti60_Demo.xml" --flow compile --output_dir "build_out" --work_dir "build_work"
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo [ERROR] Compile failed with exit code %RC%.
    exit /b %RC%
)

echo [OK] Compile completed.
if exist "build_out\Ti60_Demo.bit" echo [OK] build_out\Ti60_Demo.bit
if exist "build_out\Ti60_Demo.bit.bin" echo [OK] build_out\Ti60_Demo.bit.bin
if exist "build_out\Ti60_Demo.timing.rpt" echo [OK] build_out\Ti60_Demo.timing.rpt
exit /b 0

