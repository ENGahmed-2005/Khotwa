#!/usr/bin/env python3
"""Best-effort lexical delimiter check; NOT a Dart parser/compiler."""
from pathlib import Path

root = Path(__file__).resolve().parents[1] / 'mobile' / 'lib'
closers = {')': '(', ']': '[', '}': '{'}
for path in root.rglob('*.dart'):
    data = path.read_text(encoding='utf-8')
    stack = []
    i = 0
    mode = None
    while i < len(data):
        c = data[i]
        nxt = data[i+1] if i+1 < len(data) else ''
        if mode == '//':
            if c == '\n':mode = None
        elif mode == '/*':
            if c == '*' and nxt == '/':mode = None; i+=1
        elif mode in ("'", '"'):
            if c == '\\':i+=1
            elif c == mode:mode = None
        elif c == '/' and nxt == '/':
            mode = '//'; i+=1
        elif c == '/' and nxt == '*':
            mode = '/*'; i+=1
        elif c in ("'", '"'):
            mode = c
        elif c in '([{':
            stack.append((c, i))
        elif c in ')]}':
            assert stack and stack[-1][0] == closers[c], f'{path} invalid closing {c} at byte {i} stack={stack[-3:]}'
            stack.pop()
        i+=1
    assert not stack, f'{path}: unclosed delimiters {stack}'
print('PASS: Dart source delimiters are balanced (lexical check only)')
