import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { basename, dirname, join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

const sourceDirectory = fileURLToPath(new URL('../src/reports/', import.meta.url));
const assets = ['NotoSansArabic.ttf', 'DejaVuSans.ttf', 'DejaVuSans-Bold.ttf', 'DejaVu-LICENSE.txt', 'OFL.txt', 'SOURCE.md'];
const digest = (path: string) => createHash('sha256').update(readFileSync(path)).digest('hex');

describe('report asset packaging', () => {
  it('pins the upstream static Arabic faces and their embedding permissions', () => {
    const expected = {
      'DejaVuSans.ttf': '7da195a74c55bef988d0d48f9508bd5d849425c1770dba5d7bfc6ce9ed848954',
      'DejaVuSans-Bold.ttf': 'e6476c1b80502924294eed40894c5b18e06c181444ca953e5334262df9c27724',
    };
    for (const [asset, sha] of Object.entries(expected)) {
      const path = join(sourceDirectory, 'assets', asset), bytes = readFileSync(path);
      expect(digest(path)).toBe(sha);
      const tables = new Map(Array.from({ length: bytes.readUInt16BE(4) }, (_, index) => {
        const start = 12 + index * 16;
        return [bytes.toString('ascii', start, start + 4), bytes.readUInt32BE(start + 8)] as const;
      }));
      expect(tables.has('cmap')).toBe(true); expect(tables.has('GSUB')).toBe(true);
      expect(tables.has('fvar')).toBe(false); expect(tables.has('gvar')).toBe(false);
      expect(bytes.readUInt16BE(tables.get('OS/2')! + 8)).toBe(0);
    }
    // Git may check text out as CRLF on Windows; copyright/license wording must match.
    const license = readFileSync(join(sourceDirectory, 'assets', 'DejaVu-LICENSE.txt'), 'utf8').replace(/\r\n/g, '\n');
    expect(createHash('sha256').update(license).digest('hex')).toBe('7a083b136e64d064794c3419751e5c7dd10d2f64c108fe5ba161eae5e5958a93');
  });
  it.each(['backend', 'outside'] as const)('preserves every licensed asset from an Arabic path with %s working directory', workingDirectory => {
    const temporary = mkdtempSync(join(resolve(tmpdir()), 'khotwa-report-assets-'));
    if (dirname(temporary) !== resolve(tmpdir()) || !basename(temporary).startsWith('khotwa-report-assets-')) throw new Error('Unsafe temporary directory');
    try {
      const backend = join(temporary, 'مسار عربي مع فراغات', 'backend');
      const source = join(backend, 'src', 'reports');
      const destination = join(backend, 'dist', 'src', 'reports', 'assets');
      mkdirSync(join(source, 'assets'), { recursive: true });
      copyFileSync(join(sourceDirectory, 'copy-assets.mjs'), join(source, 'copy-assets.mjs'));
      for (const asset of assets) copyFileSync(join(sourceDirectory, 'assets', asset), join(source, 'assets', asset));

      for (let attempt = 0; attempt < 2; attempt++) {
        const result = spawnSync(process.execPath, [join(source, 'copy-assets.mjs')], {
          cwd: workingDirectory === 'backend' ? backend : temporary,
          encoding: 'utf8', timeout: 10_000, windowsHide: true,
        });
        expect(result.error).toBeUndefined();
        expect(result.status, result.stderr || result.stdout).toBe(0);
        expect(readdirSync(destination).sort()).toEqual([...assets].sort());
        for (const asset of assets) expect(digest(join(destination, asset))).toBe(digest(join(sourceDirectory, 'assets', asset)));
      }
      expect(existsSync(join(temporary, 'dist'))).toBe(false);
    } finally {
      rmSync(temporary, { recursive: true, force: true });
    }
  });
});
