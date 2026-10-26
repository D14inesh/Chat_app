@echo off
cd /d "%~dp0"
if not exist venv\Scripts\python.exe (
  echo First run: setting up...
  python -m venv venv
  venv\Scripts\python.exe -m pip install -q -r requirements.txt
)
start "" http://localhost:4700
venv\Scripts\python.exe server.py
pause
