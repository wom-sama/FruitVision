# Đối chiếu kiểm tra các thao tác demo 2.6

Đây là ma trận phạm vi của **một lượt HTTPS mới**, dùng bốn phiên đã xác minh email OTP thật. [Biên bản live](demo-actions-https-acceptance-31.json): **175 kiểm tra đạt, 0 thất bại; 112 HTTP trong 38,266 giây**, trạng thái `PASS_AUTHORIZED_HTTP_SCOPE_WITH_EXCLUSIONS`. Không suy từ kết quả này rằng cả 28 dòng, bốn điện thoại/UI, AI hoặc E2EE đã PASS.

Bốn `auth/me` cuối lượt xác nhận vai trò gốc giữ nguyên. Không refresh token trong lượt này. Consumer đã được khôi phục chính xác các trường profile và gỡ block vừa thêm; khóa file phiên đã giải phóng. Tài nguyên QA kết thúc: một hồ sơ Rejected đã bỏ proof, ba bài + hai cơ sở soft-deleted, một nhóm Closed. Chat/media/audit riêng còn giữ như phạm vi đã công bố. Không đánh dấu toàn bộ inbox đã đọc; cursor chỉ áp dụng Direct QA đã lấy message qua API.

Driver: [demo_actions_acceptance_26.py](../scripts/demo_actions_acceptance_26.py). Tối đa **120 HTTP tuần tự/240 giây**, không gọi AI, không SDK/Chrome/SQL hay tạo token thủ công. Phiên hết access chỉ được refresh bình thường, khóa file riêng và thay cặp token nguyên tử. File kết quả phải là đường dẫn mới, không ghi đè các receipt trước.

```powershell
& ./.tools/ai-venv/Scripts/python.exe -X utf8 -B ./scripts/demo_actions_acceptance_26.py --sessions ./.local/2.4-real-sessions.json --run --output ./docs/demo-actions-https-26-NEW.json
```

Chỉ dùng lệnh sau khi Root cấp quyền live; không chạy lại mù sau lỗi. ID tài nguyên QA, trạng thái cuối đã nhận và bản sao để khôi phục các trường profile của chính Consumer nằm riêng dưới `.local/demo-actions26`. Receipt công khai chỉ có bộ đếm, route đã bỏ ID/tham số cá nhân và kết quả kiểm tra.

## Từng dòng trong danh sách demo

`M01–M22` theo thứ tự bảng chính của [danh sách demo](DEMO_10_PHUT_4_VAI_TRO.md); `X01–X06` theo bảng chức năng bổ sung. Các request trong grant đã đạt theo receipt; cột phạm vi còn thiếu và các dòng KHÔNG CHẠY vẫn áp dụng.

