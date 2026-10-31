# FruitVision Android 2.6.2 — xoài, kiến thức và cộng đồng

Các tệp ghi “không công bố” chỉ có trong bộ làm việc/bàn giao nội bộ; bản clone này không kèm các tệp đó.

Bản hiện tại **2.6.2+6014** là Flutter client gọi **một API FruitVision qua HTTPS**, dùng SignalR WSS cùng origin. PostgreSQL, xử lý ảnh và ONNX Runtime CPU chạy trên PC. **APK không chứa trọng số hoặc runtime AI**; libsodium native phục vụ mã hóa. Ứng dụng offline cũ ở `../app/` là luồng riêng. Bản 6014 sửa kết nối sau reboot; chưa có lượt chạy giao diện Android 6014 trong lần này.

## Cài và kết nối

Android tối thiểu **API 26**. Chọn APK đúng ABI trong bộ đã kiểm; đường dẫn build tính từ `mobile_client/`:

| ABI | APK |
|---|---|
| ARM 64 bit | `build/app/outputs/apk/release/app-arm64-v8a-release.apk` |
| ARM 32 bit | `build/app/outputs/apk/release/app-armeabi-v7a-release.apk` |
| x86 64 bit | `build/app/outputs/apk/release/app-x86_64-release.apk` |

Package giữ `vn.mangodemo.mango_offline` để nâng cấp. Release đồ án dùng course/debug signer, chưa phải cấu hình ký Play Store. **Clone không chứa keystore riêng hoặc mật khẩu ký của người phát triển.** Build bằng khóa khác không cập nhật đè được bản đã cài; người triển khai cần quản lý signer và fingerprint riêng.

API mặc định của 6014 là `https://vip-certainly-broke-lease.trycloudflare.com`. Khi đọc đúng origin cũ `https://tips-differential-relating-validity.trycloudflare.com`, bản này chuyển sang origin được biên dịch trong APK, **bỏ token và OTP challenge trước mọi HTTP request**, lưu origin mới và yêu cầu đăng nhập lại. Origin tùy chỉnh khác được giữ nguyên; phiên tại origin mới khôi phục bình thường. Keybag E2EE không bị xóa, thu hồi hoặc tự chuyển origin.

Đây là **chuyển đổi một lần cho hostname cũ đã biết**, không sửa những lần Quick Tunnel đổi hostname sau này. APK đang trỏ tới tunnel đã mất không tự tải được cập nhật từ địa chỉ đó; cần cài đè tệp/link APK mới bằng cùng signer. Chỉ Admin còn đăng nhập mở được **Tài khoản → Cài đặt máy chủ → URL HTTPS → Lưu máy chủ**, rồi đăng nhập lại. **Không có cài đặt URL trước đăng nhập; người dùng thường không thấy mục máy chủ.**

PC, API, DB, worker và tunnel phải tiếp tục chạy. `localhost` trên điện thoại không trỏ về PC. Clone cần backend/HTTPS riêng và biên dịch URL của mình theo hướng dẫn dưới; triển khai lâu dài cần hostname ổn định. Flutter không gọi trực tiếp nhà cung cấp email/địa lý hoặc truy cập DB. Xem [khởi động lại 2.6.2](../server/docs/RESTART_2_6_2.md).

Updater kiểm bản mới, tải theo ABI, xác minh size/SHA/package/version/chữ ký rồi mở trình cài Android; người dùng vẫn phải cho phép và xác nhận cài. Không cài im lặng. Xem [quy trình phát hành](../server/docs/MOBILE_RELEASES.md).

## Tài khoản và bốn vai trò

Đăng ký mới **cố định Consumer**, chọn quốc gia/tỉnh từ API và hoàn thành **mật khẩu + mã email**; phản hồi yêu cầu OTP chưa phải phiên đăng nhập. Tiêu đề thư hiện tại là **“Mã xác thực FruitVision”**; giao diện luôn hiển thị tiêu đề do API trả về. Tài khoản cũ đã bật TOTP tiếp tục dùng mã đã đăng ký; người mới không cần cài Authenticator.

Tài khoản/mật khẩu demo riêng nằm ở `../server/.local/demo-accounts.json` trên PC được cấp quyền; không có trong clone hoặc APK và không công bố nội dung tệp.

