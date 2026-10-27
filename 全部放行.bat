@echo off
chcp 65001 >nul
rem 全部放行：国产 AI（网页+客户端）+ 中转站 + processes.txt 里的客户端进程
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0split-route.ps1" -Preset ai-all -Preset2 relay
