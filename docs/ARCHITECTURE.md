# Kiến trúc và luồng xử lý

Repository gồm hai ứng dụng độc lập. Android là bản nhiều quả chạy trên thiết bị; desktop giữ pipeline phân loại một quả xoài chính V18.6. Chúng không gọi lẫn nhau và không dùng chung hợp đồng nhãn hay thước đo chất lượng.

## Android 1.3.5

```text
Ảnh / video / CameraX
        ↓
Kotlin: decode, hướng ảnh, chuyển đổi pixel
        ↓
C++/Kotlin: resize + letterbox + RGB → tensor FP32 [1,3,480,480]
        ↓
Một session ONNX Runtime CPU: mango_detector.onnx
        ↓
Lọc score + NMS + quy đổi hộp về ảnh gốc
        ↓
Flutter: overlay / kết quả từng quả / tracking / thống kê đếm
```

Flutter chịu trách nhiệm giao diện và trạng thái thao tác. `MethodChannel` chuyển yêu cầu sang Android; kết quả camera dùng luồng sự kiện. Kotlin quản lý media, quyền sở hữu tài nguyên và một worker inference riêng, tránh chạy suy luận trên UI thread. CameraX quản lý camera/preview. MediaExtractor/MediaCodec đọc video tuần tự theo timestamp; app không cần máy chủ hoặc thiết bị IoT.

Model được đóng gói trong `app/android/app/src/main/assets/`, sao chép vào vùng riêng của app và đối chiếu SHA-256 trước khi tạo session. Bản hiện tại đọc `detector_metadata.json` ở chế độ `direct_fruit_stages`: **một graph YOLOX-Tiny FP32** trả về hộp, score, loài và hai mức nguồn. Các đường mã/asset MangoStudent lịch sử không phải model phân mức đang chạy trong chế độ này.

Tiền xử lý giữ đúng hợp đồng model: RGB chuẩn hóa về 0–1, letterbox giữa ảnh, padding `(128,128,128)`, quy tắc resize `floor`, tensor NCHW 480 × 480. Hậu xử lý dùng score **0,35**, NMS không phân biệt lớp với IoU **0,5**, tối đa **64** đối tượng được chọn. Đây là giới hạn kết quả, không phải cam kết phát hiện đúng 64 quả trong mọi cảnh.

### Ảnh, video và camera

| Nguồn | Cách xử lý | Điểm cần hiểu |
| --- | --- | --- |
| Ảnh | Decode có giới hạn kích thước, chuẩn hóa EXIF, phân tích một ảnh | Số hộp là số phát hiện tại ảnh đó |
| Video | Đọc và phân tích khung tuần tự; tối đa 10 phút; có thể hủy | Preview có thể cập nhật thưa hơn AI; FPS xử lý không phải FPS nguồn |
| Camera | Preview riêng; analyzer dùng `KEEP_ONLY_LATEST`, giới hạn tần suất và điều chỉnh theo nhiệt | Chủ động bỏ khung camera cũ để tránh hàng đợi; không hứa phân tích mọi khung camera |

Session, tensor đầu vào và các buffer được tái sử dụng. Decoder video giữ một bitmap cùng kích thước, trả quyền sử dụng sau mỗi khung và giải phóng khi đóng decoder. Kết quả/chỉ số hiển thị được giới hạn để không tích lũy toàn bộ ảnh hoặc log từng khung trong bộ nhớ. [Tài liệu tối ưu](optimizations/README.md) ghi chi tiết và bằng chứng đo.

### Tracking và đếm

`fruit_tracking.dart` ghép các hộp giữa các thời điểm bằng hình học/IoU và chuyển động, giữ ID và phiếu nhãn trong phiên. Chỉ ID được xác nhận mới tham gia thống kê. Danh sách ID còn hoạt động phục vụ ghép; lịch sử được giữ riêng để bảo toàn số đếm. Đây chưa phải mô hình tái nhận diện quả vật lý.

`fruit_line_counter.dart` đếm khi một ID đã xác nhận chuyển ổn định qua vạch theo chiều chọn. Một ID được đếm tối đa một lần trong phiên; vùng dung sai và quan sát ổn định giảm đếm do rung hộp quanh vạch. ID mới sau che khuất/đi ra rồi quay lại vẫn có thể bị đếm lại. Di chuyển camera hoặc đổi cấu hình vạch làm thay đổi ý nghĩa phép đếm; nên bắt đầu phiên mới với cấu hình cố định.

Loài/độ chín được lấy từ kết quả model và chính sách phân mức, không suy từ vị trí hoặc việc đi qua vạch. Quả chung/chưa hỗ trợ có thể được đếm nhưng không được gán mức chín. Không suy ra khối lượng, năng suất hoặc an toàn thực phẩm từ bộ đếm.

## Desktop V18.6

```text
input/ (ảnh hoặc các khung video được lấy mẫu)
        ↓
Grounding DINO tiny: chọn một quả chính
        ↓
SAM ViT base: tạo mask
        ↓
Tiền xử lý ảnh/mask + thống kê màu/patch theo notebook nguồn
        ↓
torchvision ViT-B/16 + delta V18.6: 5 lớp xoài
        ↓
output/: ảnh/video có overlay + JSON/JSONL + mask
```

`setup.py` tạo môi trường Python 3.11 và gọi `prepare_models.py`. Bước chuẩn bị tải backbone ViT từ PyTorch, hai snapshot Hugging Face khóa revision và kiểm tra hash. Delta V18.6 cùng notebook nguồn được giữ trong repository; `recover_demo.py` dựng kiến trúc và nạp đúng delta trên backbone công khai. Notebook là thành phần cần thiết của bộ chạy, không chỉ tài liệu tùy chọn.

`demo.py` chỉ chạy suy luận từ model cục bộ. Video mặc định lấy mẫu AI khoảng 2 lần/giây theo bước khung nguồn, xuất các khung video đã giải mã với kết quả mẫu gần nhất; không tracking, không giữ âm thanh. Nếu không phát hiện quả chính, kết quả không tự tạo hộp hay nhãn phân lớp.

## Phạm vi kiểm thử và tái lập

- `app/test/`: trạng thái/giao diện Flutter, overlay, tracking, đếm và hợp đồng dữ liệu.
- `app/android/app/src/test/`: toán học, chính sách tài nguyên và hợp đồng native trên JVM.
- `app/android/app/src/androidTest/`: decoder, inference, camera và vòng đời trên Android.
- `demos/desktop/test_demo.py`: logic phát hiện tệp, lịch lấy mẫu, media/output và kiểm tra artifact; một số kiểm tra thay phần gọi AI chậm bằng fake.
- `demos/desktop/verify_portability.py`: suy luận thật sau khi di chuyển thư mục; không chứng minh một lần cài phụ thuộc sạch trên mọi hệ điều hành.

Bằng chứng phát hành nằm tại [`releases/android/1.3.5/`](../releases/android/1.3.5/). Số đo máy ảo, phép thử một clip và kiểm tra đóng gói cần được đọc đúng phạm vi. Đánh giá độ chính xác đa quả, đếm quỹ đạo, pin/nhiệt dài hạn và hiệu năng điện thoại thật vẫn cần dữ liệu/thiết bị thực tế.
