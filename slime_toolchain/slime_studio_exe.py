"""slime_studio_exe.py - the entry point of SlimeFarmStudio.exe, the Windows app built from these same files.

  SlimeFarmStudio.exe              opens the app (Slime Farm Studio, in Windows Terminal)
  SlimeFarmStudio.exe <command>    the ./slime command line: doctor, hunt, perimeter, ...

Built in build.ps1 with PyInstaller when it's installed (pip install pyinstaller); people who run the .exe need
nothing, not even Python. It goes next to slime_gpu.exe and the other tools and finds them there.
"""
import importlib.machinery
import importlib.util
import os
import sys

HERE = getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__)))   # where `slime` was bundled
sys.path.insert(0, HERE)
# what `slime` imports: it's bundled as a plain file, so PyInstaller can't see these by itself
import argparse, csv, glob, re, shlex, shutil, subprocess  # noqa: E401,E402,F401
import slime_studio  # noqa: E402,F401  (and the app, which the CLI only imports when it opens)


def load_cli():
    loader = importlib.machinery.SourceFileLoader("slime_cli", os.path.join(HERE, "slime"))
    mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("slime_cli", loader))
    sys.modules["slime_cli"] = mod                    # its gui command hands itself to the app by name
    loader.exec_module(mod)
    return mod


if __name__ == "__main__":
    cli = load_cli()
    try:
        sys.exit(cli.main(sys.argv[1:] or ["gui"]))
    except KeyboardInterrupt:
        sys.exit(130)
