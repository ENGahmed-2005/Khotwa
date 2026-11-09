import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { basename, dirname, join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

const sourceDirectory = fileURLToPath(new URL('../src/reports/', import.meta.url));
const assets = ['NotoSansArabic.ttf', 'OFL.txt', 'SOURCE.md'];
const digest = (path: string) => createHash('sha256').update(readFileSync(path)).digest('hex');

describe('report asset packaging', () => {
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
