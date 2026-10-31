# FruitVision 2.5 — Luồng sử dụng, dữ liệu và trạng thái nghiệm thu

Các tệp ghi “không công bố” chỉ có trong bộ làm việc/bàn giao nội bộ; bản clone này không kèm các tệp đó.

Tài liệu dùng để chuẩn bị demo và đánh giá bản **2.5.0+6011**. Backend đã triển khai với 8 migration. Ba APK đã có kiểm tra đóng gói; **đã kiểm tra một số luồng thực tế trên APK cuối ở máy ảo; lượt bốn thiết bị vật lý đồng thời chưa thực hiện**. Không dùng kiểm thử API hoặc chữ ký APK để kết luận mọi thao tác trên điện thoại đã hoàn tất. Người phát hành cần cập nhật receipt sau bản build cuối nếu tiếp tục sửa giao diện/camera.

Lịch thao tác của bốn người, bỏ qua đăng ký/đăng nhập: [DEMO 10 PHÚT — 4 VAI TRÒ](DEMO_10_PHUT_4_VAI_TRO.md).

## 1. Bản này thực hiện những gì?

`Seller` là chính sách chung cho **Producer và Trader**, không phải vai trò thứ năm.

| Vai trò | Chức năng chính | Giới hạn quyền |
|---|---|---|
| **Consumer** | Học về xoài, đọc nội dung công khai/giá chào bán tham khảo; bài Community có ảnh; like/comment; liên hệ tác giả, Direct và nhóm; nộp hồ sơ nâng vai trò | Không chạy AI, không dùng secret, không đăng Supply/Demand |
| **Producer** | Chi nhánh; bài Professional có ảnh; tin Supply dự kiến; Direct/nhóm/ảnh thường; like/comment; AI ảnh/video/camera, thống kê/hướng dẫn; secret với Seller khác | Nội dung kinh doanh cần chi nhánh thuộc mình đã được duyệt; dữ liệu AI riêng |
| **Trader** | Như Producer; tin mặc định Demand hoặc chọn Supply; tìm nguồn cung, liên hệ Producer/Trader, kể cả cùng vai trò | Không có quyền đọc Direct/AI của người khác chỉ vì là Seller |
| **Admin** | Duyệt hồ sơ nâng vai trò, chi nhánh, bài/tin; quản lý tài khoản; tạo/đóng nhóm; xóa comment vi phạm và tham gia chat theo membership | **Không AI, không secret**; không tự đọc Direct riêng không tham gia |

Các thao tác được kiểm tra tại API, gồm tài khoản đang hoạt động, approval, vai trò, chủ sở hữu và thành viên. GUID hoặc tham số trên URL không tạo quyền truy cập. App gọi một API FruitVision và WSS cùng máy chủ; web portal chỉ có một phần chức năng mobile.

## 2. “Lưu bản nháp” chưa phải “Gửi xét duyệt”

Đăng ký luôn tạo **Consumer**; client không tự chọn Admin/Producer/Trader. Consumer đã xác minh email, đang hoạt động và Approved mới xin nâng vai trò:

1. Chọn Producer hoặc Trader, tạo `Draft`. Producer khai diện tích canh tác dương; không khai mã đăng ký của Trader. Trader khai ít nhất một trong mã số thuế/số đăng ký kinh doanh; không khai diện tích canh tác.
2. Chọn quốc gia/tỉnh qua API, sản phẩm trong danh mục, nhập thông tin liên hệ. JPEG/PNG/PDF tối đa **5 MiB/tệp, 4 tệp/hồ sơ**; ít nhất một minh chứng đúng ProductionEvidence hoặc BusinessEvidence.
3. **“Lưu bản nháp”** hoặc **“Thêm chứng từ”** chỉ lưu dữ liệu của chủ hồ sơ. Cần bấm **“Gửi xét duyệt”** và nhận thành công: trạng thái thành `Submitted`, có thời điểm nộp, thông tin/tệp đóng băng.
4. Admin dùng **“Duyệt nâng vai trò” → “Đã gửi xét duyệt”** — API `/admin/role-applications?status=Submitted`. Đây là hàng đợi khác với `/admin/applications` xét tài khoản cũ. Danh sách có tên/vai trò applicant, sắp theo thời điểm nộp; sự kiện sau commit giúp tải lại danh sách.
5. Admin chọn `Approved`, `NeedsInformation` hoặc `Rejected`, có lý do và `expectedRevision`. Chỉ Approved đổi vai trò. Hai trạng thái trả về cho phép sửa/gửi lại; Consumer vẫn giữ vai trò hiện tại. Mỗi người chỉ có một hồ sơ hoạt động trong Draft/Submitted/NeedsInformation.

