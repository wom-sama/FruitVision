# Xuất bản cập nhật APK từ PC

`scripts/Publish-MobileRelease.ps1` là CLI cho **người vận hành trên PC**, không phải API upload APK từ người dùng. Nó chỉ công bố ba APK đã có biên nhận kiểm tra tin cậy. Script không build, ký, tự chạy Android SDK, huấn luyện hoặc phân phối model/DB/config riêng.

## Chuẩn bị bộ phát hành thật

Người phụ trách Android build và kiểm package `vn.mangodemo.mango_offline`, versionName/versionCode, ba ABI `arm64-v8a`, `armeabi-v7a`, `x86_64`, APK Signature Scheme v2, cùng signer, kích thước/SHA và khả năng nâng cấp. Biên nhận từ [verify_apks.py](../../mobile_client/tool/verify_apks.py) cần có `allPassed:true` và đúng ba artifact, mỗi artifact gồm `abi`, `path`, `bytes`, `sha256`, `version` dạng `2.2.0+6005`, `v2Signature:true`, `signerSha256`.

`path` phải trỏ tới tệp `.apk` **bên trong chính ReleaseDirectory**; đường dẫn tương đối cũng được hiểu từ thư mục này. Tên nguồn có thể là `app-<abi>-release.apk` hoặc tên FruitVision được đặt khi bàn giao, nhưng file phải khớp biên nhận. Nếu chuyển/copy bộ phát hành sang thư mục khác, dùng biên nhận tin cậy tương ứng với vị trí mới; không đổi nhãn version/signature của một APK chưa được kiểm.

CLI tin vào kết luận của công cụ kiểm/người vận hành, sau đó tự đối chiếu version, ba ABI, v2 assertion, signer thống nhất, 1 byte–80 MiB, kích thước và SHA thực của tệp nguồn. Nó **không chứng minh chữ ký Android chỉ bằng một JSON tự khai**. Native updater và Android còn kiểm APK thực khi nâng cấp. Không dùng biên nhận dummy trong thử nghiệm filesystem để phát hành thật.

## Lần cấu hình đầu tiên

Khởi tạo backend trước để có `server/.local/runtime.json`. Từ thư mục `server`, ví dụ cho bộ APK **thực sự đã kiểm** là `2.2.0+6005`:

```powershell
./scripts/Publish-MobileRelease.ps1 `
  -ReleaseDirectory '../mobile_client/build/app/outputs/apk/release' `
  -VerificationReceipt '../mobile_client/verification/apk-verification.json' `
  -VersionName '2.2.0' -VersionCode 6005 `
  -MinimumSupportedVersionCode 6002 `
  -Notes 'FruitVision 2.2: cập nhật client qua bản phát hành đã kiểm.' `
  -Configure
```

Chọn đúng tệp receipt được tạo cho bản đó; tên file không tự bảo đảm nội dung là bản mới nhất. Default store là đường dẫn tuyệt đối `<clone>/server/.local/mobile-releases`. `-RootPath` chỉ nhận đường dẫn tuyệt đối nằm dưới `.local` của chính dự án, phục vụ store riêng/thử nghiệm có chủ đích; không nhận đường dẫn tương đối hoặc junction/symlink.

`-Configure` chỉ thêm `MobileUpdates.RootPath` khi chưa được cấu hình, sao lưu private JSON rồi cập nhật nguyên tử, giữ AI/DB/secret và các trường khác. Nếu root cũ đã giống thì không đổi; khác thì từ chối để tránh vô tình chuyển store đang chạy. Bản sao config vẫn chứa secret và phải ở `.local`, không đưa lên Git hoặc gửi kèm log.

Sau khi **lần đầu** ghi RootPath, người vận hành restart riêng API do dự án sở hữu:

```powershell
./scripts/Stop-Server.ps1
./scripts/Start-Server.ps1
```

CLI không tự dừng/khởi động service. Những lần phát hành tiếp theo vào cùng root chỉ cập nhật manifest; backend đọc file hiện hành nên không cần restart chỉ để thấy version mới.

## Tính bất biến và cập nhật manifest

Store có dạng:

```text
.local/mobile-releases/
  manifest.json                    # Bản mới nhất
  6005/
    manifest.json                  # Snapshot bất biến của version này
    app-arm64-v8a-release.apk
    app-armeabi-v7a-release.apk
    app-x86_64-release.apk
    .verification-receipt.sha256   # Dấu biên nhận riêng cho operator, không có route tải
```

Manifest đúng hợp đồng gồm `schemaVersion:1`, package cố định, `versionName`, `versionCode`, `minimumSupportedVersionCode`, `notes`, `publishedAt` UTC và ba artifact với `abi`, `fileName`, `sizeBytes`, `sha256`. Không nhận filename/path tùy ý từ HTTP.

