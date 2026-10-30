# FruitVision

Đồ án **Lập trình trên thiết bị di động — HUTECH**: nền tảng nông sản bốn vai trò, tin cung/cầu dự kiến, trao đổi thời gian thực và phân tích ảnh/video bằng AI trên PC.

Client hiện tại: **2.2.0+6006**, Android 8.0 trở lên. Flutter chỉ gọi **API HTTPS**; tài khoản, CSDL và AI nằm trên PC. Điện thoại không cần Python hay trọng số AI. Bản offline cũ ở `app/` được giữ để bảo toàn nguồn gốc.

## Bắt đầu

| Nhu cầu | Tệp / hướng dẫn |
|---|---|
| Cài Android | [ARM64](releases/android/2.2.0/app-arm64-v8a-release.apk) · [ARM32](releases/android/2.2.0/app-armeabi-v7a-release.apk) · [x86_64](releases/android/2.2.0/app-x86_64-release.apk) |
| Chạy backend và CSDL | [Server](server/README.md) · [Cài từ clone mới](server/docs/RELEASE_2_2_INTERACTIONS.md) |
| Build client / đổi máy chủ | [Flutter client](mobile_client/README.md) |
| Demo bốn vai trò | [Luồng demo](server/docs/DEMO_4_ROLES_2_2.md) |
| Kiến trúc và API | [Luồng hệ thống](docs/ARCHITECTURE_SERVER.md) · [Hợp đồng](server/docs/POST_COMMUNITY_CONTRACT.md) |
| Cập nhật APK trong app | [Hướng dẫn phát hành](server/docs/MOBILE_RELEASES.md) |
| Slide đã trình bày | [PDF HUTECH 23 trang](docs/presentation/AI_phan_loai_xoai_HUTECH_da_trinh_bay.pdf) |
| Offline / desktop trước đây | [Tài liệu lưu trữ](README_OFFLINE_ARCHIVE.md) |

PC phải chạy API, PostgreSQL, worker AI và tunnel HTTPS. Điện thoại cần mạng và đúng URL máy chủ; `localhost` trên điện thoại không phải PC. Hostname tunnel tạm có thể thay đổi khi khởi động lại. Tài khoản/mật khẩu demo được sinh riêng trong `server/.local/demo-accounts.json`; người vận hành cấp riêng, không đưa lên Git/APK.

## Vai trò

| Vai trò | Chức năng |
|---|---|
| **Admin — Quản trị** | Duyệt hồ sơ; khóa/mở tài khoản; duyệt, từ chối, công bố hoặc tạm dừng bài; xem số liệu hệ thống. |
| **Producer — Nhà sản xuất** | Đăng nguồn cung dự kiến, theo dõi duyệt; khám phá tin và trao đổi với thương lái/người dùng. |
| **Trader — Thương lái** | Đăng nhu cầu thu mua hoặc nguồn cung; xem thông tin vùng và mở hội thoại từ tin. |
| **Consumer — Người tiêu dùng** | Đọc tin công khai, giá chào bán tham khảo theo vùng, liên hệ người đăng và tham gia cộng đồng. |

Tài khoản hoạt động đã duyệt có thể tạo/tham gia nhóm và phân tích ảnh/video. API kiểm quyền mỗi yêu cầu; ẩn nút không thay thế phân quyền. Tin mới phải được Admin công bố mới xuất hiện công khai.

Giá tham khảo lấy từ **bài chào bán**, có vùng/số mẫu/thời điểm; không phải dự đoán AI hoặc giá giao dịch. Kg do người đăng khai là dự kiến; chưa có tồn kho, đơn hàng, thanh toán hay IoT.

## Cấu trúc và công nghệ

```text
server/            ASP.NET Core API, PostgreSQL, worker AI, migration, seed, tests
mobile_client/     Flutter client, native media/session/updater
releases/android/  APK theo phiên bản, hash và biên nhận nghiệm thu
docs/              Kiến trúc, slide và tài liệu kỹ thuật
app/               Offline cũ; giữ model/metadata/giấy phép cho worker PC
models/            Kiến trúc/checkpoint và model card đã công bố
demos/desktop/     Pipeline desktop V18.6 trước đây
```

Flutter/Dart → HTTPS REST / SignalR WSS → ASP.NET Core 10 → EF Core/Npgsql/PostgreSQL. API dùng Identity, phiên opaque, refresh rotation, MFA TOTP tùy chọn, kiểm dữ liệu/quyền và giới hạn yêu cầu. Python + ONNX Runtime chạy YOLOX-Tiny FP32 trên CPU PC. APK không nối trực tiếp CSDL hoặc Python.

Cập nhật trong app tải HTTPS vào cache riêng, đối chiếu SHA-256, package, version và signer rồi mở trình cài Android. **Cần người dùng xác nhận**; client cũ chưa có updater cần cài bản mới một lần. Thay đổi backend tương thích không cần cập nhật APK.

## Phạm vi kiểm chứng

Đọc biên nhận cùng APK để phân biệt unit/integration, HTTP/WSS thật, thao tác máy ảo và điện thoại. Bốn client mạng đồng thời không được gọi là bốn điện thoại đã kiểm thử. AI hỗ trợ ảnh và MP4 có giới hạn; chưa truyền camera liên tục lên server. Tracking có thể đếm lại khi che khuất/quay lại hoặc camera di chuyển; không bảo đảm sản lượng duy nhất, kg, độ ngọt hoặc an toàn thực phẩm.

Không công bố `.local`, `.tools`, DB/dump, secret, khóa ký, upload riêng hay môi trường Python. Hướng dẫn tạo môi trường riêng từ clone, không phụ thuộc ổ đĩa người phát triển. Đây là đồ án **phi thương mại**; xem [LICENSE.md](LICENSE.md), [model card](models/android/model-card.md) và các thông báo nguồn trong `app/android/app/src/main/assets/`. PDF 23 trang giữ nguyên; nội dung lịch sử trong slide không tự đại diện cho kiến trúc mới.