Gặp 409 phải tải lại trạng thái/phiên bản rồi quyết định. Không tự chuyển Draft thành Submitted và không nộp hộ hồ sơ của người khác. Trong demo bốn vai trò, hồ sơ **QA tổng hợp** nên kết thúc Rejected có lý do kỹ thuật, để Consumer không mất vai trò. Không dùng minh chứng tổng hợp như bằng chứng pháp lý.

Minh chứng chỉ chủ/Admin đọc; PDF tải dạng attachment, không có URL công khai. Kiểm tra định dạng, chữ ký tệp và quyền truy cập **không phải quét virus hoặc chứng nhận giấy tờ**.

Nguồn: [hồ sơ API](../src/FruitVision.Api/Features/RoleApplicationEndpoints.cs), [giao diện hồ sơ](../../mobile_client/lib/client/ui/role_applications.dart), [hàng đợi Admin](../../mobile_client/lib/client/ui/moderation.dart).

## 3. Vì sao mở app lại có thể không hỏi OTP?

**Đăng nhập mới bằng mật khẩu** đi qua email OTP theo cấu hình vận hành; tài khoản đã chủ động bật TOTP dùng mã ứng dụng xác thực. OTP 6 chữ số có hạn 10 phút, tối đa 5 lần sai; gửi lại chờ 60 giây và không xóa số lần sai. Chưa xác minh xong thì chưa có phiên đăng nhập. Relay FruitVision riêng đang gửi thư qua Gmail của người vận hành, tiêu đề **“Mã xác thực FruitVision”**; app không nhận khóa relay.

**Mở lại một phiên còn hợp lệ** là khôi phục phiên đã xác thực: app đọc vault mã hóa, kiểm tra profile, hoặc xoay refresh token còn hạn để lấy cặp token mới. Không cần gửi lại OTP mỗi lần mở app. Access token có hạn khoảng 15 phút, refresh tối đa 7 ngày theo hạn máy chủ; hết hạn/bị thu hồi thì đăng nhập lại. Refresh bị dùng lại có cơ chế thu hồi họ phiên. Đăng xuất xóa dữ liệu phiên local và thu hồi phiên tương ứng phía server.

Việc mở lại/refresh **không biến phiên cũ thành lần xác thực mạnh mới**. Quản lý khóa sinh trắc học, face hoặc thiết bị secret cần phiên mật khẩu + email OTP/TOTP được tạo trong **15 phút**. Đăng nhập bằng khóa sinh trắc học đơn thuần không đủ để thêm khóa khác.

Sinh trắc học mạnh Android là lựa chọn bổ sung trên API 28+ và thiết bị hỗ trợ, không có PIN fallback trong luồng này. Máy chủ kiểm chữ ký thử thách một lần, không nhận `biometricVerified=true`. Nhánh ảnh mặt 2D, khi readiness cho phép, vẫn cần email OTP và không thay thế nhánh TOTP đã bật.

Nguồn: [phiên opaque](../src/FruitVision.Api/Auth/SessionTokens.cs), [OTP](../src/FruitVision.Api/Auth/EmailOtpService.cs), [khóa thiết bị](../src/FruitVision.Api/Auth/DeviceBiometricEndpoints.cs), [khôi phục/lưu phiên](../../mobile_client/lib/client/session.dart).

## 4. Dữ liệu nhạy cảm nằm ở đâu?

Hash dùng để kiểm tra giá trị, không phải một bản mật khẩu/token có thể giải mã. Mã hóa dùng khóa để mở dữ liệu; cần phân biệt khóa ở thiết bị với khóa mà server có thể dùng. PostgreSQL và các thư mục private dưới đây vẫn cần quyền hệ điều hành, backup và quản lý vận hành phù hợp; không có tuyên bố toàn bộ database đã mã hóa từng cột.

