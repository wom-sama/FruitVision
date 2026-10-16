# Cài và chạy Fruit Offline trên Android

Bản bàn giao là **1.3.5+5009**, package `vn.mangodemo.mango_offline`, yêu cầu **Android 8.0 / API 26 trở lên**. Có hai cách dùng: cài APK có sẵn hoặc biên dịch từ mã nguồn. Chỉ cách thứ hai cần Android Studio/Flutter.

## Cài APK có sẵn

### 1. Chọn một tệp phù hợp

| Tệp | Dùng cho |
| --- | --- |
| [`app-arm64-v8a-release.apk`](../releases/android/1.3.5/app-arm64-v8a-release.apk) | Điện thoại ARM 64-bit; lựa chọn thường dùng |
| [`app-armeabi-v7a-release.apk`](../releases/android/1.3.5/app-armeabi-v7a-release.apk) | Thiết bị ARM 32-bit |
| [`app-x86_64-release.apk`](../releases/android/1.3.5/app-x86_64-release.apk) | Máy ảo/thiết bị x86_64 |

Chỉ cài **một** APK. Kiến trúc CPU trong quảng cáo thiết bị có thể khác ABI Android mà hệ điều hành hỗ trợ. Nếu có ADB, kết nối thiết bị đã bật USB debugging và kiểm tra:

```powershell
adb devices
adb shell getprop ro.product.cpu.abilist
```

Nếu danh sách có `arm64-v8a`, chọn ARM64. Nếu chỉ có `armeabi-v7a`, chọn ARM32. Máy ảo x86_64 chọn x86_64. Có nhiều thiết bị thì thêm `-s SERIAL` ngay sau `adb`, với `SERIAL` lấy từ `adb devices`.

### 2. Tải và cài trên điện thoại

1. Mở tệp APK tương ứng trong [thư mục bản phát hành](../releases/android/1.3.5/) trên GitHub và tải tệp gốc về máy.
2. Mở APK bằng ứng dụng quản lý tệp/trình duyệt. Nếu Android yêu cầu, cho phép ứng dụng đó **cài ứng dụng không rõ nguồn gốc**.
3. Chọn **Cài đặt**, sau đó mở **Fruit Offline**. Có thể tắt lại quyền cài từ nguồn này sau khi cài xong.
4. Cho phép camera khi cần chụp ảnh hoặc mở camera trực tiếp. Khi chọn ảnh/video, dùng trình chọn tệp của hệ thống.

APK đã chứa model; không tải model riêng và không chạy demo desktop. Suy luận ảnh/video/camera không cần kết nối mạng. Nếu dùng dịch vụ ảnh đám mây để chọn tệp, hãy tải tệp đó xuống thiết bị trước khi thử hoàn toàn offline.

### Cài bằng ADB (tùy chọn)

Từ thư mục gốc repository sau khi clone:

```powershell
adb install -r .\releases\android\1.3.5\app-arm64-v8a-release.apk
```

Thay tên APK nếu dùng ABI khác. `-r` là cài cập nhật, chỉ thành công khi chữ ký và quy tắc phiên bản tương thích.

**Lưu ý cập nhật:** APK bàn giao dùng khóa debug hiện có. Khi tự build trên máy khác, khóa debug của bạn thường khác, nên Android có thể báo `INSTALL_FAILED_UPDATE_INCOMPATIBLE`. Gỡ app sẽ xóa dữ liệu riêng của app; hãy giữ lại dữ liệu cần thiết trước khi tự quyết định gỡ. Hướng dẫn này không yêu cầu gỡ app hoặc xóa dữ liệu để thử cập nhật.

### 3. Thử các chức năng

- Chạy **Ảnh mẫu** để xác nhận model đã nạp và có kết quả.
- Dùng **Chọn ảnh** hoặc **Chụp ảnh** với một vài quả rõ, đủ sáng; xem từng khung và nhãn.
- Dùng **Chọn video** với clip ngắn trước. Video được đọc tuần tự, tối đa 10 phút; có thể hủy sau khung đang xử lý. Tốc độ xử lý có thể thấp hơn tốc độ phát video.
- Mở **Camera trực tiếp**, cấp quyền và bắt đầu phiên. Preview và tần suất AI là hai đại lượng riêng; xem FPS xử lý thực trong phần hiệu năng.
- Khi thử đếm qua vạch, cấu hình vạch/chiều trước phiên, cố định camera và cho quả đi qua vùng quan sát theo một chiều.

Bản hiện tại phân mức quan sát trên vỏ cho chuối/xoài (`Xanh / chưa chín`, `Chín`). Quả chung/chưa hỗ trợ giữ trạng thái chưa phân mức. Tracking dùng hình học; không coi tổng ID hay lượt qua vạch là số quả vật lý đã được kiểm chứng. Chưa xác nhận hiệu năng, pin hoặc nhiệt trên điện thoại thật.

## Biên dịch từ mã nguồn

### Môi trường

| Thành phần | Cấu hình của bản bàn giao |
| --- | --- |
| Flutter / Dart | **Flutter 3.47.5 stable / Dart 3.13.4**; `pubspec.yaml` yêu cầu `^3.13.4` |
| Android Studio | Bản hỗ trợ AGP 9.1; cài plugin Flutter (kèm Dart) |
| Android SDK | Platform **36**, Build Tools **36.0.0**, Platform Tools, Command-line Tools |
| NDK / CMake | **28.2.13676358** / **3.22.1** |
| Android Gradle Plugin / Gradle wrapper | **9.1.0** / **9.3.1** |
| Java/Kotlin đích biên dịch | **JVM 17** |
| Android runtime | `minSdk=26`, `compileSdk=36`, `targetSdk=36` với Flutter đã nêu |

