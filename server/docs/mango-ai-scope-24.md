# Phạm vi AI xoài 2.4

Phạm vi chính là hỗ trợ Producer/Trader quan sát và đếm **xoài được mô hình dự đoán**. Consumer ưu tiên đọc kiến thức và trao đổi cộng đồng. Không có huấn luyện, đổi trọng số hay đổi lớp để mở rộng công dụng.

## Mô hình và ý nghĩa nhãn

Đồ thị đang được ghim là [mango_detector.onnx](../../app/android/app/src/main/assets/mango_detector.onnx), YOLOX-Tiny FP32, 20.307.691 byte; SHA-256:

`8a69c66a9444c18c98a7e3e58a44f4dddda9eb4583dd4448f430ff9e8db27c41`

Đầu vào `image` `[1,3,480,480]`. Năm đầu ra: `boxes [1,4725,4]`, `scores [1,4725]`, `species_ids [1,4725]`, `stage_ids [1,4725]`, `stage_scores [1,4725,2]`. [Metadata](../../app/android/app/src/main/assets/detector_metadata.json) vẫn mô tả đúng đồ thị có banana/mango/generic fruit. Serving 2.4 chỉ giữ `species_ids == 1` **trước NMS, theo dõi và đếm**, không sửa đồ thị hoặc đổi ánh xạ lớp.

Ngưỡng giữ nguyên: detection 0,35; NMS IoU 0,5; tối đa 64 đối tượng/khung; độ tin cậy giai đoạn tối thiểu 0,6. Nhãn đối tượng là `Xoài (dự đoán)`.

| stageCode | Nhãn | Ý nghĩa |
|---|---|---|
| -1 | Chưa xác định | Chưa đủ tin cậy để gán giai đoạn nguồn. |
| 0 | Xanh / chưa chín | Nhãn dự đoán từ dữ liệu nguồn. |
| 1 | Chín | Nhãn dự đoán từ dữ liệu nguồn. |

Đây là **hai giai đoạn nguồn**, không xác nhận độ chín ngoài thực tế, vị ngọt, giống, hư hỏng, chất lượng bên trong hoặc an toàn thực phẩm. Lớp huấn luyện nội bộ số 4 của đồ thị này là `Fruit_grade_unknown`, không phải xoài hư và không phải đầu ra `stageCode=4`.

Tài sản legacy `mango_student.onnx` SHA `819d023fa5f2ee624c63c630ec37e190548f1f793848ea17a86d1000acaf6be9` còn được giữ nhưng **không chạy** ở tuyến này. Năm lớp xoài của grader legacy, gồm lớp xoài hư, không phải khả năng hiện tại. Giữ nguyên [nguồn và giấy phép](../../app/android/app/src/main/assets/SOURCE_ATTRIBUTION.json): mô hình/dữ liệu chỉ dành cho bản trình diễn phi thương mại.

## Luồng API thực tế

1. Seller đang hoạt động, đã được duyệt dùng phiên xác thực thật; đọc `GET /api/v1/ai/capabilities` và `/api/v1/ai/guide`. Admin/Consumer không được cấp quyền AI.
2. Gửi tệp nhị phân `POST /api/v1/ai/jobs?mediaType=image` với `Content-Type: image/jpeg` hoặc `image/png` và `X-Client-Request-Id` duy nhất 8–64 ký tự chữ/số/`_`/`-`. Ảnh tối đa 12 MiB, 24 triệu pixel. Video dùng `mediaType=video`, MP4 tối đa 80 MiB, 120 giây, 3.600 khung; cạnh dài tối đa 1.920, cạnh ngắn tối đa 1.080.
3. API trả `202` với ID tác vụ. Một tài khoản có tối đa một tác vụ Queued/Running; toàn hệ thống tối đa bốn tác vụ đang chờ/chạy, một bộ xử lý tuần tự. ORT CPU tối đa hai thread; giới hạn API 180 giây/tác vụ. Cùng khóa và đúng cùng byte tệp trả `200` cùng ID; đổi nội dung/loại tệp trả `409`.
4. Theo dõi metadata `AiJobChanged` ở nhóm riêng của chủ tác vụ hoặc đọc `GET /api/v1/ai/jobs/{id}`. Sau mất mạng, tải lại `/api/v1/ai/jobs` và chi tiết; REST là nguồn trạng thái. Chủ tác vụ có thể `POST /api/v1/ai/jobs/{id}/cancel`.
5. Chỉ khi Succeeded mới xem `GET /api/v1/ai/jobs/{id}/preview`. Tác vụ và preview chỉ thuộc chủ sở hữu. Kết quả `schema=fruitvision-ai-v1`, `scope=predicted-mango-only` có nhãn bằng chữ trên preview, không chỉ màu viền. Không có đối tượng đạt ngưỡng trả `Không phát hiện xoài đạt ngưỡng`; **không chứng minh không có xoài**.

