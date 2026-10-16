# Tối ưu đã áp dụng và giới hạn kiểm chứng

Tài liệu này mô tả **bản Android 1.3.5+5009**. Model đang chạy là YOLOX-Tiny FP32, đầu vào 480 × 480, graph **20.307.691 byte**, khoảng 5,03 triệu tham số. Mục tiêu của lần sửa 1.3.5 là giảm chờ ở lần phân tích đầu và chi phí cấp phát/vòng đời bộ nhớ video; mô hình, ngưỡng và số khung AI của video giữ nguyên.

## Cơ chế có trong bản bàn giao

| Cơ chế | Tác dụng và phạm vi |
| --- | --- |
| Một session ONNX Runtime CPU | Bỏ tạo/thử CPU4, NNAPI, XNNPACK ngay trước lượt phân tích đầu; không có bước dò provider chặn mỗi phiên |
| Worker inference riêng, xử lý tuần tự | Tách decode/inference khỏi UI thread và tránh nhiều lượt AI cạnh tranh tài nguyên |
| Tái sử dụng tensor/map/mảng kết quả | Giảm cấp phát lại dữ liệu đầu vào và buffer output theo từng khung |
| C++/JNI tiền xử lý và chuyển đổi pixel | Resize/letterbox/đóng gói RGB và chuyển đổi YUV trên native; giữ quy tắc tiền xử lý và kiểm tra parity |
| Bitmap decoder video được tái sử dụng | Giữ một bitmap cùng kích thước; frame mượn pixel và trả quyền sử dụng, decoder giải phóng khi đóng |
| Giới hạn 1–2 luồng CPU | Dựa trên số core; chọn 1 khi Android báo low-RAM, lowMemory hoặc RAM khả dụng dưới 256 MiB |
| Tắt thread spinning của ORT | Hạn chế CPU bận chờ khi không có tác vụ; không tự xem đây là phép đo tiết kiệm pin |
| Chỉ ghép ID tracking còn hoạt động | Tránh quét toàn bộ lịch sử ID mỗi khung; giữ lịch sử/phiếu nhãn/số đếm |
| Giới hạn dữ liệu hiển thị | Timeline video giữ tối đa 12 điểm; thống kê camera dùng cửa sổ cố định, không giữ log/ảnh vô hạn |
| CameraX `KEEP_ONLY_LATEST` và giới hạn tần suất | Bỏ khung camera cũ/đến quá sớm để tránh hàng đợi; điều chỉnh tần suất khi nóng và dừng ở mức nhiệt nghiêm trọng |

Tối ưu camera có bỏ khung theo chính sách. Video đọc khung tuần tự theo hợp đồng riêng; preview cập nhật thưa không đồng nghĩa bỏ khung AI. Không gộp hai cơ chế này thành tuyên bố “mọi khung camera/video đều được xử lý”.

## Số đo đã lưu cho 1.3.5

Nguồn: [ghi chú phát hành](../../releases/android/1.3.5/RELEASE_1.3.5.md), [báo cáo kiểm tra](../../releases/android/1.3.5/KIEM_TRA_PHAT_HANH.md) và các receipt trong [thư mục bản phát hành](../../releases/android/1.3.5/).

| Phép kiểm tra | Kết quả được ghi | Kết luận được phép rút ra |
| --- | --- | --- |
| Lần phân tích đầu trên máy ảo | 3.456,72 ms → 168,19 ms; bước dò provider cũ chiếm 3.374,62 ms | Giảm stall khởi đầu trong phép thử đó |
| Native pipeline video | 1.073 khung / 109,18 giây, khoảng 9,83 FPS, 0 khung bỏ, 7.317 lượt quan sát | Đã xử lý đủ khung của clip thử; lượt quan sát không phải quả vật lý duy nhất |
| Sáu ảnh golden | Số hộp và điểm trạng thái giữ nguyên, sai số ghi nhận bằng 0 | Không đổi output trên sáu ảnh được kiểm tra |
| Giao diện APK release cuối | Hoàn tất 1.073 khung; hiển thị 13,4 FPS; mở lại/hủy video được | Luồng release đó hoạt động trên máy ảo đã dùng |
| Bộ kiểm thử được lưu | 147 Flutter, 92 JVM, 29 Android debug đạt | Bằng chứng hồi quy theo phạm vi test đã có |

Không so 13,4 FPS giao diện với 9,83 FPS native để tính phần trăm tăng tốc: phạm vi đo và tài nguyên host khác nhau. Lượt baseline mới khoảng 10,02 FPS còn tự chọn CPU4, trong khi bản sửa dùng CPU2. Chưa có so sánh đối chứng chứng minh throughput đã tăng. Lượt CPU4 riêng không nhanh hơn và không được chọn; điều đó chưa chứng minh 1–2 luồng là cấu hình tốt nhất cho mọi SoC.

Máy thử là **Pixel 8 API 37, x86_64, máy ảo**, thực cấp **4.096 MiB RAM**, guest MemTotal khoảng 3,82 GiB. Tham số khởi tạo 2.048 MiB đã bị image nâng lên; không coi đây là kiểm chứng thiết bị 2 GB. Chưa có phép đo điện thoại vật lý, pin/nhiệt dài hạn hoặc mọi nguyên nhân gây đơ.

## Phương án đã thử nhưng không phát hành

Một candidate INT8 chọn lọc lượng tử hóa 58 Conv phần thân, giữ FP32 lớp đầu và 24 Conv của head. Graph giảm còn **8.731.905 byte**; p50 CPU ORT trên máy tính giảm từ **49,48 ms xuống 42,85 ms**, nhưng candidate không giữ được các kiểm tra băng chuyền và quả unknown nên bị loại. Candidate INT8 toàn Conv trước đó cũng không được sử dụng.

APK phát hành vẫn dùng **FP32**. Số đo graph trên máy tính không phải FPS Android và không chứng minh chất lượng của model đã nén. Mô hình YOLOX đang chạy chưa được chưng cất kiến thức; MangoStudent chưng cất trong lịch sử không chạy ở chế độ hiện tại. Không có khẳng định đã triển khai GPU/NPU, QAT hoặc pipeline IoT/server.

## Các giới hạn cần giữ khi trình bày

- **Chưa đạt 30 FPS** và chưa chứng minh ứng dụng hết đơ trên mọi điện thoại.
- Lỗi phát hiện/phân mức trong cảnh đông, che khuất hoặc khác miền dữ liệu vẫn còn. Kiểm tra video giới hạn trước đó chỉ có 45 hộp ở 5 khung (13 TP, 5 FP, 32 FN); không phải độ chính xác toàn video.
- Chưa có ground truth quỹ đạo cho bộ đếm. Sáu lượt qua vạch trong phép thử là output thuật toán, không phải xác nhận sáu quả duy nhất.
- Mức chín là nhãn quan sát theo nguồn cho loài hỗ trợ; quả chưa hỗ trợ chưa phân mức. Không suy ra an toàn thực phẩm.
- Build, hash, chữ ký, quyền offline và kiểm tra JNI/ELF chứng minh khía cạnh đóng gói; chúng không đo chất lượng AI hoặc hiệu năng điện thoại.

Xem [model card](../../models/android/model-card.md) để biết hợp đồng graph và [kiến trúc](../ARCHITECTURE.md) để biết luồng xử lý.
