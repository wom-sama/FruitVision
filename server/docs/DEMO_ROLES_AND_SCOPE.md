> Lưu trữ bằng chứng 2.0–2.1; các biên nhận local không nằm trong Git. Bản hiện tại xem [demo 2.2](DEMO_4_ROLES_2_2.md) và biên nhận cùng APK, không coi thông tin dưới đây là trạng thái mới nhất.

# FruitVision 2.1 — Danh sách vai trò và phạm vi demo

Đối chiếu mã và QA ngày 30/10/2026. **Có trong app** là có màn hình và API thật; **API-only** là backend có nhưng APK chưa có luồng thao tác; **chưa triển khai** là không giới thiệu như tính năng đã hoàn tất. Bằng chứng chạy từng phiên bản được tách ở mục 5.

## 1. Bốn vai trò trong app hôm nay

Các quyền nghiệp vụ cần tài khoản **đang hoạt động và Approved**; chat còn cần thành viên, AI còn cần chủ sở hữu tác vụ. Role do server trả về khi đăng nhập, không phải người dùng tự chọn lúc login.

| Vai trò | Có trong app | API-only / giới hạn giao diện | Không có quyền hoặc chưa có nghiệp vụ |
|---|---|---|---|
| **Admin — Quản trị** | Tab Hồ sơ: số liệu tài khoản/tin/chat/session; lọc và xem hồ sơ; phê duyệt, yêu cầu bổ sung, từ chối; khóa/mở tài khoản nghiệp vụ có lý do. Tab AI, Trao đổi, Tài khoản và lịch sử riêng | Audit có `/admin/audit` nhưng chưa có màn audit. Public feed đọc được qua API, chưa có tab nguồn cung trong workspace Admin | Không tự đăng ký Admin; không đăng tin theo policy Seller; không mặc định đọc chat/AI riêng người khác. Chưa có duyệt xuất bản tin |
| **Producer — Nhà sản xuất** | Tab đầu **Tin của tôi**; **Tạo tin dự kiến** theo danh mục server, nhập tiêu đề/mô tả/kg dự kiến; xem trạng thái tin. AI, chat có thành viên, lịch sử và tài khoản | Public feed là API công khai nhưng Producer đã duyệt hiện không có mục Khám phá riêng trong workspace | Không xét duyệt user; chưa sửa/xóa/xuất bản/tạm dừng tin; chưa thu hoạch/lô/kho/bán hàng |
| **Trader — Thương lái** | Tab **Nguồn cung**; nút **Tin dự kiến của tôi** mở danh sách/form tin của mình. AI, chat có thành viên, lịch sử và tài khoản | Các chức năng phiên/MFA ở mục 3 chưa có màn quản lý đầy đủ | Không quản trị; chưa đặt mua, chốt giá, nhập kho, giữ hàng hoặc thanh toán |
| **Consumer — Người tiêu dùng** | Tab **Khám phá** xem tin công khai; AI sau duyệt; chat có thành viên; lịch sử, tài khoản | Các chức năng phiên/MFA ở mục 3 chưa có màn quản lý đầy đủ | Không có quyền/nút đăng tin người bán; chưa giỏ hàng, đặt hàng, thanh toán hoặc theo dõi giao hàng |

Nguồn: [workspace.dart](../../mobile_client/lib/client/ui/workspace.dart), [admin.dart](../../mobile_client/lib/client/ui/admin.dart), [forms.dart](../../mobile_client/lib/client/ui/forms.dart), [models.dart](../../mobile_client/lib/client/models.dart), [policy server](../src/FruitVision.Api/Program.cs), [API tài khoản](../src/FruitVision.Api/Features/AccountEndpoints.cs), [API nội dung/chat](../src/FruitVision.Api/Features/InteractionEndpoints.cs), [API AI](../src/FruitVision.Api/Ai/AiEndpoints.cs).

## 2. Trạng thái hồ sơ và luồng xét duyệt

