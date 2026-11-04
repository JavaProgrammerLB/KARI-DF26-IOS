#!/usr/bin/env python3
"""Compile native protocol/buffering tests without signing, API calls or devices."""
from pathlib import Path
import subprocess
import shutil
import os
import plistlib
import tempfile

root = Path(__file__).resolve().parents[1]
sources = ['KariDeviceReadiness', 'KariFirmwareCache', 'KariSettings', 'KariBodyProtocol', 'KariAIRequest', 'KariPlaybackQueue', 'KariLiveConfiguration', 'KariLiveWire', 'KariLiveMicGate', 'KariLocalization', 'KariConversationLanguage', 'KariMotionPlan']
with tempfile.TemporaryDirectory(prefix='kari-native-tests-') as folder:
    output = Path(folder) / 'native-checks'
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(Path(folder) / 'cache'),
                    *[str(root / 'Native/Sources/KariNative' / (name + '.swift')) for name in sources],
                    str(root / 'Tests/native/main.swift'), '-o', str(output)], check=True)
    bundle = Path(folder) / 'Localization.bundle'
    bundle.mkdir()
    (bundle / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'org.example.kari.tests', 'CFBundleDevelopmentRegion': 'en'}))
    for language in ['en', 'zh-Hans']:
        shutil.copytree(root / 'Native/Sources/KariNative/Resources' / (language + '.lproj'), bundle / (language + '.lproj'))
    subprocess.run([str(output)], check=True, env={**os.environ, 'KARI_TEST_BUNDLE': str(bundle)})

    remote_output = Path(folder) / 'remote-checks'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(Path(folder) / 'cache'),
                    *[str(root / 'Native/Sources/KariNative' / (name + '.swift')) for name in ['KariSettings', 'KariBodyProtocol', 'KariRemoteControl']],
                    str(root / 'Tests/remote/RemoteTests.swift'), '-o', str(remote_output)], check=True)
    subprocess.run([str(remote_output)], check=True)

    device_output = Path(folder) / 'device-checks'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(Path(folder) / 'cache'),
                    *[str(root / 'Native/Sources/KariNative' / (name + '.swift')) for name in ['KariDeviceReadiness', 'KariDeviceSession', 'KariFirmwareCache', 'KariBodyProtocol']],
                    str(root / 'Tests/device/DeviceSessionTests.swift'), '-o', str(device_output)], check=True)
    subprocess.run([str(device_output)], check=True)

with tempfile.TemporaryDirectory(prefix='kari-feature-tests-') as folder:
    feature_output = Path(folder) / 'feature-checks'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(Path(folder) / 'cache'),
                    *[str(root / 'Native/Sources/KariNative' / (name + '.swift')) for name in ['KariCompanionPolicy', 'KariMotionCoordinator']],
                    str(root / 'Tests/native/FeatureTests.swift'), '-o', str(feature_output)], check=True)
    subprocess.run([str(feature_output)], check=True)

subprocess.run(['python3', str(root / 'scripts/test-transfers.py')], check=True)
