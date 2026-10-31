# FruitVision 2.6 — Chức năng và cách kiểm tra theo vai trò

Dùng bốn máy đã đăng nhập sẵn với bốn vai trò. Không gồm đăng ký và đăng nhập. Cột cuối ghi thao tác và kết quả mong đợi, không phải xác nhận mọi ca đã đạt.

| Vai trò | Chức năng | Cách kiểm tra và kết quả cần thấy |
|---|---|---|
| **Admin** | Duyệt hồ sơ nâng vai trò | Người tiêu dùng gửi hồ sơ có minh chứng. Admin mở **Xét duyệt → Duyệt nâng vai trò**, chọn hồ sơ vừa gửi, xem thông tin và minh chứng. Hồ sơ phải xuất hiện sau bước **Gửi xét duyệt**; lưu nháp chưa vào hàng chờ. |
| **Admin** | Yêu cầu bổ sung hoặc từ chối hồ sơ | Nhập lý do và chọn quyết định. Máy người nộp phải thấy trạng thái và lý do tương ứng. Dùng hồ sơ thử; chọn yêu cầu bổ sung/từ chối để giữ nguyên vai trò Người tiêu dùng trong buổi demo. |
| **Admin** | Duyệt bài viết | Nhà sản xuất hoặc Người tiêu dùng gửi bài. Admin mở đúng mục **Duyệt bài chuyên môn / Duyệt bài cộng đồng**, mở chi tiết và chọn **Công bố**. Các máy còn lại phải đọc được bài sau duyệt. |
| **Admin** | Duyệt cơ sở | Nhà sản xuất hoặc Thương lái gửi cơ sở mới. Admin mở **Duyệt cơ sở**, xem thông tin và chấp thuận. Cơ sở phải chuyển sang đã duyệt trên tài khoản chủ sở hữu. |
| **Admin** | Tạo và đóng nhóm cộng đồng | Vào **Tin nhắn → Nhóm cộng đồng → Tạo nhóm**. Ba tài khoản còn lại tham gia và gửi tin. Sau khi Admin đóng nhóm, lịch sử vẫn xem được nhưng không gửi tin mới. |
| **Nhà sản xuất** | Đăng bài chuyên môn | Bấm **Viết bài chuyên môn**, chọn cơ sở đã duyệt, nhập nội dung, chọn ảnh rồi **Gửi xét duyệt**. Bài ở trạng thái chờ; sau khi Admin công bố, các tài khoản khác đọc được nội dung và ảnh. |
| **Nhà sản xuất** | AI nhận diện xoài từ ảnh | Vào **AI xoài → Chọn ảnh → Gửi phân tích**. Dùng ảnh biết trước số quả nhìn thấy; đối chiếu khung, số quả và nhãn xanh/chín/chưa xác định. Ghi lại quả bị bỏ sót hoặc phân loại sai. |
| **Nhà sản xuất** | Camera AI trực tiếp | Vào **Camera nhận diện xoài → Bắt đầu nhận diện**, cấp quyền camera và đưa mẫu vào khung. Phải có kết quả cập nhật; bấm **Dừng nhận diện** hoặc ra nền thì camera dừng, quay lại không tự chạy tiếp. |
| **Nhà sản xuất** | Quản lý cơ sở | Tạo cơ sở và gửi duyệt. Trước khi được Admin chấp thuận, cơ sở chưa được dùng để đăng bài chuyên môn; sau duyệt phải chọn được trong biểu mẫu bài viết. |
| **Thương lái** | Liên hệ từ bài viết | Mở bài chuyên môn của Nhà sản xuất, bấm **Trao đổi với tác giả**, gửi một tin. Nhà sản xuất mở **Tin nhắn** và trả lời. Hai máy phải thấy đúng người gửi và nội dung; mở liên hệ lại vẫn dùng cùng hội thoại. |
| **Thương lái** | Đăng bài chuyên môn và quản lý cơ sở | Thử cùng luồng của Nhà sản xuất: gửi cơ sở, chờ Admin duyệt, rồi gửi bài chuyên môn. Kiểm tra bài chỉ công khai sau khi được duyệt. |
| **Thương lái** | AI nhận diện xoài | Thử nhận diện ảnh hoặc camera như Nhà sản xuất. Kiểm tra tài khoản có quyền dùng AI và nhận kết quả của chính phiên mình. Dừng phiên AI đang chạy trước khi chuyển sang tác vụ ảnh/video. |
| **Nhà sản xuất và Thương lái** | Gửi ảnh trong chat thường | Chọn ảnh trong hội thoại, bấm **Gửi ảnh**. Hai máy phải thấy ảnh thu nhỏ ngay trong lịch sử; bấm ảnh để phóng to rồi quay lại, ảnh vẫn còn. |
| **Nhà sản xuất và Thương lái** | Chat riêng mã hóa đầu cuối | Chuẩn bị khóa trên hai máy và đối chiếu mã an toàn trước. Mở chat mã hóa giữa hai tài khoản, gửi tin và ảnh; người nhận phải đọc/xem được. Không dùng chat thường để thay cho ca kiểm tra này. |
| **Nhà sản xuất và Thương lái** | Phân biệt đối tác chat | Mở một hội thoại với nhau và một hội thoại với Người tiêu dùng. Tiêu đề phải hiển thị đúng đối tác/vai trò; tùy chọn mã hóa đầu cuối chỉ xuất hiện khi cả hai đối tác đủ điều kiện. |
| **Người tiêu dùng** | Học về xoài | Vào **Học về xoài**, mở các mục kiến thức, đánh dấu đã đọc và làm câu hỏi tự kiểm tra. Phản hồi đáp án và số mục đã đọc phải cập nhật theo thao tác. |
| **Người tiêu dùng** | Đăng bài cộng đồng | Bấm **Viết bài cộng đồng**, nhập nội dung, chọn ảnh và gửi duyệt. Admin công bố; các máy còn lại phải thấy bài và ảnh trong mục cộng đồng. |
| **Người tiêu dùng** | Gửi hồ sơ nâng vai trò | Vào **Tài khoản → Nâng vai trò kinh doanh**, chọn Nhà sản xuất hoặc Thương lái, điền hồ sơ và thêm minh chứng. Thử lưu nháp trước, sau đó **Gửi xét duyệt**; kiểm tra trạng thái thay đổi và Admin thấy đúng hồ sơ. |
| **Người tiêu dùng** | Giới hạn quyền | Kiểm tra giao diện không có chức năng AI, tạo nhóm hoặc chat mã hóa dành cho hai vai trò kinh doanh. Tài khoản vẫn đọc bài, bình luận và tham gia nhóm được. |
| **Nhà sản xuất, Thương lái và Người tiêu dùng** | Thích và bình luận | Mở cùng một bài đã công bố trên ba máy, thích và gửi các bình luận khác nhau. Kiểm tra số lượt thích, nội dung và tên người gửi; xóa bình luận của mình thì bình luận và bộ đếm phải cập nhật. |
| **Nhà sản xuất, Thương lái và Người tiêu dùng** | Tham gia nhóm và nhắn tin | Mở nhóm Admin vừa tạo, chọn **Tham gia và trò chuyện**, mỗi máy gửi một tin. Các thành viên phải nhận được tin của nhau; ba vai trò này không có nút tạo/đóng nhóm. |
| **Nhà sản xuất và Thương lái** | AI video và lịch sử | Tải video mẫu ngắn, xem tiến độ, kết quả và mở lại tác vụ trong lịch sử. Đối chiếu số quả nhìn thấy, số track và lượt qua vạch theo đúng từng chỉ số; không cộng chúng thành tổng số quả vật lý duy nhất. |


