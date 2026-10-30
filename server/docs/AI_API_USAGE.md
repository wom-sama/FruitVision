# Gọi API AI ảnh/video

Chạy PowerShell từ thư mục `server`. Backend/PC và tunnel HTTPS phải đang chạy. Cả bốn vai trò đang hoạt động, hồ sơ `Approved`, đều dùng được AI; job và preview chỉ thuộc người gửi.

Đăng nhập qua Swagger hoặc `/api/v1/auth/login`, hoàn tất `/auth/mfa/login` nếu được yêu cầu. Đặt **access token của bạn** vào biến môi trường trong phiên terminal, không lưu vào tệp này:

```powershell
$apiUrl = [regex]::Match((Get-Content -LiteralPath './PUBLIC_URL.txt' -Raw), 'https://[^\s]+').Value.TrimEnd('/')
$env:FRUITVISION_ACCESS_TOKEN = '<accessToken-cua-ban>'
curl.exe --fail-with-body --silent --show-error "$apiUrl/api/v1/ai/capabilities" `
  -H "Authorization: Bearer $env:FRUITVISION_ACCESS_TOKEN"
```

`aiReady:false` hoặc `503` nghĩa là chưa có bộ xử lý sẵn sàng. Không dùng refresh token thay access token. Khi access hết hạn, refresh có serialize hoặc đăng nhập lại và thay giá trị biến.

## Gửi một ảnh

```powershell
$requestId = [Guid]::NewGuid().ToString('N')
$imageJob = curl.exe --fail-with-body --silent --show-error --max-time 100 `
  -X POST "$apiUrl/api/v1/ai/jobs?mediaType=image" `
  -H "Authorization: Bearer $env:FRUITVISION_ACCESS_TOKEN" `
  -H 'Content-Type: image/jpeg' `
  -H "X-Client-Request-Id: $requestId" `
  --data-binary '@C:\duong-dan\anh.jpg' | ConvertFrom-Json
$imageJob | Select-Object id,status,progress,revision
```

Ảnh PNG đổi `Content-Type` thành `image/png`. `--data-binary` chỉ đọc tệp cục bộ bằng curl rồi gửi bytes; API không nhận đường dẫn trong JSON, multipart hay base64. Giới hạn: **12 MiB, JPEG/PNG thật, 24 triệu pixel**.

Tạo mới trả `202` và `Location`. Retry cùng `$requestId`, media/Content-Type và **cùng bytes** lấy lại job gốc (`200`), không tạo lần phân tích mới. Backend kiểm số byte và SHA-256 bằng streaming, kể cả sau khi raw input gốc đã xóa. Khác bytes hoặc loại tệp với khóa cũ trả `409`; retry vẫn chịu magic/giới hạn byte và hạn 90 giây. Mỗi tệp/lần chạy mới cần một request ID mới, dài 8–64 ký tự chữ ASCII, số, `_` hoặc `-`.

## Video, trạng thái và preview

```powershell
$videoRequestId = [Guid]::NewGuid().ToString('N')
$videoJob = curl.exe --fail-with-body --silent --show-error --max-time 100 `
  -X POST "$apiUrl/api/v1/ai/jobs?mediaType=video" `
  -H "Authorization: Bearer $env:FRUITVISION_ACCESS_TOKEN" `
  -H 'Content-Type: video/mp4' `
  -H "X-Client-Request-Id: $videoRequestId" `
  --data-binary '@C:\duong-dan\video.mp4' | ConvertFrom-Json

$jobId = $videoJob.id
curl.exe --fail-with-body --silent --show-error "$apiUrl/api/v1/ai/jobs/$jobId" `
  -H "Authorization: Bearer $env:FRUITVISION_ACCESS_TOKEN"
curl.exe --fail-with-body --silent --show-error "$apiUrl/api/v1/ai/jobs" `
  -H "Authorization: Bearer $env:FRUITVISION_ACCESS_TOKEN"
```

Hoàn tất hoặc hủy ảnh hiện tại trước khi gửi video. Video: **80 MiB, MP4 thật, tối đa 120 giây, 3.600 khung, 1920×1080** (được quay dọc). FPS phải hợp lệ, tối đa 240; mọi khung được decode và suy luận. Upload tối đa 90 giây; worker có hạn 165 giây, tiến trình API 180 giây. Có thể cần video ngắn hơn dù tệp còn trong giới hạn.

Poll cách khoảng 2–3 giây khi cần, hoặc dùng `AiJobChanged` trên SignalR `/hubs/fruitvision`. Khi `status=Succeeded` và `previewAvailable=true`:

```powershell
curl.exe --fail-with-body --silent --show-error "$apiUrl/api/v1/ai/jobs/$jobId/preview" `
  -H "Authorization: Bearer $env:FRUITVISION_ACCESS_TOKEN" --output './ai-preview.jpg'
```

Preview là JPEG riêng tư, tối đa 10 MiB, không hỗ trợ Range. Trạng thái khác có thể không có preview. Hủy queued/running:

```powershell
curl.exe --fail-with-body --silent --show-error -X POST "$apiUrl/api/v1/ai/jobs/$jobId/cancel" `
  -H "Authorization: Bearer $env:FRUITVISION_ACCESS_TOKEN"
Remove-Item Env:FRUITVISION_ACCESS_TOKEN
```

Mỗi người tối đa một job `Queued/Running`; toàn hệ thống tối đa bốn job hoạt động, một worker. `429` có `Retry-After`; `413` vượt dung lượng, `415` sai Content-Type, `400` sai khai báo/magic/header. Lỗi decode/giới hạn worker xuất hiện trong snapshot `Failed`. Người khác nhận `404`; token thiếu/hết hạn nhận `401`, hồ sơ chưa duyệt nhận `403`.

Sự kiện gồm `{id,status,progress,framesProcessed,revision}`; bỏ qua revision cũ. Sau reconnect hoặc nhận snapshot upload, GET lại job qua REST để khôi phục trạng thái/kết quả. Trạng thái và kết quả đã ghi DB trước khi phát sự kiện; không dựa vào việc luôn nhận được mọi event.

`maxVisibleCount`, `confirmedTrackCount`, `lineCrossingCount` là ba phép đo khác nhau, không phải số quả vật lý đã xác minh. Giai đoạn nguồn không chứng nhận độ chín thực địa. Model chỉ dành cho demo phi thương mại; xem [giới hạn và giấy phép trong README](../README.md#tác-vụ-ai-ảnh-và-video).
