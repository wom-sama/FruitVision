# FruitVision 2.4 — Hướng dẫn luồng người dùng và phạm vi demo

**FruitVision 2.4.0+6010 đã được phát hành qua dịch vụ cập nhật và có ba gói Android đã kiểm chữ ký/hash.** Đã thử trên máy ảo: khôi phục phiên Người tiêu dùng, học liệu, đăng nhập Nhà sản xuất bằng Email OTP thật, gửi ảnh xoài/nhận ảnh chú thích và tạo khóa mã hóa Android. Đây không phải kiểm thử bốn điện thoại, kiểm định mật mã độc lập hoặc xác nhận độ chín thực địa. Các tài liệu 2.2/2.3 được giữ làm lịch sử.

## 1. Bốn vai trò

`Seller` là chính sách dùng chung cho **Producer và Trader**, không phải vai trò thứ năm. Một tài khoản có một vai trò hiện hành; API kiểm quyền, trạng thái hoạt động và quyền sở hữu dữ liệu trên mỗi yêu cầu.

| Vai trò | Có thể trình diễn | Điều kiện và giới hạn |
|---|---|---|
| **Consumer — Người tiêu dùng** | Học về xoài; viết bài `Community` kèm ảnh; liên hệ từ bài công bố; chat thường và nhóm; gửi hồ sơ nâng vai trò | Không chạy AI hoặc secret E2EE; không chọn quyền khi đăng ký |
| **Producer — Nhà sản xuất** | Quản lý chi nhánh; bài `Professional` kèm ảnh; liên hệ/chat/nhóm; AI xoài ảnh/video, thống kê và hướng dẫn; secret Direct với Seller khác | Bài Professional cần chi nhánh của mình đã `Approved`; secret có điều kiện thiết bị/khóa riêng |
| **Trader — Thương lái** | Các luồng Seller như Producer; trao đổi chuyên môn về xoài và sử dụng AI theo quyền | Cũng được liên hệ Seller cùng vai trò; tư cách thành viên quyết định quyền đọc chat |
| **Admin — Quản trị** | Duyệt hồ sơ nâng vai trò, chi nhánh, tin và bài viết; khóa/mở tài khoản; audit/thống kê quản trị; quản lý nhóm theo quyền | Không chạy AI, không dùng secret, không tự đọc mọi Direct hoặc ảnh chat riêng; không tạo liên hệ kinh doanh từ bài/tin |

Tài khoản mới bắt đầu bằng Consumer. Không có đăng ký Admin công khai hoặc trường chọn Producer/Trader trong đăng ký. Tên, vai trò và trạng thái tài khoản là dữ liệu do máy chủ xác nhận; ẩn nút trên giao diện không thay cho kiểm quyền.

Nguồn: [chính sách API](../src/FruitVision.Api/Program.cs), [quyền đăng nhập](../src/FruitVision.Api/Auth/AuthEndpoints.cs), [tin kinh doanh](../src/FruitVision.Api/Features/PostWorkflowEndpoints.cs), [giao diện theo vai trò](../../mobile_client/lib/client/ui/workspace.dart).

## 2. Từ đăng ký đến quyền kinh doanh

1. Chọn quốc gia và tỉnh/thành qua API của dự án, nhập thông tin đăng ký. Máy chủ tạo Consumer; phản hồi yêu cầu OTP chưa phải phiên đăng nhập thành công.
2. Nhận **“Mã xác thực FruitVision”** và hoàn thành mã email. Luồng mật khẩu dùng email OTP theo cấu hình đang vận hành; tài khoản đã chủ động bật TOTP dùng ứng dụng xác thực. OTP gồm 6 chữ số, hạn 10 phút, tối đa 5 lần sai; gửi lại chờ 60 giây và không xóa số lần sai. Dịch vụ thư lỗi trả 503, không cấp phiên giả.
3. Consumer đang hoạt động, `Approved` và đã xác minh email có thể xin nâng thành Producer **hoặc** Trader. Producer khai diện tích canh tác dương; Trader khai ít nhất một trong mã số thuế/số đăng ký kinh doanh. Chọn sản phẩm từ danh mục, địa điểm từ API.
4. Hồ sơ đi qua `Draft → Submitted → Approved / NeedsInformation / Rejected`. `Submitted` đóng băng thông tin/tệp; hai trạng thái trả về cho phép sửa và gửi lại. Chỉ `Approved` mới đổi vai trò, không cộng dồn hai vai trò.
5. Minh chứng JPEG/PNG/PDF tối đa **5 MiB/tệp, 4 tệp/hồ sơ**; cần ít nhất một minh chứng đúng loại ProductionEvidence hoặc BusinessEvidence. Tệp nằm riêng, chỉ chủ hồ sơ/Admin được đọc; PDF tải dạng attachment. Đây là kiểm tra định dạng và quyền truy cập, không có tuyên bố quét virus hoặc chứng nhận pháp lý.

