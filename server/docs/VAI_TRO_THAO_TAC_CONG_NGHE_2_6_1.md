# FruitVision 2.6.1 - Vai trò, thao tác và công nghệ

Tài liệu mang đi demo | 31/10/2026 | APK 2.6.1+6013

## 1. Phạm vi và vai trò Admin

FruitVision hỗ trợ nhận diện xoài và dự đoán nhãn xanh/chín từ ảnh, kết hợp học liệu, bài viết và trao đổi theo vai trò. Điện thoại là ứng dụng khách; API, CSDL và AI chạy trên PC. Chưa có giao dịch mua bán, thanh toán, dự báo giá hay kết nối IoT.

| Vai trò | Trách nhiệm và giới hạn |
|---|---|
| Admin | Duyệt hồ sơ, cơ sở, bài viết; quản lý nhóm; bổ nhiệm Admin. Không sử dụng AI. |
| Nhà sản xuất | Quản lý cơ sở sản xuất, chia sẻ bài chuyên môn, dùng AI xoài, trao đổi với người dùng. |
| Thương lái | Quản lý cơ sở kinh doanh, chia sẻ bài chuyên môn, dùng AI xoài, liên hệ tác giả/đối tác. Không có chức năng mua bán hoặc thanh toán. |
| Người tiêu dùng | Học, chia sẻ cộng đồng, tương tác và nhắn tin; gửi hồ sơ xin nâng vai trò. Không dùng AI hoặc tạo nhóm. |

Bốn máy nên đăng nhập sẵn. Consumer là Người tiêu dùng; Seller chỉ hai vai trò Nhà sản xuất và Thương lái. Các thao tác dưới đây ghi đường đi và kết quả cần thấy, không thay cho bảng bằng chứng kiểm thử. Chỉ Người tiêu dùng được gửi hồ sơ nâng vai trò.

| Mã | Admin thao tác | Kết quả cần thấy |
|---|---|---|
| D01 | Xét duyệt > Duyệt nâng vai trò; mở hồ sơ đã Gửi xét duyệt và xem minh chứng. | Đúng người nộp, vai trò yêu cầu, thông tin và ảnh. Bản 6013 mở JPEG/PNG trong app; hồ sơ nháp chưa vào hàng chờ. |
| D02 | Nhập lý do; chọn Yêu cầu bổ sung hoặc Từ chối trên hồ sơ thử. | Người nộp thấy trạng thái/lý do. Chọn hai quyết định này để giữ tài khoản Consumer trong buổi demo. |
| D03 | Duyệt bài cộng đồng hoặc Duyệt bài chuyên môn; mở đúng bài, nhập lý do, Công bố. | Bài chuyển Đã công bố và xuất hiện ở đúng làn bài viết. |
| D04 | Duyệt cơ sở; xem hồ sơ và Chấp thuận cơ sở thử. | Chủ cơ sở thấy Đã chấp thuận; cơ sở được chọn khi viết bài chuyên môn. |
| D05 | Tin nhắn > Nhóm cộng đồng > Tạo nhóm; chọn quốc gia/tỉnh từ danh mục. Sau trao đổi, Đóng nhóm. | Thành viên tham gia/gửi tin; nhóm đóng vẫn đọc lịch sử, không gửi mới. Chỉ Admin tạo/đóng nhóm. |
| D23 | Xét duyệt > Bổ nhiệm quản trị viên; chọn Consumer đủ điều kiện, nhập lý do và mật khẩu Admin. | Người được bổ nhiệm đăng nhập lại thành Admin. Dùng tài khoản phụ, tránh đổi Consumer đang dùng để demo. |

Đối chiếu: mã nguồn bản 2.6.1, KIEM_TRA_28_THAO_TAC và DANH_GIA_DEMO_31_10 đi cùng APK. Tài liệu không chứa mật khẩu, OTP hoặc khóa riêng.

<!-- PAGE -->

