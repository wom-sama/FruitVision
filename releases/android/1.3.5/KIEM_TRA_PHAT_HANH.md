# Kiểm tra bản sửa hiệu năng 1.3.5+5009

Đây là kiểm tra bản sửa phần chờ khởi đầu và vòng đời bộ nhớ, không phải xác nhận đạt 30 FPS hay hết mọi lỗi thực địa. Mô hình FP32, ngưỡng và đầu vào giữ nguyên; hai candidate INT8 không đạt chất lượng không được phát hành.

## Câu hỏi build và kết quả thật

Các câu hỏi dưới đây là nguyên văn trường `question` của wrapper Gradle. Build thành công không đồng nghĩa kiểm thử thiết bị hoặc benchmark đã thành công; những phần đó có receipt riêng.

| Lượt | Câu hỏi | Kết quả |
|---|---|---|
| 1 | Can the unchanged 1.3.4 native app and presentation-cost instrumentation build for an Android baseline? | Build PASS, 58,484 s |
| 2 | Do startup-stall and video pixel-reuse regressions reproduce before the native performance fix? | Chỉ build instrumentation PASS, 9,562 s; hai lỗi RED được tái hiện sau đó trong native_red.json |
| 3 | Do reused native buffers, first-analysis stall fix, and unchanged detection contracts compile and pass JVM tests? | PASS, 17,313 s |
| 4 | Does the startup and buffer performance fix build signed APK 1.3.5 versionCode 5009 for all three Android ABIs? | Build PASS, 105,203 s; đây là gói trung gian, không phải hash gói cuối |
| 5 | Does the core-count based bounded CPU thread policy fail before its implementation? | RED compile FAIL mong đợi: chưa có workerThreads, 52,891 s |
| 6 | Does bounded core-count CPU selection pass the policy and native tests and build Android instrumentation? | PASS, 18,375 s; cấu hình 4 luồng sau đó không được chọn |
| 7 | Does the thread policy reproduce oversubscription beyond the measured two-thread safety cap? | RED test FAIL mong đợi trước khi áp dụng cap 2, 41,906 s |
| 8 | Does final APK 1.3.5 pass all native tests and build three signed ABI packages with the measured two-thread cap? | PASS, 83,672 s; 92 tests, 0 failure/error, ba ABI release |
| 9 | Can the single idle Gradle daemon started by this workflow stop normally before Android performance verification? | Dừng daemon thuộc tác vụ bình thường, PASS, 1,094 s |

Ledger gọn được giữ tại `gradle_ledger_final.json`. Không xóa log ngoài quyền sở hữu của wrapper. Các cảnh báo Java/AGP/Kotlin/SDK lịch sử không bị che hoặc coi là lỗi build.

## Android và phạm vi đo

- Android debug instrumentation: 29 tests PASS cho native tương ứng, gồm decoder, màu/timestamp, dùng lại buffer, ảnh golden, startup, camera và toàn video.
- Sáu ảnh golden: số hộp và điểm trạng thái giữ nguyên, sai số quan sát bằng 0.
- Lần phân tích đầu 3.456,72 → 168,19 ms trên máy ảo. Chỉ kết luận giảm stall khởi đầu.
- Native pipeline 1.073 khung, 0 skip, 7.317 lượt quan sát, 9,828 FPS; không gồm Flutter. CPU4 thử riêng 7,234 FPS, bị loại; final giới hạn 1–2 luồng.
- Flutter 147 tests PASS, analyzer 0 lỗi; final JVM 92 tests PASS.
- Giao diện release cuối hoàn tất 1.073 khung, hiển thị 13,4 FPS, sau đó mở lại video và hủy thành công ở 795 khung. Các nút nguồn được bật lại. Chưa có phép đo độc lập thời gian hủy dưới giây.
- Sáu lượt qua vạch chỉ là output, không có ground truth quỹ đạo để xác nhận đếm đúng.
- Máy ảo API37 thực cấp 4 GiB, không phải 2 GiB. Xem `environment_correction.json`. Không có kiểm thử điện thoại vật lý.

CPU/nguồn lực host khác giữa các lượt, nhất là đã giải phóng daemon Gradle trước lượt release UI cuối. Không suy ra tỷ lệ tăng throughput từ các FPS khác môi trường. Không dùng tốc độ graph INT8 trên Windows làm FPS Android.

## Đóng gói

`apk_verification_final.json` xác nhận version 1.3.5/code5009, ba ABI riêng, đúng graph/metadata, SDK26–36, quyền offline, JNI/ELF và chữ ký v2. Đây không phải kiểm tra chất lượng AI hay tốc độ. APK dùng khóa debug hiện có và chỉ dùng demo phi thương mại theo giấy phép dữ liệu kết hợp.

Không có fit, tải dữ liệu hoặc thay model trong lần sửa này. Bản 1.3.4 và các checkpoint/receipt khoa học cũ được giữ nguyên.
