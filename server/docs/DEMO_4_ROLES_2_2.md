# Demo FruitVision 2.2: bốn vai trò trao đổi thế nào?

FruitVision 2.2 hiện nối hồ sơ đã duyệt → tin dự kiến được công bố → thông tin cung/cầu → hội thoại riêng hoặc nhóm. Tài liệu này mô tả các luồng đang có trong API, để PM/BA và người trình bày phân biệt quyền tài khoản, quyền đối với bản ghi và dữ liệu thực sự được lưu.

**Bằng chứng hiện có:** lượt kiểm công khai HTTPS/WSS đã **PASS trong 49,281 giây, 80 request HTTP và 4 kết nối WSS đồng thời**. Đây là bốn client vai trò độc lập trên một PC, không phải bốn điện thoại. Xem [biên nhận thực tế](verticals-https-e2e.json) và [mã probe](../scripts/verticals_e2e.py). 13 kiểm thử màn hình tập trung đã xanh tại thời điểm ghi chú; kết luận toàn bộ bộ kiểm thử ứng dụng và nghiệm thu APK/điện thoại còn do lượt nghiệm thu riêng xác nhận.

## Truy cập và chuẩn bị

* [Web demo hiện tại](https://tips-differential-relating-validity.trycloudflare.com/index.html).
* [Swagger / Try it out](https://tips-differential-relating-validity.trycloudflare.com/v1/index.html), [OpenAPI](https://tips-differential-relating-validity.trycloudflare.com/openapi/v1.json).
* Đây là hostname tạm. Khi tunnel được tạo lại, lấy địa chỉ mới trong tệp local `server/PUBLIC_URL.txt` (không đưa lên Git). PC, API và tunnel cần tiếp tục chạy.
* Người vận hành lấy bốn tài khoản/mật khẩu **trên PC của mình** từ `server/.local/demo-accounts.json`. Không đưa tệp đó, mật khẩu, access token, refresh token hoặc `runtime.json` vào slide, ảnh chụp hay Git. Tài liệu này không chứa thông tin đăng nhập.

Trước phần trình bày, mở bốn hồ sơ trình duyệt/session riêng và đăng nhập sẵn Admin, Producer, Trader, Consumer. Xác nhận hồ sơ đang hoạt động và `Approved`; chỉ đổi tab trong cùng một session có thể khiến các tab dùng chung tài khoản. Chuẩn bị một ảnh quả nhỏ nếu muốn thử AI; không chạy bốn video dài để minh họa phân quyền.

Để trình bày việc duyệt hồ sơ, chuẩn bị trước **một tài khoản nghiệp vụ Pending khác** và chỉ rõ đây là dữ liệu demo do người vận hành đăng ký. Không đổi trạng thái bốn tài khoản đang dùng giữa lúc trao đổi, vì quyền và kết nối của họ có thể bị thu hồi.

## Ma trận vai trò và ranh giới

| Vai trò | Việc hiện làm được | Ranh giới cần nói rõ |
|---|---|---|
| Admin | Duyệt hồ sơ Producer/Trader/Consumer; khóa/mở tài khoản; duyệt Published/Rejected/Paused cho tin; xem audit/thống kê; tạo/tham gia/đóng nhóm theo quyền | Không đăng tin nghiệp vụ qua endpoint Seller; không mở Direct bằng nút liên hệ tin (`403`); không tự đọc tin nhắn hoặc AI của người khác chỉ vì là Admin |
| Producer | Sau duyệt, đăng **Supply** với khu vực, ngày dự kiến, kg dự kiến và khoảng chào bán tùy chọn; liên hệ tin Published của người khác; trả lời Direct; tham gia nhóm; dùng AI riêng | Không gửi Demand; tin mới chờ Admin duyệt; số kg là ước tính, chưa là tồn kho |
| Trader | Sau duyệt, đăng **Demand** mặc định hoặc **Supply**; liên hệ tin Published của người khác; trả lời Direct; tham gia nhóm; dùng AI riêng | Demand là nhu cầu tự khai; khoảng giá hỏi mua không trở thành giá chào bán tham khảo |
| Consumer | Xem tin công khai/thị trường; sau duyệt, liên hệ tin Published, trả lời Direct, tạo/tham gia nhóm và dùng AI riêng | Không đăng tin Supply/Demand qua endpoint Seller; xem thông tin hoặc chat không tạo đơn mua bán |

Đăng ký công khai chỉ có ba vai trò nghiệp vụ, trạng thái mới là Pending. Tài khoản chưa duyệt vẫn có thể đăng nhập, xem hồ sơ của mình và đọc dữ liệu công khai; quyền đăng tin, liên hệ, cộng đồng và AI cần `Approved`. Huy hiệu duyệt hồ sơ không chứng nhận chất lượng/an toàn nông sản.

| Hai tài khoản tương tác | Luồng hợp lệ hiện có | Điều kiện/ngoại lệ |
|---|---|---|
| Producer ↔ Trader | Trader liên hệ tin Supply; Producer có thể liên hệ tin Demand/Supply Published của Trader; sau đó hai bên nhắn riêng | Hai người khác nhau, đang hoạt động/đã duyệt; bài còn công khai khi tạo liên hệ |
| Producer ↔ Consumer | Consumer liên hệ tin Supply Published; Producer trả lời trong Direct hai người | Consumer không có tin riêng để Producer mở một Direct mới theo chiều ngược lại qua luồng liên hệ bài |
| Trader ↔ Consumer | Consumer liên hệ tin Published của Trader và hai bên trao đổi thông tin | Server không biến cuộc trao đổi hoặc Purpose của bài thành giao dịch |
| Producer ↔ Producer | Hai Producer khác nhau có thể liên hệ tin Supply Published của nhau | Không mặc định cấm vì cùng vai trò; liên hệ bài của chính mình trả `409` |
| Trader ↔ Trader | Hai Trader khác nhau có thể liên hệ tin Demand/Supply Published của nhau | Cùng quy tắc người khác/bài Published; tự liên hệ trả `409` |
| Consumer ↔ Consumer | Cùng tham gia một Group rồi trao đổi theo membership | Luồng **tạo Direct mới** hiện đi từ một bài Published; Consumer không có quyền đăng bài, nên không có luồng khởi tạo Consumer↔Consumer qua bài đăng |
| Admin ↔ các vai trò, hoặc Admin ↔ Admin | Quản trị theo quyền; trao đổi trong Group khi là thành viên | Admin không dùng liên hệ bài để mở Direct. Quyền quản trị không bỏ qua kiểm thành viên khi đọc/gửi tin nhắn |

Vì vậy, phân quyền không chỉ là một bảng vai trò. Một Producer/Trader/Consumer đã duyệt có thể liên hệ **bất kỳ bài Published hợp lệ của người khác**, kể cả cùng vai trò. Sau khi Direct được tạo, đọc/gửi còn phụ thuộc chính người dùng có trong hai thành viên hay không. Đoán ID, gửi `participantIds` hoặc xin join một ID Direct qua API Group không cấp quyền.

## Direct và Group có ý nghĩa khác nhau

| Tình huống | Direct riêng tư từ bài đăng | Group cộng đồng |
|---|---|---|
| Khởi tạo | Một người không phải Admin liên hệ bài Published của người khác | Tài khoản Approved tạo nhóm công khai theo khu vực/nông sản tùy chọn; người tạo là chủ và thành viên |
| Ai nhìn thấy? | Danh sách/lịch sử chỉ cho thành viên; người ngoài nhận `404` | Approved có thể xem metadata nhóm đang mở; đọc/gửi tin cần đã tham gia |
| Thêm thành viên | Luồng hiện tại giữ đúng hai người; không nhận danh sách tùy ý từ client | Mỗi người tự join; tối đa 50 thành viên, mỗi chủ tối đa 10 nhóm mở |
| Lặp lại thao tác | Cùng người liên hệ cùng bài dùng lại Direct; cùng khóa tin nhắn/nội dung dùng lại tin đã lưu | Join lặp lại trả bản hiện có; leave idempotent |
| Rời/đóng | Không có API chuyển một Direct thành nhóm công khai | Chủ cần đóng trước khi rời; chủ hoặc Admin được đóng; nhóm đóng không nhận join hoặc tin mới |
| Lịch sử | Bài bị Paused không xóa hội thoại/lịch sử đã có của thành viên | Nhóm đóng vẫn đọc được bởi thành viên hiện tại; đã leave thì mất quyền đọc/gửi và không nhận tin mới |

Admin có thể quản trị metadata/đóng Group theo quyền, nhưng không được đọc lịch sử nhóm chỉ nhờ vai trò nếu chưa là thành viên. Thông báo realtime là tín hiệu cập nhật; dữ liệu và quyền hiện tại ở API/DB mới là chuẩn. Sau reconnect cần tải lại danh sách, metadata và tin nhắn, không suy từ một biểu tượng online rằng membership vẫn còn.

## Đọc bảng thị trường cho đúng

Dashboard chỉ tổng hợp bài **Published** của tác giả đang hoạt động, đã duyệt, theo nông sản/khu vực. Khu vực lấy từ bài; bài cũ thiếu khu vực dùng hồ sơ tác giả. Nhãn địa danh vẫn là dữ liệu người dùng nhập, không phải danh mục tỉnh được hệ thống tự xác thực.

| Trường | Đơn vị/nguồn và cách hiểu |
|---|---|
| `supplyEstimatedKg`, `demandEstimatedKg` | kg dự kiến tự khai từ bài Supply/Demand; không phải tồn kho, lượng đã mua hay đã thu hoạch |
| `referencePriceVndPerKg` | VND/kg; trung vị **điểm giữa khoảng chào bán** của các bài Supply có giá hợp lệ |
| `priceMinVndPerKg`, `priceMaxVndPerKg` | Giá chào bán thấp nhất/cao nhất trong các mẫu Supply hợp lệ; không phải khoảng giá giao dịch đã xác nhận |
| `priceSampleCount` | Số bài Supply có khoảng giá; không phải số giao dịch hoặc số lô độc lập |
| `supplyPostCount`, `demandPostCount`, `contributorCount` | Số bài theo Purpose và số tác giả khác nhau; một tác giả có thể đăng nhiều bài |
| `source`, `isForecast` | `published-user-asking-prices`, `false` mô tả **giá chào đã đăng được tổng hợp**; không phải dự báo giá AI. Hai trường lượng kg vẫn là dự báo/ước tính |
| `asOf`, `lastUpdated` | Thời điểm tạo bản tổng hợp và cập nhật mới nhất từ thời gian tạo/xét duyệt bài trong nhóm; không phải thời điểm một giao dịch thị trường |

Không có khoảng giá Supply hợp lệ thì giá tham chiếu/min/max là `null`, số mẫu 0. Giá hỏi mua của Demand bị loại khỏi phép tính giá chào bán tham khảo. Ví dụ một Supply chào 20.000–30.000 VND/kg có điểm giữa 25.000; thêm Demand hỏi 1.000–2.000 không làm giá Supply thành 13.250. Với nhiều Supply, lấy trung vị các điểm giữa, không mặc định luôn là 25.000.

Số liệu tự khai có thể ít, cũ hoặc nhiều bài cùng nói về một lô; tổng kg chưa khử trùng vật lý. Đây không phải bảng giá chính thức, dự báo giá tương lai hoặc đề nghị đầu tư/mua bán.

## Kịch bản trình bày 6–8 phút

Đăng nhập bốn session trước khi bắt đầu. Dùng dữ liệu mới do người trình bày nhập và gắn “Demo” trong tiêu đề; không nói đây là giá thị trường hoặc giao dịch thật. Có thể dùng bản ghi đã tạo bởi lượt nghiệm thu phía dưới để tiết kiệm thao tác.

| Thời gian | Người thao tác | Điều cần thể hiện |
|---|---|---|
| 0:00–0:45 | Admin | Chỉ một hồ sơ Pending đã chuẩn bị trước; duyệt hoặc yêu cầu bổ sung có lý do. Giải thích bốn tài khoản chính đã Approved; trạng thái hoạt động là điều kiện riêng |
| 0:45–1:40 | Producer | Tạo Supply: xoài từ catalog, **Đồng Tháp**, ngày dự kiến tuần tới, **500 kg dự kiến**, khoảng chào **20.000–30.000 VND/kg**. Kết quả AwaitingReview; Consumer/Trader chưa thấy bài công khai |
| 1:40–2:20 | Admin | Mở hàng chờ, duyệt Published với lý do. Producer thấy kết quả, Consumer/Trader tải lại feed thấy bài; cho biết đây là xét duyệt tin, không xác nhận 500 kg tồn kho |
| 2:20–3:25 | Trader + Producer | Trader liên hệ bài để tạo Direct; gửi câu hỏi về lịch dự kiến, Producer trả lời. Consumer không đọc được Direct này. Có thể chỉ Demand của Trader với lượng/giá hỏi mua tự khai nếu đã chuẩn bị |
| 3:25–4:25 | Consumer | Lọc thị trường Đồng Tháp/xoài, đọc nguồn, kg dự kiến, số mẫu, thời điểm. Consumer liên hệ chính bài Supply: tạo một Direct **khác** với Direct Trader–Producer; Producer trả lời |
| 4:25–5:45 | Cả bốn | Mở Group demo; các vai trò chưa là thành viên tự join. Mỗi vai trò gửi một lời chào/câu hỏi. Cho Consumer leave một nhóm kiểm tra, xác nhận không đọc/nhận tin mới; dùng nhóm mở khác cho phần trao đổi tiếp |
| 5:45–6:35 | Admin + Consumer | Admin Paused bài với phiên bản mới nhất. Bài biến mất khỏi feed công khai và phần tổng hợp tương ứng; lịch sử Direct của thành viên vẫn còn. Khôi phục Published nếu muốn giữ bài cho người xem thử |
| 6:35–7:30, tùy chọn | Một tài khoản Approved | Gửi **một ảnh nhỏ** cho AI chạy trên PC, xem kết quả/preview riêng tư. Chỉ ra số đang thấy, ID theo dõi và lượng kg là các khái niệm khác nhau; ảnh đơn không tạo khối lượng/tồn kho |

Nếu chọn thử đóng nhóm, dùng nhóm kiểm tra riêng: chủ đóng, thành viên hiện tại đọc lịch sử, tin mới/join mới bị chặn. Giữ nhóm cộng đồng mở để người xem có chỗ tiếp tục trao đổi. Không biến demo thành lời hứa về đơn hàng, giữ hàng, thanh toán, cảm biến/IoT hoặc hệ thống nghiệp vụ hoàn chỉnh.

### Bản ghi thực đã có để người xem tìm

Lượt HTTPS/WSS trong [biên nhận](verticals-https-e2e.json) đã tạo/lưu các bản ghi sau; không phải hàng giả được bơm qua SQL:

* Supply đang khôi phục Published: `48853e34-6371-4dfd-a9c5-ac9da67b6f02`.
* Demand: `b57fa4f8-f87f-4cda-9268-878420beec54`.
* Direct Producer–Trader: `c72ea09d-ad15-4a25-bdb0-ef291388fc6f`; Direct Producer–Consumer: `9e814411-4856-4e94-b03f-9104cabb970a`.
* Nhóm mở cho người xem: `8ec7519f-fe89-4c96-85c8-c50d3f82f3fd`, đã có bốn vai trò và lời chào thực được lưu.
* Nhóm kiểm tra đã đóng: `83f130a3-713e-4d39-8ff5-2a8bd2f10dba`.

Các ID giúp tìm bản ghi trên **PC/dataset của lượt nghiệm thu**; một bản clone/DB mới không tự có các ID này. Trạng thái có thể thay đổi khi người dùng tiếp tục thao tác; lấy lại bằng REST. Biên nhận còn ghi ID từng tin nhắn, mã HTTP, độ trễ và các lượt chạy đồng thời, không chứa token/mật khẩu.

## Khi mạng/nghiệp vụ không đi theo kịch bản

* **Mất mạng/reconnect:** giữ ghi chú ID bản ghi, nối lại rồi tải hồ sơ, feed, hội thoại/Group và lịch sử bằng REST. Không tạo lại một nhóm/bài liên tục chỉ vì mất response; kiểm danh sách của mình trước để tránh bản ghi trùng.
* **`409` khi Admin duyệt:** một thao tác khác đã đổi trạng thái/`revision`, hoặc chuyển trạng thái không hợp lệ. Tải lại bài rồi đưa quyết định mới theo phiên bản hiện tại; không tự gửi lặp mù quáng. `409` tự liên hệ bài mình là quy tắc khác, không chữa bằng tải lại.
* **Tin nhắn mất response:** cùng `clientMessageId` và cùng nội dung được dùng lại; sửa nội dung nhưng giữ khóa cũ trả `409`. Không tin `senderId`/danh sách người nhận do client tự điền.
* **`401`/`403` hoặc `404` riêng tư:** kiểm phiên, approval, trạng thái hoạt động và membership. Không suy rằng Admin có thể vượt kiểm bản ghi. Sau leave, `404` lịch sử là đúng quyền; nhóm đóng không nhận join lại.
* **`429`:** tôn trọng `Retry-After`, dừng bấm lặp. Không tăng giới hạn production để làm đẹp demo.
* **Hủy AI:** chỉ chủ tác vụ hủy Queued/Running; tác vụ đã kết thúc không bị biến thành một lần chạy mới. Nếu mạng gián đoạn, đọc lại lịch sử/trạng thái job trước khi tải lại. Thiếu runtime/capability trả `503`; không dựng kết quả thay thế. Xem [AI API](AI_API_USAGE.md).

AI phục vụ bản trình diễn phi thương mại; giai đoạn nguồn không bảo đảm độ chín thực địa, đếm video không bảo đảm số quả vật lý duy nhất. Bản 2.2 chưa có đơn hàng/giữ hàng chống vượt tồn, tồn kho từ Forecast, thanh toán, giao nhận, tranh chấp hoặc IoT. Kết luận đúng là các luồng tài khoản–tin dự kiến–trao đổi–tổng hợp đã có bằng chứng ở phạm vi kiểm tương ứng; không gọi mọi nghiệp vụ kinh doanh hoặc APK đã hoàn tất.

## Đối chiếu nguồn

Quyền/điều kiện nằm ở [AccountEndpoints](../src/FruitVision.Api/Features/AccountEndpoints.cs), [PostWorkflowEndpoints](../src/FruitVision.Api/Features/PostWorkflowEndpoints.cs), [CommunityEndpoints](../src/FruitVision.Api/Features/CommunityEndpoints.cs), [MarketEndpoints](../src/FruitVision.Api/Features/MarketEndpoints.cs), [InteractionEndpoints](../src/FruitVision.Api/Features/InteractionEndpoints.cs) và [FruitHub](../src/FruitVision.Api/Realtime/FruitHub.cs). Xem thêm [ghi chú 2.2 và cách cài trên PC khác](RELEASE_2_2_INTERACTIONS.md), [hợp đồng worker AI](../ai/README.md) và [biên nhận HTTPS/WSS](verticals-https-e2e.json).