| Vai trò | Tab và luồng chính |
|---|---|
| Consumer | **Học về xoài → Cộng đồng → Tin nhắn → Tài khoản**. Bài học/checklist/quiz, bài Community có ảnh để kiểm duyệt, chat/nhóm; không AI hoặc E2EE Seller |
| Producer | **AI xoài → Kiến thức → Tin nhắn → Tài khoản**. AI riêng, bài Professional có ảnh và cơ sở sản xuất đã duyệt; E2EE với Seller đủ điều kiện |
| Trader | Cùng nhóm chức năng Seller như Producer; tài khoản vẫn có một vai trò hiện hành |
| Admin | **Xét duyệt → Tin nhắn → Tài khoản**. Duyệt hồ sơ nâng vai trò, cơ sở, bài Community/Professional; bổ nhiệm Admin có xác nhận mật khẩu; không AI và không tự đọc mọi Direct |

Consumer đã xác minh email, đang hoạt động/Approved có thể xin nâng Producer hoặc Trader bằng hồ sơ và minh chứng riêng. Producer khai diện tích; Trader khai mã số thuế hoặc đăng ký kinh doanh. **Draft là chưa gửi**; phải gửi thành công mới thành Submitted để Admin xét duyệt. NeedsInformation/Rejected cho phép sửa/gửi lại; chỉ Approved mới đổi vai trò. Minh chứng JPEG/PNG/PDF tối đa 5 MiB/tệp, 4 tệp/hồ sơ, chỉ chủ/Admin có quyền đọc; ảnh zoom trong app, PDF cần ứng dụng xem PDF. Địa điểm mới dùng mã quốc gia/tỉnh từ API; dữ liệu vai trò đã duyệt không sửa qua hồ sơ cá nhân.

Tin nhắn có danh bạ, ngữ cảnh bài viết/tin riêng và số chưa đọc từ server. Hồ sơ cá nhân có cờ riêng tư và chặn/bỏ chặn; chặn ngăn liên hệ riêng mới, không xóa lịch sử đã nhận hoặc ngăn chat nhóm chung. Chỉ Admin tạo/đóng nhóm; thành viên Approved tham gia/chat và đọc lịch sử nhóm đã đóng.

Sinh trắc học mạnh Android và đối chiếu ảnh mặt là lựa chọn có điều kiện readiness/thiết bị. Ảnh mặt 2D vẫn cần email OTP, chưa có liveness; không gọi là Face ID hoặc chứng minh người thật. Đăng ký khóa/ảnh bảo mật yêu cầu phiên mật khẩu + OTP/TOTP mới trong 15 phút; phiên face/biometric không tự có quyền đăng ký khóa mới.

Tin Supply/Demand, Market và giá chào cũ được giữ cho tương thích, **không phải luồng chính hay hệ thống mua bán hoàn chỉnh**. Không có đặt hàng, tồn kho xác thực, thanh toán, giao nhận, IoT hoặc dự báo giá. Xem [vai trò/công nghệ 2.6.1](../server/docs/VAI_TRO_THAO_TAC_CONG_NGHE_2_6_1.md), [luồng API nền](../server/docs/USER_WORKFLOWS_2_4.md).

## AI xoài trên PC

Chỉ Producer/Trader hoạt động/Approved dùng AI. Có ảnh, MP4, ảnh chụp và camera trong app gửi tuần tự JPEG qua HTTPS tới PC; không inference trên điện thoại, dừng khi vào nền và không tự tiếp tục. Camera không tự tạo lịch sử từng khung; FPS phụ thuộc thiết bị/mạng/server, không cam kết tốc độ. Consumer học nội dung chỉ đọc, Admin không được cấp quyền AI.

- Ảnh JPEG/PNG: tối đa **12 MiB, 24 triệu pixel**.
- Video MP4: tối đa **80 MiB, 120 giây, 3600 khung**, cạnh dài 1920/cạnh ngắn 1080; stream tệp lên API, không đọc cả video vào RAM.
- Một worker tuần tự, tối đa một tác vụ đang chờ/chạy/người và bốn toàn hệ thống; có tiến độ, hủy, lịch sử riêng và timeout. Không tự POST lại khi kết quả upload chưa rõ.

Serving lọc đối tượng **được dự đoán là xoài** trước đếm/theo dõi, giữ nguyên graph/trọng số SHA `8a69c66a9444c18c98a7e3e58a44f4dddda9eb4583dd4448f430ff9e8db27c41`. Hai giai đoạn nguồn là **Xanh / chưa chín**, **Chín**; thiếu tin cậy là **Chưa xác định**, không đổi thành xoài hư. Kết quả không chứng nhận độ chín thực địa, vị ngọt, hư hỏng hoặc an toàn thực phẩm; model/dữ liệu chỉ dành cho demo phi thương mại.