| Dữ liệu | Android/app | PC/API/PostgreSQL |
|---|---|---|
| **Mật khẩu tài khoản** | Luồng lưu phiên không ghi password vào vault; password gửi qua HTTPS khi đăng nhập | ASP.NET Identity giữ password hash có salt/PBKDF2 trong PostgreSQL. Cấu hình/credential vận hành hoặc seed demo của máy phải giữ riêng trong `.local`, không đưa vào Git |
| **Access/refresh token opaque** | Cần raw token để gửi Bearer/refresh; cặp token và base URL nằm trong vault AES-GCM, khóa AES ở Android Keystore. Khi sử dụng có dữ liệu rõ trong RAM app | DB giữ hash access/refresh và metadata/hạn/thu hồi phiên; không phải JWT. Token không đặt trong URL, ảnh chụp hay log công khai |
| **OTP/challenge email** | Mã người dùng nhập và challenge chỉ phục vụ bước xác minh | Challenge token được hash; mã OTP được kiểm bằng HMAC/hash trong DB riêng, có hạn/số lần sai. DB giữ địa chỉ nhận phục vụ luồng thư; relay/Gmail nhận địa chỉ và mã để gửi. Bí mật ký relay/hash nằm trong cấu hình private |
| **Vân tay/sinh trắc học của hệ điều hành** | Hệ điều hành và BiometricPrompt quản lý cảm biến; khóa RSA Keystore ký thử thách | Server nhận public key, chữ ký và metadata thiết bị. **Không upload mẫu vân tay của OS**. Kiểm chữ ký không chứng minh server đã chứng thực phần cứng từ xa |
| **Ảnh mặt 2D và template** | Ảnh chụp dùng cache riêng; luồng app dọn các bản sao tạm. Không tự xóa ảnh gốc của người dùng ở nơi khác | Ảnh được chuyển tới bộ xử lý qua luồng/API/IPC; template `ProtectedEmbedding` trong PostgreSQL được ASP.NET Data Protection bảo vệ theo người dùng. Key ring ở đường dẫn private, trên Windows được DPAPI bảo vệ. Server có khả năng mở template để so khớp; đây không phải E2EE |
| **Hồ sơ/minh chứng, tin và ảnh thường** | App tải theo quyền; ảnh/cache xem trước có thể nằm tạm trong RAM hoặc cache riêng | Profile/hồ sơ/comment/tin thường ở DB; tệp minh chứng/ảnh ở storage private ngoài `wwwroot`. API kiểm quyền. Ảnh bài Published là công khai theo thiết kế; ảnh Direct/nhóm cần membership. Server có thể đọc và chuẩn hóa ảnh thường |
| **Secret text/ảnh** | Khóa X25519/Ed25519 ở keybag mã hóa bằng khóa AES Keystore, phân theo origin/tài khoản; mở trong RAM client để libsodium dùng. Không gửi private key lên API | Server nhận public key, envelope/blob ciphertext và metadata như hai bên, thời điểm, kích thước. Tệp ciphertext lưu riêng trên PC; không có khóa giải mã nội dung của client |

**Face không phải hash mật khẩu hoặc Face ID.** Ảnh 2D và embedding là dữ liệu nhạy cảm. Key Data Protection/DPAPI phải được quản lý khi backup/đổi máy; chỉ sao chép database không chứng minh template sẽ mở được. Mã nguồn có thu hồi/xóa template và dọn bản sao tạm, nhưng không hứa xóa vật lý mọi dữ liệu khỏi backup/thiết bị nguồn. Không có liveness, không bảo đảm chống ảnh chụp lại; chưa tuyên bố đã nghiệm thu đối chiếu đúng người trên điện thoại thật.

App Admin bị chặn ở Direct không tham gia; quyền quản trị PC/DB là quyền hệ thống khác và có thể truy cập nội dung **thường**. Secret giảm việc server tiếp cận nội dung rõ, nhưng không che mọi metadata và không bảo vệ một thiết bị/client đã bị kiểm soát.

Nguồn: [vault phiên native](../../mobile_client/android/app/src/main/kotlin/vn/mangodemo/mango_offline/MainActivity.kt), [vault keybag](../../mobile_client/android/app/src/main/kotlin/vn/mangodemo/mango_offline/SecretKeyVault.kt), [face/template](../src/FruitVision.Api/Auth/FaceAuthEndpoints.cs), [Data Protection](../src/FruitVision.Api/Program.cs), [xử lý face](../src/FruitVision.Api/Auth/FaceEngine.cs).

## 5. Bài viết, tương tác và hai loại chat

