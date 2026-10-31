# FruitVision 2.6 — hồ sơ, hộp thư và quản trị

Bản này sửa luồng sử dụng và quyền truy cập. Flutter chỉ gọi một API FruitVision; PostgreSQL, OTP relay và AI do máy tính phục vụ qua backend. Mô hình AI giữ nguyên so với 2.5, nên thay đổi giao diện không được xem là cải thiện độ chính xác nhận diện.

## Thay đổi chính

- Bốn vai trò đều có tab **Tin nhắn** cố định, nhãn điều hướng luôn hiện. Danh sách xếp theo hoạt động mới nhất, có người nhận, nội dung xem trước, thời gian và số chưa đọc.
- Nút soạn tin mới tìm tài khoản đã duyệt và mở hội thoại riêng. Thông báo trong app dẫn tới đúng hội thoại. Trạng thái đã đọc được lưu trên server theo đúng tin đã hiển thị, đồng bộ giữa các phiên; không tự đánh dấu toàn bộ bằng thời gian hiện tại.
- Chat mã hóa đầu cuối mở trong hội thoại riêng giữa hai tài khoản Nhà sản xuất / Thương lái đủ điều kiện. Hộp thư chỉ hiển thị nhãn “Tin nhắn mã hóa”, không giải mã trên server. Không còn trang hộp thư bí mật trống tách rời gây nhầm lẫn.
- Chỉ Người tiêu dùng có mục nâng vai trò. Nhà sản xuất có **Cơ sở sản xuất**, Thương lái có **Cơ sở kinh doanh**; cả hai dùng quy trình cơ sở đã duyệt, không tự cấp thêm vai trò.
- Admin tìm Người tiêu dùng đủ điều kiện để bổ nhiệm Admin. Cần xác nhận đúng người, lý do và mật khẩu Admin đang thao tác. API kiểm tra quyền hiện tại, khóa khi đoán sai nhiều lần, ghi kiểm toán và thu hồi các phiên của người được bổ nhiệm. App không có ô tự chọn hoặc tự sửa vai trò.
- Bài viết và cơ sở có tạo, xem, sửa, xóa. Sửa phải xét duyệt lại. Xóa cần đúng chủ và đúng phiên bản; cơ sở còn nội dung liên kết bị từ chối. Dữ liệu được ẩn, vẫn giữ kiểm toán và hội thoại đã có; đây không phải xóa vật lý mọi bản sao.
- Hồ sơ cá nhân cho phép sửa tên hiển thị, giới thiệu, giới tính và số liên hệ. Email chỉ có trong hồ sơ riêng. Giới tính, số liên hệ và khu vực mặc định không công khai, có công tắc riêng. Vai trò, chứng từ và thông tin pháp lý không được sửa qua API hồ sơ cá nhân; thông tin cơ sở cần xét duyệt ở luồng riêng.
- Xem hồ sơ người khác từ danh bạ, hộp thư hoặc đầu cuộc trò chuyện. Có xác nhận chặn và danh sách bỏ chặn. API chặn truy cập hồ sơ, tìm liên hệ, mở hội thoại và gửi tin riêng / ảnh thường / gói mã hóa theo cả hai chiều.
- Trang web ở địa chỉ API có các nhóm chức năng và đường dẫn CRUD, quyền sử dụng, liên kết Swagger và tải APK.

## Giới hạn cần hiểu khi demo

- Chặn không thu hồi tin hoặc ảnh đã nhận, không xóa tên đã biết khỏi lịch sử hoặc ảnh chụp màn hình. Nội dung trong nhóm chung và lịch sử vẫn được giữ; chặn liên hệ riêng không cho một thành viên vô hiệu hóa cả nhóm.
- Thông báo hiện có là thông báo trong app đang hoạt động và dữ liệu chưa đọc trên server; chưa có Android push nền.
- Hồ sơ được bảo vệ bằng HTTPS và kiểm tra quyền tại API; hồ sơ không được mô tả là mã hóa đầu cuối như các gói tin nhắn bí mật.
- AI nhận diện xoài và ước lượng nhãn xanh / chín / chưa xác định theo mô hình hiện có. Không chứng minh độ chín bên trong, an toàn thực phẩm, chất lượng thương phẩm hoặc sản lượng duy nhất chính xác trong video.
- Kiểm thử máy ảo không thay cho việc kiểm thử đồng thời bốn điện thoại, camera ngoài thực địa hay xác thực sinh trắc học thật.
- Máy tính và tunnel HTTPS cần tiếp tục chạy. Địa chỉ thử nghiệm có thể đổi khi khởi động lại tunnel.

## Cơ sở thiết kế quyền riêng tư

Tham khảo cách tách hồ sơ và quyết định chặn liên hệ của [Signal](https://support.signal.org/hc/en-us/articles/360007459591-Signal-Profiles-and-Message-Requests). FruitVision không sử dụng giao thức Signal và không tuyên bố mức bảo mật tương đương. Kiểm tra quyền sở hữu và lọc trường công khai / riêng tư tại API theo các vấn đề [BOLA](https://api-security.owasp.org/editions/2023/en/0xa1-broken-object-level-authorization/) và [BOPLA](https://api-security.owasp.org/editions/2023/en/0xa3-broken-object-property-level-authorization/) của OWASP.

Kết quả kiểm thử và SHA-256 gói phát hành đi kèm trong các receipt riêng; không dùng số lượng test phần mềm làm độ chính xác của AI.
