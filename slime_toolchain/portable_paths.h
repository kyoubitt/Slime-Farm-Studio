// portable_paths.h - lets every tool take the Windows-style paths the .ps1
// scripts build ("main\work\x.csv") when they run under pwsh on Linux.
//
// PowerShell's own cmdlets accept "\" on Linux, but the arguments it hands a
// native program arrive verbatim, and fopen("main\work\x.csv") on Linux opens
// a file literally named that. None of these tools takes a backslash for any
// other reason (arguments are numbers, hex masks, flags and paths), so on
// non-Windows builds every "\" in argv - and in the stdin command lines of
// slime_gpu --worker and hotspot_scan --phase-stdin - becomes "/".
// On Windows both functions do nothing.
#pragma once
#include <string>

static inline void slimeFixPath(char* s) {
#ifndef _WIN32
    for (; s && *s; s++) if (*s == '\\') *s = '/';
#else
    (void)s;
#endif
}

static inline void slimeFixPath(std::string& s) {
#ifndef _WIN32
    for (char& c : s) if (c == '\\') c = '/';
#else
    (void)s;
#endif
}

static inline void slimeFixArgv(int argc, char** argv) {
    for (int i = 1; i < argc; i++) slimeFixPath(argv[i]);
}