| Trạng thái | Có thể demo | Giới hạn |
|---|---|---|
| **Pending — Chờ duyệt** | Đăng nhập, xem hồ sơ/tin công khai/lịch sử riêng, Cập nhật hồ sơ | Chưa đăng tin, AI hoặc chat; không nhận WSS Approved để tự biết vừa được duyệt, cần REST refresh |
| **NeedsInformation — Cần bổ sung** | Đọc lý do, **Bổ sung và gửi lại** tên hiển thị/khu vực, quay về Pending | Chưa có tải giấy tờ pháp lý/chứng nhận trong luồng bổ sung |
| **Rejected — Từ chối** | Đọc lý do và gửi lại hai trường trên nếu còn hoạt động | Không tự chuyển Approved; Admin xét lại |
| **Approved — Đã duyệt** | Nhận quyền phù hợp role và owner/thành viên | Duyệt user không đồng nghĩa duyệt mọi tin hoặc chứng nhận chất lượng nông sản |
| **Đã khóa — isActive=false** | Admin khóa/mở với lý do; phiên cũ bị thu hồi và hub bị ngắt | Là trạng thái hoạt động riêng, không phải approvalStatus mới |

Đăng ký chỉ cho ba role nghiệp vụ; server luôn đặt Pending. Có nhập TOTP khi login nếu tài khoản đã bật MFA. Nguồn: [auth.dart](../../mobile_client/lib/client/ui/auth.dart), [session.dart](../../mobile_client/lib/client/session.dart), [AuthEndpoints.cs](../src/FruitVision.Api/Auth/AuthEndpoints.cs), [AccountEndpoints.cs](../src/FruitVision.Api/Features/AccountEndpoints.cs).

## 3. Những chỗ phải phân biệt trước buổi demo

| Chức năng | Có trong app / API | Điều không nên hứa |
|---|---|---|
| Gửi tin dự kiến | Producer/Trader đã duyệt gửi được; tin mặc định **AwaitingReview** | **Chưa có API hoặc màn Admin duyệt/xuất bản post.** Demo dừng ở tin Chờ kiểm duyệt, không hứa gửi mới rồi công khai ngay |
| Tin công khai | Chỉ Published, tác giả còn hoạt động và Approved; Trader/Consumer xem trong app | `estimatedQuantityKg` là dự kiến; `actualStockKg=null`, `canOrder=false`. Không gọi là tồn kho/có thể mua |
| Chat | Xem/gửi/nhận tin trong **hội thoại đã tham gia**, có lịch sử và tải tin cũ | **Chưa có tạo conversation/thêm thành viên/liên hệ từ một post.** User mới được duyệt vẫn có thể chưa có chat |
| AI ảnh/video | Cả bốn role Approved có chọn tệp, upload/progress, job, hủy, kết quả/preview | Không mặc định xem job người khác; không biến kết quả đếm thành kg hoặc giao dịch |
| Camera | Có nút mở camera ngoài để chụp ảnh tĩnh | Chưa có live camera stream/nhận diện liên tục; thao tác chụp thực phải được kiểm riêng |
| MFA | Có bước nhập TOTP khi login; Account hiển thị đã bật/chưa bật | Setup/enable MFA là **API-only**; APK chưa có luồng thiết lập MFA |
| Phiên đăng nhập | Có logout và lưu token an toàn | GET `/auth/sessions`, DELETE `/auth/sessions/{id}` là **API-only**; số phiên trên dashboard không phải màn quản lý từng phiên |
| Audit | Admin có GET `/admin/audit` | **API-only**, không có màn audit trong APK |

Nguồn thao tác: [forms.dart](../../mobile_client/lib/client/ui/forms.dart), [chat.dart](../../mobile_client/lib/client/ui/chat.dart), [ai.dart](../../mobile_client/lib/client/ui/ai.dart), [AuthEndpoints.cs](../src/FruitVision.Api/Auth/AuthEndpoints.cs), [InteractionEndpoints.cs](../src/FruitVision.Api/Features/InteractionEndpoints.cs), [Android MainActivity](../../mobile_client/android/app/src/main/kotlin/vn/mangodemo/mango_offline/MainActivity.kt).

**Chuẩn bị dữ liệu:** seed ban đầu có 24 user, 60 tin dự kiến, 16 hội thoại, 480 tin nhắn và 200 lịch sử tổng hợp. Đây là dữ liệu minh họa, không phải giao dịch/kiểm định thật; QA có thể đã thêm bản ghi nên số hiện tại cao hơn. Seed không cấp hội thoại cho Admin. Dùng hai thành viên nghiệp vụ có chung hội thoại để demo chat; không dùng Admin để xem mọi cuộc trao đổi. [Seed và thành viên mẫu](../seed/demo-data.json).