`GET /api/v1/learning/mango` là nội dung tiếng Việt chỉ đọc cho mọi tài khoản đã được duyệt, gồm Consumer, Producer, Trader và Admin. Đọc kiến thức không tạo tác vụ, không gửi ảnh và không mở quyền AI. UI cần giữ nhãn chữ, ngắt dòng và cỡ chữ theo thiết bị.

## Đọc số đếm và lịch sử

| Trường | Cách hiểu |
|---|---|
| framesProcessed | Số khung đã xử lý, không phải số quả hay FPS điện thoại. |
| maxVisibleCount | Số đối tượng xoài dự đoán thấy đồng thời nhiều nhất; ảnh đơn dùng số này. |
| confirmedTrackCount | Số ID được xác nhận qua ít nhất hai khung; ảnh đơn bằng 0. |
| lineCrossingCount | Số ID qua vạch giữa theo một trong hai hướng, mỗi ID tối đa một lần. |

`gradeCounts` của ảnh tổng hợp các đối tượng; của video tổng hợp các track đã xác nhận bằng phiếu giai đoạn có trọng số. Không cộng số đếm từng khung rồi gọi là số quả duy nhất. Che khuất, quay lại và camera chuyển động có thể đổi ID. Video vẫn có hạn chế chất lượng; không có bảo đảm 30 FPS hoặc độ chính xác thực địa. Không suy ra kg, tồn kho, giá hoặc mức an toàn.

Kết quả cũ có thể cùng SHA mô hình nhưng **thiếu `scope=predicted-mango-only`**, từng đếm cả banana/generic fruit và ghi `Quả`. Giữ nhãn/số đã lưu cùng cảnh báo lịch sử; không đổi tên những số đó thành xoài. API Forecast/Market cũ chỉ còn cho tương thích, không phải luồng chính hay hệ thống giao dịch, thanh toán, kho, dự báo giá hoặc IoT.

## Smoke HTTPS một ảnh

[Script](../scripts/mango_image_smoke_24.py) dùng phiên Seller thật trong JSON riêng dưới `server/.local`, cùng cấu trúc `baseURL` và `sessions` của driver 2.3; không đăng nhập mật khẩu, gửi mail, tạo token giả hoặc sửa DB. Từ gốc repository:

```powershell
& ./server/.tools/ai-venv/Scripts/python.exe -X utf8 -B ./server/scripts/mango_image_smoke_24.py --sessions ./server/.local/real-sessions.json --role Producer --fixture single --run
```

`--run` tạo một tác vụ thật được lưu; mặc định ảnh [demo_mango.jpg](../../app/android/app/src/main/assets/demo_mango.jpg) đã được native `prepareDirect` dùng làm sample, SHA `0104a1e5e313f5c4082607b4cac73b2497f9a916d130e500c96616e05684b9f5`. Đây là ảnh demo có biến đổi/padding, không phải mẫu đánh giá độc lập. Có thể chọn `--fixture multiple` để dùng `demo_multi_mango.png`; script không tạo ảnh tổng hợp mới.

Script kiểm HTTPS đúng tunnel đang được ghi riêng, không chuyển hướng, không tắt TLS; tối đa khoảng 75 giây, thêm tối đa 5 giây để yêu cầu hủy tác vụ của chính nó nếu chưa hoàn tất. Receipt mặc định `server/docs/mango-image-https-smoke-24.json` chỉ chứa ID/trạng thái/số liệu/hash, không chứa token hoặc ảnh. PASS chỉ chứng minh luồng thực thi và hợp đồng kết quả; kể cả ảnh demo có phát hiện xoài cũng không chứng minh chất lượng mô hình. Chỉ xem là đã chạy live khi có receipt thực tế; unit test và source không thay thế kiểm APK/điện thoại.
