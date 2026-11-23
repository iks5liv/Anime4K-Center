@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

rem Start_Windows.bat - запуск Anime4K Center на Windows.
rem По умолчанию используется привычный интерфейс launcher.ps1 через
rem Anime4K_Center.vbs (без окна консоли). Ключ --py запускает
rem кроссплатформенный launcher.py на Python.

if /I "%~1"=="--py" goto python_launcher

if exist "%~dp0Anime4K_Center.vbs" (
    start "" wscript.exe "%~dp0Anime4K_Center.vbs"
    exit /b 0
)

:python_launcher
where pythonw.exe >nul 2>nul
if not errorlevel 1 (
    start "" pythonw.exe "%~dp0launcher.py" --config-dir "%~dp0portable_config"
    exit /b 0
)

where python.exe >nul 2>nul
if not errorlevel 1 (
    python.exe "%~dp0launcher.py" --config-dir "%~dp0portable_config"
    exit /b %errorlevel%
)

echo.
echo Python не найден. Установите Python 3 с сайта python.org
echo (обязательно с компонентом "tcl/tk and IDLE") и запустите:
echo     python setup.py
echo.
echo Либо запустите классический интерфейс: Anime4K_Center.vbs
echo.
pause
exit /b 1
