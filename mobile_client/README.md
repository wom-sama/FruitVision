# FruitVision Android 2.2 — client máy chủ

README cho bản phát hành **2.2.0+6006**. Flutter gọi HTTPS/SignalR WSS; PC chạy PostgreSQL và CPU AI. APK không chứa model/runtime AI hoặc truy cập DB trực tiếp; ứng dụng offline lịch sử ở `../app/`. **APK 6006 đã nâng cấp qua trình cài Android và chạy nghiệp vụ bốn vai trò tuần tự trên máy ảo API 30**; xem [biên nhận cuối](../releases/android/2.2.0/native-acceptance.json). Không phải bốn điện thoại thật.

## Cài APK và chọn máy chủ

Ba APK mục tiêu, tính từ `mobile_client/`; chỉ cài bộ có receipt version/SHA/chữ ký tương ứng:

| Kiến trúc Android | APK |
|---|---|
| ARM 64 bit | `build/app/outputs/apk/release/app-arm64-v8a-release.apk` |
| ARM 32 bit | `build/app/outputs/apk/release/app-armeabi-v7a-release.apk` |
| x86 64 bit | `build/app/outputs/apk/release/app-x86_64-release.apk` |

Android tối thiểu API 26. Chọn đúng ABI, cài từ bộ bàn giao tin cậy; không dùng đường dẫn ổ riêng của người phát triển. Giữ package `vn.mangodemo.mango_offline` và chứng thư ký đồ án để cập nhật đè bản trước. Release hiện giữ course/debug signer, chưa phải cấu hình ký Play Store; không đưa keystore/mật khẩu lên Git.

PC/API/tunnel cần hoạt động và điện thoại cần mạng. Mở **Máy chủ** ở đăng nhập hoặc **Tài khoản → Cài đặt máy chủ** để chọn base HTTPS; đổi máy chủ kết thúc phiên hiện tại. Lấy URL hiện hành từ **tệp được sinh local `server/PUBLIC_URL.txt`** trên PC vận hành; tệp không có trong clone/Git. Tunnel có thể đổi tên khi khởi động lại, `localhost` trên điện thoại không trỏ về PC.

Tài khoản/mật khẩu demo riêng ở `server/.local/demo-accounts.json` trên PC được cấp quyền; không đưa nội dung vào APK, README hoặc ảnh chụp. Đăng ký chỉ Producer/Trader/Consumer, bắt đầu Pending. Có đăng nhập email/mật khẩu và mã TOTP nếu bật; hồ sơ NeedsInformation/Rejected có lý do và luồng bổ sung/gửi lại. Bấm cập nhật hồ sơ sau khi Admin duyệt.

## Vai trò, tin dự kiến và liên hệ

Bốn tab chính là không gian nghiệp vụ, **AI**, **Trao đổi**, **Tài khoản**; lịch sử cá nhân ở Tài khoản.

| Vai trò | Không gian nghiệp vụ |
|---|---|
| Admin | Duyệt hồ sơ và tin; quản lý hoạt động tài khoản/audit. Không có luồng đăng tin Seller hoặc liên hệ bài để mở Direct |
| Producer | Sau duyệt đăng Supply, theo dõi AwaitingReview/Published/Rejected/Paused; liên hệ bài Published của người khác |
| Trader | Sau duyệt đăng Demand mặc định hoặc Supply; tìm nguồn cung và liên hệ bài Published |
| Consumer | Đọc tin và giá/nguồn cung, liên hệ bài Published; không đăng Supply/Demand |

Tin có khu vực, ngày dự kiến, lượng kg **dự kiến** và khoảng giá tùy chọn. Admin công bố/paused theo revision; phiên bản cũ có thể `409` và cần tải lại. Consumer/Trader không thấy bản chưa công bố; duyệt hồ sơ/tin không chứng nhận chất lượng hoặc tồn kho.

**Liên hệ từ bài** mở Direct riêng đúng hai người và dùng lại khi cùng người liên hệ cùng bài. Khác tài khoản cùng vai trò vẫn có thể liên hệ; tự liên hệ `409`, Admin dùng endpoint liên hệ `403`. Consumer liên hệ Producer sẽ có Direct khác với Trader liên hệ cùng Producer. Người ngoài không đọc/gửi bằng cách đoán ID.

**Trao đổi → nhóm cộng đồng:** Approved có thể xem nhóm mở, tạo và tự join/leave. Tối đa 10 nhóm mở/chủ, 50 thành viên. Chủ cần đóng trước khi rời; chủ/Admin được đóng. Đã đóng: thành viên hiện tại đọc lịch sử, không join hoặc gửi tin mới. Đã leave: mất quyền đọc/gửi/nhận tin mới. Admin cũng cần membership để đọc tin; không có nút tự thêm người bất kỳ vào Direct.

**Giá & nguồn cung:** lọc nông sản/khu vực; chỉ tổng hợp bài Published từ tác giả hoạt động/Approved. Supply/Demand là lượng tự khai, chưa là tồn kho. Giá VND/kg là trung vị điểm giữa khoảng **chào bán Supply**, có min/max/số mẫu/nguồn/thời điểm; **không gồm giá hỏi mua Demand, không phải dự báo AI hoặc giá thị trường chính thức**. Thiếu giá hiện chưa có dữ liệu, không dựng giá mẫu.