Preview chú thích hiển thị trước thông tin kỹ thuật. **maxVisibleCount**, **confirmedTrackCount**, **lineCrossingCount** lần lượt là tối đa thấy đồng thời, track xác nhận và lượt qua vạch; ảnh đơn có track bằng 0. Không cộng thành số quả vật lý duy nhất, kg, sản lượng hoặc tồn kho. Kết quả cũ thiếu `scope=predicted-mango-only` có cảnh báo và giữ nguyên nhãn/số đã lưu. Xem [phạm vi xoài](../server/docs/mango-ai-scope-24.md), [worker và giấy phép model](../server/ai/README.md).

**Lỗi chất lượng chưa sửa:** trên APK 6013, video 231 khung hoàn tất nhưng cảnh băng chuyền trông như táo bị nhận nhầm một xoài/Chín, một track, không lượt qua vạch. Đây là **QUALITY FAIL dù luồng kỹ thuật hoàn tất**; 6014 chỉ sửa kết nối. Không dùng clip này làm mẫu xoài dương tính hoặc tuyên bố độ chính xác; không có ground truth độc lập để tính chỉ số.

## Chat thường, ảnh và mã hóa đầu cuối

Liên hệ từ bài công bố tạo hoặc dùng lại Direct đúng hai người. Chat thường/nhóm có ảnh tối đa 5 MiB: **máy chủ đọc và chuẩn hóa ảnh thường**, chỉ thành viên phù hợp được tải ảnh chat. Bài Community/Professional và ảnh phải được duyệt; bài Professional cần chi nhánh thuộc tác giả đã Approved. Nhóm đóng chỉ cho thành viên hiện tại đọc lịch sử; rời nhóm mất quyền đọc/gửi.

Trong Direct đủ điều kiện, chọn **Trò chuyện riêng · Mã hóa đầu cuối**; lịch sử thường không tự được mã hóa lại. Client dùng libsodium X25519 sealed box + Ed25519, niêm phong riêng cho người nhận và chính người gửi; ảnh dùng secretbox, khóa ảnh trong gói đã ký/mã hóa. Keybag được AES-GCM bảo vệ bằng Android Keystore; private key không gửi lên API. Server giữ ciphertext và metadata hai bên/thời gian/dung lượng, không có khóa để giải mã nội dung.

Mỗi tài khoản chỉ có **một thiết bị secret hoạt động**. Trước gửi lần đầu, hai người phải so sánh **toàn bộ fingerprint 64 ký tự hex qua kênh tin cậy khác** rồi xác nhận; khóa đổi thì khóa luồng gửi để xác minh lại. Đổi thiết bị phải thu hồi rõ ràng; không có khôi phục khóa, nhiều thiết bị, Signal ratchet hoặc cam kết forward secrecy. Ảnh giải mã được kiểm hash/MAC/kích thước trước hiển thị, giữ trong bộ nhớ và đóng khi khóa phiên. Quota ảnh có thể từ chối upload; ứng dụng không tự xóa lịch sử hoặc đổi khóa để né lỗi.

Khóa E2EE ràng buộc origin; đổi tunnel không mặc định khôi phục lịch sử mã hóa. Foreground WSS báo tin mới, moderation và tiến độ AI; client lấy REST có quyền, dedup và tải lại sau reconnect. Chat có ảnh inline/zoom, mở ở tin mới nhất và giữ vị trí khi đọc cũ; read cursor chỉ xác nhận tin thực đã hiển thị. Pause/đăng xuất/đổi server dừng kết nối; **không có Android background push**.

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
$apiOrigin = 'https://api.example.com' # HTTPS gốc của bạn, không thêm /api/v1

@(
  "sdk.dir=$($env:ANDROID_SDK_ROOT.Replace('\','/'))"
  "flutter.sdk=$($env:FLUTTER_ROOT.Replace('\','/'))"
  'flutter.buildMode=release'
  'flutter.versionName=2.6.2'
  'flutter.versionCode=6014'
) | Set-Content -LiteralPath android/local.properties -Encoding utf8NoBOM

& "$env:FLUTTER_ROOT\bin\flutter.bat" pub get
& "$env:FLUTTER_ROOT\bin\flutter.bat" analyze --no-pub
& "$env:FLUTTER_ROOT\bin\flutter.bat" test --no-pub

# Cách Flutter chuẩn: APK universal với URL của bạn.
& "$env:FLUTTER_ROOT\bin\flutter.bat" build apk --release `
  "--dart-define=FRUITVISION_API_URL=$apiOrigin" `
  --build-name=2.6.2 --build-number=6014