| Vai trò | Chức năng bổ sung 2.6 | Cách kiểm tra và kết quả cần thấy |
|---|---|---|
| **Admin** | Bổ nhiệm quản trị viên | Mở Xét duyệt → Bổ nhiệm quản trị viên, tìm Người tiêu dùng đã duyệt và xác minh email. Chọn đúng người, nhập lý do và mật khẩu Admin rồi xác nhận. Người được bổ nhiệm phải đăng nhập lại và có vai trò Admin. Không dùng tài khoản Người tiêu dùng của nhóm bốn vai trò khi còn cần demo vai trò đó. |
| **Cả bốn vai trò** | Hộp thư, tin mới và chưa đọc | Vào Tin nhắn → Tin nhắn mới, tìm tài khoản đích và gửi. Máy đích ở màn hình khác trong app phải thấy số chưa đọc; mở Tin nhắn thấy đúng người và hội thoại ở đầu danh sách. Đọc tin xong thì số chưa đọc cập nhật. |
| **Cả bốn vai trò** | Hồ sơ và quyền riêng tư | Vào Tài khoản → Hồ sơ & quyền riêng tư, sửa tên hiển thị hoặc giới thiệu, chọn mục giới tính/số điện thoại/khu vực muốn công khai rồi lưu. Tài khoản khác mở hồ sơ từ danh bạ hoặc đầu hội thoại: không thấy email hay minh chứng; chỉ thấy các trường được cho phép. |
| **Cả bốn vai trò** | Chặn và bỏ chặn liên hệ riêng | Mở hồ sơ người khác và xác nhận Chặn. Người bị chặn không mở được hồ sơ và không gửi được tin riêng/ảnh thường/gói mã hóa; lịch sử và nhóm chung vẫn giữ. Vào Hồ sơ & quyền riêng tư → Danh sách đã chặn để bỏ chặn, sau đó liên hệ lại được. |
| **Người tiêu dùng, Nhà sản xuất, Thương lái** | Xóa bài viết của mình | Mở bài của tôi, chọn Xóa và xác nhận. Bài biến mất khỏi danh sách và trang công khai; người khác không được xóa bài của tác giả. Bài đã xóa không thể được công bố lại bằng lệnh sửa cũ. |
| **Nhà sản xuất, Thương lái** | Xóa cơ sở của mình | Vào Cơ sở sản xuất / Cơ sở kinh doanh. Xóa hồ sơ thử không còn nội dung liên kết; nếu còn bài hoặc tin gắn cơ sở thì app phải giải thích và từ chối. Không xóa cơ sở đang dùng cho bài demo. |