## 2. Nhà sản xuất và Thương lái

Hai vai trò có quyền AI và bài chuyên môn như nhau. Tên khu vực quản lý là Cơ sở sản xuất đối với Nhà sản xuất, Cơ sở kinh doanh đối với Thương lái. Hồ sơ cơ sở và bài viết đều cần Admin xét duyệt.

| Mã | Vai trò và thao tác | Kết quả cần thấy |
|---|---|---|
| D06 | Nhà sản xuất: Viết bài chuyên môn; chọn cơ sở đã duyệt, nhập tiêu đề/nội dung, chọn ảnh, Gửi xét duyệt. | Bài ở trạng thái chờ; sau Admin công bố, người khác đọc được nội dung và phóng to ảnh. |
| D07 | Nhà sản xuất: AI xoài > Chọn ảnh > Gửi phân tích. | Có ảnh chú thích, khung dự đoán, số quả nhìn thấy và nhãn Xanh / chưa chín, Chín hoặc Chưa xác định. Đối chiếu với ảnh thật, không mặc định kết quả đúng. |
| D08 | Nhà sản xuất: Camera nhận diện xoài > Bắt đầu nhận diện; sau đó Dừng nhận diện. | Kết quả cập nhật từ PC. Ra nền phải dừng; quay lại không tự bật camera. Đây là số quả trong khung hiện tại. |
| D09 | Nhà sản xuất: Tài khoản > Cơ sở sản xuất; tạo/sửa hồ sơ và gửi duyệt. | Cơ sở chưa duyệt chưa được dùng đăng bài chuyên môn; cơ sở được duyệt mới chọn được. |
| D10 | Thương lái: Kiến thức > Đọc bài chuyên môn về xoài; mở bài > Trao đổi với tác giả. | Mở đúng đối tác; gửi/trả lời qua Tin nhắn. Liên hệ lại dùng cùng hội thoại theo ngữ cảnh, không tạo trùng do bấm lặp. |
| D11 | Thương lái: Tài khoản > Cơ sở kinh doanh; gửi cơ sở rồi viết bài chuyên môn sau khi được duyệt. | Cơ sở/bài có hai bước kiểm duyệt riêng; bài chưa duyệt chưa công khai. |
| D12 | Thương lái: AI xoài; thử ảnh hoặc camera. | Chỉ đọc được kết quả/phiên của chính tài khoản. Dừng phiên trực tiếp trước khi chạy tác vụ ảnh/video. |
| D13 | Hai vai trò: trong chat thường, Chọn ảnh > Gửi ảnh; chạm ảnh để phóng to. | Ảnh thu nhỏ hiện trong lịch sử và mở lớn được. Chat thường không mã hóa đầu cuối. |
| D14 | Hai vai trò: chuẩn bị khóa thiết bị, mở Direct > Chat riêng mã hóa đầu cuối; so toàn bộ mã an toàn, gửi tin/ảnh. | Người nhận giải mã được. Sai/đổi khóa phải khóa hội thoại, không chuyển lén sang chat thường. Chuẩn bị khóa đúng thiết bị trước buổi demo. |
| D15 | Mở Direct với đối tác kinh doanh rồi với Consumer. | Hiện đúng tên/vai trò. Tùy chọn E2EE chỉ có khi cả hai tài khoản là Nhà sản xuất/Thương lái đủ điều kiện. |

Lưu ý điều hướng: nút Đọc bài chuyên môn về xoài nằm phía cuối trang Kiến thức. Bấm vùng chữ của thẻ để mở bài; bấm ảnh là mở ảnh phóng to.

<!-- PAGE -->

## 3. Người tiêu dùng và chức năng dùng chung

