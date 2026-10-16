# Fruit Offline — Demo AI nhận diện trái cây

Ứng dụng Android xử lý ảnh, video và camera trực tiếp ngay trên thiết bị: phát hiện nhiều quả, hiển thị mức chín quan sát được cho loài được hỗ trợ và thống kê số đếm theo phiên. Repository cũng giữ demo desktop V18.6 để tham khảo pipeline phân loại xoài bằng Python.

Bản Android bàn giao: **1.3.5+5009**, Android **8.0 / API 26** trở lên. Mô hình đã đóng gói trong APK; khi sử dụng không cần Python, máy chủ, tài khoản hay kết nối Internet. Đây là demo nghiên cứu/học thuật phi thương mại.

## Bắt đầu

| Bạn muốn làm gì? | Tài liệu / tệp cần mở |
| --- | --- |
| Cài trên điện thoại, không biên dịch | [Hướng dẫn cài Android](docs/INSTALL_ANDROID.md#cài-apk-có-sẵn) |
| Tải APK phù hợp | [ARM64](releases/android/1.3.5/app-arm64-v8a-release.apk) · [ARM32](releases/android/1.3.5/app-armeabi-v7a-release.apk) · [x86_64](releases/android/1.3.5/app-x86_64-release.apk) |
| Mở mã nguồn bằng Android Studio / tự build | [Môi trường và cách build Android](docs/INSTALL_ANDROID.md#biên-dịch-từ-mã-nguồn) |
| Chạy demo Python trên máy tính | [Hướng dẫn desktop](docs/INSTALL_DESKTOP.md) |
| Tìm hiểu các thành phần | [Kiến trúc](docs/ARCHITECTURE.md) · [Mô hình Android](models/android/model-card.md) |
| Xem tối ưu và phạm vi kiểm chứng | [Tối ưu đã áp dụng](docs/optimizations/README.md) · [Bằng chứng bản 1.3.5](releases/android/1.3.5/) |
| Xem kiểm tra gói mã nguồn nộp bài | [Kiểm tra submission](docs/SUBMISSION_CHECKS.md) |
| Xem tài liệu đã thuyết trình | [PDF HUTECH đã trình bày](docs/presentation/AI_phan_loai_xoai_HUTECH_da_trinh_bay.pdf) |

Phần lớn điện thoại Android hiện nay dùng APK **ARM64**. Mở tệp APK trên GitHub rồi chọn tải tệp gốc; hướng dẫn Android giải thích cách xác định ABI, cấp quyền cài đặt và xử lý lỗi cập nhật.

## Chức năng và phạm vi

- **Ảnh:** chọn ảnh, chụp ảnh hoặc dùng ảnh mẫu; xem các khung phát hiện và kết quả từng quả.
- **Video:** đọc các khung tuần tự, cập nhật kết quả và số đếm; hỗ trợ hủy xử lý. Mỗi video tối đa 10 phút.
- **Camera trực tiếp:** xem preview và kết quả AI trên thiết bị; tần suất phân tích thực phụ thuộc phần cứng và nhiệt độ.
- **Đếm theo phiên / qua vạch:** theo dõi ID bằng hình học; có thể chọn chiều và vị trí vạch cho video/camera cố định.
- **Phân mức có giới hạn:** bản Android hiện tại hỗ trợ chuối và xoài với hai nhãn nguồn `Xanh / chưa chín`, `Chín`. Nhóm quả chung/chưa hỗ trợ có thể được phát hiện, nhưng giữ trạng thái **chưa phân mức**.

Số quả trong một ảnh, tổng ID theo phiên và lượt qua vạch là các đại lượng khác nhau. Che khuất lâu, quả đi ra rồi quay lại, quả chạm nhau hoặc camera di chuyển có thể gây mất ID, đếm thiếu hoặc đếm lại. Chưa có ground truth quỹ đạo để xác nhận sản lượng duy nhất; không quy đổi số đếm thành kg. Mức chín quan sát trên vỏ không phải kết luận an toàn thực phẩm.

## Hai demo dùng hai pipeline khác nhau

| | Android `app/` | Desktop `demos/desktop/` |
| --- | --- | --- |
| Mục đích | Demo nhiều quả trên điện thoại | Giữ pipeline xoài V18.6 trên máy tính |
| Pipeline chính | YOLOX-Tiny ONNX → hậu xử lý → tracking/đếm | Grounding DINO → SAM → ViT-B/16 + delta V18.6 |
| Đối tượng mỗi khung | Nhiều quả, tối đa 64 kết quả sau chọn lọc | Một quả chính được chọn |
| Nhãn phân mức | 2 mức cho chuối/xoài được hỗ trợ | 5 lớp xoài của checkpoint V18.6 |
| Môi trường | Flutter, Kotlin/C++, ONNX Runtime Android | Python 3.11, PyTorch, Transformers |
| Offline | Ngay sau khi cài APK | Sau khi cài thư viện và tải đủ model một lần |

Không dùng accuracy/F1 của desktop để đại diện cho Android. Script desktop hiện chạy suy luận và xuất kết quả, không huấn luyện hay tự tính lại accuracy/F1.

## Cấu trúc repository

```text
fruit-offline-mobile-demo/
├── README.md
├── app/                           # Mã nguồn Flutter + Android bản 1.3.5
│   ├── lib/                       # Giao diện, tracking và bộ đếm
│   ├── test/                      # Kiểm thử Flutter/Dart
│   └── android/app/src/
│       ├── main/assets/           # ONNX, metadata, ảnh mẫu, nguồn/giấy phép
│       ├── main/kotlin/           # Decode, camera, inference Android
│       ├── main/cpp/              # Tiền xử lý và chuyển đổi pixel native
│       ├── test/                  # Kiểm thử JVM
│       └── androidTest/           # Kiểm thử trên thiết bị/máy ảo Android
├── models/android/                # Kiến trúc PyTorch, checkpoint, model card, test/export
├── demos/desktop/                 # Demo Python, setup, notebook và delta V18.6
├── releases/android/1.3.5/         # Ba APK, hash và bằng chứng phát hành
└── docs/
    ├── INSTALL_ANDROID.md
    ├── INSTALL_DESKTOP.md
    ├── ARCHITECTURE.md
    ├── optimizations/README.md
    └── presentation/              # PDF đã thuyết trình
```

Graph Android nằm trực tiếp tại [`app/android/app/src/main/assets/mango_detector.onnx`](app/android/app/src/main/assets/mango_detector.onnx), không bị nhân bản sang `models/android/`. [Mã kiến trúc và checkpoint PyTorch](models/android/README.md) cho phép dựng lại và kiểm tra graph; không cần Python để cài/build app. Demo desktop tự tải backbone ViT và snapshot DINO/SAM được khóa phiên bản trong bước setup; repository không yêu cầu Git LFS.

## Công nghệ và kết quả kiểm chứng

Bản Android dùng Flutter **3.47.5**, Dart **3.13.4**, Kotlin và C++ qua JNI, CameraX, MediaCodec và ONNX Runtime Android **1.31.0**. Đồ thị chạy thực tế là YOLOX-Tiny **FP32, 20.307.691 byte**; chế độ hiện tại không dùng MangoStudent cũ, chưng cất kiến thức, INT8, GPU/NPU, server hay IoT.

Bộ bằng chứng bàn giao 1.3.5 ghi nhận **147 kiểm thử Flutter**, **92 kiểm thử JVM** và **29 kiểm thử Android debug** đạt. APK release đã cài và chạy offline trên máy ảo Pixel 8 API 37; video kiểm tra hoàn tất 1.073 khung. Đây là kết quả kiểm tra đã lưu cùng bản phát hành, không phải cam kết mọi môi trường clone đều đã chạy lại các kiểm thử này. Xem [tài liệu kiểm tra phát hành](releases/android/1.3.5/KIEM_TRA_PHAT_HANH.md).

Thay đổi 1.3.5 giảm độ trễ phân tích đầu và cấp phát bộ nhớ. **Chưa đạt mục tiêu 30 FPS, chưa kiểm chứng hiệu năng điện thoại vật lý**, chưa chứng minh tăng throughput trong điều kiện đối chứng. Các candidate INT8 đã thử không giữ được kiểm tra chất lượng nên không được phát hành. [Tài liệu tối ưu](docs/optimizations/README.md) phân biệt cơ chế đã có, phép đo và giới hạn.

## Tài liệu và nguồn gốc

PDF trong `docs/presentation/` là tài liệu HUTECH **đã trình bày**, được giữ làm bối cảnh học thuật. Để xác định hành vi và model của ứng dụng bàn giao, đọc model card, hướng dẫn cài và tài liệu bản 1.3.5; các pipeline/số liệu lịch sử trong bài trình bày không tự động áp dụng cho bản Android hiện tại.

Nguồn và điều kiện sử dụng model/dữ liệu được ghi tại [LICENSE.md](LICENSE.md), [`SOURCE_ATTRIBUTION.json`](app/android/app/src/main/assets/SOURCE_ATTRIBUTION.json) và [`YOLOX_LICENSE.txt`](app/android/app/src/main/assets/YOLOX_LICENSE.txt). Các thành phần bên thứ ba giữ giấy phép của chúng; việc có mã nguồn công khai không thay thế điều kiện sử dụng của model và dữ liệu kết hợp. [Các repository tham khảo](docs/REFERENCES.md) chỉ là tham khảo cách tổ chức bài nộp.
