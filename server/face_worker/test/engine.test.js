import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { normalizeEmbedding, compareEmbeddings, similarityTransform, CANONICAL_LANDMARKS } from '../geometry.js';
import { extractEmbedding } from '../recognizer.js';

const worker = fileURLToPath(new URL('../worker.js', import.meta.url));
function request(value) {
  const result = spawnSync(process.execPath, ['--max-old-space-size=128', worker], {
    input: value, encoding: 'utf8', timeout: 25000, maxBuffer: 16384,
    env: { ...process.env, UV_THREADPOOL_SIZE: '1' },
  });
  assert.equal(result.stderr, '');
  assert.equal(result.stdout.trim().split('\n').length, 1);
  return { code: result.status, body: JSON.parse(result.stdout) };
}
test('128D finite nonzero embedding is unit normalized; invalid templates are rejected', () => {
  const embedding = normalizeEmbedding(new Float32Array(128).fill(2));
  assert.equal(embedding.length, 128);
  assert.ok(Math.abs(Math.hypot(...embedding) - 1) < 1e-12);
  assert.equal(compareEmbeddings(embedding, embedding).matches, true);
  for (const bad of [new Float32Array(127), new Float32Array(128), Array(128).fill(NaN)])
    assert.throws(() => normalizeEmbedding(bad), { code: 'FACE_TEMPLATE_INVALID' });
});
test('canonical SFace landmarks produce identity alignment', () => {
  const transform = similarityTransform(CANONICAL_LANDMARKS);
  assert.ok(Math.abs(transform[0] - 1) < 1e-12);
  assert.ok(transform.slice(1).every(value => Math.abs(value) < 1e-12));
});
test('malformed base64 fails before decoder/runtime and releases sequential slot', async () => {
  for (const input of ['bad', 'a'.repeat(3000000), 'data:text/plain;base64,AAAA'])
    await assert.rejects(extractEmbedding(input), { code: 'FACE_IMAGE_INVALID' });
});
test('single-request worker rejects malformed/unknown fields without stderr or extra protocol lines', () => {
  for (const input of ['', '{bad', '{"imageBase64":"bad","path":"outside"}', '{}']) {
    const result = request(input);
    assert.equal(result.code, 1);
    assert.equal(result.body.error, 'FACE_REQUEST_INVALID');
  }
});
test('single-request worker bounds wire bytes and exposes only generic error enums', () => {
  const large = request(JSON.stringify({ imageBase64: 'A'.repeat(3000000) }));
  assert.equal(large.code, 1);
  assert.equal(large.body.error, 'FACE_IMAGE_INVALID');
  const malformed = request('{"imageBase64":"bad"}');
  assert.equal(malformed.body.error, 'FACE_IMAGE_INVALID');
  assert.equal(malformed.body.embedding, undefined);
  assert.equal(malformed.body.status, 422);
});
