# FruitVision 2.6.2+6014 - kết nối sau khi khởi động lại PC

Ngày 31/10/2026, hệ thống PostgreSQL, ASP.NET Core API và AI đã được khởi động lại từ cấu hình/dữ liệu hiện có trên máy. API cục bộ vẫn ở 127.0.0.1:5098, PostgreSQL ở 127.0.0.1:55432. Cổng dữ liệu và worker không được mở trực tiếp ra Internet.

## Địa chỉ hiện tại

- Web/API: https://vip-certainly-broke-lease.trycloudflare.com
- Kiểm tra sẵn sàng: https://vip-certainly-broke-lease.trycloudflare.com/health/ready
- OpenAPI: https://vip-certainly-broke-lease.trycloudflare.com/openapi/v1.json

Đã kiểm tra đường HTTPS công khai trả `ready`, `aiReady: true` và trang index trả HTTP 200. Đây là kết quả kiểm tra sau khởi động, không phải cam kết thời gian hoạt động liên tục.

## Vì sao địa chỉ cũ không còn dùng được?

Địa chỉ `tips-differential-relating-validity.trycloudflare.com` thuộc Quick Tunnel tạm. Sau khi tiến trình cũ kết thúc, Quick Tunnel mới được cấp hostname mới; không có cấu hình tunnel cố định trên máy để khôi phục hostname cũ.

APK 6013 lưu địa chỉ cũ và không có đường đổi máy chủ trước đăng nhập. Vì vậy chỉ bật lại API chưa đủ để các APK cũ kết nối được. Bản 6014 sửa đúng trường hợp này; đây chưa phải giải pháp hostname cố định cho các lần tắt máy tiếp theo.

## Cài bản cập nhật

1. Điện thoại Android 64-bit dùng `app-arm64-v8a-release.apk` trong thư mục APK_2.6.2_6014, hoặc tải từ trang API mới sau khi bản phát hành được công bố.
2. Cài đè bằng cùng khóa ký, giữ dữ liệu ứng dụng. Android vẫn cần người dùng xác nhận cài đặt. APK đang giữ hostname cũ không thể tự kiểm tra cập nhật qua một địa chỉ đã mất; lần này cần mở link mới hoặc tệp APK trực tiếp.
3. Bản mới chỉ chuyển đúng hostname cũ đã biết sang hostname mới được ghim trong bản phát hành. Phiên và OTP challenge cũ được bỏ trước khi gửi yêu cầu; người dùng đăng nhập lại bằng mật khẩu và OTP email bình thường.
4. Địa chỉ máy chủ tùy chỉnh khác không bị tự đổi. Khóa E2EE cục bộ không bị tự xóa, thu hồi hoặc chuyển sang origin mới. Do khóa ràng buộc với địa chỉ máy chủ, chat mã hóa cần kiểm tra/thiết lập lại đúng thiết bị trước khi demo; không mặc định lịch sử bí mật dùng được qua origin mới.

CSDL tài khoản, bài viết, hội thoại và hồ sơ trên PC được giữ nguyên. Không huấn luyện lại, đổi mô hình, sửa phân quyền hoặc nới bảo mật. Giới hạn chất lượng AI video của bản 6013 vẫn còn; tài liệu vai trò và công nghệ 2.6.1 vẫn áp dụng cho các chức năng không thay đổi.

## Kiểm tra phần sửa kết nối

Bốn ca mới đã tái hiện lỗi rồi đạt: chuyển đúng origin cũ mà không gửi token cũ; giữ nguyên origin tùy chỉnh/hostname gần giống; khôi phục bình thường tại origin hiện tại; cài mới dùng địa chỉ hiện tại. Toàn bộ 174 kiểm thử Flutter đạt và analyzer không báo lỗi. Kiểm tra đóng gói, chữ ký và tải APK được lưu riêng cùng bản phát hành; không coi kiểm thử host là kiểm thử điện thoại thật.

Đã build ba APK 6014 qua wrapper trong 339,4 giây, kiểm đúng phiên bản/chữ ký/quyền/thư viện và hostname mới trong mã Dart đã biên dịch. Chín GET công khai xác minh metadata/Range 206 cả ba bản, một lượt tải trọn ARM64 khớp hash, bản 6014 không yêu cầu cập nhật lại. Bản ARM64 SHA-256: `0f9843e4e3d152b9ae5d99c4476982567b8ebb90e7a4d7938c1d49692e3aa57b`.

Sau reboot, một tác vụ ảnh xoài thật qua HTTPS mới đã hoàn tất, có ảnh xem trước, xử lý model 0,797 giây và giữ đúng model hash. Đây là kiểm tra vận hành với ảnh mẫu có sẵn, không phải đánh giá độ chính xác mới. Không mở máy ảo hoặc thao tác điện thoại trong lượt khởi động lại này. Workflow build đã kết thúc và tài nguyên SDK đã trả cho chat HUTECH.

Để giữ địa chỉ lâu dài, cần chuyển sang tunnel/hostname cố định được cấu hình bằng tài khoản và tên miền phù hợp. Trong buổi demo hiện tại, giữ PC, API và tiến trình tunnel hoạt động, tránh Sleep hoặc tắt máy.
