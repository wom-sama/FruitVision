# FruitVision 2.4 — backend trên PC

Backend 2.4 có đăng ký Consumer/Email OTP, hồ sơ nâng vai trò, chi nhánh, bài Community/Professional có kiểm duyệt, ảnh thường, Direct/nhóm, secret Direct dành cho Seller, học liệu và AI xoài trên PC. PostgreSQL giữ dữ liệu, SignalR phát sự kiện, worker chạy model ONNX đã ghim. **APK 2.4.0+6010 đã phát hành; đã thử các luồng chính trên máy ảo, không phải bốn điện thoại thật.** Tin Supply/Demand cũ chỉ được giữ tương thích, không có giao dịch mua bán. Xem [luồng người dùng](docs/USER_WORKFLOWS_2_4.md) và [báo cáo kỹ thuật](docs/TECHNICAL_REPORT_2_4.md).

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

## Bốn vai trò và luồng 2.4

| Vai trò | Luồng hiện có sau khi Approved |
|---|---|
| Admin | Duyệt hồ sơ nâng vai trò/chi nhánh/tin/bài, khóa/mở tài khoản, audit/thống kê; không có quyền AI hoặc secret |
| Producer | Chi nhánh; tin Supply; bài Professional; liên hệ Direct/Group, ảnh thường; AI xoài riêng; secret với Seller khác |
| Trader | Như Producer, tin Demand mặc định hoặc Supply; tìm nguồn cung và trao đổi với Seller kể cả cùng vai trò |
| Consumer | Đọc tin/thị trường/học liệu xoài; bài Community có ảnh; liên hệ Direct/Group và ảnh thường; xin nâng vai trò; không AI/secret/Supply–Demand |

Đăng ký công khai luôn tạo Consumer và cần xác minh email OTP; không nhận trường chọn vai trò. Consumer hoạt động/Approved/đã xác minh email xin nâng Producer hoặc Trader qua hồ sơ `Draft → Submitted → Approved/NeedsInformation/Rejected`. Submitted đóng băng thông tin/minh chứng; chỉ Approved đổi vai trò. Minh chứng JPEG/PNG/PDF tối đa 5 MiB/tệp, 4 tệp, chủ/Admin đọc riêng; không có tuyên bố AV scan hoặc chứng nhận pháp lý.

Seller tạo chi nhánh Pending để Admin duyệt. Tin và bài Professional cần chi nhánh thuộc mình đã Approved; Consumer viết lane Community. Tin/bài mới AwaitingReview; Admin Published/Rejected, Published có thể Paused rồi Published lại; tác giả được rút bài viết Published. Review kiểm `expectedRevision`, tranh chấp trả `409`. Ảnh bài/ảnh chat thường JPEG/PNG tối đa 5 MiB, máy chủ chuẩn hóa JPEG/bỏ EXIF/cạnh tối đa 2048. Ảnh bài Published công khai; ảnh chat chỉ thành viên.

Liên hệ tin hoặc bài viết công khai tạo Direct riêng đúng hai người, dùng lại khi cùng người liên hệ cùng nội dung kể cả yêu cầu đồng thời. Người khác cùng vai trò vẫn được liên hệ; tự liên hệ `409`, Admin liên hệ nghiệp vụ `403`. Chỉ thành viên đọc/gửi tin/ảnh; không nhận danh sách participant tùy ý từ client. Chat thường được máy chủ đọc/xử lý, không gọi là E2EE.

Secret là luồng riêng cho Direct đúng hai Producer/Trader hoạt động/Approved. Client dùng libsodium sealed box X25519/chữ ký Ed25519; server giữ ciphertext và metadata, không giữ private key. Đăng ký/thu hồi khóa cần phiên mật khẩu + email OTP/TOTP mới trong 15 phút, mỗi tài khoản một thiết bị hoạt động. Hai bên đối chiếu đầy đủ fingerprint qua kênh tin cậy ngoài chat và pin trước gửi; đổi khóa phải xác minh lại. Không tự chuyển lịch sử thường sang secret, không có group secret/multi-device/khôi phục khóa/ratchet. Ảnh secret là ciphertext riêng, tối đa 5 MiB + 64 KiB phụ trội; server không giải mã để chuẩn hóa hoặc quét ảnh. Nghiệm thu crypto/native riêng vẫn cần biên bản.

Quota chung ảnh thường + blob secret mặc định 100 MiB/người, 2 GiB toàn máy và chừa ít nhất 1 GiB ổ lưu. Đầy quota trả lỗi, không tự xóa lịch sử; liên hệ Admin để xử lý lưu trữ.

Nhóm công khai cho Approved tự tạo/join/leave; tối đa 10 nhóm mở/chủ, 50 thành viên/nhóm. Chủ cần đóng trước khi rời; chủ/Admin được đóng. Nhóm đóng giữ lịch sử cho thành viên hiện tại, chặn join/tin mới; người đã leave không nhận tin mới. Tin nhắn lưu DB/outbox, dispatcher tra membership hiện tại và gửi tới user group.

