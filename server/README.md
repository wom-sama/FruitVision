# FruitVision 2.2 — backend trên PC

Backend phục vụ client Android **2.2.0+6006**: tài khoản/xét duyệt, tin Supply–Demand có kiểm duyệt, liên hệ riêng, cộng đồng, tham khảo cung/cầu, AI ảnh/video trên PC và đăng ký bản cập nhật APK. PostgreSQL giữ dữ liệu, SignalR phát sự kiện, CPU worker chạy model ONNX đã ghim. **APK 6006 đã nâng cấp qua trình cài Android và chạy nghiệp vụ bốn vai trò tuần tự trên máy ảo API 30**; xem [biên nhận cuối](../releases/android/2.2.0/native-acceptance.json). Không phải bốn điện thoại thật.

## Chạy từ bản clone

Windows x64, PowerShell 7, .NET 10 SDK. Từ thư mục `server`:

```powershell
./scripts/Install-Runtimes.ps1
dotnet restore FruitVision.slnx --locked-mode
dotnet build src/FruitVision.Api/FruitVision.Api.csproj -c Release
./scripts/Start-Server.ps1
```

Script tạo PostgreSQL 18.6 riêng tại `127.0.0.1:55432`, migration bằng owner, API bằng role dữ liệu tối thiểu và runtime .NET 10.0.14 riêng. API ở `http://127.0.0.1:5098/`, Swagger ở `/v1/index.html`, OpenAPI ở `/openapi/v1.json`, readiness ở `/health/ready`. Không cài Windows Service hoặc đổi PATH toàn máy.

Tài khoản demo/mật khẩu ngẫu nhiên của **máy hiện tại** nằm trong `.local/demo-accounts.json`; cấu hình/secret/DB/log ở `.local`, runtime ở `.tools`, đều không đưa lên Git. Không sao chép runtime.json hoặc database riêng của người phát triển sang máy khác. `seed/demo-data.json` là seed demo có marker/giao dịch chống chạy trùng, không có mật khẩu hay tồn kho thực; các probe có thể tạo thêm bản ghi.

```powershell
./scripts/Install-Public.ps1
./scripts/Start-Public.ps1
```

Đây là HTTPS/WSS tạm qua Cloudflare Quick Tunnel; PC, API và tunnel cần tiếp tục chạy. Script sinh địa chỉ hiện hành trong **tệp local `server/PUBLIC_URL.txt`**; tệp này không thuộc Git, không phải link tải của bản clone. `localhost` trên điện thoại không trỏ về PC. Không mở PostgreSQL, worker hoặc thư mục media ra Internet; chưa có hostname cố định/24×7.

Dừng đúng tiến trình dự án bằng `Stop-Server.ps1`, thêm `-StopDatabase` khi cần; dừng riêng tunnel bằng `Stop-Public.ps1`. Script không xóa dữ liệu hoặc quét/kill tiến trình dự án khác.

## Bốn vai trò và luồng 2.2

| Vai trò | Luồng hiện có sau khi Approved |
|---|---|
| Admin | Duyệt hồ sơ/tin, khóa/mở tài khoản, audit/thống kê; tham gia cộng đồng; AI riêng |
| Producer | Đăng Supply, theo dõi xét duyệt; liên hệ bài Published của người khác; Direct/Group; AI riêng |
| Trader | Đăng Demand mặc định hoặc Supply; tìm nguồn cung, liên hệ Direct/Group; AI riêng |
| Consumer | Đọc tin/thị trường, liên hệ bài Published, Direct/Group; AI riêng; không đăng Supply/Demand |

Đăng ký nghiệp vụ bắt đầu Pending; có NeedsInformation/Rejected, lý do và gửi lại hồ sơ. Không đăng ký Admin công khai. Bài mới AwaitingReview; Admin Published/Rejected, Published có thể Paused rồi Published lại. Review kiểm `expectedRevision`, tranh chấp trả `409`.

Liên hệ bài công khai tạo Direct riêng đúng hai người, dùng lại khi cùng người liên hệ cùng bài. Người khác cùng vai trò vẫn được liên hệ; tự liên hệ `409`, Admin liên hệ nghiệp vụ `403`. Chỉ thành viên đọc/gửi tin; không nhận danh sách participant tùy ý từ client.

Nhóm công khai cho Approved tự tạo/join/leave; tối đa 10 nhóm mở/chủ, 50 thành viên/nhóm. Chủ cần đóng trước khi rời; chủ/Admin được đóng. Nhóm đóng giữ lịch sử cho thành viên hiện tại, chặn join/tin mới; người đã leave không nhận tin mới. Tin nhắn lưu DB/outbox, dispatcher tra membership hiện tại và gửi tới user group.

