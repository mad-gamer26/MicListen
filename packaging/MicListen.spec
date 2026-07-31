# -*- mode: python ; coding: utf-8 -*-

from pathlib import Path

from PyInstaller.utils.hooks import collect_all, collect_submodules


project_root = Path(SPECPATH).parent
pyaudio_datas, pyaudio_binaries, pyaudio_hiddenimports = collect_all(
    "pyaudiowpatch"
)

analysis = Analysis(
    [str(project_root / "packaging" / "pyinstaller_entry.py")],
    pathex=[str(project_root)],
    binaries=pyaudio_binaries,
    datas=[
        (str(project_root / "miclisten" / "static"), "miclisten/static"),
        *pyaudio_datas,
    ],
    hiddenimports=[
        *pyaudio_hiddenimports,
        *collect_submodules("uvicorn"),
    ],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(analysis.pure)

executable = EXE(
    pyz,
    analysis.scripts,
    analysis.binaries,
    analysis.datas,
    [],
    name="MicListen",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    upx_exclude=[],
    runtime_tmpdir=None,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)
