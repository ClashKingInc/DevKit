import { createHmac, createHash, timingSafeEqual } from 'node:crypto';
import { createServer } from 'node:http';

const listenHost = '127.0.0.1';
const expectedBucket = 'clashking-wars';
const defaultPort = 9000;
const defaultMaximumUploadBytes = 256 * 1024 * 1024;
const maximumClockSkewMs = 5 * 60 * 1000;
const safePath = /^\/clashking-wars\/(packs\/[0-9]+\.pack)$/u;

function hmac(key, value) {
  return createHmac('sha256', key).update(value).digest();
}

function sha256(value, encoding = 'hex') {
  return createHash('sha256').update(value).digest(encoding);
}

function constantEqual(left, right) {
  const first = Buffer.from(left);
  const second = Buffer.from(right);
  return first.length === second.length && timingSafeEqual(first, second);
}

function header(headers, name) {
  const value = headers[name.toLowerCase()];
  return Array.isArray(value) ? value.join(',') : value ?? '';
}

function normalizeHeader(value) {
  return value.trim().replace(/\s+/gu, ' ');
}

function parseAmzDate(value) {
  if (!/^\d{8}T\d{6}Z$/u.test(value)) return undefined;
  const parsed = Date.UTC(
    Number(value.slice(0, 4)), Number(value.slice(4, 6)) - 1, Number(value.slice(6, 8)),
    Number(value.slice(9, 11)), Number(value.slice(11, 13)), Number(value.slice(13, 15)),
  );
  return Number.isNaN(parsed) ? undefined : parsed;
}

function authorizationParts(value) {
  const match = /^AWS4-HMAC-SHA256 Credential=([^/\s]+)\/(\d{8})\/([^/\s]+)\/s3\/aws4_request, SignedHeaders=([a-z0-9;-]+), Signature=([a-f0-9]{64})$/u.exec(value);
  if (!match) return undefined;
  return {
    accessKeyId: match[1],
    date: match[2],
    region: match[3],
    signedHeaders: match[4].split(';'),
    signature: match[5],
  };
}

function verifyPayloadHash(payloadHash, body, method) {
  if (/^[a-f0-9]{64}$/u.test(payloadHash)) return constantEqual(payloadHash, sha256(body));
  if (payloadHash === 'STREAMING-UNSIGNED-PAYLOAD-TRAILER') return method === 'PUT';
  return payloadHash === 'UNSIGNED-PAYLOAD' && method !== 'PUT';
}

export function verifySigV4(request, credentials, now = () => Date.now()) {
  const authorization = authorizationParts(header(request.headers, 'authorization'));
  if (!authorization || !constantEqual(authorization.accessKeyId, credentials.accessKeyId)) return false;
  if (authorization.region.length === 0 || authorization.date.length !== 8) return false;
  if (header(request.headers, 'x-amz-security-token')) return false;

  const amzDate = header(request.headers, 'x-amz-date');
  const timestamp = parseAmzDate(amzDate);
  if (timestamp === undefined || Math.abs(now() - timestamp) > maximumClockSkewMs || !amzDate.startsWith(authorization.date)) return false;
  const requiredHeaders = ['host', 'x-amz-content-sha256', 'x-amz-date'];
  if (!requiredHeaders.every((name) => authorization.signedHeaders.includes(name))) return false;
  if ([...authorization.signedHeaders].sort().join(';') !== authorization.signedHeaders.join(';')) return false;
  if (new Set(authorization.signedHeaders).size !== authorization.signedHeaders.length) return false;

  const canonicalHeaders = [];
  for (const name of authorization.signedHeaders) {
    const value = header(request.headers, name);
    if (value === '') return false;
    canonicalHeaders.push(`${name}:${normalizeHeader(value)}\n`);
  }
  const payloadHash = header(request.headers, 'x-amz-content-sha256');
  if (!verifyPayloadHash(payloadHash, request.body, request.method)) return false;
  if (payloadHash === 'STREAMING-UNSIGNED-PAYLOAD-TRAILER') {
    const streamingHeaders = ['content-encoding', 'x-amz-decoded-content-length', 'x-amz-sdk-checksum-algorithm', 'x-amz-trailer'];
    if (!streamingHeaders.every((name) => authorization.signedHeaders.includes(name))) return false;
  }
  const canonicalRequest = [
    request.method,
    request.pathname,
    request.search.startsWith('?') ? request.search.slice(1) : request.search,
    canonicalHeaders.join(''),
    authorization.signedHeaders.join(';'),
    payloadHash,
  ].join('\n');
  const scope = `${authorization.date}/${authorization.region}/s3/aws4_request`;
  const stringToSign = `AWS4-HMAC-SHA256\n${amzDate}\n${scope}\n${sha256(canonicalRequest)}`;
  const dateKey = hmac(`AWS4${credentials.secretAccessKey}`, authorization.date);
  const regionKey = hmac(dateKey, authorization.region);
  const serviceKey = hmac(regionKey, 's3');
  const signingKey = hmac(serviceKey, 'aws4_request');
  const expected = createHmac('sha256', signingKey).update(stringToSign).digest('hex');
  return constantEqual(expected, authorization.signature);
}