```

Hoặc build ba APK riêng cùng versionCode 6014. Flutter Gradle nhận từng `dart-defines` dạng Base64, không đặt URL thô vào property này:

```powershell
$apiDefine = [Convert]::ToBase64String(
  [Text.Encoding]::UTF8.GetBytes("FRUITVISION_API_URL=$apiOrigin"))
Push-Location android
try {
  & .\gradlew.bat :app:assembleRelease `
    '-Ptarget=lib/main.dart' `
    '-Ptarget-platform=android-arm,android-arm64,android-x64' `
    '-Psplit-per-abi=true' `
    '-Pforce-version-code-ignoring-abi=true' `
    "-Pdart-defines=$apiDefine" `
    --max-workers=1 --no-daemon --console=plain --no-scan
} finally { Pop-Location }
```

Dùng wrapper **`android/gradlew.bat` trong repo**; không dùng wrapper `.local` hoặc ổ riêng của máy phát triển. `force-version-code-ignoring-abi` giữ ba APK cùng versionCode 6014. Kiểm package/version/ABI/SHA/chữ ký trước phát hành: `tool/verify_apks.py --version-name 2.6.2 --version-code 6014 --expected-signer-sha256 <64-hex-của-bạn>`. Không dùng mặc định signer của người phát triển cho deployment clone. Tool hiện tìm SDK tại `%LOCALAPPDATA%\Android\Sdk\build-tools\36.0.0`; SDK đặt nơi khác cần đổi đường dẫn kiểm tương ứng.

Gradle hiện ký release bằng debug keystore cục bộ; cấu hình signing riêng cho triển khai độc lập. `android/local.properties`, keystore/mật khẩu, `server/.local`, token và tài khoản demo không thuộc Git. Clone phải dựng backend/HTTPS riêng theo [server README](../server/README.md), không sao chép secret/DB của người phát triển.

Giấy phép sodium **4.1.2+1** (BSD-3-Clause), libsodium **1.0.22** (ISC), crypto **3.0.7** (BSD-3-Clause), AndroidX Camera **1.6.2** (Apache-2.0) đóng gói từ [assets/legal](assets/legal/NOTICE.txt); giữ nguyên license và `flutter.assets: assets/legal/` khi build lại. Model PC có phạm vi/giấy phép riêng trong tài liệu worker.

## Bằng chứng và giới hạn nghiệm thu

Các receipt trong `verification/` là bằng chứng local/bộ bàn giao; chúng không tự xuất hiện từ một bản clone Git.

- Source 6014: **174/174 Flutter tests PASS**, analyzer **0 issues**. Bốn ca origin có RED trước sửa/GREEN sau sửa: `verification/2.6.2-origin-{red,green}.log`, `2.6.2-full-flutter.log`, `2.6.2-full-analyze.log`. Không thay cho nghiệm thu thiết bị.
- Build/chữ ký/ba ABI, HTTP phát hành và tác vụ ảnh HTTPS sau reboot ghi riêng ở [RESTART_2_6_2](../server/docs/RESTART_2_6_2.md). **Chưa chạy giao diện Android 6014 trong lần reboot này.**
- APK 6012/6013 đã có bốn vai trò đăng nhập bình thường **lần lượt trên một AVD**, Admin xem ảnh minh chứng/xét duyệt, inbox/read/block, học liệu/quiz và camera foreground. Không phải bốn điện thoại đồng thời; nhóm từng cần bấm kết nối lại một lần.
- Ca QAProducer APK + Trader host Sodium thật đã xác nhận fingerprint, tin/ảnh mã hóa và phản hồi; [receipt host](../server/docs/secret-trader-qa-host-peer-26.json) không chứng minh hai điện thoại/OOB hai người. Lỗi khóa cũ Producer chính vẫn được giữ; không suy thành đã phục hồi.
- Ma trận 28 thao tác (`verification/2.6/demo-28-coverage.md`; không công bố) tách APK hiện tại, APK trước, HTTP và widget; **không tuyên bố cả 28 đạt trên APK**. [Đánh giá 2.6](../server/docs/DANH_GIA_2_6.md) là mốc lịch sử, không thay số liệu source 6014. Video nhận nhầm không-xoài vẫn là lỗi chất lượng chưa xử lý.

Lượt demo ngắn: **Consumer học về xoài → bài/ảnh cộng đồng → Seller AI ảnh xoài → xem preview và ba số đếm đúng nghĩa → Admin kiểm duyệt → liên hệ/chat ảnh**. Chỉ trình diễn secret sau khi đủ hai thiết bị/khóa và hoàn thành đối chiếu fingerprint thật; không bỏ qua bước này để làm nhanh demo.