Dùng **JDK 17** là cấu hình khởi đầu phù hợp. JDK chạy Gradle khác với đích bytecode 17 của app: Gradle 9.3.1 hỗ trợ chạy trên JDK 17–25; Java 26 cần Gradle 9.4 trở lên. Không tự nâng JDK, wrapper hoặc AGP riêng lẻ để xử lý lỗi. Đối chiếu [bảng tương thích Gradle](https://docs.gradle.org/current/userguide/compatibility.html) và [yêu cầu AGP 9.1](https://developer.android.com/build/releases/agp-9-1-0-release-notes).

Tải đúng Flutter từ [SDK archive chính thức](https://docs.flutter.dev/install/archive), thêm thư mục `flutter/bin` vào PATH. Trong Android Studio → SDK Manager, bật **Show Package Details** để chọn đúng NDK và CMake. Android Emulator chỉ cần nếu không dùng điện thoại thật. Lần cài SDK/phụ thuộc/build đầu cần Internet và dung lượng cho SDK, NDK, cache Gradle; APK chạy xong vẫn offline.

### 1. Clone và kiểm tra công cụ

```powershell
git clone https://github.com/wom-sama/fruit-offline-mobile-demo.git
cd fruit-offline-mobile-demo\app
flutter --version
java -version
flutter doctor -v
flutter doctor --android-licenses
```

Chấp nhận giấy phép SDK và xử lý các lỗi thuộc Android toolchain trước khi build. Nếu Flutter chọn sai JDK, cấu hình đường dẫn JDK trên máy bạn bằng `flutter config --jdk-dir "DUONG_DAN_JDK_17"`, rồi chạy lại `flutter doctor -v`. `DUONG_DAN_JDK_17` là thư mục JDK thực tế, không phải tên phải chép nguyên. Thiết lập Gradle JDK trong Android Studio cũng cần dùng bản tương thích.

### 2. Mở dự án

Trong Android Studio, chọn **Open** và mở thư mục **`fruit-offline-mobile-demo/app`** có `pubspec.yaml`. Chọn Flutter SDK 3.47.5 đã cài khi IDE yêu cầu. Không dùng đường dẫn SDK của máy phát triển cũ; `android/local.properties` là cấu hình cục bộ được Flutter tạo trên máy bạn.

Chạy trong thư mục `app`:

```powershell
flutter pub get
flutter analyze
flutter test
```

Các model và metadata Android đã nằm trong `android/app/src/main/assets/`; không cần cài Python hay tải dữ liệu huấn luyện để build app. Nên giữ `pubspec.lock`, phiên bản thư viện và Gradle wrapper của bản bàn giao.

### 3. Build APK release

```powershell
flutter build apk --release --split-per-abi --build-name=1.3.5 --build-number=5009 --android-project-arg=force-version-code-ignoring-abi=true
```

Ba APK mới nằm tại:

```text
app/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
app/build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk
app/build/app/outputs/flutter-apk/app-x86_64-release.apk
```

Lệnh trên giữ `versionCode=5009` cho từng APK như bản bàn giao. Nếu chỉ dùng `flutter build apk --release --split-per-abi`, Flutter mặc định cộng mã ABI vào versionCode. APK tự build có chữ ký/cache/toolchain riêng nên không được kỳ vọng trùng hash với APK đã bàn giao.

Để chạy trên thiết bị kết nối, từ `app` dùng `flutter devices`, chọn ID phù hợp và chạy `flutter run --release -d ID_THIET_BI`. Việc build thành công không thay thế kiểm thử camera, decoder hoặc hiệu năng trên thiết bị đó.

### Kiểm thử native (dành cho người phát triển)

Từ `app/android` trên Windows:

```powershell
.\gradlew.bat :app:testDebugUnitTest
```

Kiểm thử instrumentation nằm tại `app/android/app/src/androidTest/` và cần thiết bị/máy ảo Android. Xem bằng chứng 1.3.5 trong [thư mục phát hành](../releases/android/1.3.5/); các con số đã lưu không tự thay thế một lần kiểm thử trên môi trường của bạn.

## Xử lý lỗi thường gặp

| Hiện tượng | Cách kiểm tra |
| --- | --- |
| `flutter` / `adb` chưa được nhận diện | Kiểm tra PATH; mở lại terminal sau khi cài SDK |
| Thiếu SDK / NDK / CMake | Cài đúng phiên bản trong bảng trên, chạy `flutter doctor -v` |
| Java/Gradle không tương thích | Xem JDK thực tế trong `flutter doctor -v` và cấu hình Gradle JDK của IDE |
| `INSTALL_FAILED_NO_MATCHING_ABIS` | Kiểm tra `ro.product.cpu.abilist`, cài đúng một APK tương ứng |
| Lỗi chữ ký khi cập nhật | Đọc lưu ý về khóa debug và dữ liệu trước khi quyết định gỡ app |
| Không chọn/đọc được ảnh hoặc video | Thử tệp được lưu cục bộ, clip MP4 ngắn phổ thông; khả năng đọc phụ thuộc codec và decoder của thiết bị |
| Camera không mở | Kiểm tra quyền camera, đóng ứng dụng khác đang dùng camera, dừng rồi mở lại phiên |
| Video xử lý chậm / máy nóng | Thử clip ngắn và quan sát FPS/nhiệt; chưa có cam kết 30 FPS hoặc hiệu năng điện thoại thật |

Xem thêm [kiến trúc](ARCHITECTURE.md), [model card](../models/android/model-card.md) và [các tối ưu đã áp dụng](optimizations/README.md).