| Dòng | Thao tác | Request/kết quả HTTP cần quan sát | Phạm vi ngoài HTTP/còn thiếu |
|---|---|---|---|
| M01 | Admin thấy hồ sơ nâng vai trò | Consumer tạo/lưu profile/tải JPEG thật; Admin Submitted queue không có Draft; sau `POST /role-applications/{id}/submit` thì queue/detail có applicant, thời điểm nộp và proof | UI hiển thị/hàng đợi realtime cần thao tác app |
| M02 | Yêu cầu bổ sung/từ chối | Admin review NeedsInformation; Consumer GET thấy lý do; resubmit rồi Admin Rejected; xóa đúng proof QA của chủ | Không phê duyệt vai trò Consumer chính; không dùng minh chứng thật |
| M03 | Admin duyệt bài | Ba bài QA Consumer/Producer/Trader được review Published; detail/ảnh đọc được theo quyền | Render ảnh/refresh UI cần kiểm riêng |
| M04 | Admin duyệt cơ sở | Hai Seller tạo/sửa cơ sở QA Pending; Admin Approved; dùng đúng branchId khi đăng bài | Tên nút/địa điểm trên UI cần kiểm riêng |
| M05 | Admin tạo/đóng nhóm | Admin create201; ba vai trò khác create403; ba người join201; cả bốn gửi201; Admin close200; gửi mới409 | HTTP không chứng minh bốn máy nhận WSS/notification |
| M06 | Producer đăng bài chuyên môn | Upload JPEG → article Professional gắn cơ sở của mình → Published → Consumer đọc/ảnh JPEG chuẩn hóa | Không đo chất lượng nông sản |
| M07 | Producer AI ảnh | **KHÔNG CHẠY: ngoài quyền lượt này** | Root giữ bằng chứng AI riêng; không gọi endpoint AI dù chỉ kiểm trạng thái |
| M08 | Camera live | **KHÔNG CHẠY: ngoài quyền lượt này** | Quyền camera/vòng đời/FPS cần native/thiết bị và grant riêng |
| M09 | Producer quản lý cơ sở | Create201 → PUT revision hiện tại200 → Admin approve200 → được gắn bài | Xóa được kiểm ở X06 |
| M10 | Trader liên hệ Producer | Bài QA mới → contact201, lặp200 cùng Direct; hai phía gửi text; người thứ ba GET messages404 | Chỉ dữ liệu QA mới, không gửi vào thread cá nhân đã tồn tại |
| M11 | Trader cơ sở/bài Professional | Thực hiện cùng Producer bằng tài khoản Trader và cơ sở QA riêng | Không suy từ quyền giống nhau rằng đã bấm UI trên máy Trader |
| M12 | Trader AI | **KHÔNG CHẠY: ngoài quyền lượt này** | Bằng chứng AI riêng |
| M13 | Ảnh chat thường | Trader upload JPEG201; Producer tải ảnh thật, kiểm size/dimensions/EXIF; Admin không phải thành viên tải404 | Ảnh thu nhỏ/zoom/giữ vị trí cuộn cần UI; ảnh thường không E2EE |
| M14 | Secret E2EE | **KHÔNG CHẠY: không đăng ký/đổi khóa hoặc gửi ciphertext** | Root có lượt crypto/native riêng; không mượn PASS chat thường |
| M15 | Phân biệt đối tác | Inbox Producer có peer Trader và Consumer đúng từng Direct; preview image/top/unread đúng | Nhãn/menu E2EE chỉ trên hai Seller cần UI/crypto riêng |
| M16 | Consumer học xoài | GET `/learning/mango`200 có nội dung xoài | **MỘT PHẦN:** đánh dấu đã đọc/câu hỏi là trạng thái app, chưa kiểm bằng HTTP |
| M17 | Consumer bài Community | JPEG thật → Community AwaitingReview → Admin Published → ảnh công khai đúng | UI lựa chọn/chụp ảnh cần thiết bị |
| M18 | Consumer nộp hồ sơ | Dùng hồ sơ QA mới; Draft chỉ lưu; Submit mới vào hàng đợi, xem lại NeedsInformation/Rejected | Nếu Consumer có hồ sơ hoạt động từ trước thì dừng trước ghi domain; không sửa/nộp hộ hồ sơ đó |
| M19 | Consumer giới hạn quyền | Bốn role xác minh qua auth/me; Consumer tạo nhóm403, vẫn gửi comment/join/chat | **MỘT PHẦN:** không gọi AI/secret và không kiểm ẩn nút UI trong lượt này |
| M20 | Thích/comment | Ba tài khoản PUT like, POST comment; exact retry200 cùng ID; khác body409; delete body, retry409, count giảm | Không spam bấm gửi để tạo tải |
| M21 | Tham gia nhóm/chat | Ba vai trò join nhóm Admin; bốn tin đúng sender; nhóm còn gửi được khi có chặn cá nhân | WSS/foreground alert/bốn màn hình cần bằng chứng khác |
| M22 | Video/lịch sử AI | **KHÔNG CHẠY: ngoài quyền lượt này** | Không gọi AI jobs/history/stats; không kết luận đếm vật lý/độ chính xác |
| X01 | Bổ nhiệm Admin | **KHÔNG GHI PUBLIC PASS TỪ DRIVER NÀY:** 7 ca PostgreSQL riêng nằm trong full backend204/204; lượt Consumer thứ năm do Root kiểm tra có receipt riêng | Không gộp bằng chứng hoặc bổ nhiệm Consumer của bốn vai trò |
| X02 | Danh bạ/inbox/unread/read | Contacts không email; generic Direct metadata mở/dùng lại; tin QA mới lên đầu, peer đúng, unread incoming2; recipient GET messages rồi `/read` giảm0; outsider read404 | Không đánh dấu bằng timestamp hiện tại, không autoack tin chưa lấy; UI/badge/WSS cần lượt app |
| X03 | Profile/privacy | Sao lưu trường own Consumer riêng; thử ẩn rồi công khai số QA/giới tính/vùng; public GET không email; khôi phục đúng snapshot | Không đưa số điện thoại/profile thật vào receipt; không ghi đè một sửa đổi đồng thời của người dùng |
| X04 | Chặn/bỏ chặn | Chỉ thêm block mới khi cả hai phía không có block từ trước; public profile404, direct text/image403, contact404; lịch sử/nhóm vẫn200/201; bỏ block và đọc lại | Không kiểm secret gửi bị chặn bằng live trong lượt này; có 3 ca PG riêng gồm stream race |
| X05 | Xóa bài của mình | DELETE ba bài QA204 bằng expectedRevision; trang công khai bài Community404 | Soft delete, audit/private media có thể còn; không xóa bài người khác |
| X06 | Xóa cơ sở mình | Cơ sở còn bài liên kết DELETE409; sau xóa bài QA thì DELETE hai cơ sở204 | Không động vào cơ sở cũ đang dùng cho demo |

## Vị trí bằng chứng HTTP thực tế

Các số dưới đây là thứ tự request, bắt đầu từ 1 trong mảng `requests` của [receipt 175 kiểm tra](demo-actions-https-acceptance-31.json). Đây là chín nhóm đã chạy; những giới hạn NOT_RUN/PARTIAL trong bảng 28 dòng vẫn giữ nguyên.

