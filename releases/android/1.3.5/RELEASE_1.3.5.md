# Fruit Offline 1.3.5

Bản sửa thời gian bắt đầu phân tích và vòng đời bộ nhớ video. Đây chưa phải bản đạt 30 FPS hoặc đã chứng minh không đơ trên mọi điện thoại.

## Những thay đổi thực sự có trong bản này

- Bỏ việc tạo nhiều phiên CPU4, NNAPI và XNNPACK ngay ở lần phân tích đầu. Bản này sử dụng một phiên ONNX Runtime CPU, không gọi quá trình dò provider trong mỗi phiên phân tích. Không tuyên bố dùng NPU hay GPU điện thoại.
- Giữ một tensor đầu vào, bản đồ đầu vào và các mảng nhận kết quả để dùng lại, thay vì cấp phát lại mỗi khung.
- Decoder giữ một bitmap video có cùng kích thước để dùng lại. Đóng frame trả quyền sử dụng cho decoder; đóng decoder mới giải phóng bitmap. Kiểm tra tám khung về timestamp và màu sắc xác nhận đường chuyển đổi vẫn đúng.
- Tracking chỉ tìm ghép trong các ID còn hoạt động, giữ nguyên lịch sử, phiếu phân lớp và số đếm. Thay đổi này tránh chi phí tăng theo toàn bộ lịch sử nhưng không được coi là tăng FPS AI đáng kể.
- Số luồng CPU giới hạn 1–2 theo số core khả dụng; chọn 1 khi Android báo máy ít RAM, lowMemory hoặc RAM khả dụng dưới 256 MiB. Lượt thử 4 luồng không nhanh hơn nên không được chọn. Đây không phải bằng chứng cấu hình này tối ưu trên mọi chip.

Mô hình, ảnh đầu vào 480 × 480, ngưỡng, NMS và số khung phân tích giữ nguyên. Không giảm độ phân giải mô hình hay bỏ khung để tạo số FPS cao hơn. Mô hình đang chạy vẫn là YOLOX-Tiny FP32 khoảng 5,03 triệu tham số, đồ thị 20.307.691 byte. Mô hình này chưa được chưng cất kiến thức. MangoStudent chưng cất trong lịch sử không chạy ở chế độ hiện tại.

## Kết quả Android đã đo trước đóng gói release

Trên máy ảo Pixel 8 API 37, lần phân tích đầu giảm từ 3.456,72 ms xuống 168,19 ms. Phần dò provider trước sửa chiếm 3.374,62 ms. Đây là phép đo độ trễ khởi đầu, không phải phép đo FPS toàn video hoặc điện thoại vật lý.

Pipeline native bản sửa xử lý đủ 1.073 khung trong 109,18 giây, khoảng 9,83 FPS, không bỏ khung, cùng 7.317 lượt quan sát phát hiện như baseline. Các lượt quan sát không phải số quả vật lý duy nhất. Một phép đo mới của bản cũ đạt khoảng 10,02 FPS nhưng tự chọn CPU 4 thread; bản sửa dùng CPU 2 thread. Khác biệt cấu hình và biến động máy ảo không cho phép kết luận throughput đã tăng. Mục tiêu 30 FPS vẫn chưa đạt.

Sáu ảnh golden giữ nguyên số hộp và điểm trạng thái, sai số ghi nhận bằng 0. Có 29 kiểm tra Android đạt ở bản debug cùng thay đổi native, gồm decoder, màu, buffer, khởi đầu, ảnh/video, camera dừng/mở lại/nền/xoay/nhiệt và toàn video. Flutter có 147 tests đạt, analyzer 0 lỗi; bản build cuối có 92 JVM tests đạt, 0 failure/error.

APK release cuối 1.3.5+5009 đã cài và chạy offline trên máy ảo: ảnh mẫu có kết quả; video hoàn tất 1.073 khung và giao diện hiển thị 13,4 FPS xử lý. Sáu lượt qua vạch chỉ là output của thuật toán, không phải kết quả đếm đã đối chiếu ground truth. Điều kiện tài nguyên host đã thay đổi giữa các lượt (đã dừng daemon Gradle thuộc tác vụ trước lượt UI cuối), nên không lấy 13,4 so với 9,9 FPS cũ để kết luận phần trăm tăng tốc. Mục tiêu 30 FPS vẫn chưa đạt.

