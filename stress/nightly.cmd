@echo off
echo Start %date% %time% > nightly.log
C:\misc\OneLuaPro\intel\OneLuaPro-5.5.1.1-RC1-x64\bin\lua.exe stress.lua oracle nightly >> nightly.log 2>&1
echo Exit %errorlevel%, Ende %date% %time% >> nightly.log
