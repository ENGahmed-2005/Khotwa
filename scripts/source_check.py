#!/usr/bin/env python3
"""Validate text-level project scaffolding without requiring Flutter installation.
This is not a Dart compiler; run flutter analyze/test after bootstrap.
"""
from pathlib import Path
from collections import Counter
import re
import yaml

root = Path(__file__).resolve().parents[1]
files = list((root/'mobile'/'lib').rglob('*.dart'))
assert len(files) >= 7, 'Missing Dart source files'
assert (root/'docs'/'SRS_Khotwa_v1.3.docx').stat().st_size > 40000
manifest = yaml.safe_load((root/'mobile'/'pubspec.yaml').read_text(encoding='utf8'))
assert manifest['name'] == 'khotwa'
assert 'flutter_secure_storage' in manifest['dependencies']
raw = (root/'mobile'/'lib'/'data'/'assessment_templates.dart').read_text(encoding='utf8')
assert raw.count('AssessmentCard(number:') == 6
assert raw.count('AssessmentTask(id:') == 20, raw.count('AssessmentTask(id:')
for n in range(1, 7):
    assert f'AssessmentCard(number: {n}' in raw
for field in ('birthDate', 'medicalDiagnosis', "'name':", "'dob':"):
    assert field not in (root/'mobile'/'lib'/'models'/'student.dart').read_text(encoding='utf8')
for token in ('AssessmentStatus.approved', 'SecureLocalStore', 'recommendedAgeGroup', 'approveAssessment'):
    assert any(token in f.read_text(encoding='utf8') for f in files)
for file in files:
    text = file.read_text(encoding='utf8')
    assert text.endswith('\n'), f'{file} missing final newline'
    assert 'TODO:' not in text, f'{file} contains unfinished markers'
    assert not re.search(r'(?m)^\s*<<<<<<< |^\s*=======|^\s*>>>>>>> ', text), f'{file} merge conflict'
print(f'PASS: {len(files)} Dart sources, six cards, 20 tasks, SRS present, secure plugin configured')
print('NOTE: This is a content check. Flutter SDK was unavailable in this environment.')
