# Kịch bản nghiệm thu HTTPS 2.4 — chuẩn bị, chưa chạy

Chỉ chạy sau khi người vận hành xác nhận **đúng API 2.4 đã triển khai**. Kịch bản tạo dữ liệu có nhãn `DEMO QA2.4`; không phải giấy tờ, giao dịch, giá hay tồn kho thật. Không tự chạy lại nếu có lỗi; giữ biên bản dở dang và các ID để chẩn đoán.

## Chuẩn bị

- Bốn phiên Admin/Producer/Trader/Consumer được đăng nhập và hoàn thành OTP/TOTP thật trước đó. Kịch bản không tạo hoặc làm mới token, không gửi OTP, không dùng SQL hay đổi vai trò.
- File phiên riêng nằm dưới `server/.local`, cùng cấu trúc của driver 2.3: `baseURL`, `sessions` theo bốn vai trò, mỗi vai trò có `accessToken` và `user.id`. Không đưa file, token hoặc mã email vào Git, tài liệu, ảnh chụp hay dòng lệnh.
- `baseURL` phải trùng HTTPS hiện hành trong bản ghi tunnel riêng. TLS luôn được kiểm tra; không theo redirect hoặc chuyển thông tin xác thực sang host khác.
- Dùng Python đã có Pillow của dự án. Bộ xử lý ảnh thực trên máy chủ phải sẵn sàng; không thay bằng bộ xử lý giả và không hạ quota để chạy bài này.

Từ thư mục `server`, sau khi được phép thực hiện kiểm tra live:

```powershell
& ./.tools/ai-venv/Scripts/python.exe -X utf8 -B ./scripts/media_acceptance_24.py --sessions ./.local/https-sessions-24.json --run --output ./docs/media-https-e2e-24.json
```

Nếu phiên hết hạn, dừng và lấy phiên qua luồng xác thực thật. Không sửa database để có phiên. Nếu file biên bản đã tồn tại, driver từ chối ghi đè; chọn tên đầu ra mới sau khi đã xem lần chạy trước.

## Phạm vi thực hiện

Trong tối đa 80 yêu cầu HTTP và 180 giây, driver:

1. Xác minh danh tính/vai trò hiện tại của bốn phiên và danh mục Việt Nam 34 tỉnh qua API.
2. Tạo **JPEG thật bằng Pillow**, kích thước 2400×1600, có EXIF thử nghiệm không chứa thông tin cá nhân. Ảnh đầu vào nằm riêng dưới `.local/acceptance-media24`.
3. Upload ảnh Consumer, tạo bài `Community`, kiểm tra ảnh riêng khi chờ duyệt, Admin công bố, tải ảnh JPEG chuẩn hóa thực tế; kiểm tra giới hạn kích thước và EXIF đã bỏ. Rút bài phải làm ảnh công khai biến mất, rồi Admin công bố lại dữ liệu demo.
4. Dùng chi nhánh đã duyệt thuộc Producer/Trader; nếu chưa có, chỉ tạo/duyệt chi nhánh QA có nhãn rõ. Kiểm tra Seller không có chi nhánh/bằng chi nhánh người khác bị từ chối; bài hợp lệ thuộc lane `Professional`, không còn dùng giả định Seller viết bài luôn nhận403 của bản 2.3 cũ.
5. Hai yêu cầu liên hệ cùng bài tạo đúng một Direct thread. Kiểm tra Admin không mở liên hệ, tác giả không tự liên hệ, người ngoài không đọc được tin/ảnh.
6. Gửi ảnh chat thường, gửi lại cùng bytes/key phải dùng lại message/image; đổi bytes với cùng key phải409. Tải ảnh chuẩn hóa qua tài khoản thành viên, kiểm tra sender và khôi phục bằng REST có đúng một bản ghi.
7. Chỉ **đọc** bề mặt metadata secret: Seller đọc được danh sách của mình, Admin/Consumer bị403, người không đăng nhập bị401 và ID không có bị404. Không đăng ký/đổi/thu hồi khóa, không tạo secret thread, không gửi ciphertext hoặc ảnh secret giả.

Ảnh bài viết và ảnh chat **thường** có thể được máy chủ đọc/xử lý; không gọi các luồng đó là E2EE. Driver không suy luận “server không thể giải mã” từ việc API trả các trường ciphertext hoặc từ tên endpoint. Luồng real-Sodium riêng phải chứng minh sealed box/chữ ký, fingerprint kiểm tra ngoài băng, ảnh mã hóa, keybag native, khóa sai/tamper và người thứ ba trước khi kết luận sản phẩm E2EE đã chạy.

Không có lời gọi AI cho bất kỳ vai trò nào, không kiểm tra native/APK/cảm biến sinh trắc học, không có WSS acceptance và không làm thử nghiệm nâng vai trò chính thức. Kết quả HTTPS/WSS của bản trước hoặc 157 kiểm thử backend riêng không thay cho nghiệm thu những phạm vi này.

## Biên bản và dữ liệu sau chạy

Biên bản chỉ ghi trạng thái, độ trễ, ID bản ghi, kích thước/hash của ảnh fixture và các cờ kiểm tra. Không ghi token, OTP, mật khẩu, email, public/private keys, nội dung chat hoặc ảnh base64. Các phiên đầu vào không bị đăng xuất hoặc chỉnh sửa. Bài/ảnh demo đã công bố và Direct thread được giữ để người vận hành kiểm tra; không tự xóa lịch sử.

Kịch bản dùng lại transport kiểm tra host/phiên từ [driver 2.3](../scripts/auth_publishing_e2e_23.py), nhưng không gọi quy trình cũ. Mã mới: [media_acceptance_24.py](../scripts/media_acceptance_24.py).
