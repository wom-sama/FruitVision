# FruitVision

Đồ án **Lập trình trên thiết bị di động — HUTECH**: ứng dụng học về xoài, cộng đồng chia sẻ kinh nghiệm, nhận diện xoài và dự đoán trạng thái xanh/chín bằng mô hình hiện có.

Client hiện tại **2.6.2+6014**, backend **2.6**. Flutter gọi **một API HTTPS**; PostgreSQL và AI chạy trên PC. Realtime dùng SignalR WSS cùng origin. APK không chứa trọng số AI và không kết nối trực tiếp CSDL. Kết quả có nhãn chữ và ảnh chú thích; không thay thế kiểm tra chất lượng thực tế.

## Mã nguồn và cài đặt

| Thành phần | Đường dẫn |
|---|---|
| Frontend Flutter / Android | **[mobile_client/](mobile_client/README.md)** — cấu hình, build, API client và native media/Keystore |
| Backend, CSDL và API | **[server/](server/README.md)** — ASP.NET Core, PostgreSQL, auth, realtime và AI worker |
| APK mới nhất, gồm Android 32 bit | [GitHub Release 2.6.2](https://github.com/wom-sama/FruitVision/releases/tag/v2.6.2) |
| Hash, phạm vi kiểm chứng và hạn chế bản mới | [Gói 2.6.2](releases/android/2.6.2/README.md) |
| Vai trò, thao tác demo và kết quả kiểm tra | [28 thao tác theo bốn vai trò](server/docs/DEMO_10_PHUT_4_VAI_TRO.md) |
| Công nghệ và giới hạn đã triển khai | [Tổng hợp hiện tại](server/docs/VAI_TRO_THAO_TAC_CONG_NGHE_2_6_1.md) |
| Báo cáo nền tảng hệ thống | [Kiến trúc, dữ liệu, bảo mật và AI bản 2.4](server/docs/TECHNICAL_REPORT_2_4.md) — tài liệu lịch sử, đọc cùng tổng hợp hiện tại |
| Slide đã trình bày | [PDF HUTECH 23 trang](docs/presentation/AI_phan_loai_xoai_HUTECH_da_trinh_bay.pdf) |

Clone repo rồi làm theo hướng dẫn tương ứng:

```sh
git clone https://github.com/wom-sama/FruitVision.git
cd FruitVision
```

1. **PC:** cài môi trường và khởi động PostgreSQL/API theo [server/README.md](server/README.md). Cài riêng môi trường Python nếu cần bật AI; installer kiểm model và các gói đã ghim. Cấu hình riêng được tạo trên máy triển khai.
2. **HTTPS:** chạy tunnel theo hướng dẫn server; địa chỉ được ghi vào tệp local `server/PUBLIC_URL.txt`. Máy chủ và tunnel cần tiếp tục chạy. `localhost` trên điện thoại không trỏ về PC.
3. **Android:** dùng APK đã công bố để kết nối hệ thống demo hiện tại, hoặc build từ [mobile_client/README.md](mobile_client/README.md) với địa chỉ HTTPS của máy triển khai. Flutter dùng một origin cho REST, WSS, ảnh và cập nhật APK. Các API địa điểm/email do backend gọi.

Địa chỉ demo ngày 31/10/2026: [trang API và nhóm chức năng CRUD](https://vip-certainly-broke-lease.trycloudflare.com/index.html), [Swagger](https://vip-certainly-broke-lease.trycloudflare.com/v1/index.html). Đây là **Quick Tunnel tạm**, có thể đổi hoặc ngừng khi PC/tunnel tắt. Xem [lưu ý sau reboot](server/docs/RESTART_2_6_2.md). Đây chưa phải dịch vụ 24/7 hoặc hostname cố định.

Tài khoản/mật khẩu demo được người vận hành cấp riêng. Repo không chứa DB người dùng, mật khẩu, OTP, token, khóa relay hoặc khóa ký riêng. Tài khoản mới luôn là Người tiêu dùng; đăng nhập chính bằng mật khẩu và Email OTP. Sinh trắc học là tùy chọn theo thiết bị, ảnh mặt 2D vẫn cần OTP. Hướng dẫn build nêu rõ khóa ký riêng và giới hạn nâng cấp giữa các máy.

## Bốn vai trò

| Vai trò | Chức năng hiện có |
|---|---|
| **Consumer — Người tiêu dùng** | Học liệu/quiz xoài, bài Community có ảnh chờ duyệt, thích/bình luận, hộp thư và nhóm, hồ sơ/quyền riêng tư/chặn; gửi hồ sơ xin nâng Producer hoặc Trader. Không chạy AI. |
| **Producer — Nhà sản xuất** | Cơ sở sản xuất được duyệt, bài Professional, AI xoài ảnh/video/camera trực tiếp, lịch sử/thống kê, trao đổi thường và mã hóa đầu cuối với Seller khác. |
| **Trader — Thương lái** | Cơ sở kinh doanh được duyệt, bài Professional, AI xoài, liên hệ tác giả và Nhà sản xuất/Thương lái khác, hộp thư/nhóm và E2EE. |
| **Admin — Quản trị** | Duyệt hồ sơ/cơ sở/bài, quản lý tài khoản, bổ nhiệm Consumer đủ điều kiện thành Admin, tạo/đóng nhóm. Không chạy AI hoặc tham gia chat E2EE. |

Người dùng thấy hộp thư và số chưa đọc; từ bài được công bố có thể mở Direct với tác giả. Tin/ảnh thường do máy chủ xử lý, ảnh có xem trước/phóng to. Tin bí mật thuộc Direct giữa hai Seller, dùng libsodium trên client và cần đối chiếu mã an toàn trước gửi. Server giữ bản mã, không giữ private key. Chưa có forward secrecy, phục hồi khóa hoặc đồng bộ nhiều thiết bị; đổi origin có thể cần thiết lập lại thiết bị E2EE.

Hai khu vực Community/Professional cùng cần Admin công bố. Chỉ Admin tạo/đóng nhóm. Hồ sơ chia thông tin công khai/riêng tư và có chặn liên hệ. Xem chi tiết quyền và luồng ở [hướng dẫn server](server/README.md).

## Công nghệ và cấu trúc

- **Client:** Flutter/Dart, HTTP/SignalR, CameraX, Android Keystore/BiometricPrompt, libsodium; APK updater kiểm hash/package/version/chứng thư trước khi chuyển sang trình cài Android để người dùng xác nhận.
- **Server:** ASP.NET Core .NET 10, EF Core/Npgsql, PostgreSQL, session opaque xoay refresh token, Email OTP qua relay HMAC riêng, kiểm quyền phía API, validation/rate limit/quota và outbox realtime.
- **AI trên PC:** Python, ONNX Runtime CPU FP32, YOLOX-Tiny đầu vào 480; xử lý ảnh/video/live và theo dõi hình học. Mô hình/ngưỡng giữ nguyên trong đợt chuyển hệ thống, không có huấn luyện/chưng cất mới để mô tả như thành quả của bản này.

```text
mobile_client/     Frontend hiện tại: UI bốn vai trò, API client, realtime, native/crypto
server/            Backend hiện tại: API, EF/migrations, auth, media, realtime, worker AI
server/otp-relay/  Mẫu Email OTP relay; không có khóa hoặc hộp thư vận hành
server/docs/       Hướng dẫn, công nghệ, thao tác demo và receipt đã được công khai
releases/android/  Hash/tài liệu các phiên bản; APK 2.6.2 tại GitHub Releases
models/            Model card/checkpoint/kiến trúc đã công bố
app/               App offline lịch sử; có model/metadata/giấy phép worker PC đang dùng
demos/desktop/     Pipeline desktop lịch sử
docs/presentation/ PDF đã trình bày, giữ nguyên bản 23 trang
```

Phần offline/desktop được giữ để đối chiếu nguồn mô hình; xem [tài liệu lưu trữ](README_OFFLINE_ARCHIVE.md). **Ứng dụng hiện tại nằm ở `mobile_client/`, API ở `server/`.**

## Kiểm chứng và giới hạn

- Backend 2.6: **204/204 kiểm thử**. Flutter 6014: **174/174**, analyzer không báo lỗi. Đây là kiểm thử phần mềm trong phạm vi ghi nhận, không phải nghiệm thu bốn điện thoại.
- Nghiệp vụ HTTPS: [175 điểm kiểm tra/112 request](server/docs/demo-actions-https-acceptance-31.json). Có quan sát APK các luồng học tập, minh chứng Admin, nhóm, ảnh và chat; không cộng số kiểm tra các lớp để gọi là đạt toàn bộ hệ thống.
- Gói 6014: kiểm phiên bản, ba kiến trúc, chữ ký, quyền, hostname và không chứa model AI; tải trọn ARM64 qua HTTPS khớp SHA, hai bản còn lại đã kiểm metadata/range. Xem [receipt công khai](releases/android/2.6.2/README.md). Chưa chạy lại giao diện trên điện thoại/máy ảo cho 6014.
- **AI chưa đạt chất lượng mọi tình huống:** video băng chuyền giống táo đã bị nhận thành xoài/Chín. Không dùng video đó làm minh chứng nhận diện đúng. Một [tác vụ ảnh sau reboot](server/docs/post-restart-mango-smoke-6014.json) chỉ xác nhận luồng kỹ thuật. Camera máy ảo 6012 từng ghi nhận **4,85 AI FPS**, chưa chứng minh 6 FPS, bốn máy đồng thời hoặc hiệu năng máy thật.
- Số thấy đồng thời, track và số qua vạch là các đại lượng khác nhau; che khuất/quay lại/camera di chuyển có thể làm sai đếm. Nhãn xanh/chín là trạng thái nguồn, không bảo đảm độ chín bên trong hay an toàn thực phẩm. Không có giao dịch mua bán, thanh toán hoặc IoT.

Bản hiện tại phục vụ **đồ án phi thương mại**; giữ [giấy phép và giới hạn nguồn](LICENSE.md). Slide 23 trang là tư liệu đã trình bày, không tự đại diện đầy đủ kiến trúc client–server mới.

Không commit `.local`, `.tools`, media riêng, DB/dump, cache, OTP/token/khóa ký hoặc môi trường Python. Khi clone, tạo cấu hình và khóa riêng theo hướng dẫn từng thành phần.