Thị trường chỉ tổng hợp bài Published của tác giả hoạt động/Approved. Supply/Demand là **kg dự kiến, không phải tồn kho**. Giá tham khảo là trung vị điểm giữa khoảng **chào bán Supply**, kèm min/max/số mẫu, `source=published-user-asking-prices`, VND/kg, `asOf`/`lastUpdated`; Demand bid bị loại, thiếu giá trả null. Đây **không phải dự báo AI hoặc giá thị trường chính thức**. Nhiều bài có thể trùng một lô.

Xem [playbook bốn vai trò 6–8 phút](docs/DEMO_4_ROLES_2_2.md) và [ghi chú hợp đồng 2.2](docs/RELEASE_2_2_INTERACTIONS.md).

## API chính

Prefix `/api/v1`; JSON camelCase, từ chối thuộc tính lạ. List mặc định 20/tối đa 50 và cursor; AI lấy 20 tác vụ gần nhất.

| Route | Quyền/ý nghĩa |
|---|---|
| `/auth/register`, `/auth/login`, `/auth/refresh`, `/auth/mfa/login` | Đăng ký/đăng nhập, session opaque và TOTP |
| `/auth/me`, `/auth/sessions`, `/auth/logout`, `/applications/resubmit` | Hồ sơ/phiên của mình |
| `/admin/applications`, `/admin/posts`, các route `/review`, `/admin/users/{id}/status` | Admin, có lý do và kiểm phiên bản khi xét tin |
| `/catalog/products`, `/posts`, `/posts/{id}`, `/market/summary` | Public read, lọc nội dung theo quyền bản ghi |
| `POST /posts` | Producer/Trader đã duyệt; tạo bài dự kiến |
| `GET /me/posts`, `/history` | Phiên hợp lệ; chỉ dữ liệu của mình |
| `POST /posts/{id}/conversations` | Người khác đã duyệt, không phải Admin |
| `/conversations`, `/conversations/{id}/messages` | Chỉ thành viên; message key idempotent |
| `/community/groups`, `/{id}/join`, `/{id}/leave`, `/{id}/close` | Approved, membership/chủ/Admin theo thao tác |
| `/ai/capabilities`, `/ai/jobs`, `/{id}`, `/{id}/preview`, `/{id}/cancel` | Approved; job/preview chỉ chính chủ, kể cả Admin |
| `/mobile/update?versionCode=6002&abi=arm64-v8a`, `/mobile/releases/{versionCode}/{abi}.apk` | Bản APK operator đã đăng ký, public download có kiểm size/SHA |

Session access 15 phút, refresh tối đa 7 ngày, xoay khóa/chống replay; DB chỉ giữ hash. Identity PBKDF2, TOTP thật, khóa sau nhiều lần sai; role/approval/membership được kiểm phía server. Rate mặc định 120/phút theo người đã đăng nhập hoặc IP ẩn danh, auth 30/IP/phút; quá giới hạn trả `429`/Retry-After. Token không phải JWT; không log password/token/body bí mật.

Hub `/hubs/fruitvision` phát MessageCreated, ConversationCreated, PostChanged/PublishedPostChanged, CommunityChanged, AiJobChanged. Client phải khôi phục REST sau reconnect và dedup ID/revision. Không phải push nền Android; dispatcher hiện dành cho một API instance, chưa có backplane/lease vận hành nhiều instance hoàn chỉnh.

## AI riêng tư trên PC

Cài CPython 3.11 x64, rồi từ `server` (đổi đường dẫn Python theo máy):

```powershell
./scripts/Install-AiRuntime.ps1 -PythonExecutable 'C:\Python311\python.exe' -Configure
./scripts/Stop-Server.ps1
./scripts/Start-Server.ps1
```

Installer tạo `.tools/ai-venv`, cài bảy gói đã ghim trong [requirements-ai.txt](ai/requirements-ai.txt), kiểm import, SHA/metadata/graph và real ORT preflight. `-Configure` sao lưu/giữ AI–DB/secret khác rồi ghi đường dẫn clone tuyệt đối; không cần ổ E: hoặc thư viện toàn máy. Xem [cài trên PC khác](docs/RELEASE_2_2_INTERACTIONS.md). `RunEnabled` mặc định false; thiếu tài nguyên trả `aiReady:false`/`503`. Readiness không thay thế một job thực thành công.

