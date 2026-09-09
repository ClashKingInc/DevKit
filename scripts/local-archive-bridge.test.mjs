import assert from 'node:assert/strict';
import { createHmac, createHash } from 'node:crypto';
import test from 'node:test';

import { createLocalArchiveHandler, localArchiveBridgeDefaults } from './local-archive-bridge.mjs';

const accessKeyId = 'local-access-key';
const secretAccessKey = 'local-secret-access-key';
const timestamp = '20260906T120000Z';
const now = () => Date.UTC(2026, 8, 6, 12, 0, 0);

function hmac(key, value) {
  return createHmac('sha256', key).update(value).digest();
}

function signedRequest(method, pathname, body = Buffer.alloc(0), extraHeaders = {}, search = '') {
  const payloadHash = extraHeaders['x-amz-content-sha256'] ?? createHash('sha256').update(body).digest('hex');
  const headers = {
    host: '127.0.0.1:9000',
    'x-amz-content-sha256': payloadHash,
    'x-amz-date': timestamp,
    ...extraHeaders,
  };
  const signedHeaders = Object.keys(headers).sort();
  const canonicalHeaders = signedHeaders.map((name) => `${name}:${headers[name]}\n`).join('');
  const canonical = [method, pathname, search.startsWith('?') ? search.slice(1) : search, canonicalHeaders, signedHeaders.join(';'), payloadHash].join('\n');
  const date = timestamp.slice(0, 8);
  const scope = `${date}/auto/s3/aws4_request`;
  const stringToSign = `AWS4-HMAC-SHA256\n${timestamp}\n${scope}\n${createHash('sha256').update(canonical).digest('hex')}`;
  const dateKey = hmac(`AWS4${secretAccessKey}`, date);
  const regionKey = hmac(dateKey, 'auto');
  const serviceKey = hmac(regionKey, 's3');
  const signingKey = hmac(serviceKey, 'aws4_request');
  const signature = createHmac('sha256', signingKey).update(stringToSign).digest('hex');
  headers.authorization = `AWS4-HMAC-SHA256 Credential=${accessKeyId}/${scope}, SignedHeaders=${signedHeaders.join(';')}, Signature=${signature}`;
  return { method, pathname, search, headers, body, remoteAddress: '127.0.0.1' };
}

function bucketFixture() {
  const objects = new Map();
  return {
    objects,
    async put(key, body) {
      const bytes = Buffer.from(body);
      objects.set(key, bytes);
      return { etag: createHash('sha256').update(bytes).digest('hex') };
    },
    async head(key) {
      const body = objects.get(key);
      return body ? { size: body.length, etag: createHash('sha256').update(body).digest('hex') } : null;
    },
    async get(key, options) {
      const stored = objects.get(key);
      if (!stored) return null;
      const body = options?.range
        ? stored.subarray(options.range.offset, options.range.offset + options.range.length)
        : stored;
      return {
        size: stored.length,
        etag: createHash('sha256').update(stored).digest('hex'),
        arrayBuffer: async () => body,
      };
    },
  };
}

function handler(bucket = bucketFixture(), options = {}) {
  return { bucket, handle: createLocalArchiveHandler({ bucket, accessKeyId, secretAccessKey, now, maximumUploadBytes: 1024, ...options }) };
}

test('uses a bounded loopback-only archive endpoint', () => {
  assert.deepEqual(localArchiveBridgeDefaults, {
    host: '127.0.0.1', port: 9000, bucket: 'clashking-wars', maximumUploadBytes: 256 * 1024 * 1024,
  });
});

test('accepts signed PutObject and returns the same bytes through signed GET and HEAD', async () => {
  const { bucket, handle } = handler();
  const bytes = Buffer.from('archive-pack');
  const put = await handle(signedRequest('PUT', '/clashking-wars/packs/000001.pack', bytes));
  assert.equal(put.status, 200);
  assert.deepEqual(bucket.objects.get('packs/000001.pack'), bytes);

  const get = await handle(signedRequest('GET', '/clashking-wars/packs/000001.pack'));
  assert.equal(get.status, 200);
  assert.deepEqual(get.body, bytes);
  assert.equal(get.headers['accept-ranges'], 'bytes');

  const head = await handle(signedRequest('HEAD', '/clashking-wars/packs/000001.pack'));
  assert.equal(head.status, 200);
  assert.equal(head.headers['content-length'], String(bytes.length));
  assert.equal(head.body.length, 0);
});

test('supports a signed single byte range for archive frame reads', async () => {
  const bucket = bucketFixture();
  bucket.objects.set('packs/12.pack', Buffer.from('abcdefghij'));
  const { handle } = handler(bucket);
  const response = await handle(signedRequest('GET', '/clashking-wars/packs/12.pack', Buffer.alloc(0), { range: 'bytes=2-5' }));
  assert.equal(response.status, 206);
  assert.equal(response.body.toString(), 'cdef');
  assert.equal(response.headers['content-range'], 'bytes 2-5/10');
});

