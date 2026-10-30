import { extractEmbedding, FaceRecognitionError, MAX_FACE_IMAGE_BYTES } from './recognizer.js';

process.env.VIPS_CONCURRENCY = '1';
const maximumWireBytes = Math.ceil(MAX_FACE_IMAGE_BYTES / 3) * 4 + 256;
const messages = Object.freeze({
  FACE_REQUEST_INVALID: [400, 'Yêu cầu ảnh khuôn mặt không hợp lệ.'],
  FACE_IMAGE_INVALID: [422, 'Ảnh khuôn mặt không hợp lệ.'],
  FACE_NOT_FOUND: [422, 'Chưa tìm thấy khuôn mặt trong ảnh.'],
  FACE_MULTIPLE_FACES: [422, 'Chỉ một khuôn mặt được phép xuất hiện.'],
  FACE_IMAGE_QUALITY: [422, 'Ảnh khuôn mặt chưa đủ rõ.'],
  FACE_TEMPLATE_INVALID: [422, 'Kết quả khuôn mặt không hợp lệ.'],
  FACE_SERVICE_BUSY: [429, 'Bộ xử lý khuôn mặt đang bận.'],
  FACE_SERVICE_UNAVAILABLE: [503, 'Bộ xử lý khuôn mặt chưa sẵn sàng.'],
});
let finished = false;
function finish(body, code) {
  if (finished) return;
  finished = true;
  process.stdin.pause();
  process.stdout.write(JSON.stringify(body) + '\n', () => process.exit(code));
}
function fail(code = 'FACE_SERVICE_UNAVAILABLE') {
  const [status, message] = messages[code] ?? messages.FACE_SERVICE_UNAVAILABLE;
  finish({ error: messages[code] ? code : 'FACE_SERVICE_UNAVAILABLE', status, message }, 1);
}
// No stack traces, raw image, native exception text or template diagnostics enter stdout/stderr.
process.on('uncaughtException', () => fail());
process.on('unhandledRejection', () => fail());
setTimeout(() => fail(), 20000).unref();
const chunks = [];
let bytes = 0;
process.stdin.on('data', chunk => {
  bytes += chunk.length;
  if (bytes > maximumWireBytes) {
    chunks.length = 0;
    fail('FACE_IMAGE_INVALID');
  } else chunks.push(chunk);
});
process.stdin.on('error', () => fail('FACE_REQUEST_INVALID'));
process.stdin.on('end', async () => {
  if (finished) return;
  let request;
  try {
    request = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    chunks.length = 0;
    if (!request || Array.isArray(request) || Object.keys(request).length !== 1 ||
        typeof request.imageBase64 !== 'string') return fail('FACE_REQUEST_INVALID');
  } catch { return fail('FACE_REQUEST_INVALID'); }
  try {
    const embedding = await extractEmbedding(request.imageBase64);
    request.imageBase64 = '';
    if (embedding.length !== 128 || !embedding.every(Number.isFinite) || Math.abs(Math.hypot(...embedding) - 1) > 1e-5)
      return fail('FACE_TEMPLATE_INVALID');
    finish({ embedding }, 0);
  } catch (error) {
    request.imageBase64 = '';
    fail(error instanceof FaceRecognitionError ? error.code : 'FACE_SERVICE_UNAVAILABLE');
  }
});
