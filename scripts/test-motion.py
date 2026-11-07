#!/usr/bin/env python3
"""Compile the pure motion-plan checks. No device, signature, or network."""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sources = [
    root / "Native/Sources/KariNative/KariMotionPlan.swift",
    root / "Native/Sources/KariNative/KariTurnPulseCalibration.swift",
    root / "Native/Sources/KariNative/KariChassisIntent.swift",
    root / "Tests/native/MotionChecks.swift",
]
swiftc = shutil.which("swiftc")
command = [swiftc] if swiftc else (["xcrun", "swiftc"] if shutil.which("xcrun") else None)
if command is None:
    sys.stderr.write("swiftc is not available; motion checks were not executed\n")
    sys.exit(2)

with tempfile.TemporaryDirectory(prefix="kari-motion-checks-") as folder:
    output = Path(folder) / "motion-checks"
    main = Path(folder) / "main.swift"
    shutil.copyfile(sources[-1], main)
    subprocess.run([*command, "-module-cache-path", str(Path(folder) / "cache"), *[str(source) for source in sources[:-1]], str(main), "-o", str(output)], check=True)
    subprocess.run([str(output)], check=True)
