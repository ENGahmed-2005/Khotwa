import { cpSync, mkdirSync } from 'node:fs';
mkdirSync('dist/src/reports/assets', { recursive: true });
cpSync('src/reports/assets', 'dist/src/reports/assets', { recursive: true });
