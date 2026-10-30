# Biên bản nền tảng FruitVision —30/10/2026

Backend chạy trên PC bằng .NET CLI/runtime10.0.14 riêng; PostgreSQL18.6 riêng ở loopback. HTTPS/WSS qua Cloudflare Quick Tunnel; không Render, không mở cổng DB.

## Những gì đã hoạt động

- Bốn vai trò đúng đặc tả; đăng ký ba vai trò nghiệp vụ bắt đầu Pending, Admin seed riêng.
- Đăng nhập, session opaque256bit chỉ lưu hash, refresh rotation/replay, logout/revoke/lock; trạng thái/quyền đọc từ server.
- Xét duyệt, lý do, gửi lại hồ sơ, lịch sử/audit; kiểm dữ liệu riêng theo user/membership.
- TOTP thật, challenge một lần và thu hồi phiên cũ; đây không phải sinh trắc học.
- Tin dự kiến công khai/gửi chờ duyệt, chat idempotent và SignalR/outbox; history seed tách audit thật.
- index.html và Swagger /v1/index.html tự host assets, có Authorize/Try it out,27operations/25paths; ghi API thay đổi dữ liệu demo thật.
- Runtime fv_api không có superuser/tạoDB/tạoRole; migrations tách quyền. .local ACL riêng và không được phát ra web.

## Bằng chứng

18/18test toàn bộ solution backend PASS,0skip; Releasebuild0warnings. PostgreSQL thật, không SQLite/in-memory. Probe HTTPS+WSS21checksPASS và final8publicpaths đúng; WebSocket gửi được MessageCreated. Đã restart API lẫn DB, counts24users/60posts/481messages giữ nguyên, session hợp lệ còn dùng được; probe HTTPS gửi thêm1tin, tức482messages sau hai probe. Không seed lặp.

Web browserẩn đã tải Swagger, có Authorize, Execute GET/health/ready trả200. Crawler web bên ngoài không truy cập được hostname tạm qua công cụ của nó; không đổi nhãn thành test thành công bằng điện thoại/mạng thứ hai. HTTP/WSS qua tên miền thật đã được kiểm trên máy này với TLS validation bật.

Probe nhỏ30request/6client: localhost p50≈2.63ms/p95≈50.58ms; HTTPS tạm p50≈479.88ms/p95≈751.63ms. urllib có thể tạo TLS connection mới; không phải đo Flutter persistent connection, tải AI hoặc năng lực sản phẩm nhiều người dùng. Không suy ra6AIFPS từ đây.

NuGet package audit của project API không báo package có lỗ hổng đã biết từ feed được truy vấn; không thay cho pentest. .NET10.0.14 được kiểm SHA512 metadata Microsoft; cloudflared2026.10.6 khớp digestGitHub và Authenticode Cloudflare hợp lệ. Các runtime toàn máy giữ nguyên.

## Chưa hoàn thành

Sinh trắc/passkey; recoveryMFA/resetemail; worker/API phân tích ảnh xoài; ước tính khảo sát; APKFlutter chỉ gọiAPI; hai tuyến giao dịch, giữ hàng/tồn kho, giao nhận, thanh toán, tranh chấp; domain cố định vàWindowsService/backup vận hành. Bản này là nền tảng thử nghiệm có phân quyền thật, không tuyên bố production hoặc nghiệm thu toàn bộ đặc tả.

## Vận hành và tệp

Địa chỉ chuẩn ở ../PUBLIC_URL.txt. Giữ máy/API/tunnel chạy; tạo tunnel mới đổiURL. ScriptsStart/Stop chỉ quản lý đúng dịch vụ sở hữu. Credentials ở ../.local/demo-accounts.json riêng tư. Dữ liệu seed là giả lập, không có thanh toán/tồn/AI được dựng thành thành tích thật.

Hai biên nhận di chuyển xác nhận15tệp/~1GiB vào E:/OneDrive/Desktop/FruitVision_CoTheXoa_20261030 để người dùng tự xóa; model, dữ liệu nghiên cứu, rollback và VM không bị chuyển/xóa.
