# Bộ dữ liệu demo FruitVision

`demo-data.json` là dữ liệu tổng hợp cho nền tảng backend xác thực/phân quyền .NET và PostgreSQL. Tệp dùng schema `fruitvision-demo-seed-v1`, `isDemo: true`, UTF-8 và tên thuộc tính camelCase. Bộ dữ liệu không thay thế việc triển khai hoặc kiểm chứng các luồng giao dịch đầy đủ trong yêu cầu nghiệp vụ.

## Số lượng và ý nghĩa

| Nhóm | Số lượng | Nội dung |
| --- | ---: | --- |
| Người dùng | 24 | 1 Admin, 8 Producer, 8 Trader, 7 Consumer |
| Trạng thái hồ sơ | 24 | 15 Approved, 3 Pending, 3 NeedsInformation, 3 Rejected |
| Danh mục | 3 | `mango` (xoài), `orange` (cam), `vegetable` (rau ăn lá); đều dùng `kg` |
| Tin dự kiến | 60 | 24 Published, 12 Draft, 8 AwaitingReview, 6 NeedsChanges, 6 Paused, 4 Closed |
| Cuộc hội thoại | 16 | Mỗi cuộc có 2 người tham gia, tham chiếu tin đã công khai |
| Tin nhắn | 480 | 30 tin/cuộc, trao đổi tiếng Việt về quan tâm và kế hoạch dự kiến |
| Lịch sử tương tác mẫu | 200 | `kind: DemoInteraction`, minh họa thao tác đọc/tìm hiểu/chuẩn bị |

Bốn email đầu mối: `admin@fruitvision.test`, `producer@fruitvision.test`, `trader@fruitvision.test`, `consumer@fruitvision.test`. Các tài khoản còn lại đánh số theo vai trò. Mọi tên, email và nội dung đều giả định; vùng/địa phương chỉ là bối cảnh chung, không phải địa chỉ cá nhân hay cơ sở thực. Tệp không chứa mật khẩu, mã truy cập, giấy tờ, số điện thoại, thông tin ngân hàng hoặc chi tiết người thật. Cơ chế cấp thông tin đăng nhập demo phải nằm trong cấu hình seed an toàn của backend, không nhúng vào fixture.

## Giới hạn nghiệp vụ

- Chỉ có đúng bốn vai trò `Admin`, `Producer`, `Trader`, `Consumer`. Luồng đăng ký công khai chỉ được phép chọn ba vai trò nghiệp vụ; Admin phải được khởi tạo riêng. Fixture không tự thực thi quyền đó.
- Cả ba vai trò nghiệp vụ có trường hợp `Pending`, `NeedsInformation` và `Rejected`. Hồ sơ được duyệt chỉ biểu thị kết quả xét duyệt hồ sơ, không chứng nhận an toàn hay bảo đảm chất lượng nông sản.
- Mọi tin đều có `sourceType: Forecast`. `estimatedQuantityKg` là ước tính phục vụ kế hoạch, không phải hàng đã cân, hàng sẵn có, tồn kho, lượng đã giữ hoặc quyền nhận hàng. Cả tin của đơn vị kinh doanh cũng chưa ghi nhận nhận hàng từ nguồn cung.
- Tác giả của tất cả tin là Producer/Trader đã Approved. Hội thoại chỉ có người dùng nghiệp vụ đã Approved; người gửi luôn thuộc danh sách tham gia.
- Tin nhắn chỉ mô phỏng việc tìm hiểu và quan tâm nguồn dự kiến. Không có đề nghị có cấu trúc được chấp nhận, đơn hàng, xác nhận mua bán, giữ tồn, nhập/xuất kho, giao nhận, đánh giá giao dịch hoặc khoản thanh toán đã hoàn tất.
- Không có dữ liệu phân tích AI hoặc kết quả mô hình thật. Không suy ra khối lượng, chất lượng, độ ngọt, độ an toàn hay thời gian bảo quản từ các đoạn hội thoại.
- 200 dòng lịch sử đều ghi rõ là tương tác giả lập. Chúng không phải nhật ký kiểm toán/quản trị, bằng chứng đăng nhập, kết quả kiểm tra quyền, sự kiện bảo mật hoặc bằng chứng rằng API tương ứng đã chạy. Nhật ký thật của backend cần được lưu và phân biệt riêng.
- Các mốc thời gian là lịch trình mẫu cố định tháng 10/2026 (UTC, đuôi `Z`), không phải thời điểm tác vụ thực tế xảy ra. Khung tháng 11/2026 trong nội dung tin là kế hoạch giả định.

## Cách nạp và đối chiếu

Chỉ dùng tệp trong môi trường demo đã được cấu hình rõ ràng và bật cơ chế seed demo có kiểm soát của backend. Không cung cấp endpoint seed công khai hoặc tự bật seed trong môi trường production. Cách chạy backend và biến cấu hình seed thực tế được mô tả ở tài liệu server; fixture không tự thiết lập kết nối cơ sở dữ liệu hay tạo thông tin đăng nhập.

ID tin, cuộc hội thoại, tin nhắn và lịch sử là UUID v5 xác định từ schema, loại bản ghi và số thứ tự. Chúng giữ nguyên khi dùng lại tệp. Email và mã danh mục cũng ổn định. Loader cần dùng các khóa này để nạp kiểu upsert/skip một cách có kiểm soát, bảo toàn dữ liệu phát sinh và tránh tạo bản sao khi chạy lại; tính idempotent phải được kiểm chứng ở loader thực tế.

Sau khi nạp, đối chiếu số lượng theo bảng; kiểm tra khóa tham chiếu email, mã danh mục và `postId`; kiểm tra quyền đọc riêng của cuộc hội thoại/lịch sử bằng tài khoản liên quan. Mở dữ liệu bằng từng vai trò, kiểm tra tài khoản chưa Approved không vượt quyền, và xác minh dữ liệu vẫn còn sau khi khởi động lại. Bộ fixture chỉ cung cấp dữ liệu cho các bước kiểm tra này, không tuyên bố các bước đã thành công.
