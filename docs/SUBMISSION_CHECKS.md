# Kiểm tra gói mã nguồn nộp bài — 16/10/2026

Gói nộp dùng **APK 1.3.5+5009 đã phát hành**, không tạo một bản APK hay một model mới. Không đưa nhánh preview video còn đang phát triển vào mã nguồn công bố.

## Kiểm tra mới trên bản nguồn đã đóng gói

| Kiểm tra | Kết quả | Phạm vi |
| --- | --- | --- |
| `flutter pub get --offline` | Thành công với cache có sẵn | Không phải lần tải phụ thuộc sạch trên máy mới |
| `flutter analyze` | Không có issue | Mã Flutter trong gói nộp |
| `flutter test --no-pub --concurrency=1` | **147 tests đạt** | Logic/UI/tracking/hợp đồng; không phải độ chính xác thực địa |
| Desktop `python -m unittest test_demo test_prepare_models -v` | **11 tests đạt** | Logic media và tải/kiểm hash; test mạng dùng mock |
| Android model `python -m unittest test_model -v` | **1 test đạt** | Nạp strict 5.034.030 tham số, so PyTorch/ONNX trên một tensor xám; không phải cả dataset |
| Đối chiếu artifact | Hash model/checkpoint, ba APK và PDF khớp nguồn đã chọn | Bảo toàn đúng bytes, không suy ra chất lượng AI |
| Kiểm tra công bố cục bộ | Không phát hiện token/private key theo các mẫu đã rà; liên kết Markdown nội bộ tồn tại | Không thay thế một kiểm toán bảo mật toàn diện |

Các test Python mới chạy trong môi trường Python 3.11 đã cài sẵn thư viện; chưa tuyên bố đã cài mới toàn bộ thư viện/model desktop từ Internet trên một máy sạch. Model công khai lớn không nằm trong Git; setup tải đúng phiên bản và kiểm hash.

## Bằng chứng Android phát hành đã lưu

[Thư mục 1.3.5](../releases/android/1.3.5/verification/) giữ receipt đóng gói, golden ảnh, decoder/camera, benchmark và UI offline. 92 tests JVM/29 tests Android trong tài liệu phát hành là bằng chứng **của bản phát hành trước khi đóng gói repo**, không phải một lượt mới trên clone. Các APK được kiểm hash để bảo đảm không bị thay đổi.

PDF hiện tại là [bản HUTECH phục dựng đầy đủ 23 trang](presentation/README.md), thay bản 12 trang bị thiếu theo yêu cầu cập nhật ngày 16/10/2026. Giữ nguyên 12 trang đã chỉnh sửa và bổ sung 11 trang thiếu, không dùng lại toàn bộ bản cũ 24 trang. Lần thay slide này không đổi APK, model hoặc mã nguồn ứng dụng. Dữ liệu huấn luyện đầy đủ, cache, môi trường Python/Flutter/Android SDK, khóa ký cá nhân và tệp đường dẫn riêng không được commit. Gradle wrapper được giữ để clone có thể build theo [hướng dẫn Android](INSTALL_ANDROID.md).

## Không nâng phạm vi kết luận

Chưa đạt 30 FPS, chưa kiểm chứng điện thoại vật lý, chưa có ground truth quỹ đạo đếm sản lượng và chưa xác nhận mọi lỗi đơ/nhầm độ chín đã hết. Xem [tối ưu và giới hạn](optimizations/README.md). Phát hành repository này không thay đổi những giới hạn đó.