| Mã | Vai trò và thao tác | Kết quả cần thấy |
|---|---|---|
| D16 | Consumer: Học về xoài; mở bài học, đánh dấu đã đọc; làm câu hỏi tự kiểm tra. | Bộ đếm mục đã đọc và phản hồi đáp án thay đổi. Tiến độ hiện chỉ trong lần mở trang, chưa lưu bền trên server. |
| D17 | Consumer: Viết bài cộng đồng; nhập nội dung/ảnh, Gửi xét duyệt. | Bài chờ Admin công bố; sau duyệt xuất hiện trong Cộng đồng. |
| D18 | Consumer: Tài khoản > Nâng vai trò kinh doanh; chọn Nhà sản xuất/Thương lái, nhập hồ sơ và thêm minh chứng. | Lưu nháp khác Gửi xét duyệt. Chỉ khi gửi thành công Admin mới thấy trong hàng chờ. |
| D19 | Consumer: kiểm tra các mục điều hướng và tham gia cộng đồng. | Không có AI, tạo nhóm hoặc E2EE kinh doanh; vẫn đọc bài, bình luận, nhắn thường và tham gia nhóm. |
| D20 | Consumer/Seller: mở bài đã công bố, thích, bình luận; xóa bình luận của mình. | Lượt thích, nội dung/tác giả và bộ đếm cập nhật. Không xóa được bình luận của người khác. |
| D21 | Consumer/Seller: Nhóm cộng đồng > chọn nhóm > Tham gia và trò chuyện. | Nhận tin các thành viên; không có quyền tạo/đóng nhóm. Nếu mất realtime, dùng Kết nối lại hoặc cập nhật. |
| D22 | Seller: Chọn video > Gửi phân tích; xem tiến độ/kết quả và mở lại tác vụ trong lịch sử AI. | Phân biệt số thấy đồng thời, track xác nhận và lượt qua vạch. Luồng đã chạy nhưng chất lượng AI video còn lỗi, không trình bày là đếm chính xác. |
| D24 | Cả bốn: Tin nhắn > Tin nhắn mới; tìm đối tác, gửi tin. Máy đích mở Tin nhắn rồi đọc. | Có số chưa đọc, hội thoại mới lên đầu; đọc xong số chưa đọc cập nhật. Đây là thông báo trong app, không phải push nền Android. |
| D25 | Cả bốn: Tài khoản > Hồ sơ & quyền riêng tư; sửa tên/giới thiệu và lựa chọn công khai rồi lưu. | Tài khoản khác chỉ thấy trường được công khai; không thấy email/minh chứng. Vai trò/thông tin pháp lý không tự sửa để vượt xét duyệt. |
| D26 | Cả bốn: hồ sơ người khác > Chặn; bỏ chặn tại Hồ sơ & quyền riêng tư > Danh sách đã chặn. | Chặn xem hồ sơ/liên hệ riêng theo chính sách; lịch sử và nhóm chung vẫn giữ. Bỏ chặn cho phép liên hệ lại. |
| D27 | Consumer/Seller: Bài của tôi > mở bài thử > Xóa bài viết > xác nhận. | Bài không còn ở danh sách/trang công khai. Không xóa được bài người khác; bản đã xóa không được hồi sinh bằng lệnh sửa cũ. |
| D28 | Seller: Cơ sở sản xuất/Cơ sở kinh doanh > xóa cơ sở thử không có nội dung liên kết. | Xóa được cơ sở hợp lệ của mình; nếu còn bài/tin liên kết phải từ chối và giải thích. Giữ cơ sở chính cho demo. |

<!-- PAGE -->

## 4. Công nghệ nền tảng và bảo mật đang sử dụng

Luồng chính: Flutter trên Android > HTTPS REST > ASP.NET Core API > PostgreSQL / kho tệp riêng / worker AI trên PC. SignalR qua WSS báo thay đổi về app. Mọi dịch vụ ngoài do backend gọi; điện thoại không kết nối trực tiếp CSDL, Gmail hoặc worker.

