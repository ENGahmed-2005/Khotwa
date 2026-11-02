#!/usr/bin/env python3
"""Compatibility entry point; source checks never establish runtime acceptance."""
from validate_planning import validate

errors = validate()
if errors:
    print('\n'.join(errors))
    raise SystemExit(1)
print('PASS: planning/source inventory only. Run Flutter and PostgreSQL-backed tests separately.')