Bộ chuyển tiếp thư **FruitVision riêng đang hoạt động qua Gmail của người vận hành** trên bản triển khai hiện tại. App gọi API FruitVision; backend mới gọi bộ chuyển tiếp có xác thực. Không đưa hộp thư, địa chỉ relay, khóa, mật khẩu hay OTP vào slide, mã nguồn hoặc biên bản công khai.

Đăng ký/đổi khóa sinh trắc học mạnh là lựa chọn bổ sung trên Android API 28+ có hỗ trợ, dùng Keystore/BiometricPrompt và chữ ký thử thách; không dùng boolean do client tự khai, không có PIN fallback trong luồng đó. Nhánh ảnh mặt 2D, nếu readiness cho phép, vẫn cần email OTP; không có liveness và không phải xác nhận Face ID/phần cứng hay người thật.

Nguồn: [đăng ký](../src/FruitVision.Api/Auth/AuthEndpoints.cs), [OTP](../src/FruitVision.Api/Auth/EmailOtpService.cs), [transport thư](../src/FruitVision.Api/Auth/AppsScriptOtpMailer.cs), [hồ sơ/minh chứng](../src/FruitVision.Api/Features/RoleApplicationEndpoints.cs), [khóa sinh trắc học](../src/FruitVision.Api/Auth/DeviceBiometricEndpoints.cs), [ảnh mặt 2D](../src/FruitVision.Api/Auth/FaceAuthEndpoints.cs).

## 3. Chi nhánh, tin kinh doanh và bài viết

**Chi nhánh Seller:** tạo `Pending`, Admin chọn `Approved`, `NeedsInformation` hoặc `Rejected`. Chỉnh sửa phải gửi phiên bản hiện tại và đưa hồ sơ về xét duyệt. Chi nhánh bị trả về hoặc chủ tài khoản mất điều kiện sẽ làm nội dung gắn với nó mất tính công khai theo kiểm tra của máy chủ.

**Dữ liệu nghiệp vụ cũ:** API Supply/Demand và tổng hợp giá chào bán được giữ để đọc dữ liệu cũ; công cụ Seller nằm trong mục thu gọn “Công cụ nghiệp vụ trước đây”. Chúng không phải trọng tâm hoặc tính năng giao dịch của bản xoài hiện tại. Số kg cũ là tự khai, không phải sản lượng AI; không có đặt hàng, thanh toán hay giá dự báo được kiểm chứng.

**Bài viết có ảnh:** Consumer gửi lane `Community`; Producer/Trader gửi lane `Professional` với chi nhánh của mình đã duyệt. Cả hai phải qua kiểm duyệt. Tác giả rút bài Published thành Paused; Admin có thể công bố lại. Bài/ảnh chưa công bố chỉ chủ/Admin phù hợp đọc được; ảnh bài đã công bố là công khai. Mọi lần sửa/duyệt dùng `expectedRevision`; gặp 409 phải tải lại, không lặp mù thao tác.

Ảnh thường nhận JPEG/PNG thật tối đa **5 MiB**, máy chủ giải mã, chuẩn hóa JPEG, bỏ EXIF và giới hạn cạnh tối đa 2048. Không tải ảnh bằng URL tùy ý. Chọn liên hệ trên bài/tin Published tạo hoặc dùng lại Direct riêng đúng hai người; cùng người liên hệ cùng nội dung không sinh nhiều thread khi bấm đồng thời. Tự liên hệ nhận 409; Admin không dùng thao tác này.

Nguồn: [bài viết/chi nhánh](../src/FruitVision.Api/Features/PublishingEndpoints.cs), [liên hệ bài viết](../src/FruitVision.Api/Features/ArticleContactEndpoints.cs), [ảnh thường](../src/FruitVision.Api/Features/NormalMediaEndpoints.cs), [tham khảo vùng](../src/FruitVision.Api/Features/MarketEndpoints.cs).

## 4. Chat thường, nhóm và secret E2EE là ba phạm vi rõ ràng

