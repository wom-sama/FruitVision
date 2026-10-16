# Cài và chạy demo desktop V18.6

Demo này đọc ảnh/video trong `input`, chọn **một quả chính** bằng Grounding DINO, tạo mask bằng SAM rồi phân loại xoài bằng ViT-B/16 + delta V18.6. Kết quả được ghi vào `output`. Đây là pipeline khác với Android nhiều quả; không cần chạy desktop để dùng APK.

## Chuẩn bị

- **Python 3.11, 64-bit**, Git và Internet cho lần cài thư viện/tải model đầu tiên. Repository này không yêu cầu Git LFS.
- CPU chạy được; NVIDIA GPU là tùy chọn. `setup.py --cuda` cài wheel CUDA 12.8 và cần driver NVIDIA tương thích. Có GPU không đồng nghĩa PyTorch đã nhận CUDA.
- Chừa dung lượng cho môi trường Python, model công khai, cache tải và video đầu ra. Tổng dung lượng lớn hơn nhiều so với mã nguồn; riêng backbone ViT khoảng 346 MB và DINO/SAM cộng lại khoảng 1 GB.
- Windows là môi trường đã dùng để kiểm chứng. Script có nhánh Linux/macOS nhưng chưa coi đó là bằng chứng đã thử đầy đủ hai hệ điều hành này; macOS hiện dùng CPU, chưa tối ưu MPS.

Kiểm tra trên Windows PowerShell:

```powershell
git --version
py -3.11 --version
```

Nếu dùng NVIDIA, có thể kiểm tra driver bằng `nvidia-smi`. Nếu chưa có GPU phù hợp, chọn cách cài CPU.

## 1. Clone repository

```powershell
git clone https://github.com/wom-sama/FruitVision.git
cd FruitVision\demos\desktop
```

Các lệnh còn lại được chạy trong **`demos/desktop`**, nơi có `demo.py`, `setup.py`, `prepare_models.py` và `requirements.txt`. Nếu đã clone để build Android, chỉ cần chuyển vào thư mục này.

## 2. Cài môi trường một lần

Trên Windows, chọn **một** lệnh:

```powershell
# CPU
py -3.11 setup.py
```

```powershell
# NVIDIA / CUDA 12.8
py -3.11 setup.py --cuda
```

Linux/macOS dùng `python3.11 setup.py`; Linux NVIDIA có thể thêm `--cuda`. Không dùng Python 3.12/3.13 cho script setup hiện tại.

Setup tạo `.venv` trong `demos/desktop`, cài **torch 2.10.0**, **torchvision 0.25.0**, các phụ thuộc đã khóa trong `requirements.txt`, rồi chạy `prepare_models.py`. Chờ thông báo **`Setup complete`**; thư mục `.venv` đã xuất hiện chưa có nghĩa setup đã thành công.

### Model được lấy từ đâu?