Thị trường chỉ tổng hợp bài Published của tác giả hoạt động/Approved. Supply/Demand là **kg dự kiến, không phải tồn kho**. Giá tham khảo là trung vị điểm giữa khoảng **chào bán Supply**, kèm min/max/số mẫu, `source=published-user-asking-prices`, VND/kg, `asOf`/`lastUpdated`; Demand bid bị loại, thiếu giá trả null. Đây **không phải dự báo AI hoặc giá thị trường chính thức**. Nhiều bài có thể trùng một lô.

Luồng demo hiện tại xem [USER_WORKFLOWS_2_4](docs/USER_WORKFLOWS_2_4.md). [Playbook 2.2](docs/DEMO_4_ROLES_2_2.md), [hợp đồng 2.2](docs/RELEASE_2_2_INTERACTIONS.md) và [luồng 2.3](docs/USER_WORKFLOWS_2_3.md) được giữ làm tài liệu lịch sử.

## API chính

Prefix `/api/v1`; JSON camelCase, từ chối thuộc tính lạ. List mặc định 20/tối đa 50 và cursor; AI lấy 20 tác vụ gần nhất.

| Route | Quyền/ý nghĩa |
|---|---|
| `/auth/register`, `/auth/login`, `/auth/otp/verify`, `/auth/otp/resend`, `/auth/refresh`, `/auth/mfa/login` | Consumer mới, email OTP/TOTP, session opaque; challenge chưa phải đăng nhập thành công |
| `/auth/me`, `/auth/sessions`, `/auth/logout`, `/applications/resubmit` | Hồ sơ/phiên của mình |
| `/locations/countries`, `/locations/provinces?country=VN` | Danh mục API có source/asOf/stale; Việt Nam hiện có 34 tỉnh/thành |
| `/role-applications`, `/admin/role-applications`, các route evidence/review | Consumer đã xác minh xin nâng vai trò, minh chứng riêng và Admin xét duyệt |
| `/admin/applications`, `/admin/posts`, các route `/review`, `/admin/users/{id}/status` | Admin, có lý do và kiểm phiên bản khi xét tin |
| `/catalog/products`, `/posts`, `/posts/{id}`, `/market/summary` | Public read, lọc nội dung theo quyền bản ghi |
| `POST /posts`, `/branches/mine`, `/branches` | Seller; tin dự kiến cần chi nhánh thuộc mình đã duyệt |
| `/articles`, `/articles/images`, `/articles/{id}/image`, `/admin/articles`, `/admin/branches` | Community/Professional, ảnh thường và kiểm duyệt theo quyền |
| `GET /me/posts`, `/history` | Phiên hợp lệ; chỉ dữ liệu của mình |
| `POST /posts/{id}/conversations`, `/articles/{id}/conversations` | Người khác đã duyệt, không phải Admin; tạo/dùng lại Direct |
| `/conversations`, `/conversations/{id}/messages`, `/{id}/images` | Chỉ thành viên; message/image key idempotent |
| `/community/groups`, `/{id}/join`, `/{id}/leave`, `/{id}/close` | Approved, membership/chủ/Admin theo thao tác |
| `/secret/devices`, `/secret/conversations`, `/{id}/messages`, `/{id}/attachments` | Seller đúng hai thành viên/thiết bị; server opaque, không phải chat thường |
| `/learning/mango` | Học liệu xoài cho Approved, không tạo tác vụ AI |
| `/ai/capabilities`, `/ai/jobs`, `/{id}`, `/{id}/preview`, `/{id}/cancel`, `/ai/stats`, `/ai/guide` | Chỉ Seller; job/preview/thống kê chỉ chính chủ; Admin/Consumer bị từ chối |
| `/mobile/update?versionCode=6002&abi=arm64-v8a`, `/mobile/releases/{versionCode}/{abi}.apk` | Bản APK operator đã đăng ký, public download có kiểm size/SHA |

Session access 15 phút, refresh tối đa 7 ngày, xoay khóa/chống replay; DB chỉ giữ hash. Identity PBKDF2, email OTP/TOTP, khóa sau nhiều lần sai; role/approval/membership được kiểm phía server. Relay FruitVision riêng đang gửi mail qua Gmail của người vận hành, tiêu đề “Mã xác thực FruitVision”; không công bố địa chỉ hoặc khóa relay. Rate mặc định 120/phút theo người đã đăng nhập hoặc IP ẩn danh, auth 30/IP/phút; quá giới hạn trả `429`/Retry-After. Token không phải JWT; không log password/token/body bí mật.

Hub `/hubs/fruitvision` phát MessageCreated, ConversationCreated, PostChanged/PublishedPostChanged, CommunityChanged, ArticleChanged/PublishedArticleChanged, AiJobChanged và thông báo secret chỉ chứa metadata. Client phải khôi phục REST sau reconnect và dedup ID/revision. Không phải push nền Android; dispatcher hiện dành cho một API instance, chưa có backplane/lease vận hành nhiều instance hoàn chỉnh.