function checksum(bytes, algorithm) {
  if (algorithm === 'sha256') return sha256(bytes, 'base64');
  if (algorithm === 'sha1') return createHash('sha1').update(bytes).digest('base64');
  if (algorithm === 'crc32') return integerChecksum(bytes, 0xedb88320);
  if (algorithm === 'crc32c') return integerChecksum(bytes, 0x82f63b78);
  return undefined;
}

function integerChecksum(bytes, polynomial) {
  let value = 0xffffffff;
  for (const byte of bytes) {
    value ^= byte;
    for (let bit = 0; bit < 8; bit += 1) value = (value >>> 1) ^ ((value & 1) ? polynomial : 0);
  }
  const output = Buffer.allocUnsafe(4);
  output.writeUInt32BE((value ^ 0xffffffff) >>> 0);
  return output.toString('base64');
}

function decodeAwsChunked(body) {
  const chunks = [];
  const trailers = {};
  let offset = 0;
  for (;;) {
    const lineEnd = body.indexOf('\r\n', offset, 'utf8');
    if (lineEnd < 0) throw new Error('invalid aws-chunked body');
    const sizeText = body.subarray(offset, lineEnd).toString('ascii').split(';', 1)[0];
    if (!/^[a-f0-9]+$/iu.test(sizeText)) throw new Error('invalid aws-chunked size');
    const size = Number.parseInt(sizeText, 16);
    offset = lineEnd + 2;
    if (size === 0) break;
    if (!Number.isSafeInteger(size) || offset + size + 2 > body.length) throw new Error('invalid aws-chunked length');
    chunks.push(body.subarray(offset, offset + size));
    offset += size;
    if (body.subarray(offset, offset + 2).toString('ascii') !== '\r\n') throw new Error('invalid aws-chunked delimiter');
    offset += 2;
  }
  for (;;) {
    const lineEnd = body.indexOf('\r\n', offset, 'utf8');
    if (lineEnd < 0) throw new Error('invalid aws-chunked trailer');
    const line = body.subarray(offset, lineEnd).toString('utf8');
    offset = lineEnd + 2;
    if (line === '') break;
    const separator = line.indexOf(':');
    if (separator <= 0) throw new Error('invalid aws-chunked trailer');
    const name = line.slice(0, separator).toLowerCase();
    if (Object.hasOwn(trailers, name)) throw new Error('duplicate aws-chunked trailer');
    trailers[name] = line.slice(separator + 1).trim();
  }
  if (offset !== body.length) throw new Error('unexpected aws-chunked suffix');
  return { body: Buffer.concat(chunks), trailers };
}

function decodedUpload(request) {
  const payloadHash = header(request.headers, 'x-amz-content-sha256');
  if (payloadHash !== 'STREAMING-UNSIGNED-PAYLOAD-TRAILER') return { body: request.body, trailers: {} };
  if (!header(request.headers, 'content-encoding').toLowerCase().split(',').map((value) => value.trim()).includes('aws-chunked')) {
    throw new Error('streaming payload is not aws-chunked');
  }
  const decoded = decodeAwsChunked(request.body);
  const expectedLength = Number(header(request.headers, 'x-amz-decoded-content-length'));
  if (!Number.isSafeInteger(expectedLength) || expectedLength !== decoded.body.length) throw new Error('decoded content length mismatch');
  return decoded;
}

function verifyChecksum(request, upload) {
  const streaming = header(request.headers, 'x-amz-content-sha256') === 'STREAMING-UNSIGNED-PAYLOAD-TRAILER';
  const declared = header(request.headers, 'x-amz-sdk-checksum-algorithm').toLowerCase();
  const trailerNames = header(request.headers, 'x-amz-trailer').toLowerCase().split(',').map((value) => value.trim()).filter(Boolean);
  const algorithms = ['crc32', 'crc32c', 'sha1', 'sha256'];
  const present = algorithms.filter((algorithm) => {
    const name = `x-amz-checksum-${algorithm}`;
    return header(request.headers, name) || upload.trailers[name];
  });
  if (declared && !algorithms.includes(declared)) return false;
  if (declared && !present.includes(declared)) return false;
  if (streaming && (!declared || !trailerNames.includes(`x-amz-checksum-${declared}`))) return false;
  if (trailerNames.some((name) => !Object.hasOwn(upload.trailers, name))) return false;
  if (Object.keys(upload.trailers).some((name) => !trailerNames.includes(name))) return false;
  return present.every((algorithm) => {
    const name = `x-amz-checksum-${algorithm}`;
    return constantEqual(header(request.headers, name) || upload.trailers[name], checksum(upload.body, algorithm));
  });
}