`POST /ai/jobs?mediaType=image|video` nhận raw binary, Bearer và `X-Client-Request-Id` 8–64 ký tự. Không nhận multipart/base64/URL/đường dẫn client. Cùng key, loại và bytes dùng lại job; khác bytes `409`.

| Giới hạn | Ảnh | Video |
|---|---|---|
| Tệp | JPEG/PNG thực, tối đa 12 MiB/24 triệu pixel | MP4 thực, tối đa 80 MiB |
| Nội dung | Một ảnh, có xử lý EXIF | Tối đa 120 giây/3600 khung/1920×1080, cho phép dọc; FPS lớn hơn 0 và không quá 240 |
| Xử lý | CPU trên PC | Mỗi khung đã decode được suy luận; không cộng detection thành unique fruit |

Upload 90 giây, worker 165 giây, API 180 giây; một worker tuần tự, tối đa 4 Queued/Running toàn hệ thống và 1/người. Chủ có thể hủy Queued/Running. Tệp gốc xóa khi kết thúc; kết quả/preview riêng tư còn giữ, chưa có lịch tự xóa theo hạn.

Kết quả tách `maxVisibleCount`, `confirmedTrackCount`, `lineCrossingCount`, `gradeCounts`; ảnh đơn có confirmedTrackCount=0. Không cộng các số thành số quả vật lý duy nhất, kg hoặc tồn kho. Giai đoạn nguồn không bảo đảm độ chín thực địa; yếu/không biết là Chưa xác định. Camera ở client là **chụp một ảnh qua app máy ảnh**, chưa có truyền camera liên tục.

Model SHA `8a69c66a9444c18c98a7e3e58a44f4dddda9eb4583dd4448f430ff9e8db27c41` giữ nguyên; metadata vẫn ghi video-quality FAIL. Chỉ dùng demo phi thương mại; chuyển worker sang PC không mở rộng giấy phép dữ liệu/model. Giữ [nguồn/giấy phép](ai/README.md), [SOURCE_ATTRIBUTION](../app/android/app/src/main/assets/SOURCE_ATTRIBUTION.json), [YOLOX license](../app/android/app/src/main/assets/YOLOX_LICENSE.txt). Xem [AI API](docs/AI_API_USAGE.md).

## Phát hành cập nhật Android

Dùng [Publish-MobileRelease.ps1](scripts/Publish-MobileRelease.ps1) với **ba APK và receipt Android thật**. Version directory/snapshot bất biến, latest manifest thay nguyên tử sau kiểm size/SHA; không có HTTP upload APK tùy ý. Lần đầu `-Configure` cần restart riêng API; lần sau manifest được đọc live. Xem [MOBILE_RELEASES.md](docs/MOBILE_RELEASES.md).

Client cũ chưa có updater cần một lần bootstrap thủ công bằng APK tin cậy. Android vẫn hỏi xác nhận cài; lần đầu có thể cần cho đúng nguồn quyền cài APK. Giữ package/chứng thư ký đồ án để nâng cấp; đây chưa phải khóa phát hành Play Store. Hủy cài không được coi là đã nâng cấp.

## Bằng chứng và phần còn giới hạn

[HTTPS/WSS bốn vai trò](docs/verticals-https-e2e.json): PASS **49,281 giây, 80 HTTP, 4 WSS đồng thời**, có moderation/contact races, Direct riêng, Group join/leave/close, Supply-only price và bản ghi demo thực. Đây là bốn client trên PC, không phải bốn điện thoại. [AI HTTPS E2E](docs/ai-https-e2e.json) giữ bằng chứng ảnh/video và tính nhất quán pipeline; không phải ground truth mô hình. Các receipt 2.1 là lịch sử, không thay thế biên nhận native 6006.

Lệnh kiểm backend: `dotnet test FruitVision.slnx`; integration dùng PostgreSQL/DB thử riêng. Worker: `python -B -m unittest discover -s ai -v` trong môi trường đã cài. Bộ kiểm hiện tại: backend 60/60, Flutter 64/64 và analyzer sạch, native policy 22/22. Ba APK 6006 đã kiểm package/chữ ký/hash; biên nhận Android lưu riêng cùng bản phát hành, không suy từ unit tests thành nghiệm thu điện thoại.

Chưa triển khai đơn mua bán, giữ hàng/chống vượt tồn, thanh toán/giao nhận/tranh chấp, IoT, chuyển Forecast thành tồn kho hoặc camera streaming. Chưa bảo đảm production 24×7, mô hình chính xác ngoài thực địa hay APK cuối đã chạy trên điện thoại thật. Duyệt hồ sơ không phải chứng nhận nông sản.