## 4. Công nghệ, cách chạy và khác với bản offline cũ

| Phần | Đang dùng làm gì? |
|---|---|
| Flutter/Dart + Kotlin | UI theo role; HTTP/WSS; Kotlin nối Keystore và chọn/chụp media qua MethodChannel |
| ASP.NET Core 10 / Identity | API, mật khẩu, TOTP, opaque session, role/approval/owner check |
| PostgreSQL / EF Core / Npgsql | Lưu user, session, chat, job và lịch sử; transaction và migration |
| Python 3.11 / Pillow / OpenCV / ONNX Runtime CPU | Decode ảnh/video, chạy model ONNX FP32 đã ghim hash, tracking và preview trên PC |
| SignalR WSS | Sự kiện chat/job khi app đang hoạt động; REST lấy lại dữ liệu khi mất kết nối |
| Android Keystore / AES-GCM / HTTPS | Bảo vệ token lưu cục bộ và kết nối; không phải sinh trắc học |

**Khác bản cũ:** `app/` có native detector và tài sản model để suy luận cục bộ. APK mới ở `mobile_client/` không chứa model/runtime AI, chỉ gửi tệp và nhận kết quả từ `server/` trên PC. Tái sử dụng model đã ghim không biến APK mới thành app offline. Nguồn: [NativeDetector cũ](../../app/android/app/src/main/kotlin/vn/mangodemo/mango_offline/NativeDetector.kt), [Program.cs](../src/FruitVision.Api/Program.cs), [AiJobWorker.cs](../src/FruitVision.Api/Ai/AiJobWorker.cs), kiểm APK cuối (`../../mobile_client/verification/2.1-polished/apk-verification-final.json` — biên nhận local).

PC tự host, **không dùng Render**. Quick Tunnel HTTPS tạm có thể đổi hostname; PC/API/DB/tunnel phải chạy và điện thoại cần mạng. Chưa có vận hành 24/7, tên miền cố định, auto-start/Windows Service, backup/retention hoàn chỉnh hoặc signer phát hành Play Store. Chưa có push khi app đóng.

AI nhận ảnh 12 MiB/24 triệu pixel hoặc MP4 80 MiB/120 giây/3.600 khung/1080p, có timeout. Mỗi người một job hoạt động, toàn hệ thống bốn job và một worker. Số đang thấy, track xác nhận và qua vạch là các phép đếm khác nhau; không phải số quả vật lý duy nhất đã kiểm chứng. Nhãn giai đoạn nguồn/Chưa xác định không chứng nhận độ chín, an toàn thực phẩm hoặc chất lượng hàng hóa. Model kết hợp hiện chỉ **demo phi thương mại**; xem [giới hạn nguồn](../ai/README.md).

**Chưa có thương mại hoặc IoT:** giỏ hàng, đơn mua/bán, thanh toán, giữ hàng/tồn kho, thu hoạch/lô, giao nhận, hoàn tiền/tranh chấp, ESP32/cảm biến, MQTT và dữ liệu/điều khiển phần cứng chưa có workflow vận hành. Dashboard đếm user/tin/chat/session, không phải doanh thu hay cảm biến. Server báo `tradeFlowReady=false`. [Nguồn API và capabilities](../src/FruitVision.Api/Program.cs).

## 5. Đã kiểm đến đâu? Không gộp các phiên bản

