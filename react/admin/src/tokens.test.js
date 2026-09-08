import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

/**
 * `src/tokens.css` is generated from `design/color-tokens.json` by
 * `scripts/generate-color-tokens.py`. This holds the tree to that file: a
 * hand edit to the CSS, or a token change without a regeneration, fails
 * here rather than drifting from the Apple and Android exports.
 */
const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');

describe('tokens.css', () => {
  it('matches design/color-tokens.json', () => {
    const generator = resolve(repoRoot, 'scripts/generate-color-tokens.py');
    expect(existsSync(generator), `generator missing at ${generator}`).toBe(true);
    const run = spawnSync('python3', [generator, '--check'], { cwd: repoRoot, encoding: 'utf8' });
    expect(run.error, run.error && run.error.message).toBeUndefined();
    expect(run.status, `${run.stdout}${run.stderr}`).toBe(0);
  });
});
