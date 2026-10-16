# Model card — Android 1.3.5

## Artifact đang được dùng

| Thuộc tính | Giá trị |
| --- | --- |
| Model | YOLOX-Tiny reviewed partial-visibility fruit geometry and source stages |
| Artifact | [`app/android/app/src/main/assets/mango_detector.onnx`](../../app/android/app/src/main/assets/mango_detector.onnx) |
| Kích thước | **20.307.691 byte** ≈ **20,3 MB** thập phân |
| SHA-256 | `8a69c66a9444c18c98a7e3e58a44f4dddda9eb4583dd4448f430ff9e8db27c41` |
| Precision | **FP32** |
| Runtime | ONNX Runtime Android **1.31.0**, CPU |
| Chế độ | `direct_fruit_stages` / `detection_stages` |
| Lineage ghi trong metadata | `partial_visibility_context_training_20261015` |
| Phạm vi sử dụng | Demo học thuật/nghiên cứu **phi thương mại** |

Graph ONNX chỉ có một bản trong thư mục asset của app; thư mục `models/android/` chứa [kiến trúc, checkpoint PyTorch và hướng dẫn kiểm tra/export](README.md), không nhân đôi graph phục vụ. Khi nạp, Android đối chiếu SHA-256 và hợp đồng tensor với metadata. Model hiện tại chưa được chưng cất kiến thức và không phải model ViT-B/16 của desktop. Asset/đường mã `mango_student.onnx` còn trong lịch sử không tham gia phân mức của chế độ hiện tại.

## Hợp đồng đầu vào và đầu ra

Đầu vào tên `image`, **float32 NCHW `[1, 3, 480, 480]`**. Ảnh RGB chuẩn hóa về 0–1, resize giữ tỉ lệ và letterbox ở giữa; padding RGB `(128,128,128)`, quy tắc làm tròn resize `floor`. App chuẩn hóa hướng ảnh/khung trước khi suy luận.

| Tensor đầu ra | Ý nghĩa |
| --- | --- |
| `boxes` | Hộp ứng viên, dạng `[1,N,4]` |
| `scores` | Điểm phát hiện, dạng `[1,N]` |
| `species_ids` | ID trong namespace `banana`, `mango`, `fruit`, dạng `[1,N]` |
| `stage_ids` | ID mức nguồn, dạng `[1,N]` |
| `stage_scores` | Điểm hai mức nguồn, dạng `[1,N,2]` |

Hậu xử lý dùng confidence threshold **0,35**, NMS **class-agnostic**, IoU **0,5**, tối đa **64** kết quả được chọn. Hộp được quy đổi về hệ tọa độ ảnh để vẽ overlay/tracking. Điểm phát hiện và điểm mức chín là hai loại điểm khác nhau; không coi một trong hai là độ chính xác toàn hệ thống.

Metadata phục vụ: [`detector_metadata.json`](../../app/android/app/src/main/assets/detector_metadata.json). Tên tệp `mango_detector.onnx` được giữ để tương thích bộ chạy; namespace phục vụ hiện tại có chuối, xoài và nhóm quả chung.

## Nhãn và hành vi từ chối phân mức

- **Chuối, xoài:** hai mức nguồn `Xanh / chưa chín` và `Chín`, mô tả dấu hiệu quan sát trên vỏ theo dữ liệu nguồn.
- **`fruit` / loài chưa hỗ trợ:** phát hiện hình học có thể được dùng cho overlay và đếm, nhưng **không gán mức chín** (`geometry_only_grade_abstention=true`).
- Không phát hiện được hộp phù hợp không đồng nghĩa không có quả trong cảnh; có thể do quả nhỏ, che khuất, mờ hoặc khác miền dữ liệu.

Hai mức Android không tương đương năm lớp desktop V18.6. Không dùng nhãn này để kết luận hư hỏng bên trong, giá trị dinh dưỡng, dư lượng hóa chất hoặc an toàn thực phẩm.

## Kiểm chứng và giới hạn

Bộ bằng chứng 1.3.5 kiểm tra hash/payload ở ba APK, hợp đồng model, parity trên sáu ảnh golden, decoder và luồng inference. Sửa 1.3.5 giữ model/ngưỡng/đầu vào và số khung video; đó không phải một lần nâng chất lượng model.

Các metric trong metadata thuộc các tập/miền đánh giá cụ thể. Không gộp thành một con số accuracy chung cho mọi quả, mọi thiết bị hoặc toàn video; cũng không lấy metric V18.6 của desktop làm metric Android. Kiểm tra video giới hạn được báo cáo là **13 TP, 5 FP, 32 FN trên 45 hộp ở 5 khung**. Chưa có ground truth quỹ đạo để đánh giá số quả vật lý duy nhất.

Cảnh đông, quả chạm/che nhau, ánh sáng/màu camera khác, quả rất nhỏ và miền mới vẫn có thể gây bỏ sót, nhầm loài hoặc nhầm mức. Tracking hình học có thể đổi ID sau che khuất/re-entry. Chưa xác nhận tốc độ, pin/nhiệt dài hạn trên điện thoại vật lý; số đo máy ảo không phải cam kết 30 FPS. Xem [phạm vi tối ưu/kiểm chứng](../../docs/optimizations/README.md).

Các candidate INT8 đã thử không qua các kiểm tra chất lượng cần thiết nên bị loại. **Không có candidate INT8 trong model đang phục vụ**; graph FP32 trên là artifact cần đối chiếu khi tái lập.

## Nguồn gốc và điều kiện sử dụng

Tham khảo [`SOURCE_ATTRIBUTION.json`](../../app/android/app/src/main/assets/SOURCE_ATTRIBUTION.json) và [`YOLOX_LICENSE.txt`](../../app/android/app/src/main/assets/YOLOX_LICENSE.txt) trong bộ asset. Các giấy phép nguồn/dữ liệu kết hợp giới hạn bản demo này ở phạm vi phi thương mại; không suy ra quyền triển khai thương mại chỉ từ giấy phép của kiến trúc YOLOX hoặc việc repository công khai.

Hướng dẫn sử dụng: [cài Android](../../docs/INSTALL_ANDROID.md). Bằng chứng phát hành: [`releases/android/1.3.5/`](../../releases/android/1.3.5/).
