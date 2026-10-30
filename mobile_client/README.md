# FruitVision Android 2.4 — xoài, kiến thức và cộng đồng

Bản phát hành **2.4.0+6010** đã build, kiểm ba ABI và công bố qua updater; bộ bàn giao có tên `APK_2.4.0_6010`. Đây là Flutter client gọi **một API FruitVision qua HTTPS**, dùng SignalR WSS cùng máy chủ. PostgreSQL, xử lý ảnh và ONNX Runtime CPU chạy trên PC. **APK không chứa trọng số hoặc runtime AI**; thư viện native libsodium trong APK phục vụ mã hóa. Ứng dụng offline cũ giữ riêng ở `../app/`, không phải luồng AI hiện tại.

## Cài và kết nối

Android tối thiểu **API 26**. Chọn APK đúng ABI trong bộ đã kiểm; đường dẫn build tính từ `mobile_client/`:

| ABI | APK | Dung lượng bản 6010 |
|---|---|---|
| ARM 64 bit | `build/app/outputs/apk/release/app-arm64-v8a-release.apk` | 18,81 MiB |
| ARM 32 bit | `build/app/outputs/apk/release/app-armeabi-v7a-release.apk` | 16,56 MiB |
| x86 64 bit | `build/app/outputs/apk/release/app-x86_64-release.apk` | 20,41 MiB |

[Biên nhận APK cuối](../releases/android/2.4.0/apk-verification.json) ghi version, SHA256, chữ ký, ABI libsodium và giấy phép được đóng gói. Package vẫn là `vn.mangodemo.mango_offline` để giữ đường nâng cấp. Release đồ án dùng course/debug signer, chưa phải cấu hình ký Play Store. Bản build từ clone có thể dùng debug keystore khác; muốn cập nhật đè bộ đã phát hành phải dùng đúng chứng thư được quản lý riêng, không đưa keystore/mật khẩu vào Git.

Mở **Máy chủ** ở đăng nhập hoặc **Tài khoản → Cài đặt máy chủ**, nhập base HTTPS do người vận hành cung cấp. Đổi máy chủ kết thúc phiên hiện tại. Trên PC vận hành, URL tunnel hiện hành nằm ở tệp local `../server/PUBLIC_URL.txt`; tệp này không có trong clone. Tunnel có thể đổi, và `localhost` trên điện thoại không trỏ về PC. API, DB, worker/tunnel cần tiếp tục chạy. Flutter không gọi trực tiếp nhà cung cấp email/địa lý hoặc truy cập DB.

Updater kiểm bản mới, tải theo ABI, xác minh size/SHA/package/version/chữ ký rồi mở trình cài Android; người dùng vẫn phải cho phép và xác nhận cài. Không cài im lặng. [Receipt công bố 6010](../releases/android/2.4.0/public-release.json) xác nhận ba ABI và hash tải công khai. Xem [quy trình phát hành](../server/docs/MOBILE_RELEASES.md).

## Tài khoản và bốn vai trò

Đăng ký mới **cố định Consumer**, chọn quốc gia/tỉnh từ API và hoàn thành **mật khẩu + mã email**; phản hồi yêu cầu OTP chưa phải phiên đăng nhập. Tiêu đề thư hiện tại là **“Mã xác thực FruitVision”**; giao diện luôn hiển thị tiêu đề do API trả về. Tài khoản cũ đã bật TOTP tiếp tục dùng mã đã đăng ký; người mới không cần cài Authenticator.

Tài khoản/mật khẩu demo riêng nằm ở `../server/.local/demo-accounts.json` trên PC được cấp quyền; không có trong clone hoặc APK và không công bố nội dung tệp.

| Vai trò | Tab và luồng chính |
|---|---|
| Consumer | **Học về xoài → Cộng đồng → Tài khoản**. Đọc học liệu, viết bài Community có ảnh để kiểm duyệt, liên hệ tác giả, chat/nhóm; không AI hoặc secret |
| Producer | **AI xoài → Kiến thức → Trao đổi → Tài khoản**. AI riêng, bài Professional có ảnh và chi nhánh đã duyệt; chat/nhóm, secret với Seller đủ điều kiện |
| Trader | Cùng nhóm chức năng Seller như Producer; tài khoản vẫn có một vai trò hiện hành |
| Admin | **Xét duyệt → Trao đổi → Tài khoản**. Duyệt hồ sơ nâng vai trò, chi nhánh, bài Community/Professional; không AI hoặc secret và không tự đọc mọi Direct |

