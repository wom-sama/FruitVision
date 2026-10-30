# FruitVision face embedding worker

One process reads one JSON object from stdin, then EOF; it writes one JSON line and exits. It opens no port and stores no image, embedding, person record or key. .NET owns authentication, encrypted templates, consent, admission and any mail/TOTP challenge.

Input is exactly `{ "imageBase64": "..." }`. JPEG/PNG must actually decode, be canonical base64 (a matching image data-URI is also accepted), at most 2 MiB/16 million pixels, 80–4096 pixels per axis, one image/page and exactly one detected face of sufficient size/landmark quality. Input wire is bounded to base64 plus 256 bytes; process lifetime is 20 seconds. Success is `{ "embedding": [128 finite unit-normalized numbers] }`, exit 0. Error is `{ "error": "FACE_*", "status": 400|422|429|503, "message": "safe generic message" }`, exit 1. Stdout must never become an application log; embeddings are sensitive biometric data.

The user-authorized source reuse is four modules from the existing Nguyen Hoai Nam engine, identified by [source-provenance.json](source-provenance.json). No peer users, enrolled templates, keys or account services were read/copied. Geometry is unchanged; Sharp is limited to one CPU thread/cache off. ORT runs CPU sequential, intra/inter-op 1. Source inference admission remains one active plus two waiting; the one-request process is additionally bounded by the .NET global queue. There is no GPU/CUDA provider or training.

| Model | Bytes | SHA-256 | License |
|---|---:|---|---|
| `face_detection_yunet_2026may.onnx` | 229738 | `ebafce4e3c118d6554634be5c27ab333b4c047a9a8c3faf1d7cf93101c22f0f0` | [MIT, exact notice](licenses/YuNet-LICENSE.txt) |
| `face_recognition_sface_2021dec.onnx` | 38696353 | `0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79` | [Apache-2.0, exact notice](licenses/SFace-LICENSE.txt) |

Pins are from OpenCV Zoo commit `48b10fa505aeb51fbd127fc60a5c660040e823b7`. Detector preprocessing is inside-320 RGB decode converted to padded BGR NCHW; quality/NMS thresholds retain the source contract. Five-point orientation-preserving alignment feeds RGB 0–255 `[1,3,112,112]` into SFace. Output dimension is 128. Source cosine reference threshold is 0.363; it is not a liveness claim or independent product operating-point evaluation.

## Own runtime and verification

Use Node >=22 (verified 24.14.0). From this folder:

```powershell
npm ci --ignore-scripts --omit=dev --no-audit --no-fund
node fetch-models.mjs
npm test
$env:UV_THREADPOOL_SIZE='1'
node test/probe-synthetic.mjs --fixture '<authorized-synthetic-image.jpg>'
```

The minimal lock retains exactly two direct packages, `onnxruntime-node@1.31.1` and `sharp@0.35.5`, plus their peer-lock-resolved transitive/platform dependencies. `--ignore-scripts` prevents optional ORT CUDA downloads and install hooks; bundled CPU/native packages were actually import/inference tested on Windows x64. Models are verified before every process's first inference. Model weights, node_modules and cache/results are ignored by Git; fetch downloads only the two pinned files and refuses an unexpected existing model. Keep the license notices with distribution.

Development verification installed an independent C-drive runtime and copied only hash-verified pinned models; no E-drive runtime is required. Five unit/protocol tests passed. The authorized synthetic fixture SHA `4dd6546c49d28bba16d56872684987d2de39ea34f89a8a5b292a8c9cf7265433` produced a real 128D vector with norm 1; neutral image, two synthetic faces and excessive dimensions were rejected by the actual worker. Receipt is in ignored `.test-results/synthetic-smoke.json`; no embedding/image is persisted there. These tests establish execution and validation, not camera acceptance, identity accuracy, anti-spoofing, liveness or standalone biometric authentication safety.

## Hợp đồng xác thực FruitVision trên .NET

Module [FaceAuthEndpoints](../src/FruitVision.Api/Auth/FaceAuthEndpoints.cs) sử dụng [FaceEngine](../src/FruitVision.Api/Auth/FaceEngine.cs), không dùng tài khoản, template hay key của hệ thống nguồn. Config riêng chỉ có `Face:NodePath` và `Face:WorkerPath` là đường dẫn tuyệt đối trên PC vận hành. `AddFaceAuth(configuration)`, `MapFaceAuth()` và `FaceIdentity.ConfigureModel(builder)` được backend đăng ký tập trung. Khóa ASP.NET Data Protection riêng của FruitVision nằm trong thư mục private do operator cấu hình; không đưa key/config lên Git.