| Nhóm | Công nghệ và vai trò thực tế |
|---|---|
| Giao diện | Flutter và Dart; Material, điều hướng theo vai trò, trạng thái tải/lỗi, nhãn chữ, ảnh thu nhỏ và phóng to. |
| API/backend | C# và ASP.NET Core 10; endpoint REST, kiểm đầu vào, quyền, chủ sở hữu và trạng thái nghiệp vụ. OpenAPI cùng trang index giúp tra cứu/thử các nhóm API. |
| CSDL | PostgreSQL; Entity Framework Core và Npgsql để ánh xạ dữ liệu, migration và giao dịch. Lưu tài khoản, vai trò, xét duyệt, bài, chat, job và metadata; tệp lớn nằm ở kho riêng. |
| Realtime | ASP.NET Core SignalR qua WSS; phát sự kiện cho người dùng/hội thoại được phép. REST tải bù dữ liệu sau mất kết nối; ID/revision hỗ trợ loại trùng. |
| Mật khẩu/phiên | ASP.NET Core Identity với hash mật khẩu PBKDF2. Opaque access token và refresh token có xoay/chống dùng lại; server lưu hash token. Đây không phải JWT. |
| OTP email | FruitVision OTP Relay riêng trên Google Apps Script/Gmail; backend gắn mã xác thực HMAC cho yêu cầu. APK không giữ khóa gửi thư. Đăng nhập mới dùng mật khẩu + Email OTP; phiên hợp lệ được khôi phục bằng refresh. |
| Phân quyền | Kiểm vai trò, xét duyệt, ownership và membership ở server. Ẩn nút trên giao diện không thay thế kiểm tra quyền API. Đăng ký mới luôn là Consumer. |
| Khóa trên Android | Android Keystore và AES-GCM bảo vệ phiên/kho khóa cục bộ, ràng buộc tài khoản và máy chủ. BiometricPrompt dùng xác thực sinh trắc học hệ thống nếu thiết bị hỗ trợ. |
| Chat E2EE | sodium/libsodium: X25519, Ed25519, sealed envelope và secretbox cho ảnh. Mã hóa/ký ở client; server nhận bản mã và khóa công khai, không nhận private key. Hai bên so toàn bộ mã an toàn trước gửi. |
| Bảo vệ API/tệp | HTTPS, giới hạn tần suất, kích thước/định dạng, quota và timeout; kiểm quyền khi tải ảnh/minh chứng/kết quả. Chuẩn hóa ảnh thường, bỏ EXIF. Idempotency hạn chế ghi/tải xử lý trùng. |
| Truy cập ngoài mạng | Cloudflare Quick Tunnel cung cấp HTTPS/WSS tạm tới API trên PC. Không mở PostgreSQL/worker ra Internet; URL tạm không phải cam kết máy chủ hoạt động 24/7. |
| Danh mục địa điểm | Backend gọi API địa điểm và cache; app chọn quốc gia/tỉnh qua API FruitVision, không tự gọi nhà cung cấp khác. |
| Cập nhật APK | App hỏi phiên bản qua API, tải APK có kiểm kích thước/SHA-256 rồi mở trình cài Android. APK giữ cùng khóa ký; người dùng vẫn phải xác nhận cài đặt. |

E2EE hiện chưa có forward secrecy, khôi phục khóa hoặc đồng bộ nhiều thiết bị. Face/sinh trắc học không được trình bày là đã chống giả mạo hoặc đã kiểm thử đầy đủ trên điện thoại thật.

<!-- PAGE -->

## 5. AI, tối ưu và cách trình bày đúng