Consumer đã xác minh email, đang hoạt động/Approved có thể xin nâng Producer hoặc Trader bằng hồ sơ và minh chứng riêng. Producer khai diện tích; Trader khai mã số thuế hoặc đăng ký kinh doanh. Hồ sơ `Draft → Submitted → Approved / NeedsInformation / Rejected`; bị trả về thì sửa/gửi lại, chỉ Approved mới đổi vai trò. Minh chứng JPEG/PNG/PDF tối đa 5 MiB/tệp, 4 tệp/hồ sơ, chỉ chủ/Admin có quyền đọc. Địa điểm mới dùng mã quốc gia/tỉnh từ API; hồ sơ vùng cũ được giữ như dữ liệu lịch sử.

Sinh trắc học mạnh Android và đối chiếu ảnh mặt là lựa chọn có điều kiện readiness/thiết bị. Ảnh mặt 2D vẫn cần email OTP, chưa có liveness; không gọi là Face ID hoặc chứng minh người thật. Đăng ký khóa/ảnh bảo mật yêu cầu phiên mật khẩu + OTP/TOTP mới trong 15 phút; phiên face/biometric không tự có quyền đăng ký khóa mới.

Tin Supply/Demand, Market và giá chào cũ được giữ cho tương thích/công cụ nâng cao, **không phải luồng chính hay hệ thống mua bán hoàn chỉnh**. Không có đặt hàng, tồn kho xác thực, thanh toán, giao nhận, IoT hoặc dự báo giá. Xem [luồng và quyền API 2.4](../server/docs/USER_WORKFLOWS_2_4.md).

## AI xoài trên PC

Chỉ Producer/Trader đang hoạt động/Approved dùng AI; tab AI mở đầu không gian Seller. Consumer học từ nội dung chỉ đọc, Admin không được cấp quyền AI. Có chọn ảnh, MP4 hoặc **chụp một ảnh qua ứng dụng máy ảnh bên ngoài**; chưa có camera streaming liên tục.

- Ảnh JPEG/PNG: tối đa **12 MiB, 24 triệu pixel**.
- Video MP4: tối đa **80 MiB, 120 giây, 3600 khung**, cạnh dài 1920/cạnh ngắn 1080; stream tệp lên API, không đọc cả video vào RAM.
- Một worker tuần tự, tối đa một tác vụ đang chờ/chạy/người và bốn toàn hệ thống; có tiến độ, hủy, lịch sử riêng và timeout. Không tự POST lại khi kết quả upload chưa rõ.

Serving 2.4 lọc đối tượng **được dự đoán là xoài** trước đếm/theo dõi, giữ nguyên graph/trọng số SHA `8a69c66a9444c18c98a7e3e58a44f4dddda9eb4583dd4448f430ff9e8db27c41`. Hai giai đoạn nguồn là **Xanh / chưa chín**, **Chín**; thiếu tin cậy là **Chưa xác định**, không đổi thành xoài hư. Kết quả không chứng nhận độ chín thực địa, vị ngọt, hư hỏng hoặc an toàn thực phẩm; model/dữ liệu chỉ dành cho demo phi thương mại.

Preview chú thích hiển thị trước thông tin kỹ thuật. **maxVisibleCount**, **confirmedTrackCount**, **lineCrossingCount** lần lượt là tối đa thấy đồng thời, track xác nhận và lượt qua vạch; ảnh đơn có track bằng 0. Không cộng thành số quả vật lý duy nhất, kg, sản lượng hoặc tồn kho. Kết quả cũ thiếu `scope=predicted-mango-only` có cảnh báo và giữ nguyên nhãn/số đã lưu. Xem [phạm vi xoài](../server/docs/mango-ai-scope-24.md), [worker và giấy phép model](../server/ai/README.md).