Consumer gửi bài `Community`; Seller gửi `Professional` gắn chi nhánh thuộc mình đã Approved. Admin công bố/từ chối; tác giả rút bài Published thành Paused. Chủ tài khoản/chi nhánh mất điều kiện sẽ làm nội dung liên quan mất tính công khai theo kiểm tra server. Ảnh thường JPEG/PNG tối đa **5 MiB**, chuẩn hóa JPEG, bỏ EXIF, cạnh tối đa 2048; không tải ảnh từ URL tùy ý.

Like là trạng thái rõ ràng `PUT /articles/{id}/like {liked:true|false}`, không phải tăng đếm mỗi lần retry. Comment 2–1000 ký tự cần UUID `clientCommentId`; cùng key/nội dung trả bản cũ, đổi nội dung trả 409. Chủ/Admin được xóa comment. Server xóa phần body hiện hành, giữ dấu idempotency để một retry đến muộn không tạo lại nội dung; comment đó bị loại khỏi danh sách/bộ đếm. Metadata/audit hoặc bản backup có thể vẫn tồn tại.

Liên hệ bài/tin Published tạo hoặc dùng lại Direct đúng hai người. Chỉ thành viên đọc/gửi tin/ảnh. **Ảnh Direct thường có kiểm soát truy cập nhưng không E2EE.** Nhóm cộng đồng chỉ Admin tạo/đóng; các vai trò Approved vẫn khám phá/join/leave/chat. Nhóm tối đa 50 thành viên; đóng nhóm chặn tin mới/thành viên mới, giữ lịch sử theo quyền. WSS báo thay đổi, REST lấy bù và dedup sau reconnect; chưa có push nền Android.

**Secret Direct v1:** chỉ hai Seller trong Direct hợp lệ, mỗi người một thiết bị active. Client dùng libsodium sealed box X25519, chữ ký Ed25519 và mã hóa ảnh trước upload. Hai bên đối chiếu đầy đủ fingerprint **64 ký tự hex qua kênh tin cậy ngoài chat**, rồi pin; thay khóa phải xác minh lại. Không tự chuyển lịch sử chat thường sang secret; không tự thay keybag khi lỗi. Mất khóa có thể mất khả năng đọc lịch sử. V1 không có nhiều thiết bị, khôi phục khóa, ratchet hoặc cam kết forward secrecy. Secret preview/zoom cần giữ và dọn dữ liệu đã giải mã trong RAM theo vòng đời app.

Quota ảnh thường + blob secret mặc định **100 MiB/người, 2 GiB toàn máy**, chừa ít nhất 1 GiB ổ lưu. Đầy quota báo lỗi, không tự xóa lịch sử. Secret blob tối đa 5 MiB + 64 KiB phụ trội; server không giải mã để quét/chuẩn hóa ảnh.

Nguồn: [bài/chi nhánh](../src/FruitVision.Api/Features/PublishingEndpoints.cs), [like/comment](../src/FruitVision.Api/Features/ArticleEngagementEndpoints.cs), [nhóm](../src/FruitVision.Api/Features/CommunityEndpoints.cs), [server opaque](../src/FruitVision.Api/Features/SecretMessagingEndpoints.cs), [giao thức libsodium client](../../mobile_client/lib/client/secret_protocol.dart), [pin và keybag client](../../mobile_client/lib/client/secret_messaging.dart), [quota](../src/FruitVision.Api/Infrastructure/MediaStorageQuota.cs).

## 6. AI xoài và camera: thực hiện trên PC

Chỉ Producer/Trader được dùng AI. Consumer có học liệu `/learning/mango`, quan sát/chia sẻ và comment; Admin không có AI. Mô hình ONNX chạy bằng ONNX Runtime CPU tại PC; APK không mang model/runtime suy luận AI này và không chạy AI offline.

| Luồng | Hành vi/giới hạn hiện tại |
|---|---|
| **Ảnh/video thành tác vụ** | Raw binary JPEG/PNG tối đa 12 MiB; MP4 tối đa 80 MiB/120 giây/1920×1080. Job bền trong PostgreSQL; tiến độ WSS + REST, có hủy. Một worker, tối đa 4 Queued/Running và một tác vụ/người. File gốc được dọn khi kết thúc; kết quả/preview private còn giữ |
| **Camera trực tiếp qua API** | CameraX xem trước/chụp khung, client gửi JPEG tối đa 1 MiB/cạnh 960 tới phiên live có chủ sở hữu. Một lượt gửi đang xử lý trên client; server xử lý có giới hạn, tối đa hai phiên live, mỗi người một phiên; không chạy chồng với tác vụ file. Phiên tối đa 10 phút theo hạn auth và hết idle sau 30 giây. Dừng/rời màn hình phải dừng camera, hủy upload và kết thúc phiên |
| **Lưu dữ liệu live** | Khung/kết quả phục vụ phiên live và xử lý trong RAM/tiến trình; không tạo một AiJob bền cho mỗi khung. Receipt chỉ đối chiếu metadata job của chính người dùng, không phải kiểm toán toàn bộ ổ đĩa/DB |