| Nhóm thực tế | Request | Đối chiếu dòng demo | Kết quả |
|---|---|---|---|
| Phiên, điều kiện an toàn và nội dung học xoài | 1–9 | M16, M19 | Bốn vai trò đúng; không có hồ sơ Consumer hoạt động hoặc block cũ bị ghi đè; nội dung học đọc được |
| Hồ sơ nâng vai trò và Admin review | 10–22 | M01, M02, M18 | Draft khác Submitted; queue/detail/proof đúng; NeedsInformation → nộp lại → Rejected; bỏ proof QA |
| Cơ sở và ba bài có ảnh thật | 23–42 | M03, M04, M06, M09, M11, M17 | Hai cơ sở Approved; ba bài Published; ảnh trả về JPEG giới hạn kích thước và đã bỏ EXIF |
| Like, comment, retry và xóa comment | 43–56 | M20 | Ba lượt like/comment; retry cùng nội dung không trùng; khác nội dung hoặc retry comment đã xóa bị từ chối |
| Nhóm do Admin tạo và bốn vai trò gửi tin | 57–68 | M05, M19, M21 | Non-Admin tạo nhóm403; join và bốn tin có sender đúng được lưu |
| Direct, ảnh riêng, inbox và cursor đã đọc | 69–84 | M10, M13, M15, X02 | Contact lặp dùng cùng thread; recipient đọc ảnh; outsider404; incoming unread2 → 0 đúng thread QA |
| Profile, privacy, block và khôi phục | 85–99 | M21, X03, X04 | Public profile không email; block chặn Direct nhưng giữ nhóm/lịch sử; gỡ block và khôi phục profile gốc |
| Xóa tài nguyên của lượt QA và đóng nhóm | 100–108 | M05, X05, X06 | Bài/cơ sở soft-deleted; nhóm Closed; gửi tin mới409 |
| Xác nhận cuối bốn vai trò gốc | 109–112 | Điều kiện chung | Bốn `auth/me` vẫn đúng vai trò và trạng thái cho phép |

## Kiểm tra phiên sau lượt chức năng

[Biên bản dọn phiên và preflight](demo31-session-cleanup-preflight.json) là **lượt riêng gồm 13 HTTP**, kết thúc lúc **05:09:25 ngày 31/10/2026 (ICT)**. Cả bốn phiên gốc đã refresh qua API bình thường, ghi cặp token nguyên tử và được kiểm tra lại bằng `auth/me`: đúng Admin/Producer/Trader/Consumer, hoạt động, Approved và đã xác minh email. Snapshot UI3 chỉ chứa access token, giữ riêng trong `.local`; snapshot UI2 cũ không còn dùng được sau rotation. Khóa file phiên đã giải phóng.

Phiên hiện tại của **QAAdmin bổ sung thuộc lượt kiểm thử riêng** đã logout204 và kiểm tra lại401; tài khoản/vai trò Admin đó không bị xóa hoặc hạ quyền. QAProducer bổ sung còn phiên Producer hợp lệ; không refresh phiên này, không đặt lại xác thực mạnh hoặc thay khóa thiết bị. Lượt dọn phiên không thay dữ liệu nghiệp vụ hay vai trò chính, không chứng minh thao tác app/bốn máy/E2EE. Bốn rotation của preflight này không cộng vào 175 kiểm tra hoặc 112 HTTP của lượt chức năng trước.

## Điều kiện, khôi phục và cách đọc receipt

- Cả bốn role phải hoạt động/Approved/đã xác minh email. Nếu Consumer có Draft/Submitted/NeedsInformation cũ, dừng trước ghi domain. Không tìm cách giải phóng slot bằng cách sửa/từ chối hồ sơ người dùng.
- Chỉ tài nguyên vừa trả về201 ở lượt này được ghi là owned. Generic Direct trả200 có thể là thread cũ: không gửi tin, sửa/xóa hoặc nhận quyền sở hữu thread đó.
- Profile Consumer chỉ tạm dùng số QA khi bật công khai. Bản gốc lưu riêng; trước khôi phục phải kiểm tra trạng thái vẫn bằng lần ghi của driver. Block chỉ xóa nếu chính lượt này vừa thêm trên cặp không có block ban đầu.
- Thành công yêu cầu self-restore hoàn tất, bài/cơ sở QA soft-deleted, nhóm QA đóng, hồ sơ QA Rejected và proof QA đã bỏ. Thread/messages/audit và media riêng có thể còn; không giả báo xóa sạch khỏi DB/backup hoặc tự đánh dấu tất cả chat đã đọc.
- Lỗi giữa chừng: dừng, giữ receipt/ID riêng và khôi phục privacy/block của chính mình trong ngân sách còn lại. Các tài nguyên QA khác cần người vận hành kiểm trạng thái thật trước khi quyết định; không lặp mutation không rõ đã commit hay chưa.
- `PASS_AUTHORIZED_HTTP_SCOPE_WITH_EXCLUSIONS` chỉ nói các request trong grant đã đạt. Các dòng AI/E2EE/native/local state hoặc bổ nhiệm Admin public vẫn là NOT_RUN/PARTIAL như trên. Nó **không phải PASS tất cả thao tác của bốn máy**.