Mỗi lượt xuất bản giữ khóa độc quyền của store, kiểm toàn bộ đầu vào, copy vào một thư mục staging mới dưới root, kiểm lại SHA sau copy, rồi đổi tên cả thư mục thành `<versionCode>`. Chỉ sau đó mới thay **nguyên tử** `ROOT/manifest.json` bằng đúng bytes của `ROOT/<versionCode>/manifest.json`. Bản cũ/snapshot cũ vẫn tồn tại để link tải đã đăng ký không biến thành một APK khác.

Không công bố versionCode thấp hơn latest. Version đã tồn tại chỉ cho chạy lặp với **chính biên nhận gốc, metadata và bytes giống hệt**; `publishedAt` được giữ nguyên. Sửa notes, minimum supported version, receipt, signer claim hoặc APK cùng version đều bị từ chối. Muốn đổi một bản phát hành, build/kiểm một versionCode mới cao hơn; không đổi nhãn APK cũ thành version mới.

Nếu một bước fail, không xóa đệ quy hay ghi đè thư mục version cũ để “chữa nhanh”. Staging có thể được giữ lại trong `.local` cho operator kiểm tra. Lượt kiểm tra thất bại trước commit không thay latest; nếu crash sau khi version directory hoàn tất mà trước cập nhật latest, chạy lại với chính receipt gốc có thể hoàn tất pointer mà không thay bytes.

## Kiểm tra qua API và trên Android

Sau khi xuất bản thật, dùng host HTTPS hiện hành trong tệp local `server/PUBLIC_URL.txt` do script tunnel tạo (không đăng tệp đó lên Git):

* `GET /api/v1/mobile/update?versionCode=6002&abi=arm64-v8a` kiểm khả dụng cho một client cụ thể.
* `GET /api/v1/mobile/releases/6005/arm64-v8a.apk` tải đúng artifact đã đăng ký cho version/ABI đó.

Backend chỉ phục vụ ABI/leaf đã đăng ký, đối chiếu file/size/SHA; không biến `.local` thành thư mục static download tổng quát. `minimumSupportedVersionCode` là ngưỡng tương thích do operator công bố, không phải quyền ép Android cài im lặng.

Android cần người dùng xác nhận cài/nâng cấp. Lần đầu cài từ app/nguồn ngoài kho, hệ điều hành có thể yêu cầu bật quyền **cài ứng dụng không rõ nguồn gốc cho đúng nguồn đó**; đây là cổng đồng ý của Android, không phải lỗi API. Client thông thường không được tự bỏ qua hộp xác nhận. Người dùng có thể hủy; phiên bản đang cài không vì thế trở thành bản mới.

Các client cũ chưa có màn hình/chức năng cập nhật cần **một lần bootstrap bằng cách cài thủ công APK tin cậy có updater**. Sau đó mới dùng luồng cập nhật trong app ở các phiên bản tiếp theo. Package và chứng thư ký phải tương thích với bản đã cài; không gỡ app hoặc tắt kiểm tra để né lỗi chữ ký. Máy/Android thật và nâng cấp trên bản đã cài cần lượt nghiệm thu riêng.

## Bằng chứng kiểm CLI

Script đã chạy bộ kiểm filesystem riêng trong `.local/publisher-cli-validation-*` bằng **bytes dummy chưa ký**, không gọi SDK hay HTTP và không dùng `-Configure` vào runtime thật. 26 kiểm tra đã qua: copy/hash ba ABI, snapshot/latest giống bytes, idempotence giữ timestamp, từ chối downgrade/metadata khác/receipt khác/hash sai/path traversal/mixed signer/v2 false/oversize/missing ABI/root tương đối, các lần từ chối giữ latest, và xuất bản version cao hơn vẫn giữ snapshot/APK cũ.

Đây là bằng chứng hành vi CLI/atomic publication trong store thử nghiệm, **không phải chữ ký APK thật hoặc cập nhật đã phát hành cho người dùng**. Lượt xuất bản thật dùng receipt Android thật và biên nhận triển khai riêng của operator.

## Khóa ký khi clone sang máy khác

Không phân phối khóa ký riêng qua Git. Build trên máy khác bằng debug key mới có thể cài như một triển khai riêng, nhưng không thể cập nhật app đã ký bằng khóa cũ. Giữ khóa của chính triển khai đó cho các lần sau. Công cụ verify_apks.py mặc định ghim chứng thư của bộ APK đồ án hiện tại; triển khai độc lập dùng --expected-signer-sha256 với fingerprint khóa của mình, rồi kiểm nâng cấp thật giữa hai bản cùng khóa. Thay tham số không khiến Android chấp nhận signer khác với app đang cài.

Khi cấp quyền cài APK, Android có thể kết thúc tiến trình ứng dụng. Client khôi phục gói hoàn tất trong cache riêng bằng cách xác minh lại theo manifest hiện tại; không coi cache là tin cậy chỉ vì tên file. Gói khác phiên bản/hash hoặc tải dở không được đưa ra để cài. Bản cập nhật vẫn cần xác nhận của Android.