Phạm vi serving giữ **xoài được dự đoán**, có thể bỏ sót hoặc nhận nhầm. Hai nhãn từ dữ liệu nguồn là **“Xanh / chưa chín”** và **“Chín”**; yếu/không đủ tin cậy là **“Chưa xác định”**, không đổi thành xoài hư. Graph, trọng số/SHA và các nhãn loài tổng quát lưu trữ từ nguồn giữ nguyên; không gọi bộ lọc serving là huấn luyện lại hoặc mở rộng số lớp.

`maxVisibleCount`, track xác nhận và lượt qua vạch là ba đại lượng khác nhau. Không cộng chúng thành số quả vật lý duy nhất, kg, tồn kho hoặc tỷ lệ chính xác. Nhãn nguồn không chứng minh độ chín bên trong, vị ngọt, hư hỏng hay an toàn thực phẩm. Giới hạn chất lượng video/giấy phép demo phi thương mại vẫn giữ.

**Đo thật hiện có:** [live HTTPS smoke 2.5](live-ai-https-smoke-25.json) gửi ba lần **cùng một JPEG mẫu có sẵn**, mỗi kết quả một xoài dự đoán, nhãn Xanh / chưa chín. `processingMs` **47–109 ms**, RTT **390–469 ms**. Đây là ba quan sát pipeline API/PC, không phải camera điện thoại liên tục, FPS native, ground truth, benchmark độ chính xác hoặc số quả duy nhất. Khi camera/quyền/mạng chưa ổn, dừng live và dùng ảnh đơn làm phương án dự phòng; hiển thị lỗi thật, không tạo kết quả giả.

Nguồn: [job](../src/FruitVision.Api/Ai/AiEndpoints.cs), [live API](../src/FruitVision.Api/Ai/LiveAiEndpoints.cs), [live runtime](../src/FruitVision.Api/Ai/LiveAiRuntime.cs), [controller camera](../../mobile_client/lib/client/live_camera.dart), [CameraX native](../../mobile_client/android/app/src/main/kotlin/vn/mangodemo/mango_offline/LiveCameraPlatform.kt), [nguồn/phạm vi model](mango-ai-scope-24.md).

## 7. Bằng chứng và điều kiện bàn giao

| Phạm vi | Kết quả đã ghi nhận | Điều không được suy ra |
|---|---|---|
| Backend full | **173/173 PASS**, đợt tích hợp PostgreSQL thật do người phát hành chạy; triển khai 8 migration | Không tự chứng minh mọi giao diện/cảm biến hoạt động |
| Nghiệp vụ HTTPS 2.5 | [**115 kiểm tra/68 HTTP PASS**, 27,593 giây](feedback-https-acceptance-25.json): hai hồ sơ QA, Admin thấy Submit/applicant/proof; ảnh thực, like/comment/retry/xóa, Direct private, nhóm Admin | Không sửa hồ sơ người thật; không có WSS/native/secret crypto acceptance trong driver này |
| Live AI HTTPS | Ba khung mẫu, số đo và giới hạn ở mục 6; phiên đã dừng sau kiểm tra | Không có chứng minh camera liên tục, FPS/độ chính xác hoặc điện thoại thật |
| Android/native | **36 kiểm thử native PASS** theo đợt kiểm người phát hành | Là số ca kiểm thử, không phải “đã thử trên Android API 36”; không chứng minh vân tay/face vật lý |
| Flutter | **135/135 kiểm thử full cuối PASS**, analyzer **0 lỗi/cảnh báo**; gồm các hồi quy mới về Admin detail, ảnh mã hóa, sự kiện bài viết và điều kiện Direct | Đây là một lần chạy full cuối; không chứng minh bốn thiết bị vật lý |
| Đóng gói | Ba ABI APK 2.5.0+6011 (`../../mobile_client/verification/2.5/apk-verification.json`; không công bố) đã kiểm phiên bản/chữ ký/ABI/hash | Android vẫn hỏi xác nhận cài; cập nhật không phải cài âm thầm hoặc chứng nhận UI |
| Máy ảo/giao diện cuối | **Đã thử trên APK cuối với Producer:** khôi phục phiên không OTP, camera HAL→HTTPS→PC, xin quyền lần đầu, start/stop, ra nền không tự chạy lại, Direct đúng đối tác/ẩn E2EE với Consumer, gửi ảnh→thumbnail→zoom, gửi bài chuyên môn; Admin công bố qua API thật. Xem biên bản Android (`../../mobile_client/verification/2.5/android-final.json`; không công bố) | Chưa gọi toàn bộ sáu luồng, camera/secret hoặc bốn thiết bị đồng thời là PASS |