## Chat thường, ảnh và phòng secret

Liên hệ từ bài công bố tạo hoặc dùng lại Direct đúng hai người. Chat thường/nhóm có ảnh tối đa 5 MiB: **máy chủ đọc và chuẩn hóa ảnh thường**, chỉ thành viên phù hợp được tải ảnh chat. Bài Community/Professional và ảnh phải được duyệt; bài Professional cần chi nhánh thuộc tác giả đã Approved. Nhóm đóng chỉ cho thành viên hiện tại đọc lịch sử; rời nhóm mất quyền đọc/gửi.

**Secret Direct là thao tác riêng**, chỉ đúng hai Seller đủ điều kiện; chat thường trước đó không tự trở thành secret. Client dùng libsodium X25519 sealed box + chữ ký Ed25519, niêm phong riêng cho người nhận và chính người gửi; ảnh dùng secretbox, khóa ảnh nằm trong gói tin đã ký/mã hóa. Keybag riêng được mã hóa AES-GCM bằng khóa Android Keystore; private key không gửi lên API. Máy chủ giữ ciphertext và metadata hai bên/thời gian/dung lượng; server không giải mã nội dung secret bằng các dữ liệu/khóa mà hệ thống lưu.

Mỗi tài khoản chỉ có **một thiết bị secret hoạt động**. Trước gửi lần đầu, hai người phải so sánh **toàn bộ fingerprint 64 ký tự hex qua kênh tin cậy khác** rồi xác nhận; khóa đổi thì khóa luồng gửi để xác minh lại. Đổi thiết bị phải thu hồi rõ ràng; không có khôi phục khóa, nhiều thiết bị, Signal ratchet hoặc cam kết forward secrecy. Ảnh giải mã được kiểm hash/MAC/kích thước trước hiển thị, giữ trong bộ nhớ và đóng khi khóa phiên. Quota ảnh có thể từ chối upload; ứng dụng không tự xóa lịch sử hoặc đổi khóa để né lỗi.

Foreground WSS báo tin/ảnh, phòng mới, moderation và tiến độ AI; client lấy REST có quyền, dedup và tải lại sau reconnect. Chat mở ở tin mới nhất, giữ vị trí khi đọc cũ và có nút tin mới. Pause/đăng xuất/đổi máy chủ dừng kết nối; **không có Android background push**.

## Build từ clone trên Windows

Dùng **Flutter 3.47.5 / Dart 3.13.4**, JDK 17, Android SDK/compile-target **36**, minSdk **26**, NDK **28.2.13676358**. Cài Git for Windows có **Git Bash** và GNU make của NDK. Sodium hook trên Windows cần `Git\bin` có `bash.exe` trong PATH; chỉ thêm `Git\cmd` là chưa đủ. Hook biên dịch libsodium từ nguồn đã ghim; không sửa pub cache hoặc bỏ kiểm nguồn.

Chạy các test Sodium thật trên host Windows còn cần Visual Studio/Build Tools có MSVC C++ và Developer Command Prompt mà hook tìm được; đây là phụ thuộc build/test trên PC, không phải runtime AI trong APK.

Ví dụ PowerShell 7, thay các đường dẫn SDK/JDK theo máy nhận. Từ `mobile_client/`; PATH chỉ áp dụng phiên shell hiện tại:

```powershell
$env:FLUTTER_ROOT = 'C:\SDKs\flutter_3.47.5'
$env:JAVA_HOME = 'C:\SDKs\jdk-17'
$env:ANDROID_SDK_ROOT = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
$env:ANDROID_NDK_HOME = Join-Path $env:ANDROID_SDK_ROOT 'ndk\28.2.13676358'
$gitBashBin = 'C:\Program Files\Git\bin'
$ndkMakeBin = Join-Path $env:ANDROID_NDK_HOME 'prebuilt\windows-x86_64\bin'
$env:Path = "$env:FLUTTER_ROOT\bin;$env:JAVA_HOME\bin;$gitBashBin;$ndkMakeBin;$env:Path"

@(
  "sdk.dir=$($env:ANDROID_SDK_ROOT.Replace('\','/'))"
  "flutter.sdk=$($env:FLUTTER_ROOT.Replace('\','/'))"
  'flutter.buildMode=release'
  'flutter.versionName=2.4.0'
  'flutter.versionCode=6010'
) | Set-Content -LiteralPath android/local.properties -Encoding utf8NoBOM

& "$env:FLUTTER_ROOT\bin\flutter.bat" pub get
& "$env:FLUTTER_ROOT\bin\flutter.bat" analyze --no-pub
& "$env:FLUTTER_ROOT\bin\flutter.bat" test --no-pub

Push-Location android
try {
  & .\gradlew.bat :app:assembleRelease `
    '-Ptarget=lib/main.dart' `
    '-Ptarget-platform=android-arm,android-arm64,android-x64' `
    '-Psplit-per-abi=true' `
    '-Pforce-version-code-ignoring-abi=true' `
    --max-workers=1 --no-daemon --console=plain --no-scan
} finally { Pop-Location }
```

Dùng wrapper **`android/gradlew.bat` trong repo**; không phụ thuộc wrapper, PATH, `.local` hoặc ổ riêng của máy phát triển. `force-version-code-ignoring-abi` giữ **cả ba APK cùng versionCode 6010**; kiểm lại package/version/SHA/chữ ký từng APK bằng `tool/verify_apks.py` trước phát hành. `android/local.properties`, keystore, `server/.local`, token và tài khoản demo riêng không thuộc Git. Máy clone phải cấu hình backend/HTTPS của mình theo [server README](../server/README.md); không sao chép secret/DB riêng của người phát triển.

Các giấy phép sodium **4.1.2+1** (BSD-3-Clause), libsodium **1.0.22-stable** (ISC), crypto **3.0.7** (BSD-3-Clause) được đóng gói từ [assets/legal](assets/legal/NOTICE.txt); giữ nguyên các license và mục `flutter.assets: assets/legal/` khi build lại.

## Bằng chứng và giới hạn nghiệm thu

Các receipt trong `verification/` là bằng chứng local/bộ bàn giao; chúng không tự xuất hiện từ một bản clone Git.

- Flutter full suite **110/110 PASS**, analyzer sạch; delta sự kiện phòng mới có kiểm tra tập trung riêng. Đây là kiểm thử client, không thay cho thiết bị thật.
- [Host API + Sodium thật](../releases/android/2.4.0/secret-api-acceptance.json) PASS: hai khóa độc lập, niêm phong/ký, retry, sai thiết bị, tamper và ảnh ciphertext → giải mã. Receipt ghi rõ không kiểm Keystore Android hoặc đối chiếu fingerprint ngoài băng bởi hai người.
- **AVD dùng chung** đã chạy Consumer học liệu, Producer mật khẩu + OTP FruitVision, gửi ảnh xoài qua HTTPS và xem preview; đã chạy Sodium Android keygen → Keystore keybag → đăng ký thiết bị. [Bốn native instrumentation tests](../releases/android/2.4.0/keystore-photo-instrumentation.txt) PASS. Không suy thành nghiệm thu hai điện thoại vật lý, OOB giữa hai người, camera streaming hoặc cảm biến sinh trắc học thật.
- [API 2.4 ảnh/bài/chat/quyền](../server/docs/media-https-acceptance-24.json) và [AI ảnh HTTPS](../server/docs/mango-image-https-smoke-24.json) là các phạm vi riêng. Chất lượng video/ground truth chưa được xác nhận chỉ bằng PASS kỹ thuật. Receipt cũ 2.1–2.3 được giữ làm lịch sử.

Lượt demo ngắn: **Consumer học về xoài → bài/ảnh cộng đồng → Seller AI ảnh xoài → xem preview và ba số đếm đúng nghĩa → Admin kiểm duyệt → liên hệ/chat ảnh**. Chỉ trình diễn secret sau khi đủ hai thiết bị/khóa và hoàn thành đối chiếu fingerprint thật; không bỏ qua bước này để làm nhanh demo.
