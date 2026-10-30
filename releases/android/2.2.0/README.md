# FruitVision 2.2.0+6006 — 30/10/2026

## Cài và mở

1. Điện thoại Android 64 bit thông thường: tải `app-arm64-v8a-release.apk`. Máy Android 32 bit dùng `app-armeabi-v7a-release.apk`; bản `x86_64` dành cho máy tương thích/máy ảo. Kiến trúc này còn gọi là ABI.
2. Cài đè cùng ứng dụng, không gỡ trước. Giữ chứng thư ký của đồ án để nâng cấp từ các bản client2.x trước. Chỉ cấp quyền cài cho nguồn tin cậy và xác nhận hộp cài Android.
3. PC chạy API/DB/worker/tunnel. Ở màn đăng nhập → biểu tượng máy chủ, hoặc Tài khoản → Cài đặt máy chủ, nhập đúng gốc HTTPS hiện hành.
4. Người vận hành lấy tài khoản/mật khẩu của PC tại `server/.local/demo-accounts.json` và cấp riêng cho bốn người; không đưa mật khẩu vào Git hoặc slide.

[Hướng dẫn bốn vai trò](../../../server/docs/DEMO_4_ROLES_2_2.md) · [Cài backend](../../../server/README.md) · [Cơ chế cập nhật](../../../server/docs/MOBILE_RELEASES.md).

## Cập nhật trong app

Khi mở app, client kiểm phiên bản từ API. Có bản mới: bấm **Cập nhật**, app tải vào cache riêng, kiểm SHA-256/package/version/chữ ký, rồi chọn **Cài bản cập nhật**. Android yêu cầu cấp quyền nguồn cài lần đầu và xác nhận cài; app không cài im lặng. Android có thể đóng tiến trình khi đổi quyền: client khôi phục và xác minh lại gói hoàn tất, tránh tải lại. Có thể kiểm tra thủ công ở **Tài khoản → Kiểm tra cập nhật**.

Các client cũ chưa có updater cần cài bộ này một lần. Về sau không cần tải APK thủ công từ Git cho mỗi lần. Thay đổi backend tương thích không nhất thiết cần cập nhật APK. PC/tunnel phải hoạt động để kiểm/tải bản mới.

## Đã thao tác thật trên bộ này

- Bootstrap bản6004, tải6006 qua HTTPS và cài bằng **trình cài Android**, không dùng `adb install` cho bản đích. PackageManager xác nhận6006; phiên Producer được giữ qua Keystore.
- Khôi phục gói đã tải sau tiến trình bị đóng, hủy một lượt tải đang chạy, tải lại và hoàn tất cài.
- Producer tạo tin125kg/giá22.000–26.000; Admin công bố; Trader liên hệ từ tin và gửi/nhận chat với phiên Producer độc lập. Tên/vai trò người gửi đúng trên app.
- Consumer xem tham khảo24.000đ/kg từ đúng một mẫu tin, tham gia/chat/rời nhóm. API chặn lịch sử sau rời (`404`). Consumer tạo và đóng nhóm khác; composer nhóm đóng bị khóa.

Đây là bốn vai trò tuần tự trên **một máy ảo API 30**, RAM guest 997.976 KiB, 2 core. Bằng chứng bốn HTTPS/WSS client đồng thời nằm riêng trong `server/docs/verticals-https-e2e.json`; không gọi đó là bốn điện thoại.

Kiểm tự động: backend 60/60, Flutter 64/64 + analyzer sạch, native policy 22/22; ba APK đúng package/version/ABI, v2 signature, hash, không trọng số/runtime AI, không cleartext/backup. Xem [APK](apk-verification.json), [Android](native-acceptance.json), [HTTP tải gói](public-downloads.json), [build](BUILD_CHECKS.md) và `screenshots/`.

## Giới hạn

Đây là đồ án phi thương mại, dùng khóa ký debug hiện có để giữ đường nâng cấp; chưa phải phát hành Play Store. UI nhóm đóng còn câu gợi ý gửi lời chào ở vùng trống, nhưng khóa và ô nhập bị vô hiệu đúng. Một lần UiAutomator lỗi kết nối và framework Android khởi động lại; các thao tác cuối được thực hiện bằng input/screenshot thật trên lần boot ổn định.

Không kiểm điện thoại vật lý trong đợt này. Tác vụ AI ảnh/video không được gửi lại trên chính6006; giữ bằng chứng API2.2 ảnh thật và mobile2.1 ảnh/video 1.073 khung của pipeline không đổi, không biến chúng thành nghiệm thu mới. Chưa có camera streaming liên tục, đơn hàng/tồn kho/thanh toán/IoT, dự đoán giá AI hoặc bảo đảm mức chín/sản lượng thực địa. Snapshot PSS 105.154 KiB là một thời điểm, không phải benchmark CPU/FPS hay điện thoại.