App gọi một API riêng cho mọi chức năng và WSS cùng máy chủ. Backend gọi nguồn địa điểm HTTPS và relay mail; AI chạy tiến trình Python tại PC. Địa điểm cache tươi 24 giờ, có thể dùng snapshot tối đa 7 ngày khi nguồn lỗi với cờ stale; không có dữ liệu hợp lệ thì 503. Web portal có phạm vi giới hạn, không thay toàn bộ app mobile.

## AI xoài riêng tư của Seller trên PC

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

Bản phục vụ 2.4 lọc chỉ đối tượng **được dự đoán là xoài**; graph/trọng số/SHA, ngưỡng và nhãn loài tổng quát lưu trữ từ nguồn được giữ nguyên. Hai nhãn giai đoạn nguồn là **Xanh / chưa chín** và **Chín**; yếu/không biết ghi **Chưa xác định**, không gọi là xoài hư. Xem [phạm vi xoài](docs/mango-ai-scope-24.md).

Kết quả tách `maxVisibleCount`, `confirmedTrackCount`, `lineCrossingCount`, `gradeCounts`; ảnh đơn có confirmedTrackCount=0. Không cộng các số thành số quả vật lý duy nhất, kg hoặc tồn kho. Nhãn không bảo đảm độ chín bên trong hoặc an toàn thực phẩm. Camera ở client là **chụp một ảnh qua app máy ảnh**, chưa có truyền camera liên tục. Không có AI offline hay cam kết FPS trên điện thoại; Consumer đọc học liệu xoài, Admin không có quyền AI.

Model SHA `8a69c66a9444c18c98a7e3e58a44f4dddda9eb4583dd4448f430ff9e8db27c41` giữ nguyên; metadata vẫn ghi video-quality FAIL. Chỉ dùng demo phi thương mại; chuyển worker sang PC không mở rộng giấy phép dữ liệu/model. Giữ [nguồn/giấy phép](ai/README.md), [SOURCE_ATTRIBUTION](../app/android/app/src/main/assets/SOURCE_ATTRIBUTION.json), [YOLOX license](../app/android/app/src/main/assets/YOLOX_LICENSE.txt). Xem [AI API](docs/AI_API_USAGE.md).

## Phát hành cập nhật Android

Dùng [Publish-MobileRelease.ps1](scripts/Publish-MobileRelease.ps1) với **ba APK và receipt Android thật**. Version directory/snapshot bất biến, latest manifest thay nguyên tử sau kiểm size/SHA; không có HTTP upload APK tùy ý. Lần đầu `-Configure` cần restart riêng API; lần sau manifest được đọc live. Xem [MOBILE_RELEASES.md](docs/MOBILE_RELEASES.md).

Client cũ chưa có updater cần một lần bootstrap thủ công bằng APK tin cậy. Android vẫn hỏi xác nhận cài; lần đầu có thể cần cho đúng nguồn quyền cài APK. Giữ package/chứng thư ký đồ án để nâng cấp; đây chưa phải khóa phát hành Play Store. Hủy cài không được coi là đã nâng cấp.

## Bằng chứng và phần còn giới hạn

[HTTPS 2.4](docs/media-https-acceptance-24.json): **PASS 88 kiểm tra/49 HTTP, 23,922 giây**, bốn phiên thực đã hoàn thành OTP; Community/Professional có ảnh chuẩn hóa, kiểm duyệt, article Direct/ảnh riêng, idempotency và quyền đọc metadata secret. Receipt không chạy WSS, native hoặc crypto E2EE, không đăng ký khóa giả cho tài khoản demo. Full suite backend nguồn 2.4 đạt **157/157, không skip** theo đợt kiểm người phát hành ghi nhận. APK 2.4.0+6010 đã phát hành. Đã thử luồng Email OTP/ảnh AI và tạo khóa trên máy ảo; crypto API thật có biên nhận riêng, không có kiểm định mật mã độc lập hoặc kiểm thử bốn điện thoại.

Bằng chứng lịch sử: [HTTPS/WSS bốn vai trò](docs/verticals-https-e2e.json) PASS 80 HTTP/4 WSS trên PC; [AI HTTPS E2E](docs/ai-https-e2e.json) giữ bằng chứng pipeline ảnh/video, không phải ground truth mô hình. Các receipt cũ không thay cho kiểm thử native, cảm biến hoặc secret crypto của bản mới.

Lệnh kiểm backend: `dotnet test FruitVision.slnx`; integration dùng PostgreSQL/DB thử riêng. Worker: `python -B -m unittest discover -s ai -v` trong môi trường đã cài. Số kiểm thử Flutter/native và package/chữ ký/hash phải lấy từ receipt của đúng bản phát hành; không dùng số liệu 6006 hoặc unit tests để suy thành nghiệm thu APK 6010/điện thoại.

Chưa triển khai đơn mua bán, giữ hàng/chống vượt tồn, thanh toán/giao nhận/tranh chấp, IoT, chuyển Forecast thành tồn kho hoặc camera streaming. Chưa bảo đảm production 24×7, mô hình chính xác ngoài thực địa hay APK cuối đã chạy trên điện thoại thật. Duyệt hồ sơ không phải chứng nhận nông sản.