Đính chính môi trường: lệnh mở máy ảo yêu cầu 2.048 MiB nhưng image API 37 tự nâng lên 4.096 MiB; `/proc/meminfo` báo MemTotal 4.008.504 KiB (~3,82 GiB). Không coi các phép đo này là kiểm thử điện thoại 2 GB. Không sửa lại receipt lịch sử; receipt đính chính được lưu riêng.

Ba APK ARM64, ARM32 và x86_64 đã qua kiểm tra payload/hash, version, SDK, JNI/ELF, quyền offline và chữ ký v2. Các kiểm tra đóng gói không thay thế đo FPS hoặc chất lượng phát hiện.

## Nén mô hình đã thử và không phát hành

Một lần INT8 chọn lọc mới lượng tử hóa 58 Conv ở thân mạng, giữ FP32 lớp đầu và toàn bộ 24 Conv của head. Đồ thị còn 8.731.905 byte. Thời gian p50 trên CPU ORT máy tính giảm từ 49,48 ms xuống 42,85 ms nhưng không giữ các kiểm tra băng chuyền và unknown. Candidate bị loại, không nằm trong APK và không dùng TEST/video để chọn lại ngưỡng. Bản INT8 toàn Conv thất bại trước đây cũng không được sử dụng.

## Cài đặt và dùng

Android 8.0/API 26 trở lên. Cài đúng một APK:

- `app-arm64-v8a-release.apk`: phần lớn điện thoại Android hiện nay.
- `app-armeabi-v7a-release.apk`: điện thoại ARM 32-bit.
- `app-x86_64-release.apk`: máy ảo hoặc thiết bị x86_64.

Cài cập nhật qua tệp APK hoặc `adb install -r <đường-dẫn-APK>`. Mô hình chạy offline trên thiết bị. Thử **Ảnh mẫu**, **Chọn video** và **Camera trực tiếp**. Có thể hủy video sau khung đang xử lý. Video phân tích tối đa 10 phút và đọc tuần tự; preview hiển thị thưa hơn không đồng nghĩa với bỏ khung AI.

Muốn đếm qua vạch, bật chế độ trên màn hình chính trước khi chọn video, chọn chiều và vị trí vạch, giữ camera cố định so với băng chuyền. Tracking hình học vẫn có thể đổi ID, đếm lại hoặc bỏ sót khi che khuất/camera di chuyển. Chưa có ground truth quỹ đạo để xác nhận sản lượng duy nhất. Không quy đổi kết quả thành kg.

## Những giới hạn vẫn còn

- Khả năng phát hiện và phân mức chín không được cải thiện bằng đổi mô hình trong lần sửa này. Các lỗi phân lớp xanh/chín và cảnh nhiều quả vẫn cần đánh giá thực địa.
- Kiểm tra video giới hạn trước đó vẫn là 13 TP, 5 FP và 32 FN trên 45 hộp ở 5 khung. Không gọi đây là độ chính xác toàn video.
- Số đo máy ảo không phải cam kết hiệu năng điện thoại. Bản sửa giảm stall khởi đầu và cấp phát bộ nhớ, chưa chứng minh xử lý AI 30 FPS hoặc chữa mọi nguyên nhân app đơ.
- Chỉ loài được hỗ trợ mới có mức quan sát theo nguồn. Quả chưa hỗ trợ giữ trạng thái chưa phân mức. Không đánh giá an toàn thực phẩm.
- Chỉ dùng demo phi thương mại do các giấy phép dữ liệu kết hợp. APK dùng khóa ký debug hiện có, chưa phải gói phân phối thương mại.

Bản 1.3.4 và hash của nó được giữ tại `E:\OneDrive\Desktop\Demo\APK_1.3.4`; bản sao C nằm trong `rollback\apk_1_3_4_before_1_3_5`. Không ghi đè bản dự phòng.