| Luồng | Nội dung và quyền đọc | Cách dùng trong demo |
|---|---|---|
| **Direct thường** | Tin/ảnh được máy chủ lưu và xử lý; chỉ thành viên đọc qua API | Mở từ bài/tin đã công bố; thử người thứ ba biết ID vẫn bị từ chối |
| **Nhóm cộng đồng** | Thành viên hiện tại gửi/đọc lịch sử theo quyền; ảnh là ảnh thường | Approved tạo/join/leave; tối đa 10 nhóm mở/chủ, 50 thành viên/nhóm. Nhóm đóng chặn thành viên mới/tin mới; chủ cần đóng trước khi rời |
| **Secret Direct** | Client mã hóa tin/ảnh; máy chủ giữ ciphertext, public key và metadata định tuyến, không giữ private key của client | Chỉ Producer/Trader đang hoạt động, Approved, trong Direct đúng hai Seller; không dùng cho nhóm/Admin/Consumer hoặc biến lịch sử chat thường thành secret |

Thiết lập/thu hồi thiết bị secret cần đăng nhập lại bằng **mật khẩu + email OTP hoặc TOTP trong 15 phút**. Mỗi tài khoản chỉ có **một thiết bị secret hoạt động**; khóa/UUID bất biến. Đổi thiết bị phải thu hồi rõ ràng rồi đăng ký UUID mới, không tự thay khóa khi lỗi mạng.

Client dùng libsodium sealed box X25519 và chữ ký Ed25519; tin được niêm phong riêng cho hai thiết bị, gồm cả người gửi. Trước lần gửi đầu, hai bên phải đối chiếu **đầy đủ fingerprint 64 ký tự hex qua kênh tin cậy ngoài cuộc chat** rồi xác nhận. Khóa thay đổi yêu cầu xác minh lại. HTTPS bảo vệ đường truyền; fingerprint giúp kiểm tra đúng khóa người đối diện. Người dùng mất khóa có thể không đọc lại lịch sử secret; v1 không có đồng bộ nhiều thiết bị, khôi phục khóa hoặc cam kết forward secrecy/ratchet.

Ảnh secret được client chuẩn hóa, bỏ EXIF rồi mã hóa; server không giải mã hoặc quét nội dung ảnh. Server giới hạn blob **5 MiB + 64 KiB phụ trội**, envelope tối đa 16 KiB; thành viên phải dùng đúng thiết bị còn hiệu lực của bản ghi để tải. Quota chung ảnh thường + blob secret mặc định **100 MiB/người, 2 GiB toàn máy**, chừa ít nhất 1 GiB ổ lưu; đầy quota báo lỗi và liên hệ Admin, không tự xóa lịch sử. Metadata như hai bên, thời điểm, kích thước vẫn hiện diện trên máy chủ.

WSS báo thay đổi; client lấy dữ liệu có quyền qua REST, dedup và tải bù sau reconnect. Không có push nền Android. **88 kiểm tra HTTPS hiện tại chỉ chứng minh ảnh/chat thường và quyền metadata secret; chưa chứng minh luồng mã hóa thực, native keybag hoặc E2EE APK cuối.**

Nguồn: [chat/nhóm](../src/FruitVision.Api/Features/InteractionEndpoints.cs), [nhóm](../src/FruitVision.Api/Features/CommunityEndpoints.cs), [server opaque](../src/FruitVision.Api/Features/SecretMessagingEndpoints.cs), [giao thức client](../../mobile_client/lib/client/secret_protocol.dart), [pin/khóa client](../../mobile_client/lib/client/secret_messaging.dart), [quota](../src/FruitVision.Api/Infrastructure/MediaStorageQuota.cs).

## 5. AI chỉ cho Seller; Consumer có học liệu về xoài

Seller gửi ảnh JPEG/PNG tối đa **12 MiB** hoặc video MP4 tối đa **80 MiB, 120 giây, 1920×1080**. App stream binary lên API; model ONNX chạy bằng ONNX Runtime CPU trên PC. Một worker, tối đa 4 tác vụ Queued/Running toàn hệ thống và một tác vụ/người; có tiến độ, hủy, timeout và lịch sử riêng. Admin/Consumer không có quyền AI; Consumer dùng học liệu `/learning/mango` để đọc/trao đổi mà không tạo tác vụ.

Bản phục vụ 2.4 chỉ giữ đối tượng **được dự đoán là xoài**. Hai nhãn giai đoạn từ dữ liệu nguồn là **“Xanh / chưa chín”** và **“Chín”**; độ tin cậy yếu ghi **“Chưa xác định”**. Không đổi “Chưa xác định” thành xoài hư. Graph, trọng số/SHA và các nhãn loài tổng quát lưu trữ từ nguồn được giữ nguyên; bộ lọc serving không tạo thêm lớp hoặc dữ liệu huấn luyện mới.

