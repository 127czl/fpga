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

echo [INFO] JTAG programming through Efinity project flow.
echo [INFO] Ensure the board is powered and the JTAG downloader is connected.

call "%EFINITY_HOME%\bin\efx_run.bat" "Ti60_Demo.xml" --flow program --pgm_opts mode=jtag --output_dir "build_out" --work_dir "build_work"
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo [ERROR] JTAG programming failed with exit code %RC%.
    echo You can also open Efinity Programmer and select:
    echo   bitstream\Ti60_v102clear_Competition.bit
    exit /b %RC%
)

echo [OK] JTAG programming completed.
exit /b 0

