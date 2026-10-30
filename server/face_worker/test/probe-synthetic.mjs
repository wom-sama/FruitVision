import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import sharp from 'sharp';

const { values } = parseArgs({ options: { fixture: { type: 'string' } } });
if (!values.fixture) throw new Error('Pass an explicitly authorized synthetic --fixture image. No camera/person input is assumed.');
sharp.concurrency(1); sharp.cache(false);
const source = readFileSync(values.fixture);
const report = { scope: 'Authorized synthetic fixture only; execution smoke, not person identity accuracy, liveness or camera acceptance.',
  node: process.version, fixtureSha256: createHash('sha256').update(source).digest('hex'), fixtureBytes: source.length, checks: [] };
const worker = fileURLToPath(new URL('../worker.js', import.meta.url));
const ownModels = fileURLToPath(new URL('../models/', import.meta.url));
report.modelsFromProject = true;
function run(bytes, expected, name) {
  const start = performance.now();
  const child = spawnSync(process.execPath, ['--max-old-space-size=128', worker], { input: JSON.stringify({ imageBase64: bytes.toString('base64') }),
    encoding: 'utf8', timeout: 25000, maxBuffer: 16384, env: { ...process.env, UV_THREADPOOL_SIZE: '1', FACE_MODELS_DIR: ownModels } });
  let result;
  try { result = JSON.parse(child.stdout); } catch { result = {}; }
  const embedding = result.embedding;
  const actual = Array.isArray(embedding) ? 'embedding' : result.error;
  const passed = actual === expected && child.stderr.length === 0 && (expected !== 'embedding' ||
    child.status === 0 && embedding.length === 128 && embedding.every(Number.isFinite) && Math.abs(Math.hypot(...embedding) - 1) < 1e-5);
  report.checks.push({ name, passed, expected, actual, exitCode: child.status, stderrBytes: Buffer.byteLength(child.stderr),
    embeddingDimensions: Array.isArray(embedding) ? embedding.length : null,
    embeddingNorm: Array.isArray(embedding) ? Math.hypot(...embedding) : null, milliseconds: Math.round(performance.now() - start) });
  if (!passed) throw new Error('Synthetic check failed: ' + name);
}
let failure;
try {
  run(source, 'embedding', 'one synthetic face returns a finite 128D normalized embedding');
  const blank = await sharp({ create: { width: 320, height: 320, channels: 3, background: '#808080' } }).png().toBuffer();
  run(blank, 'FACE_NOT_FOUND', 'decoded neutral image rejects no-face');
  const tile = await sharp(source).resize(320, 320, { fit: 'contain' }).jpeg().toBuffer();
  const pair = await sharp({ create: { width: 640, height: 320, channels: 3, background: '#808080' } })
    .composite([{ input: tile, left: 0, top: 0 }, { input: tile, left: 320, top: 0 }]).jpeg().toBuffer();
  run(pair, 'FACE_MULTIPLE_FACES', 'two copies of the synthetic face reject multiple faces');
  const wide = await sharp({ create: { width: 4097, height: 80, channels: 3, background: '#808080' } }).png().toBuffer();
  run(wide, 'FACE_IMAGE_INVALID', 'decoded dimensions beyond source limit reject before inference');
  report.status = 'PASS';
} catch (error) { report.status = 'FAIL'; report.errorType = error.name; failure = error; }
const directory = fileURLToPath(new URL('../.test-results/', import.meta.url));
mkdirSync(directory, { recursive: true });
writeFileSync(directory + 'synthetic-smoke.json', JSON.stringify(report, null, 2));
console.log(JSON.stringify(report, null, 2));
if (failure) process.exitCode = 1;
