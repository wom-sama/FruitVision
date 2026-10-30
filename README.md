# FruitVision

Đồ án **Lập trình trên thiết bị di động — HUTECH**: nhận diện xoài, dự đoán trạng thái xanh/chín từ hình ảnh bằng mô hình hiện có, cùng học liệu và cộng đồng trao đổi kinh nghiệm.

Bản hiện tại **2.4.0+6010**, Android 8.0 trở lên. Flutter chỉ gọi **một API HTTPS**; máy tính chạy backend, PostgreSQL và AI. Điện thoại không chứa trọng số AI hoặc kết nối CSDL trực tiếp. Kết quả có nhãn chữ, ảnh chú thích/phóng to và giới hạn rõ ràng; không thay thế kiểm tra chất lượng thực tế.

## Cài và chạy

| Nhu cầu | Tệp / hướng dẫn |
|---|---|
| APK điện thoại | [ARM64](releases/android/2.4.0/app-arm64-v8a-release.apk) · [ARM32](releases/android/2.4.0/app-armeabi-v7a-release.apk) |
| APK máy ảo | [x86_64](releases/android/2.4.0/app-x86_64-release.apk) |
| Backend, CSDL, API và môi trường AI | [Server](server/README.md) |
| Build Flutter / đổi máy chủ | [Client](mobile_client/README.md) |
| Tài khoản và bốn vai trò | [Luồng người dùng 2.4](server/docs/USER_WORKFLOWS_2_4.md) |
| Báo cáo kỹ thuật hiện tại | [Kiến trúc, dữ liệu, bảo mật, AI và tối ưu](server/docs/TECHNICAL_REPORT_2_4.md) |
| Phạm vi mô hình đang phục vụ | [Mango scope và trọng số](server/docs/mango-ai-scope-24.md) |
| Hash và nghiệm thu | [Gói 2.4](releases/android/2.4.0/) |
| Slide đã trình bày | [PDF HUTECH 23 trang](docs/presentation/AI_phan_loai_xoai_HUTECH_da_trinh_bay.pdf) |
| Phiên bản offline/desktop trước đây | [Tài liệu lưu trữ](README_OFFLINE_ARCHIVE.md) |

PC phải đang chạy API, PostgreSQL, môi trường AI và tunnel. URL thử nghiệm có thể đổi khi tunnel khởi động lại; cấu hình đúng máy chủ trong app. `localhost` trên điện thoại không phải máy tính. Mọi REST, WSS, ảnh và APK cập nhật dùng cùng origin; nguồn địa điểm/thư chỉ do backend gọi.

Tài khoản/mật khẩu demo do người vận hành cấp riêng từ `server/.local/demo-accounts.json`, không đưa lên Git/APK. Tài khoản mới luôn là Người tiêu dùng. Đăng nhập chính dùng **mật khẩu + Email OTP có tiêu đề “Mã xác thực FruitVision”**; không cần cài Authenticator cho tài khoản mới. Sinh trắc học là tùy chọn theo thiết bị; ảnh mặt 2D vẫn cần OTP.

## Vai trò và tương tác

| Vai trò | Chức năng chính trong app |
|---|---|
| **Consumer — Người tiêu dùng** | Học về xoài, bài cộng đồng có ảnh, chat/nhóm, gửi hồ sơ nâng vai trò; không chạy AI |
| **Producer — Nhà sản xuất** | AI xoài ảnh/video, hướng dẫn/thống kê, chi nhánh và bài chuyên môn đã duyệt, trao đổi |
| **Trader — Thương lái** | Các công cụ Seller tương ứng, AI và trao đổi với Nhà sản xuất/Thương lái khác |
| **Admin — Quản trị** | Xét duyệt hồ sơ nâng vai trò, chi nhánh và bài; quản lý tài khoản; không chạy AI |

Bài Community và Professional đều cần Admin công bố. Liên hệ bài đã công bố mở Direct đúng hai người. Tin/ảnh thường được máy chủ đọc và xử lý; **tin bí mật** giữa hai Seller dùng mã hóa đầu cuối trên client, khóa riêng trên thiết bị và mã an toàn phải đối chiếu trước gửi. Chưa có forward secrecy, khôi phục khóa hoặc đồng bộ nhiều thiết bị.

Không có giao dịch mua bán, thanh toán hoặc IoT. API/công cụ cung–cầu cũ được giữ tương thích trong phần thu gọn; không phải trọng tâm bản xoài mới. Số đếm video có thể sai do che khuất, quay lại hoặc camera di chuyển; hai nhãn giai đoạn nguồn không chứng minh độ chín thực địa/an toàn thực phẩm.

## Tổ chức mã nguồn

```text
mobile_client/     Flutter UI, API client, realtime, native media/Keystore/updater, crypto
server/            ASP.NET Core API, EF/PostgreSQL, migration, auth, media, AI worker
server/otp-relay/  Template relay Email OTP; không có khóa hoặc hộp thư vận hành
server/docs/       Hướng dẫn, báo cáo kỹ thuật và biên nhận API
releases/android/  APK, hash, giấy phép và phạm vi nghiệm thu theo phiên bản
models/            Model card/checkpoint/kiến trúc đã công bố
app/               Nguồn offline cũ và model/metadata/giấy phép dùng cho worker PC
demos/desktop/     Pipeline desktop lịch sử
docs/presentation/ PDF đã trình bày; giữ nguyên bản 23 trang
```

## Bằng chứng và giới hạn

Backend157 kiểm tra; Flutter110 nền và kiểm tra liên quan sau sửa; HTTPS88 kiểm tra/49 request; real-Sodium API40 quan sát; Android4 kiểm tra Keystore/ảnh. Máy ảo đã chạy đăng nhập Email OTP, học liệu Consumer, gửi ảnh xoài/nhận preview và tạo khóa Android. Bản cuối chỉ sửa thêm một dòng mô tả đăng nhập rồi build/kiểm hash lại cả ba gói. Xem [biên nhận native](releases/android/2.4.0/native-acceptance.json), [API thường](server/docs/media-https-acceptance-24.json), [crypto API](releases/android/2.4.0/secret-api-acceptance.json).

Không gọi API/máy ảo là bốn điện thoại thật, kiểm định mật mã hoặc bằng chứng AI FPS/độ chính xác thực địa. Bản hiện tại phục vụ **đồ án phi thương mại**; xem [giấy phép](LICENSE.md) và thông báo model/nguồn. Trọng số giữ nguyên, không có huấn luyện hay chưng cất mới trong lượt chuyển hệ thống này. Slide giữ nguyên là tư liệu lịch sử, không tự đại diện toàn bộ kiến trúc2.4.

Không commit `.local`, `.tools`, cache, upload riêng, DB/dump, OTP, token, khóa ký hoặc môi trường Python. Tạo cấu hình/khóa riêng khi clone. Cập nhật APK tải qua HTTPS, kiểm hash/package/version/signer rồi cần người dùng xác nhận ở trình cài Android.
