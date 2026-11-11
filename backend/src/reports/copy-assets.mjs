import { copyFileSync, mkdirSync } from 'node:fs';
import { URL } from 'node:url';

const source = new URL('./assets/', import.meta.url);
const destination = new URL('../../dist/src/reports/assets/', import.meta.url);
mkdirSync(destination, { recursive: true });

// Recursive cpSync crashes on Arabic Windows paths in Node 22.23.2.
for (const asset of ['NotoSansArabic.ttf', 'DejaVuSans.ttf', 'DejaVuSans-Bold.ttf', 'DejaVu-LICENSE.txt', 'OFL.txt', 'SOURCE.md']) {
  copyFileSync(new URL(asset, source), new URL(asset, destination));
}
