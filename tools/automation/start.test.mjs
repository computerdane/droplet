import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { copyFileSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const launcher = fileURLToPath(new URL('./start', import.meta.url));

for (const [name, args, expectedCli, expectedModel] of [
  ['default', [], 'codex', 'gpt-6-sol'],
  ['explicit Codex', ['codex'], 'codex', 'gpt-6-sol'],
  ['Claude Code', ['claude'], 'claude', 'opus'],
]) {
  test(`launcher starts ${name} after shared preflight`, () => {
    const root = mkdtempSync(join(tmpdir(), 'droplet-start-'));
    try {
      const bin = join(root, 'bin');
      mkdirSync(bin);
      mkdirSync(join(root, 'tools', 'automation'), { recursive: true });
      copyFileSync(launcher, join(root, 'tools', 'automation', 'start'));
      const log = join(root, 'calls');
      for (const command of ['flock', 'git', 'node', 'codex', 'claude']) {
        const stub = `#!/usr/bin/env bash\nprintf '%s %s\\n' '${command}' "$*" >> "$START_TEST_LOG"\nif [[ '${command}' == node && "\${2:-}" == status ]]; then printf '{"ok":true}\\n'; fi\nif [[ '${command}' == codex && "\${1:-}" == login && "\${2:-}" == status ]]; then printf '%s\\n' 'Logged in using ChatGPT'; fi\n`;
        writeFileSync(join(bin, command), stub, { mode: 0o755 });
      }
      const result = spawnSync('bash', [join(root, 'tools', 'automation', 'start'), ...args, '--extra'], {
        cwd: root,
        env: { ...process.env, ANTHROPIC_API_KEY: '', OPENAI_API_KEY: '', PATH: `${bin}:${process.env.PATH}`, START_TEST_LOG: log, GH_CONFIG_DIR: join(root, 'bot-gh') },
        encoding: 'utf8',
      });
      assert.equal(result.status, 0, result.stderr);
      const calls = readFileSync(log, 'utf8').trim().split('\n');
      const preflight = expectedCli === 'codex' ? ['codex login status'] : [];
      assert.deepEqual(calls.slice(0, preflight.length), preflight);
      const remaining = calls.slice(preflight.length);
      assert.match(remaining[0], /^flock -n 9$/);
      assert.match(remaining[1], /^git config --local credential\.https:\/\/github\.com\.helper /);
      assert.equal(remaining[2], 'node tools/automation/queue.mjs reconcile');
      assert.equal(remaining[3], 'node tools/automation/queue.mjs status');
      assert.match(remaining[4], new RegExp(`^${expectedCli} .*--model ${expectedModel} `));
      assert.match(remaining[4], /--extra$/);
      assert.equal(remaining.length, 5);
      assert.deepEqual(JSON.parse(readFileSync(join(root, '.automation', 'startup.json'), 'utf8')), { ok: true });
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
}

test('Claude launch rejects API billing before shared preflight', () => {
  const result = spawnSync('bash', [launcher, 'claude'], {
    env: { ...process.env, ANTHROPIC_API_KEY: 'test-key' },
    encoding: 'utf8',
  });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /Unset ANTHROPIC_API_KEY/);
});

test('Codex launch rejects API billing before shared preflight', () => {
  const result = spawnSync('bash', [launcher], {
    env: { ...process.env, OPENAI_API_KEY: 'test-key' },
    encoding: 'utf8',
  });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /Unset OPENAI_API_KEY/);
});

test('Codex launch rejects a saved API-key login before shared preflight', () => {
  const bin = mkdtempSync(join(tmpdir(), 'droplet-codex-auth-'));
  try {
    writeFileSync(join(bin, 'codex'), '#!/usr/bin/env bash\nprintf "Logged in using API key\\n"\n', { mode: 0o755 });
    const result = spawnSync('bash', [launcher], {
      env: { ...process.env, OPENAI_API_KEY: '', PATH: `${bin}:${process.env.PATH}` },
      encoding: 'utf8',
    });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /Sign in to Codex with ChatGPT/);
  } finally {
    rmSync(bin, { recursive: true, force: true });
  }
});
