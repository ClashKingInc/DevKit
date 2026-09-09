import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

import { createLocalArchiveBridge } from './local-archive-bridge.mjs';
import { loadConfig } from './local-stack.mjs';

const scriptRoot = dirname(fileURLToPath(import.meta.url));
const config = loadConfig(join(scriptRoot, '..', 'local', 'local-stack.example.json'));
const localAccessKeyId = 'local-integration-access-key';
const localSecretAccessKey = 'local-integration-secret-key';

function runGoProbe(trackingRoot, cacheDirectory) {
  return new Promise((resolve, reject) => {
    const child = spawn('go', ['run', join(scriptRoot, 'testdata', 'local_archive_sdk_probe.go')], {
      cwd: trackingRoot,
      env: {
        ...process.env,
        GOCACHE: cacheDirectory,
        CK_LOCAL_ARCHIVE_ENDPOINT: config.services.r2.origin,
        CK_LOCAL_ARCHIVE_BUCKET: config.services.r2.bucket,
        CK_LOCAL_ARCHIVE_ACCESS_KEY_ID: localAccessKeyId,
        CK_LOCAL_ARCHIVE_SECRET_ACCESS_KEY: localSecretAccessKey,
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    const append = (current, chunk) => `${current}${chunk}`.slice(-32_768);
    child.stdout.on('data', (chunk) => { stdout = append(stdout, chunk); });
    child.stderr.on('data', (chunk) => { stderr = append(stderr, chunk); });
    const timer = setTimeout(() => {
      child.kill('SIGKILL');
      reject(new Error('Tracking Go SDK archive probe timed out'));
    }, 30_000);
    child.once('error', (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.once('exit', (code) => {
      clearTimeout(timer);
      if (code === 0) resolve(stdout.trim());
      else reject(new Error(`Tracking Go SDK archive probe failed with exit ${code}: ${stderr.trim()}`));
    });
  });
}

test('Tracking Go SDK PutObject is range-readable from the same Miniflare R2 bucket', { timeout: 45_000 }, async () => {
  const requireFromApi = createRequire(join(config.repositories.api, 'package.json'));
  const { Miniflare, convertV4MiniflareOptions } = requireFromApi('miniflare');
  const runtime = new Miniflare(convertV4MiniflareOptions({
    modules: true,
    script: 'export default { fetch() { return new Response("ok") } }',
    compatibilityDate: '2026-08-22',
    r2Buckets: ['WAR_ARCHIVE'],
  }));
  const cacheDirectory = mkdtempSync(join(tmpdir(), 'ck-local-archive-go-cache-'));
  let bridge;
  let listening = false;
  try {
    await runtime.ready;
    const bucket = await runtime.getR2Bucket('WAR_ARCHIVE');
    bridge = createLocalArchiveBridge({
      bucket,
      accessKeyId: localAccessKeyId,
      secretAccessKey: localSecretAccessKey,
      port: config.services.r2.port,
    });
    await bridge.listen();
    listening = true;
    assert.equal(await runGoProbe(config.repositories.tracking, cacheDirectory), 'uploaded');

    // workers/api/src/war-archive.ts uses this same R2 range shape.
    const object = await bucket.get('packs/424242.pack', { range: { offset: 10, length: 12 } });
    assert.ok(object);
    assert.equal(Buffer.from(await object.arrayBuffer()).toString(), 'tracking-sdk');
  } finally {
    if (listening) await bridge.close();
    await runtime.dispose();
    rmSync(cacheDirectory, { recursive: true, force: true });
  }
});