Xem [ma trận tương tác và demo bốn vai trò 6–8 phút](../server/docs/DEMO_4_ROLES_2_2.md).

## AI ảnh và MP4 trên PC

Cả bốn vai trò đang hoạt động/Approved được dùng AI, nhưng chỉ xem/hủy/tải preview tác vụ của mình, kể cả Admin. Có chọn ảnh, chọn video hoặc **chụp một JPEG qua ứng dụng máy ảnh bên ngoài**; chưa truyền camera liên tục/suy luận live stream.

| Giới hạn | Ảnh | Video |
|---|---|---|
| Định dạng/dung lượng | JPEG/PNG thực, tối đa 12 MiB | MP4 thực, tối đa 80 MiB |
| Nội dung | Tối đa 24 triệu pixel | Tối đa 120 giây/3600 khung/1920×1080, cho phép quay dọc |
| Xử lý | Một ảnh | Suy luận mỗi khung đã decode trên PC |

Tệp qua trình chọn Android, cache riêng có giới hạn rồi stream; không đọc cả video vào RAM hoặc xin toàn bộ kho ảnh. Một worker tuần tự, tối đa 4 Queued/Running toàn hệ thống và 1/người. Upload có hạn 90 giây, worker/API có hạn xử lý; video hợp lệ vẫn có thể cần cắt ngắn. Có hủy Queued/Running và đọc lại trạng thái sau mất mạng; không tự gửi POST trùng khi response chưa rõ.

Kết quả/ảnh chú thích tách **maxVisibleCount**, **confirmedTrackCount**, **lineCrossingCount**; ảnh đơn có confirmedTrackCount=0. Không cộng thành unique fruit, kg, sản lượng hay tồn kho. Giai đoạn nguồn không xác nhận độ chín thực địa; yếu/không biết là Chưa xác định. Model SHA `8a69c66a9444c18c98a7e3e58a44f4dddda9eb4583dd4448f430ff9e8db27c41` giữ nguyên, chỉ demo phi thương mại và metadata vẫn ghi video-quality FAIL. Xem [worker/nguồn/giấy phép](../server/ai/README.md), [AI API](../server/docs/AI_API_USAGE.md).

## Realtime, khôi phục và cập nhật APK

Foreground WSS nhận tin, moderation/community và tiến độ AI; sau reconnect tải REST, dedup ID/revision. Đăng xuất/đổi máy chủ hoặc app tạm dừng thì kết nối dừng; đây không phải background push khi đóng app. Chat mở ở tin mới nhất, giữ vị trí khi đọc lịch sử, có nút tin mới. Gửi lại cùng message key/nội dung dùng lại tin; đổi nội dung với key cũ `409`.

Bản 6006 hỗ trợ luồng cập nhật từ manifest/APK **đã đăng ký** trên PC: đúng ABI, size/SHA và kiểm package/version/signer ở native trước khi mở installer. Có kiểm tra/tải/hủy; hủy không được tính là đã nâng cấp. Tính sẵn sàng thực tế phụ thuộc server đã công bố bộ APK và receipt nghiệm thu native cuối.

Android yêu cầu người dùng xác nhận cài; lần đầu có thể cần quyền cài từ nguồn này. Không có cập nhật im lặng hoặc bỏ kiểm chữ ký. Client cũ chưa có updater cần **một lần bootstrap cài thủ công APK tin cậy** có updater, rồi mới dùng cập nhật trong app. Giữ cùng course signer để nâng cấp; không gỡ app để né lỗi signer. Quy trình operator ở [MOBILE_RELEASES.md](../server/docs/MOBILE_RELEASES.md).

## Build và bằng chứng

Dùng Flutter đáp ứng `pubspec.yaml`, Android SDK và JDK 17. Từ `mobile_client`, các lệnh dành cho người build:

```powershell
flutter pub get
flutter analyze
flutter test
flutter build apk --release --split-per-abi --build-name=2.2.0 --build-number=6006
```

Kiểm ba APK bằng `tool/verify_apks.py` với version name/code đúng; Android/Gradle/build do người phụ trách chạy theo giới hạn tài nguyên, không suy thành PASS từ việc có file APK.

[HTTPS/WSS bốn vai trò](../server/docs/verticals-https-e2e.json) đã PASS **49,281 giây, 80 HTTP, 4 WSS đồng thời** trên PC; không phải bốn điện thoại. [AI HTTPS E2E](../server/docs/ai-https-e2e.json) giữ bằng chứng ảnh/video 1073 khung và nhất quán API/worker, không chứng minh ground truth. Receipt 2.1 trong `verification/` là lịch sử. Flutter 64/64 và analyzer sạch; native policy 22/22, package/signature ba ABI đã kiểm. [Biên nhận6006](../releases/android/2.2.0/native-acceptance.json) ghi nâng cấp thực và nghiệp vụ bốn vai trò trên máy ảo. Không chạy lại tác vụ AI ảnh/video mới trên chính6006; bằng chứng AI nêu trên là các lượt giữ nguyên pipeline. Camera emulator trước đây chưa xác nhận chụp JPEG thành công.

Chưa triển khai đơn hàng, giữ hàng/chống vượt tồn, thanh toán/giao nhận/tranh chấp, IoT hoặc chuyển Forecast thành tồn kho. Không gọi toàn bộ nghiệp vụ kinh doanh, camera live hoặc APK chạy trên điện thoại thật đã hoàn tất.

