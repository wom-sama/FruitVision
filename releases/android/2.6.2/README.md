# FruitVision 2.6.2+6014

Client Flutter hiện tại dùng backend 2.6. Bản này sửa kết nối sau reboot PC: chuyển đúng địa chỉ tunnel cũ đã biết sang địa chỉ mới được biên dịch trong APK, bỏ phiên/OTP challenge cũ trước HTTP và yêu cầu đăng nhập lại. Các địa chỉ tùy chỉnh khác được giữ nguyên. Không đổi model/ngưỡng, nghiệp vụ hoặc phân quyền trong 6014.

## Tải APK

Bộ cài được lưu tại [GitHub Release v2.6.2](https://github.com/wom-sama/FruitVision/releases/tag/v2.6.2):

| Thiết bị | APK |
|---|---|
| Android ARM 64 bit | [app-arm64-v8a-release.apk](https://github.com/wom-sama/FruitVision/releases/download/v2.6.2/app-arm64-v8a-release.apk) |
| Android ARM 32 bit | [app-armeabi-v7a-release.apk](https://github.com/wom-sama/FruitVision/releases/download/v2.6.2/app-armeabi-v7a-release.apk) |
| Máy ảo/x86 64 bit | [app-x86_64-release.apk](https://github.com/wom-sama/FruitVision/releases/download/v2.6.2/app-x86_64-release.apk) |

Android tối thiểu API 26. Package `vn.mangodemo.mango_offline`, versionCode 6014. Chứng thư ký đồ án được giữ để cập nhật đè; đây là course/debug signer, không phải khóa phát hành Play Store. Người dùng vẫn xác nhận ở trình cài Android. Clone repo không chứa private keystore của người phát triển.

- [SHA256SUMS.txt](SHA256SUMS.txt): hash đầy đủ ba bộ cài.
- [apk-verification.json](apk-verification.json): phiên bản, kiến trúc/thư viện, chữ ký v2, quyền, CameraX/libsodium, không có runtime/trọng số AI. Đường dẫn máy đã được đổi thành tên asset công khai, các kết quả kiểm được giữ nguyên.
- [public-release.json](public-release.json): chín GET tới API demo; metadata/range cả ba APK và một lần tải đầy đủ ARM64 khớp hash. Đây là kiểm tra phục vụ APK qua API trước khi công bố GitHub, không phải receipt tải từ GitHub.

## Kết nối và kiểm chứng

Địa chỉ được biên dịch trong APK là `https://vip-certainly-broke-lease.trycloudflare.com`. Cần PC/API/tunnel đang chạy. Quick Tunnel là địa chỉ tạm; APK này chưa giải quyết hostname cố định cho những lần tắt máy sau. Xem [khởi động lại hệ thống](../../../server/docs/RESTART_2_6_2.md) và [cài backend riêng](../../../server/README.md).

6014 đạt 174 kiểm thử Flutter và analyzer không báo lỗi; bốn ca mới kiểm chuyển origin, giữ origin tùy chỉnh/lookalike, khôi phục origin hiện tại và cài mới. Backend 2.6 giữ kết quả 204 kiểm thử trước đó. Không có lượt UI Android/điện thoại mới cho 6014 và không gọi kiểm hash/đóng gói là kiểm thử chức năng máy thật.

## Hạn chế còn tồn tại

- AI vẫn có thể nhận quả khác thành xoài/Chín; video băng chuyền giống táo đã cho kết quả sai. Không dùng video đó làm minh chứng độ chính xác. Chuyển AI sang PC chưa sửa chất lượng mô hình.
- Lượt camera máy ảo 6012 ghi nhận 4,85 AI FPS, chưa chứng minh 6 FPS hoặc nhiều máy đồng thời. 6014 không mang cải tiến hiệu năng AI mới.
- Khóa E2EE ràng buộc origin; không tự xóa, thu hồi hay di chuyển keybag. Sau đổi hostname cần kiểm tra thiết bị/mã an toàn; không mặc định đọc được lịch sử bí mật qua origin mới.
- Đếm là theo dõi hình học; che khuất/quay lại/camera di chuyển có thể sai. Nhãn xanh/chín không bảo đảm độ chín bên trong hoặc an toàn thực phẩm.
- Phạm vi đồ án phi thương mại, không giao dịch mua bán, không IoT, chưa bảo đảm dịch vụ 24/7.

[Mã frontend](../../../mobile_client/README.md) · [API/backend](../../../server/README.md) · [Vai trò và thao tác demo](../../../server/docs/DEMO_10_PHUT_4_VAI_TRO.md).