| Thành phần | Cách chuẩn bị |
| --- | --- |
| Delta V18.6, khoảng 97 MB | Có trong `models/V186/v186_final_deployment_delta.pt` |
| Notebook nguồn, khoảng 27 MB | Có trong `models/V186/OBJECT_VITB16_CHROMATIC_RESCUE_SWA_V186_LOCAL_CHECKPOINTED_FINAL.ipynb` |
| Backbone torchvision ViT-B/16 | Setup tải từ [máy chủ PyTorch chính thức](https://download.pytorch.org/models/vit_b_16-c867db91.pth) vào `models/V186/torch_hub/checkpoints/` |
| Grounding DINO tiny | Snapshot `IDEA-Research/grounding-dino-tiny` @ `a2bb814dd30d776dcf7e30523b00659f4f141c71` |
| SAM ViT base | Snapshot `facebook/sam-vit-base` @ `70c1a07f894ebb5b307fd9eaaee97b9dfc16068f` |

Hai snapshot cuối được tải vào `models/pretrained/`. `prepare_models.py` kiểm tra SHA-256 cho các trọng số cần thiết; backbone có SHA-256 `c867db91d3e12c6cbadabb610d73c24a546bf82d8c03a9fea34f43a712ddb0e9`. Không thay tệp bằng một checkpoint cùng tên từ nguồn khác và không bỏ kiểm tra hash.

Sau khi cài, kiểm tra trên Windows:

```powershell
.\.venv\Scripts\python.exe prepare_models.py --check-only
.\.venv\Scripts\python.exe -c "import torch; print('PyTorch:', torch.__version__); print('CUDA:', torch.cuda.is_available())"
```

Linux/macOS thay `.\.venv\Scripts\python.exe` bằng `.venv/bin/python`. `Models ready` xác nhận bộ model được script kiểm tra đã có. Với bản CPU, `CUDA: False` là bình thường. Suy luận chỉ nạp model cục bộ và bật chế độ offline; quá trình chạy demo không tự tải model còn thiếu.

## 3. Chuẩn bị dữ liệu và chạy

Đặt ảnh/video của bạn vào `demos/desktop/input/`. Có thể dùng thư mục con; demo quét đệ quy.

| Loại | Phần mở rộng được nhận |
| --- | --- |
| Ảnh | `.jpg`, `.jpeg`, `.png`, `.webp`, `.bmp`, `.tif`, `.tiff` |
| Video | `.mp4`, `.mov`, `.avi`, `.mkv`, `.webm`, `.m4v` |

Khả năng đọc video còn phụ thuộc codec bên trong. Nên thử một ảnh trước, rồi video ngắn. Không di chuyển tệp đầu vào trong khi xử lý. Thư mục đầu vào và đầu ra phải tách nhau, không lồng vào nhau.

Windows:

```powershell
.\run_demo.bat
```

Hoặc gọi trực tiếp môi trường đã cài:

```powershell
.\.venv\Scripts\python.exe demo.py --device cpu
```

GPU NVIDIA đã nhận CUDA:

```powershell
.\.venv\Scripts\python.exe demo.py --device cuda --video-fps 2
```

`--device auto` là mặc định: dùng CUDA khi khả dụng, nếu không dùng CPU. Có thể đặt thư mục khác bằng `--input "DUONG_DAN_ANH" --output "DUONG_DAN_KET_QUA"`. Trên Linux/macOS, dùng `.venv/bin/python demo.py` với các tham số tương tự.

### Hiểu kết quả video

`--video-fps 2` là **mục tiêu lấy mẫu AI khoảng hai lần trên một giây của video**, không phải tốc độ chạy thực hoặc FPS xuất video. Script đổi tần suất này thành bước khung gần nhất theo FPS nguồn. Nó vẫn ghi các khung đã giải mã vào video đầu ra, dùng kết quả mẫu gần nhất cho overlay và hiển thị tuổi kết quả (`age`). Không có tracking trong demo desktop.

Video đầu ra không giữ âm thanh. Nếu kích thước nguồn lẻ, script thêm viền đen để encoder có kích thước chẵn. Nhãn có thể đi sau chuyển động giữa hai lần suy luận; không dùng demo này để đếm nhiều quả hoặc suy ra chất lượng toàn video.

## 4. Xem kết quả

Mỗi lần chạy tạo một thư mục mới:

```text
output/run_YYYYMMDD_HHMMSS_ffffff/
├── summary.json
├── anh.jpg/
│   ├── annotated.jpg
│   ├── mask.png                 # Có khi tạo được mask cho quả chính
│   └── result.json
└── video.mp4/
    ├── annotated.mp4
    ├── predictions.jsonl
    ├── masks/
    └── result.json
```

`result.json` lưu nhãn, điểm và thông tin phát hiện cho ảnh, hoặc thông tin xử lý cho video. `predictions.jsonl` ghi dự đoán tại các khung được lấy mẫu, kèm frame/timestamp. `summary.json` ghi tệp đã xử lý, lỗi và hash model/notebook.

Năm lớp desktop được script hiển thị là `Song / chua`, `Song / chua nhe`, `Chin`, `Chin gia`, `Hu` (ID 0–4). Điểm model không phải xác suất an toàn thực phẩm. Trạng thái `NO_MANGO_DETECTED` không có hộp/nhãn phân lớp; lỗi đọc hoặc suy luận được ghi là `ERROR`. Nếu có tệp lỗi, tiến trình trả mã thoát khác 0 dù những tệp khác có thể đã được xử lý.

## Kiểm thử và xử lý lỗi

Kiểm thử logic/media, không thay thế đánh giá chất lượng model:

```powershell
.\.venv\Scripts\python.exe -m unittest test_demo test_prepare_models -v
```

`verify_portability.py` là kiểm tra tích hợp có suy luận thật trong thư mục di chuyển; cần model đã sẵn sàng, thư mục `output` và ít nhất một JPG trong `input`. Nó không kiểm tra việc cài phụ thuộc mới từ đầu. Xem nội dung script trước khi dùng cho dữ liệu của bạn.

| Lỗi / hiện tượng | Cách xử lý |
| --- | --- |
| Không có Python 3.11 | Cài Python 3.11 64-bit; kiểm tra `py -3.11 --version` |
| Thiếu model / tải bị ngắt | Chạy lại `.\.venv\Scripts\python.exe prepare_models.py` khi có Internet, rồi `--check-only` |
| SHA-256 không khớp | Đối chiếu tệp tải/checkpoint với bản repository; không tắt kiểm tra hash |
| CUDA không khả dụng | Kiểm tra driver và `torch.cuda.is_available()`; dùng `--device cpu` nếu cần |
| Không có dữ liệu đầu vào | Đặt tệp hỗ trợ trong `input`, hoặc chỉ định đúng `--input` |
| Không giải mã/ghi được video | Thử clip MP4 phổ thông ngắn; xem lỗi trong `result.json`/`summary.json` |
| Chạy CPU chậm | Thử ảnh hoặc clip ngắn; tốc độ phụ thuộc máy và độ phân giải, chưa có cấu hình tối thiểu được xác lập |

Quay lại [README](../README.md) hoặc xem [kiến trúc hai demo](ARCHITECTURE.md).