function xml(status, code, message) {
  return {
    status,
    headers: { 'content-type': 'application/xml', 'cache-control': 'no-store' },
    body: Buffer.from(`<?xml version="1.0" encoding="UTF-8"?><Error><Code>${code}</Code><Message>${message}</Message></Error>`),
  };
}

function etag(object) {
  const value = object?.httpEtag ?? object?.etag;
  if (!value) return undefined;
  return value.startsWith('"') ? value : `"${value}"`;
}

function objectHeaders(object, length, range) {
  const headers = {
    'accept-ranges': 'bytes',
    'content-length': String(length),
    'content-type': object?.httpMetadata?.contentType ?? 'application/octet-stream',
    'cache-control': 'no-store',
  };
  const objectEtag = etag(object);
  if (objectEtag) headers.etag = objectEtag;
  if (object?.uploaded instanceof Date) headers['last-modified'] = object.uploaded.toUTCString();
  if (range) headers['content-range'] = `bytes ${range.offset}-${range.offset + range.length - 1}/${range.total}`;
  return headers;
}

function requestedRange(value, total) {
  if (!value) return undefined;
  const match = /^bytes=(\d*)-(\d*)$/u.exec(value);
  if (!match || (match[1] === '' && match[2] === '')) throw new Error('invalid range');
  let start;
  let end;
  if (match[1] === '') {
    const suffix = Number(match[2]);
    if (!Number.isSafeInteger(suffix) || suffix <= 0) throw new Error('invalid range');
    start = Math.max(0, total - suffix);
    end = total - 1;
  } else {
    start = Number(match[1]);
    end = match[2] === '' ? total - 1 : Number(match[2]);
  }
  if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 0 || start >= total || end < start) throw new Error('unsatisfiable range');
  end = Math.min(end, total - 1);
  return { offset: start, length: end - start + 1, total };
}

async function objectBytes(object) {
  if (typeof object.arrayBuffer === 'function') return Buffer.from(await object.arrayBuffer());
  if (object.body) return Buffer.from(await new Response(object.body).arrayBuffer());
  throw new Error('R2 object has no readable body');
}