test('accepts only the AWS SDK method-matched signed x-id query', async () => {
  const { handle } = handler();
  const request = signedRequest('PUT', '/clashking-wars/packs/9.pack', Buffer.from('pack'), {}, '?x-id=PutObject');
  assert.equal((await handle(request)).status, 200);
  const wrong = signedRequest('PUT', '/clashking-wars/packs/10.pack', Buffer.from('pack'), {}, '?x-id=DeleteObject');
  assert.equal((await handle(wrong)).status, 400);
});

test('rejects invalid signatures, stale requests, remote clients, browser origins, and unsafe paths', async () => {
  const { handle } = handler();
  const invalid = signedRequest('PUT', '/clashking-wars/packs/1.pack', Buffer.from('safe'));
  invalid.headers.authorization = `${invalid.headers.authorization.slice(0, -1)}${invalid.headers.authorization.endsWith('0') ? '1' : '0'}`;
  assert.equal((await handle(invalid)).status, 403);

  const stale = createLocalArchiveHandler({ bucket: bucketFixture(), accessKeyId, secretAccessKey, now: () => now() + 600_000 });
  assert.equal((await stale(signedRequest('GET', '/clashking-wars/packs/1.pack'))).status, 403);

  const remote = signedRequest('GET', '/clashking-wars/packs/1.pack');
  remote.remoteAddress = '192.0.2.1';
  assert.equal((await handle(remote)).status, 403);

  const browser = signedRequest('GET', '/clashking-wars/packs/1.pack', Buffer.alloc(0), { origin: 'http://127.0.0.1:3000' });
  assert.equal((await handle(browser)).status, 403);

  assert.equal((await handle(signedRequest('GET', '/clashking-wars/private.json'))).status, 404);
  assert.equal((await handle(signedRequest('GET', '/other/packs/1.pack'))).status, 404);
  assert.equal((await handle(signedRequest('DELETE', '/clashking-wars/packs/1.pack'))).status, 405);
});

test('rejects oversized uploads and payload tampering before writing R2', async () => {
  const { bucket, handle } = handler();
  const request = signedRequest('PUT', '/clashking-wars/packs/2.pack', Buffer.from('signed'));
  request.body = Buffer.from('changed');
  assert.equal((await handle(request)).status, 403);
  assert.equal(bucket.objects.size, 0);

  const oversized = signedRequest('PUT', '/clashking-wars/packs/2.pack', Buffer.alloc(1025));
  assert.equal((await handle(oversized)).status, 413);
  assert.equal(bucket.objects.size, 0);

  const unsigned = signedRequest('PUT', '/clashking-wars/packs/2.pack', Buffer.from('unsigned'), {
    'x-amz-content-sha256': 'UNSIGNED-PAYLOAD',
  });
  assert.equal((await handle(unsigned)).status, 403);
  assert.equal(bucket.objects.size, 0);
});

test('decodes and verifies the checksum for AWS streaming unsigned trailers', async () => {
  const { bucket, handle } = handler();
  const decoded = Buffer.from('hello');
  const encoded = Buffer.from('5\r\nhello\r\n0\r\nx-amz-checksum-crc32:NhCmhg==\r\n\r\n');
  const request = signedRequest('PUT', '/clashking-wars/packs/3.pack', encoded, {
    'content-encoding': 'aws-chunked',
    'x-amz-content-sha256': 'STREAMING-UNSIGNED-PAYLOAD-TRAILER',
    'x-amz-decoded-content-length': String(decoded.length),
    'x-amz-sdk-checksum-algorithm': 'CRC32',
    'x-amz-trailer': 'x-amz-checksum-crc32',
  });
  const response = await handle(request);
  assert.equal(response.status, 200);
  assert.deepEqual(bucket.objects.get('packs/3.pack'), decoded);

  const bad = signedRequest('PUT', '/clashking-wars/packs/4.pack', Buffer.from('5\r\nhello\r\n0\r\nx-amz-checksum-crc32:AAAAAA==\r\n\r\n'), {
    'content-encoding': 'aws-chunked',
    'x-amz-content-sha256': 'STREAMING-UNSIGNED-PAYLOAD-TRAILER',
    'x-amz-decoded-content-length': String(decoded.length),
    'x-amz-sdk-checksum-algorithm': 'CRC32',
    'x-amz-trailer': 'x-amz-checksum-crc32',
  });
  assert.equal((await handle(bad)).status, 400);
  assert.equal(bucket.objects.has('packs/4.pack'), false);
});
