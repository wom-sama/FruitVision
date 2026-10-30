# FruitVision Email OTP relay

Template riêng cho FruitVision; người vận hành tạo Google Apps Script và xác nhận quyền gửi thư bằng tài khoản của mình.

1. Thêm Code.gs/appsscript.json vào dự án mới.
2. Tạo khóa ngẫu nhiên riêng ít nhất 32 byte; lưu Script Property `OTP_RELAY_SECRET` và cùng giá trị trong private server config `EmailOtp:RelaySecret`. Không commit khóa.
3. Triển khai Web app chạy bằng chủ tài khoản. Endpoint nhận yêu cầu bên ngoài nhưng bắt buộc chữ ký HMAC hợp lệ; đọc mã trước khi cấp quyền.
4. Lưu URL deployment trong private `EmailOtp:RelayUrl`. Chỉ backend gọi relay; APK không giữ khóa gửi thư.
5. Kiểm tra thư thật có tiêu đề “Mã xác thực FruitVision”. Quota Google vẫn áp dụng; lỗi gửi không được bỏ qua OTP.

`node --test relay.test.cjs` kiểm tra giao thức với dịch vụ giả, không chứng minh thư đã đến.
Không công khai deployment secret, OTP, hộp thư hoặc handoff vận hành.