export function createLocalArchiveHandler(options) {
  const { bucket, accessKeyId, secretAccessKey } = options;
  const port = options.port ?? defaultPort;
  const maximumUploadBytes = options.maximumUploadBytes ?? defaultMaximumUploadBytes;
  const now = options.now ?? (() => Date.now());
  if (!bucket || typeof bucket.put !== 'function' || typeof bucket.get !== 'function' || typeof bucket.head !== 'function') throw new Error('An R2-compatible bucket is required');
  if (typeof accessKeyId !== 'string' || accessKeyId.length < 8 || typeof secretAccessKey !== 'string' || secretAccessKey.length < 16) throw new Error('Local bridge credentials are required');
  if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('Invalid local bridge port');
  if (!Number.isSafeInteger(maximumUploadBytes) || maximumUploadBytes < 1) throw new Error('Invalid maximum upload size');

  return async (request) => {
    if (!['127.0.0.1', '::ffff:127.0.0.1', '::1'].includes(request.remoteAddress)) return xml(403, 'AccessDenied', 'Loopback access required');
    if (header(request.headers, 'origin')) return xml(403, 'AccessDenied', 'Browser origins are not accepted');
    const operation = { PUT: 'PutObject', GET: 'GetObject', HEAD: 'HeadObject' }[request.method];
    if (request.search && request.search !== `?x-id=${operation ?? ''}`) return xml(400, 'InvalidRequest', 'Query parameters are not supported');
    if (header(request.headers, 'host') !== `${listenHost}:${port}`) return xml(403, 'AccessDenied', 'Unexpected host');
    const match = safePath.exec(request.pathname);
    if (!match) return xml(404, 'NoSuchKey', 'Object key is not available');
    if (!['PUT', 'GET', 'HEAD'].includes(request.method)) return xml(405, 'MethodNotAllowed', 'Method is not supported');
    if (!verifySigV4(request, { accessKeyId, secretAccessKey }, now)) return xml(403, 'SignatureDoesNotMatch', 'Request authentication failed');
    const key = match[1];

    if (request.method === 'PUT') {
      if (request.body.length > maximumUploadBytes) return xml(413, 'EntityTooLarge', 'Upload exceeds local bridge limit');
      let upload;
      try {
        upload = decodedUpload(request);
      } catch {
        return xml(400, 'InvalidRequest', 'Invalid streaming payload');
      }
      if (upload.body.length > maximumUploadBytes) return xml(413, 'EntityTooLarge', 'Upload exceeds local bridge limit');
      if (!verifyChecksum(request, upload)) return xml(400, 'BadDigest', 'Payload checksum did not match');
      const contentType = header(request.headers, 'content-type') || 'application/octet-stream';
      const cacheControl = header(request.headers, 'cache-control') || undefined;
      if (contentType !== 'application/octet-stream') return xml(400, 'InvalidRequest', 'Archive content type is not supported');
      if (cacheControl && cacheControl !== 'public,max-age=31536000,immutable') return xml(400, 'InvalidRequest', 'Archive cache policy is not supported');
      const result = await bucket.put(key, upload.body, { httpMetadata: { contentType, ...(cacheControl ? { cacheControl } : {}) } });
      const headers = { 'content-length': '0', 'cache-control': 'no-store' };
      const storedEtag = etag(result);
      if (storedEtag) headers.etag = storedEtag;
      return { status: 200, headers, body: Buffer.alloc(0) };
    }

    const existing = await bucket.head(key);
    if (!existing) return xml(404, 'NoSuchKey', 'Object key is not available');
    let range;
    try {
      range = requestedRange(header(request.headers, 'range'), existing.size);
    } catch {
      return { ...xml(416, 'InvalidRange', 'Requested range is not satisfiable'), headers: { 'content-range': `bytes */${existing.size}`, 'cache-control': 'no-store' } };
    }
    if (request.method === 'HEAD') {
      if (range) return xml(400, 'InvalidRequest', 'Range is not supported for HEAD');
      return { status: 200, headers: objectHeaders(existing, existing.size), body: Buffer.alloc(0) };
    }
    if (!range && existing.size > maximumUploadBytes) return xml(413, 'EntityTooLarge', 'Object exceeds local bridge read limit');
    const object = await bucket.get(key, range ? { range: { offset: range.offset, length: range.length } } : undefined);
    if (!object) return xml(404, 'NoSuchKey', 'Object key is not available');
    const body = await objectBytes(object);
    return { status: range ? 206 : 200, headers: objectHeaders(object, body.length, range), body };
  };
}

function readBoundedBody(request, maximumUploadBytes) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    request.on('data', (chunk) => {
      size += chunk.length;
      if (size > maximumUploadBytes) {
        reject(Object.assign(new Error('upload too large'), { code: 'ENTITY_TOO_LARGE' }));
        request.destroy();
      } else chunks.push(chunk);
    });
    request.on('end', () => resolve(Buffer.concat(chunks)));
    request.on('error', reject);
  });
}

export function createLocalArchiveBridge(options) {
  const port = options.port ?? defaultPort;
  const maximumUploadBytes = options.maximumUploadBytes ?? defaultMaximumUploadBytes;
  const handler = createLocalArchiveHandler({ ...options, port, maximumUploadBytes });
  const server = createServer(async (incoming, response) => {
    try {
      const contentLength = Number(incoming.headers['content-length'] ?? 0);
      if (Number.isFinite(contentLength) && contentLength > maximumUploadBytes) {
        const result = xml(413, 'EntityTooLarge', 'Upload exceeds local bridge limit');
        response.writeHead(result.status, result.headers).end(result.body);
        incoming.resume();
        return;
      }
      const url = new URL(incoming.url ?? '/', `http://${incoming.headers.host ?? `${listenHost}:${port}`}`);
      const result = await handler({
        method: incoming.method ?? 'GET', pathname: url.pathname, search: url.search,
        headers: incoming.headers, body: await readBoundedBody(incoming, maximumUploadBytes),
        remoteAddress: incoming.socket.remoteAddress,
      });
      response.writeHead(result.status, result.headers).end(incoming.method === 'HEAD' ? undefined : result.body);
    } catch (error) {
      if (!response.headersSent) {
        const result = error?.code === 'ENTITY_TOO_LARGE'
          ? xml(413, 'EntityTooLarge', 'Upload exceeds local bridge limit')
          : xml(500, 'InternalError', 'Local archive bridge failed');
        response.writeHead(result.status, result.headers).end(result.body);
      }
    }
  });
  return {
    server,
    listen: () => new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(port, listenHost, () => {
        server.off('error', reject);
        resolve({ host: listenHost, port, origin: `http://${listenHost}:${port}`, bucket: expectedBucket });
      });
    }),
    close: () => new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve())),
  };
}

export const localArchiveBridgeDefaults = {
  host: listenHost,
  port: defaultPort,
  bucket: expectedBucket,
  maximumUploadBytes: defaultMaximumUploadBytes,
};