`maxVisibleCount` là số lớn nhất thấy đồng thời; `confirmedTrackCount` là track xác nhận; `lineCrossingCount` là số qua vạch. Chúng không bảo đảm số quả vật lý duy nhất, kg hay tồn kho. Nhãn không xác nhận độ chín bên trong, vị ngọt hoặc an toàn thực phẩm; chất lượng video còn hạn chế. Camera hiện chụp một ảnh, không stream AI liên tục. Không có AI offline hoặc cam kết FPS trên điện thoại.

Nguồn: [AI Seller](../src/FruitVision.Api/Ai/AiEndpoints.cs), [thống kê/hướng dẫn](../src/FruitVision.Api/Ai/AiInsightsEndpoints.cs), [worker và nguồn model](../ai/worker.py), [phạm vi xoài 2.4](mango-ai-scope-24.md), [học liệu](../src/FruitVision.Api/Features/LearningEndpoints.cs).

## 6. Một API riêng và cách tổ chức buổi demo

App gọi **một API FruitVision** cho tài khoản, địa điểm, nghiệp vụ, chat, AI và cập nhật APK; WSS cùng máy chủ phục vụ realtime. ASP.NET Core/.NET 10 dùng PostgreSQL, private file storage và tiến trình Python riêng. Backend gọi dịch vụ ngoài cho chuyển tiếp mail và danh mục địa lý HTTPS; client không tự lấy tỉnh hoặc gửi khóa relay cho nhà cung cấp. Danh mục địa điểm trả `source/asOf/stale`, cache tươi 24 giờ và có thể dùng bản cũ tối đa 7 ngày khi nguồn lỗi; không có cache hợp lệ thì báo 503. Việt Nam hiện có 34 tỉnh/thành; đổi quốc gia phải xóa tỉnh cũ. Vùng văn bản ở bản ghi cũ là lịch sử, không tự đổi thành mã địa điểm mới.

Gợi ý lượt demo: **Consumer đăng nhập → đọc học liệu/bài → Seller gửi bài Professional có ảnh → Admin công bố → người khác liên hệ và chat ảnh → kiểm tra người ngoài bị chặn**. Sau đó mới trình diễn AI của Seller hoặc secret khi đã đủ điều kiện và bằng chứng thực. Dùng dữ liệu có nhãn demo; duyệt kỹ thuật không xác nhận giấy tờ, nông sản hay giao dịch thật.

- Backend nguồn 2.4: **157/157 kiểm thử đạt**, không skip, theo đợt full suite người phát hành đã ghi nhận.
- [Nghiệm thu HTTPS 2.4](media-https-acceptance-24.json): **PASS, 88 kiểm tra/49 HTTP, 23,922 giây**; bốn phiên thật đã hoàn thành OTP, ảnh server thực sự chuẩn hóa 2048×1365 và bỏ EXIF. Không có WSS/native/secret crypto acceptance trong receipt này.
- **APK 6010 đã phát hành**: ba gói cùng mã phiên bản/chữ ký, không có trọng số AI; đã xác minh bản ARM64 tải trọn qua HTTPS đúng SHA-256. Android Keystore/xử lý ảnh đạt 4 kiểm tra thiết bị; giao thức Sodium đạt 40 quan sát qua API thật và có tạo khóa thực trên Android. Chưa thử hai điện thoại trao đổi bí mật hoặc so sánh mã an toàn bởi hai người. Web portal chỉ là cổng tài khoản/APK/API.
- PC, PostgreSQL, worker và tunnel phải còn chạy. HTTPS tạm có thể đổi; lấy địa chỉ hiện hành, đăng nhập lại và kiểm tra quyền/phiên. Dừng khi email/địa điểm/AI báo 503, quota báo lỗi hoặc review nhận 409 để xử lý đúng nguyên nhân.

Chưa triển khai đặt hàng, giữ hàng, thanh toán, giao nhận, tồn kho xác thực, IoT, dự báo giá hay bảo đảm vận hành 24×7. Không trình diễn dữ liệu tổng hợp như bằng chứng kinh doanh thật; không công bố token, OTP, khóa hoặc minh chứng cá nhân.

Nguồn triển khai: [địa điểm](../src/FruitVision.Api/Infrastructure/LocationDirectory.cs), [phiên và đăng nhập](../src/FruitVision.Api/Auth/SessionTokens.cs), [README hiện tại](../README.md), [kịch bản HTTPS](PUBLIC_ACCEPTANCE_2_4.md).
