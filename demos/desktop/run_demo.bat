@echo off
setlocal
cd /d "%~dp0"
if not defined DEMO_PYTHON if exist "%~dp0.demo-python" set /p DEMO_PYTHON=<"%~dp0.demo-python"
if exist "%~dp0.venv\Scripts\python.exe" (
  "%~dp0.venv\Scripts\python.exe" -u "%~dp0demo.py" %*
) else if defined DEMO_PYTHON (
  "%DEMO_PYTHON%" -u "%~dp0demo.py" %*
) else (
  python -u "%~dp0demo.py" %*
)
exit /b %errorlevel%