| Mức bằng chứng | Kết luận dùng được |
|---|---|
| Native 2.0 cũ (`../../mobile_client/verification/android-ui-smoke.json` — biên nhận local) | Khôi phục phiên, Producer/Trader/Consumer nhận đúng UI và không có quyền Admin. File này không xác nhận Admin native UI hoặc mọi role trên APK cuối 2.1 |
| Mã hiện tại và test widget/session | Có nhánh bốn role, form/trạng thái; không thay cho kiểm từng thao tác trên thiết bị |
| Polished 2.1 (`../../mobile_client/verification/2.1-polished/android-acceptance.json` — biên nhận local), chat (`../../mobile_client/verification/2.1-polished/chat-ui.json` — biên nhận local) | Đã có cài APK/khôi phục phiên, workspace Producer, WSS/join và tin mới tự tải. Chat vẫn phải cuộn xuống cuối mới thấy tin mới |
| QA Android mới hoàn tất (`../../mobile_client/verification/2.1-lowram-validation/acceptance.json` — biên nhận local) | APK polished 2.1.0: bốn vai trò đăng nhập/UI/logout đã chạy thật; ảnh ba quả Xanh và video đủ 1.073 khung đã hiện kết quả. Một lượt video mới đi từ SAF/upload Android qua PC tới kết quả tự cập nhật cũng PASS. Camera ngoài mở được preview nhưng shutter emulator bị vô hiệu; chưa xác nhận chụp thành công |
| [HTTPS/WSS server](ai-https-e2e.json), job mobile (`../../mobile_client/verification/2.1-polished/mobile-submitted-jobs.json` — biên nhận local) | PC xử lý ảnh/video thật và kiểm quyền. Server Succeeded không tự chứng minh mọi màn APK đã render hoặc đã kiểm điện thoại thực |

RAM emulator ghi ở các lượt cũ có thể chỉ là **mức yêu cầu**, chưa xác nhận trong guest. Lượt lowram mới đã đối chiếu `/proc/meminfo`, nhưng không dùng RAM guest thay cho PSS/CPU/FPS của app. Có snapshot PSS khi xem kết quả ảnh/video lần lượt là 75.617 và 74.830 KiB, guest có swap; đây không phải benchmark điện thoại hoặc phép đo CPU/FPS liên tục. Bốn workspace đã chạy, nhưng không suy rộng thành đã kiểm mọi thao tác trong mỗi workspace. Khi có biên nhận mới, đối chiếu đúng hash APK. Các biên nhận cuối (`../../mobile_client/verification/2.1-polished` — biên nhận local).

## 6. Danh sách thao tác để lên demo ngày mai

1. **Giới thiệu ranh giới:** Android là client; PC giữ API, DB, model; kết nối bằng HTTPS/WSS.
2. **User mới/Pending → Admin:** đăng ký role nghiệp vụ, xem Chờ duyệt; Admin mở hồ sơ, nhập lý do, bổ sung/duyệt. User bấm Cập nhật hồ sơ; bổ sung hiện chỉ sửa tên/khu vực.
3. **Producer:** tạo tin dự kiến và xem Chờ kiểm duyệt. Dừng đúng ở đây, không hứa bước xuất bản chưa có.
4. **Trader/Consumer:** dùng tài khoản mẫu đã duyệt; chỉ nguồn cung, lối vào tin của Trader và việc Consumer không có đăng tin.
5. **Chat:** dùng hai thành viên có chung hội thoại mẫu; đứng ở cuối danh sách, gửi/nhận tin. Không giới thiệu tạo hội thoại mới.
6. **AI và kết luận:** chọn ảnh nhỏ đã chuẩn bị, tách upload với phân tích, giải thích kết quả. Video/camera trình bày theo đúng mức đã quan sát; nếu dùng biên nhận thì nói rõ. Kết lại: “Có phân quyền, tin dự kiến, chat và AI theo tác vụ; chưa hoàn thành thương mại, IoT hoặc camera liên tục.”

Chi tiết luồng công nghệ: [TECHNICAL_FLOW_2_1.md](TECHNICAL_FLOW_2_1.md). Tài liệu này chỉ đọc mã/biên nhận, không chạy SDK/VM/test suite hoặc thay đổi tài khoản/dữ liệu.


## Bổ sung bản 2.1.1

Bản 2.1.1+6002 giữ nguyên các vai trò và API nêu trên, sửa cách cuộn chat. Trên Android release đã xác nhận: mở tin mới nhất và thấy tin gửi từ phiên HTTPS độc lập mà không cuộn hoặc bấm làm mới; xem lại kết quả ảnh/video cũng đạt. Toàn bộ 40 kiểm thử Flutter và analyzer đạt. Lượt video mới đầy đủ và bốn workspace được kiểm trên 2.1.0 ngay trước đó; không đổi AI hoặc các workspace trong bản vá này. Chụp ảnh tĩnh vẫn chưa được xác nhận thành công trong emulator, và không có camera truyền liên tục.
