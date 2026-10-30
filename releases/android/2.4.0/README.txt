FruitVision 2.4.0 (6010) — app gọi API; AI chạy trên máy tính.

Điện thoại Android phổ biến: app-arm64-v8a-release.apk.
Điện thoại Android 32 bit: app-armeabi-v7a-release.apk.
Máy ảo x86_64: app-x86_64-release.apk.
Android 8.0 trở lên. Cùng chữ ký với bản trước nên cài đè để cập nhật.
Có thể mở app cũ và chọn Cập nhật; Android vẫn yêu cầu bạn xác nhận cài đặt.

Đăng nhập bằng mật khẩu và mã email có tiêu đề “Mã xác thực FruitVision”.
Tài khoản mới mặc định Người tiêu dùng; không cần cài ứng dụng Authenticator.
Chỉ tài khoản đã từng tự bật TOTP mới tiếp tục dùng mã TOTP đã có.
Sinh trắc học là tùy chọn; đối chiếu ảnh mặt vẫn phải xác minh email.

Một API: https://tips-differential-relating-validity.trycloudflare.com
Máy chủ trên máy tính và đường HTTPS phải đang chạy. URL thử nghiệm có thể đổi khi khởi động lại tunnel.

Người tiêu dùng: học về xoài, cộng đồng và trao đổi; không có quyền chạy AI.
Nhà sản xuất/Thương lái: phân tích xoài, bài chuyên môn theo chi nhánh đã duyệt, trao đổi.
Admin: xét duyệt/quản lý; không chạy AI.
Tin nhắn/ảnh thường được máy chủ xử lý và đọc được.
Tin bí mật chỉ giữa hai Seller đã duyệt: khóa riêng trên thiết bị, so sánh toàn bộ mã an toàn trước khi gửi.
Một thiết bị bí mật hoạt động mỗi tài khoản; chưa có khôi phục khóa, đồng bộ nhiều thiết bị hoặc forward secrecy.

AI giữ nguyên trọng số; chỉ giữ đối tượng dự đoán là xoài. Hai nhãn giai đoạn nguồn Xanh/Chín và Chưa xác định.
Đếm có thể sai khi che khuất hoặc camera chuyển động; chưa xác nhận độ chín thực địa/an toàn thực phẩm, không bảo đảm FPS.
Chỉ trình diễn phi thương mại. Không có giao dịch mua bán, thanh toán hoặc IoT.

Đã kiểm: backend157; Flutter110 nền +2 kiểm tra UI liên quan sau sửa; HTTPS88 kiểm tra;
40 quan sát Sodium mã hóa API; 4 kiểm tra Android Keystore/ảnh trên máy ảo.
APK đã thử Email OTP thật, kiến thức Người tiêu dùng, ảnh xoài/ảnh chú thích và tạo khóa trên máy ảo.
Bản cuối chỉ sửa thêm một dòng mô tả đăng nhập; đã build lại và kiểm chữ ký/hash cả ba gói.
Không gọi kết quả máy ảo là kiểm thử điện thoại thật hoặc kiểm định mật mã độc lập.