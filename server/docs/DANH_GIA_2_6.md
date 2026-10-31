# Đánh giá ứng dụng FruitVision 2.6

## Những lỗi đã xử lý trong lượt này

| Vấn đề | Cách xử lý và bằng chứng |
|---|---|
| Người nhận không tìm được tin mới | Tab Tin nhắn ở cả bốn vai trò; xếp theo hoạt động cuối; danh bạ để mở tin riêng; số chưa đọc lưu ở PostgreSQL. Đã kiểm tra Consumer gửi → Producer nhận bằng WSS mà không mở hội thoại trước. |
| Nhiều hội thoại cùng một người khó phân biệt | Hiển thị ngữ cảnh tin riêng, từ bài viết hoặc từ tin cũ; giữ nguyên lịch sử đã có. |
| Trang chat bí mật trống, tách rời | Gỡ lối vào hộp thư bí mật riêng; mở mã hóa đầu cuối từ hội thoại Direct đủ điều kiện. Xem trước mã hóa chỉ có nhãn chung. |
| Menu không phù hợp vai trò | Chỉ Consumer có nâng vai trò. Producer dùng Cơ sở sản xuất; Trader dùng Cơ sở kinh doanh. Admin không có AI. |
| Thiếu nguồn tạo Admin | Admin hiện tại bổ nhiệm Consumer đủ điều kiện, xác nhận lại mật khẩu và lý do. Có kiểm toán, chống bổ nhiệm lặp, thu hồi phiên cũ. Luồng thay đổi quyền được kiểm tra trên PostgreSQL thử nghiệm riêng; không tự nâng tài khoản demo Consumer. |
| CRUD chưa có xóa | Xóa bài / cơ sở thuộc mình, kiểm tra revision. Cơ sở còn nội dung không được xóa. Xóa mềm giữ kiểm toán và hội thoại, không thể hồi sinh bằng lệnh sửa cũ. |
| Thiếu hồ sơ và quyền riêng tư | Hồ sơ riêng, hồ sơ công khai, cờ công khai từng trường, thông tin vai trò chỉ đọc và chặn / bỏ chặn. API từ chối trường vai trò / trạng thái do người dùng chèn vào. |
| Vượt chặn bằng lời gọi API hoặc upload đang chạy | Kiểm tra cả hai chiều trên tin thường, ảnh, tin mã hóa và mở liên hệ. Có kiểm thử gửi đồng thời lúc chặn và chặn trong lúc upload; không để lại bản ghi / file mới sau khi bị từ chối. |
| Thanh báo tin che nút hồ sơ | Phát hiện bằng APK thực trên máy ảo. Tách ScaffoldMessenger của Workspace, thêm nút đóng; kiểm thử thông báo không đi theo sang trang hồ sơ. |
| Khó kiểm tra API | Index web nhóm chức năng, CRUD, vai trò, mã lỗi và liên kết Swagger. Đã đọc HTML / OpenAPI từ HTTPS đang chạy, không chỉ kiểm tra file nguồn. |

## Bằng chứng và cách đọc kết quả

- Backend: 204/204 kiểm thử đạt, không bỏ qua. Flutter sau sửa giao diện: 167/167 đạt; analyzer không có lỗi. Đây là kiểm thử phần mềm, không phải độ chính xác của AI.
- Gửi nhận công khai: 38 HTTP request và một kết nối WSS thực. Hồ sơ, quyền riêng tư, chặn và CRUD: 51 kiểm tra / 36 request HTTPS thực; hồ sơ Consumer được khôi phục sau kiểm tra.
- APK được kiểm tra riêng ba kiến trúc: phiên bản, chữ ký, hash, quyền Android, thư viện native, giấy phép và không chứa trọng số AI. Chữ ký giữ tương thích cập nhật bản trước.
- Các lượt kiểm thử APK chưa đạt được giữ lại; không gọi chúng là thành công. Kết quả cuối trên máy ảo được ghi trong receipt đi kèm APK. Máy ảo và nhiều HTTP client không phải bằng chứng bốn điện thoại thật cùng chạy.

## Hạn chế còn lại, cần nói rõ khi trình bày

1. AI giữ mô hình cũ, còn bỏ sót và nhầm xanh / chín. Chưa có đánh giá thực địa mới, chưa đạt bằng chứng 6 FPS trên mọi thiết bị, chưa đảm bảo tổng sản lượng duy nhất từ video. Cần dữ liệu và bộ kiểm tra có gán nhãn phù hợp; không sửa chỉ số bằng giao diện.
2. Thông báo đang có là trong app và hộp thư chưa đọc; push nền Android cần bổ sung sau. Chặn liên hệ riêng không xóa dữ liệu đã nhận hoặc nội dung nhóm chung.
3. Hồ sơ cá nhân không phải hồ sơ pháp lý đã xác minh. Các trường công khai được lọc ở API; Admin vẫn có quyền quản trị được cấp riêng. Chỉnh sửa thông tin cá nhân không tự sửa hồ sơ pháp lý, cơ sở hoặc vai trò đã duyệt.
4. Chat mã hóa cần khóa thiết bị và bước kiểm tra danh tính hai bên. Chưa tuyên bố kiểm toán mật mã độc lập hoặc bảo đảm khôi phục đầy đủ khi mất thiết bị. Không gán các bảo đảm của Signal cho FruitVision.
5. Địa chỉ HTTPS thử nghiệm phụ thuộc tunnel và máy tính. Để vận hành dài hạn cần địa chỉ cố định, giám sát, sao lưu có kiểm tra phục hồi và quản lý khóa triển khai. Không dùng địa chỉ tạm như cam kết dịch vụ công khai liên tục.

Ưu tiên demo là những luồng hiện có, với dữ liệu và giới hạn nói đúng. Các hạng mục tốn nhiều thời gian ở trên không được ghi thành chức năng đã hoàn thành.