Trước bàn giao cần ghi đúng phiên bản/hash APK cuối, chạy sáu luồng trong playbook bằng thao tác thật; kiểm camera lần xin quyền đầu, quay lại màn hình, dừng/rời app và phương án ảnh. Kiểm tra reconnect/membership, nháp→Submit→Admin queue, upload riêng/ảnh thường, và secret thực nếu đưa vào phạm vi demo. Khi chưa có bằng chứng, giữ PENDING hoặc bỏ mục đó khỏi danh sách đã hoàn tất.

PC/DB/worker/tunnel phải còn chạy; HTTPS tạm có thể đổi, cần lấy địa chỉ hiện hành và đăng nhập lại phù hợp. Backend gọi relay thư và nguồn địa điểm HTTPS; cache địa điểm có provenance/stale, không có dữ liệu hợp lệ thì báo 503. Giữ `.local`, DB, media và key ring riêng; không công khai secret/PII hoặc sao chép cấu hình máy vận hành sang Git.

Chưa có commerce/giữ hàng/thanh toán/giao nhận/tồn kho xác thực, IoT, dự báo giá, bảo đảm an toàn thực phẩm, liveness hoặc vận hành production 24×7. Dữ liệu seed/QA là dữ liệu tổng hợp; xét duyệt kỹ thuật không chứng nhận kinh doanh hoặc nông sản.


## 8. Đánh giá khách quan trước buổi demo

**Có thể chuẩn bị demo có kiểm soát; chưa phải sản phẩm được bảo đảm trên mọi máy.** QA đã phát hiện và sửa các lỗi thật: nhầm lưu nháp với nộp hồ sơ; Admin chi tiết bài/chi nhánh GET sai đường dẫn; nút camera ngoài viewport; cấp quyền lần đầu hủy startup; E2EE được mời cho đối tác không đủ vai trò; bài đang mở không cập nhật sau công bố. Các kiểm thử mới bắt lỗi trước khi sửa, không chỉ kiểm cú pháp.

- Bốn tài khoản/role đã chạy qua HTTPS thật. Producer và Trader đều có một chi nhánh đã duyệt; Producer có bài Professional công khai. Đây là dữ liệu demo tổng hợp, không xác nhận doanh nghiệp thật. [Preflight](demo25-preflight.json).
- Camera máy ảo hiển thị **165 khung / 4,76 khung AI/giây** trong một cửa sổ quan sát; PSS **140.249 KiB**, RSS **268.200 KiB**. Đây là số cả luồng app trong cảnh ảo, không phải FPS native; **chưa đạt/chứng minh 6 FPS**, không suy rộng cho điện thoại hay mạng khác.
- Chưa chạy bốn điện thoại thật cùng lúc, chưa có ca dương tính khuôn mặt/vân tay trên thiết bị vật lý, chưa xác minh E2EE ảnh trên hai điện thoại trong đợt này. Đếm qua video/độ chín thực địa chưa được chứng nhận bởi các kiểm tra phần mềm.
- Lượt tự động mở bài Professional trên máy ảo dừng vì giới hạn bốn lần vuốt của helper. Link tồn tại ở cuối trang học; không ghi ca đó PASS. Trước giờ demo nên mở sẵn feed Professional trên máy C/D.
- Không trình bày độ chính xác98%, liveness/FaceID, số quả vật lý duy nhất hoặc sản lượng kg như thành quả đã xác minh. Camera chỉ đếm quả thấy trong khung; video có chỉ số track/qua vạch riêng và giới hạn đã ghi.
