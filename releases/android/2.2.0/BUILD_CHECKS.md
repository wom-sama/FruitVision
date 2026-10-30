# Câu hỏi build và kết quả thực tế

Managed wrapper + Gradle tasks; đây là kiểm build/test, không thay bằng chứng thao tác Android.

## gradle-ledger-6003.json

> APK FruitVision 2.2.0 có build đủ ba kiến trúc sau khi hoàn thiện nghiệp vụ và 49 kiểm thử đạt không?

Exit 0; 92.562 giây; task `.\gradlew.bat :app:assembleRelease -Ptarget=lib/main.dart -Ptarget-platform=android-arm,android-arm64,android-x64 -Psplit-per-abi=true -Pforce-version-code-ignoring-abi=true`.

## gradle-ledger.json

> Các ca chính sách URL, APK và chữ ký cập nhật có phát hiện phần triển khai còn thiếu không?

Exit 1; 49.844 giây; task `.\gradlew.bat :app:testDebugUnitTest`.

> 22 ca chính sách cập nhật có đạt và mã Android tải/cài có biên dịch sau triển khai không?

Exit 0; 29.391 giây; task `.\gradlew.bat :app:testDebugUnitTest`.

> Chính sách cập nhật vẫn đạt sau khi sửa hủy tải tại lúc trả kết quả và giới hạn tổng ba phút không?

Exit 0; 23.406 giây; task `.\gradlew.bat :app:testDebugUnitTest`.

> Bản nền6004 có build release cả ba ABI với updater và62 Flutter tests đã đạt không?

Exit 1; 16.36 giây; task `.\gradlew.bat :app:assembleRelease -Ptarget=lib/main .dart -Ptarget-platform=android-arm,android-arm64,android-x64 -Psplit-per-abi=true -Pforce-version-code-ignoring-abi=true`.

> Bản nền6004 có build release cả ba ABI với updater và62 Flutter tests đã đạt không?

Exit 0; 110.734 giây; task `.\gradlew.bat :app:assembleRelease -Ptarget=lib/main.dart -Ptarget-platform=android-arm,android-arm64,android-x64 -Psplit-per-abi=true -Pforce-version-code-ignoring-abi=true`.

> APK cuối2.2.0+6005 có build release đủ ba kiến trúc với updater không?

Exit 0; 69.719 giây; task `.\gradlew.bat :app:assembleRelease -Ptarget=lib/main.dart -Ptarget-platform=android-arm,android-arm64,android-x64 -Psplit-per-abi=true -Pforce-version-code-ignoring-abi=true`.

## gradle-cache-ledger.json

> Bản nền6004 khôi phục cache có qua22 native tests và build3ABI không?

Exit 0; 131.703 giây; task `.\gradlew.bat :app:testDebugUnitTest :app:assembleRelease -Ptarget=lib/main.dart -Ptarget-platform=android-arm,android-arm64,android-x64 -Psplit-per-abi=true -Pforce-version-code-ignoring-abi=true`.

> APK cuối6006 có build3ABI sau sửa khôi phục gói khi Android đổi quyền không?

Exit 0; 47.672 giây; task `.\gradlew.bat :app:assembleRelease -Ptarget=lib/main.dart -Ptarget-platform=android-arm,android-arm64,android-x64 -Psplit-per-abi=true -Pforce-version-code-ignoring-abi=true`.

Expected RED: thiếu UpdatePolicy ở lượt đầu. Một lệnh build6004 bị PowerShell tách đối số .dart; đã sửa quoting và build đạt. Các lượt cuối6004-cache/6006 đều exit0.

Cả ba workflow đã finish; chỉ log thuộc wrapper được xóa. Các cảnh báo Gradle/Kotlin DSL/SDK XML/Java native-access còn giữ trong ledger local, không tắt kiểm để qua build.