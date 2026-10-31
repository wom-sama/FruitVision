# FruitVision 2.6.1+6013 — kết quả rà soát demo

Ngày kiểm tra: 31/10/2026. Đây là bản sửa ứng dụng; mô hình AI và backend không thay đổi.

## Cài đặt và chạy

- Điện thoại Android 64-bit: dùng `app-arm64-v8a-release.apk`. Hai tệp còn lại dành cho Android 32-bit và máy ảo x86_64 tương ứng.
- Có thể cập nhật từ app qua API hiện tại. Android vẫn yêu cầu người dùng xác nhận cài đặt; ứng dụng không tự vượt bước này.
- API: https://tips-differential-relating-validity.trycloudflare.com . PC chạy API, PostgreSQL và AI phải tiếp tục hoạt động. Địa chỉ HTTPS thử nghiệm có thể thay đổi khi tunnel được tạo lại.
- App chỉ gọi API FruitVision; không đóng gói mô hình AI trong APK.

## Lỗi đã sửa và kiểm tra lại

Admin trên bản 6012 không mở được ảnh minh chứng nếu máy thiếu ứng dụng xem ảnh ngoài. Bản 6013 mở JPEG/PNG ngay trong FruitVision, hỗ trợ phóng to, giữ kiểm tra quyền của API và xóa dữ liệu ảnh trong RAM/cache khi đóng. PDF vẫn cần ứng dụng đọc PDF phù hợp.

Đã quan sát trực tiếp trên APK 6013: mở ảnh minh chứng, yêu cầu bổ sung hồ sơ, chấp thuận cơ sở, công bố bài cộng đồng; trạng thái và revision trên API khớp. Người tiêu dùng vẫn giữ đúng vai trò sau yêu cầu bổ sung.

Admin cũng đã tạo/đóng nhóm bằng giao diện. Nhà sản xuất, Thương lái và Người tiêu dùng tham gia/gửi tin qua HTTPS thật; Admin nhận tin trên APK. Có một lần phải bấm **Kết nối lại**; tin gửi sau đó tự xuất hiện. Sau khi đóng nhóm, lịch sử còn và hội thoại chỉ đọc.

## Bằng chứng kiểm tra

- Toàn bộ Flutter: 170/170 đạt; analyzer không báo lỗi. Ba ca mới kiểm tra PNG, JPEG và lỗi API khi tải minh chứng.
- Ba APK đã kiểm tra phiên bản, chữ ký, kiến trúc, quyền, thư viện và hash; giữ cùng chữ ký để cập nhật bản cũ.
- HTTPS công khai: thông tin cập nhật và tải từng phần của cả ba bản khớp; một lượt tải đầy đủ bản ARM64 khớp SHA-256.
- Bảng `KIEM_TRA_28_THAO_TAC.md` phân biệt bằng chứng APK, HTTPS, kiểm thử widget và phần chưa kiểm tra. Không gọi đây là 28 ca đã đạt trên bốn điện thoại.
- Bốn vai trò được đăng nhập bằng mật khẩu và OTP email thật, lần lượt trên một máy ảo. Một số quan sát trước khi sửa ảnh minh chứng thuộc bản 6012, được ghi riêng trong đánh giá.

## Các giới hạn phải nói rõ khi demo

1. **AI video còn nhận nhầm.** Clip băng chuyền mẫu hoàn tất 231 khung trên APK 6013, nhưng cảnh quả tròn giống táo vẫn nhận một khung xoài và một track chín. Đây là lỗi chất lượng nhận diện, không phải kết quả đếm xoài đạt yêu cầu. Không dùng clip này làm ví dụ nhận diện xoài đúng; giữ nó làm ca lỗi cần sửa.
2. Camera bản 6012 ghi nhận 303 khung, 4,85 khung AI/giây trên máy ảo trong một cảnh phòng. Chưa chứng minh 6 FPS, độ chính xác thực địa hoặc hiệu năng trên bốn máy đồng thời.
3. Nhãn xanh/chín là dự đoán từ ảnh theo dữ liệu nguồn; không chứng nhận chất lượng bên trong hay an toàn thực phẩm. Số thấy đồng thời, track và lượt qua vạch là ba chỉ số khác nhau.
4. E2EE đã trao đổi tin/ảnh giữa một APK QA và peer Sodium thật trên host. Chưa phải hai điện thoại/hai người đối chiếu mã độc lập. Kho khóa Producer chính trên máy ảo đang cũ và bị khóa an toàn; không reset khóa tài khoản chính để làm demo.
5. Chưa kiểm thử dương tính sinh trắc học vật lý hoặc bốn điện thoại cùng thao tác. Một số thao tác trong bảng 28 mục hiện có bằng chứng API/widget, chưa có đủ bước bấm APK.

Các bản ghi có tiền tố QA/DEMO là dữ liệu kiểm thử, không phải hồ sơ kinh doanh hoặc chứng nhận thật. Thông tin đăng nhập và OTP không nằm trong gói APK/tài liệu này.