| Endpoint `/api/v1` | Yêu cầu và kết quả |
|---|---|
| `GET /auth/face/status` | Phiên của chính mình; `{enrolled,ready,livenessVerified:false}`. Ready yêu cầu tài nguyên engine và email OTP sẵn sàng, không phải bằng chứng liveness |
| `POST /auth/face/enroll` | `{imageBase64}`; đăng ký mới `201`, thay mẫu `200`; trả trạng thái/thời gian, không trả embedding |
| `DELETE /auth/face` | Thu hồi mẫu của chính mình, `204`; không nhận userId của người khác |
| `POST /auth/face/login` | Anonymous `{email,imageBase64}`; nếu khớp và đủ điều kiện thì trả **challenge email OTP**, chưa có access/refresh token |
| `POST /auth/otp/verify` | `{challengeToken,code}` từ bước trên; chỉ mã hợp lệ, chưa dùng và chưa hết hạn mới tạo phiên `face_email_otp` |

API nhận **base64 thuần/canonical** JPEG hoặc PNG, tối đa 2 MiB giải mã và 2.796.204 ký tự base64; không nhận path, URL hoặc embedding do client tự khai. Chỉ hai POST enroll/login được cấp body cap 3 MiB; body JSON thường không bị nâng giới hạn. Worker tiếp tục kiểm decode/pixel/one-face/quality. Ảnh chỉ đi qua bộ nhớ và pipe tới tiến trình con, không lưu ảnh gốc hoặc avatar.

Đăng ký, thay mẫu và thu hồi đều yêu cầu tài khoản hoạt động, email đã xác minh và phiên tạo **trong 15 phút gần nhất** bằng `password_email_otp` hoặc `password_totp`. Refresh một phiên cũ không biến nó thành xác minh mới. Phiên `face_email_otp` không đủ để tự thay/thu hồi mẫu; cần đăng nhập lại bằng mật khẩu và mã. Quyền được đọc lại từ DB trước và sau inference; không tin cờ `biometricPassed` từ client.

Template chuẩn hóa 128D được mã hóa bằng `IDataProtection` với chuỗi purpose `FruitVision.Face.v1` rồi user ID; DB chỉ lưu ciphertext, model SHA và thời gian. Một mẫu mã hóa của người A không giải mã được dưới purpose của người B. Enroll/revoke khóa User trong transaction và tiêu thụ các email challenge `face_login` đang chờ.

Đăng nhập chỉ so cosine với ngưỡng tham chiếu SFace **0,363**, không trả score/vector ra client. Khớp mặt **không tạo phiên một mình**: `EmailOtpService.StartAsync(...,"face_login",expectedFaceTemplate:...)` khóa/đọc lại User và kiểm đúng snapshot mẫu còn tồn tại trước khi gửi mã. Thay/thu hồi mẫu làm mất hiệu lực challenge đang chờ; xác minh email vẫn kiểm chống dùng lại, hết hạn, thay security stamp và trạng thái tài khoản.

Tài khoản đã bật TOTP hiện **không dùng face alternative để bỏ qua TOTP**; Face login trả lỗi xác thực chung, tiếp tục dùng mật khẩu + TOTP. Đây là hạn chế hiện tại, không phải fallback tự cấp phiên. Enrollment không cấp thêm vai trò hoặc quyền nghiệp vụ.

Lỗi đăng nhập không khớp/không đủ điều kiện trả `401` chung, thiếu xác minh mới khi quản lý mẫu trả `403`, ảnh/quality lỗi `422`, hàng đợi đầy `429`, engine chưa sẵn sàng `503`. Engine .NET dùng một tiến trình active, tối đa hai request chờ, timeout **20 giây/tiến trình**, JS heap 128 MiB và CPU inference 1 thread. Native ORT/Sharp có bộ nhớ ngoài JS heap; con số 128 MiB không phải cam kết tổng RAM. Body/ảnh/embedding/secret không được ghi log.

Đây là nhận dạng **ảnh camera 2D**, không phải Apple Face ID, liveness hoặc chống ảnh chụp/màn hình giả mạo đã được chứng nhận. UI chỉ chụp/gửi khi người dùng chủ động chọn tính năng. Cần thông báo rõ việc xử lý dữ liệu khuôn mặt và quyền thu hồi; không tự lấy ảnh nền.

**Bằng chứng tại thời điểm ghi chú:** 5 kiểm API thực với PostgreSQL đã PASS bằng fake engine/fake mail cho các điều kiện bảo mật; full backend 128 kiểm đã PASS ở lượt tích hợp. 5 kiểm unit/protocol và 4 lượt worker thật trên fixture tổng hợp đã PASS riêng. API security tests không chứng minh nhận dạng ảnh người thật. Lượt live HTTP → worker với môi trường đã lọc → email thật, camera Android và toàn bộ trải nghiệm người dùng còn **PENDING** cho tới biên nhận riêng; không gọi phần mới viết là đã nghiệm thu trực tiếp.
