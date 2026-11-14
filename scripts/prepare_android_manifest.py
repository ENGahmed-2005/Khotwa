#!/usr/bin/env python3
"""Disable Android auto-backup for encrypted secure-storage compatibility.
Generated manifest must have an android: namespace on root, as Flutter does.
"""
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit('Usage: python prepare_android_manifest.py <AndroidManifest.xml>')
path = Path(sys.argv[1])
text = path.read_text(encoding='utf-8')
if 'android:allowBackup=' in text:
    import re
    text = re.sub(r'android:allowBackup="[^"]*"', 'android:allowBackup="false"', text)
elif '<application' in text:
    text = text.replace('<application', '<application android:allowBackup="false"', 1)
else:
    raise SystemExit('No application node found')
path.write_text(text, encoding='utf-8')
print('Android auto-backup disabled:', path)