| Công nghệ | Ý nghĩa và vị trí sử dụng |
|---|---|
| YOLOX-Tiny | Kiến trúc detector gọn của graph hiện phục vụ, đầu vào 480 x 480. Backend xử lý kết quả dự đoán xoài và nhãn nguồn xanh/chín/chưa xác định. Bộ lọc vẫn có thể nhận nhầm loài khác. |
| ONNX | Định dạng mô tả đồ thị và trọng số mô hình để thực thi bằng runtime tương thích; bản thân định dạng không tự tăng tốc hoặc tăng độ chính xác. |
| ONNX Runtime | Bộ thực thi graph. Mô hình xoài hiện chạy trên CPU của PC, không chạy trong Flutter hoặc điện thoại. |
| FP32 | Số thực 32 bit của graph hiện tại; không phải tên mô hình hoặc thuật toán tăng tốc. Không tuyên bố bản này đã INT8/FP16 trên điện thoại. |
| Python và xử lý media | Worker PC dùng NumPy, Pillow, OpenCV và FFmpeg theo loại đầu vào: giải mã, tiền xử lý, suy luận, tạo JSON/ảnh chú thích. |
| NMS và tracking | NMS giảm khung chồng trùng; theo dõi hình học gán track và ghi lượt qua vạch. Che khuất, vào lại khung hoặc camera di chuyển có thể gây sai đếm. |
| Camera Android | CameraX lấy khung trên Android; MethodChannel nối Flutter với mã Android. Ảnh trực tiếp được gửi qua API cho PC xử lý. |
| Face + OTP riêng | Worker Node.js dùng ONNX Runtime Node: YuNet phát hiện mặt/landmark, căn chỉnh rồi SFace tạo embedding để đối chiếu. Khớp ảnh vẫn cần Email OTP; không phải chứng minh người thật hoặc chống ảnh giả. |
| Tối ưu đường truyền | Streaming tệp, xử lý ảnh ngoài UI thread, giới hạn độ phân giải/kích thước trước gửi; tránh giữ toàn video trong RAM Dart. |
| Tối ưu live/job | Job bất đồng bộ, hàng đợi/timeout có giới hạn. Live chờ phản hồi rồi gửi khung mới, tránh chồng yêu cầu và lưu mỗi khung thành một job. |
| Tối ưu dữ liệu/UI | Phân trang, index, revision, debounce/dedup sự kiện và tải ảnh có giới hạn. Ảnh minh chứng JPEG/PNG xem trong app, giải phóng cache/bytes khi đóng. |

### Những câu cần nói rõ

- Bản hiện tại là client-server. Không nói AI chạy offline trên điện thoại, không gọi ViT/chưng cất/INT8/NNAPI là công nghệ đang thực thi trong APK này.
- Camera ghi nhận 4,85 khung AI/giây trên một máy ảo ở bản 6012; chưa đạt bằng chứng 6 FPS. Video trên APK 6013 xử lý xong 231 khung nhưng cảnh giống táo bị nhận một xoài: luồng kỹ thuật chạy được, chất lượng chưa đạt.
- Không dùng clip `camera_replay_demo.mp4` làm ví dụ nhận diện xoài đúng. Dùng ảnh xoài đã chuẩn bị và đối chiếu số quả/khung/nhãn thật; không che giấu kết quả sai.
- Số thấy đồng thời, track và lượt qua vạch không phải ba cách gọi của cùng một tổng sản lượng. Không quy đổi kg, không chứng nhận độ ngọt/chất lượng/an toàn thực phẩm.
- Bốn vai trò đã đăng nhập lần lượt trên một máy ảo; chưa có bằng chứng bốn điện thoại hoạt động đồng thời. Có ca API/widget chưa được bấm đủ lại trên APK.

### Chuẩn bị trước khi demo

Giữ PC, PostgreSQL, API và tunnel hoạt động; kiểm tra link API từ mạng ngoài. Cài bản 6013 trên bốn máy, đăng nhập đúng vai trò; chuẩn bị cơ sở đã duyệt và ảnh xoài. Chuẩn bị khóa E2EE đúng thiết bị, không reset khóa tài khoản chính để thử. Nếu realtime báo mất kết nối, bấm Kết nối lại; nếu dùng minh chứng PDF thì máy cần ứng dụng đọc PDF.
