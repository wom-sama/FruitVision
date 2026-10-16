# Model chính của ứng dụng Android

Đây là mã dựng kiến trúc và checkpoint **đúng model đang phát hành trong APK 1.3.5**, không phải pipeline ViT V18.6 của desktop. Không cần cài Python để cài APK hay build Flutter.

| Tệp | Vai trò |
| --- | --- |
| [model-card.md](model-card.md) | Hợp đồng đầu vào/đầu ra, nhãn và giới hạn |
| [checkpoint.pt](checkpoint.pt) | Checkpoint PyTorch được chọn, 63.170.105 byte |
| [model.py](model.py) | Dựng YOLOX-Tiny 5 lớp, nạp checkpoint strict và wrapper phục vụ |
| [test_model.py](test_model.py) | So sánh PyTorch với graph đóng gói trên một tensor cố định |
| [vendor/YOLOX](vendor/YOLOX/) | Mã YOLOX Apache-2.0 đã khóa commit |
| [mango_detector.onnx](../../app/android/app/src/main/assets/mango_detector.onnx) | Graph thực tế app sử dụng; không nhân đôi tại đây |

Checkpoint SHA-256: `eb1716e3d9f4ecfaca124849a0ec0385638aaa381d770a7136969d35502a97ee`.
Graph ONNX SHA-256: `8a69c66a9444c18c98a7e3e58a44f4dddda9eb4583dd4448f430ff9e8db27c41`.

YOLOX được lấy từ [Megvii-BaseDetection/YOLOX](https://github.com/Megvii-BaseDetection/YOLOX/tree/6ddff4824372906469a7fae2dc3206c7aa4bbaee), commit `6ddff4824372906469a7fae2dc3206c7aa4bbaee`. Giữ nguyên [LICENSE](vendor/YOLOX/LICENSE). `model.py` là wrapper triển khai riêng: RGB 0–1 → BGR 0–255, các hộp/điểm/loài/hai mức nguồn. Hậu xử lý NMS và tracking nằm trong app, không nằm trong graph này.

## Dựng và kiểm tra model (tùy chọn)

Chạy từ thư mục `models/android`, dùng Python 3.11 64-bit:

```powershell
py -3.11 -m venv .venv
.\.venv\Scripts\python.exe -m pip install --upgrade pip
.\.venv\Scripts\python.exe -m pip install torch==2.10.0 torchvision==0.25.0 --index-url https://download.pytorch.org/whl/cpu
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe model.py
.\.venv\Scripts\python.exe -m unittest test_model -v
```

Kết quả nạp đúng phải có **5.034.030 tham số**. Test so sánh năm tensor đầu ra với ONNX đã đóng gói trên một ảnh xám cố định: ID phải khớp, dung sai hộp 0,002 pixel và score 0,0001. Test này kiểm tra tái dựng/hợp đồng, **không phải đánh giá lại độ chính xác trên dataset**. Linux/macOS dùng `python3.11` và `.venv/bin/python`; chưa kiểm thử cài sạch trên các hệ đó.

Xuất một graph riêng để tìm hiểu:

```powershell
.\.venv\Scripts\python.exe model.py --export exports/reconstructed.onnx
```

Lệnh từ chối ghi đè tệp tồn tại. Một lần export mới không bảo đảm hash byte giống graph cũ giữa mọi phiên bản thư viện; muốn thay asset phải kiểm tra parity và Android riêng, không tự thay graph đóng gói.

## Phạm vi mã nguồn và dữ liệu

Repository có kiến trúc, checkpoint, graph và toàn bộ mã suy luận ứng dụng. Không kèm toàn bộ dataset huấn luyện, cache tải hay lịch sử các thử nghiệm. Mã này phục vụ dựng lại checkpoint/suy luận/export, **không phải một gói tái huấn luyện đầy đủ**. Xem [nguồn và giấy phép](../../LICENSE.md); model kết hợp chỉ dùng demo học thuật phi thương mại.
