@echo off
cd /d "%~dp0"
if not exist build mkdir build
cl /nologo /O2 /std:c11 /W3 /D_CRT_SECURE_NO_WARNINGS /Fobuild\ /Fe:SlimeChunkPerimeterGen.exe src\main.c src\Perimeter.c src\util\Inputs.c
