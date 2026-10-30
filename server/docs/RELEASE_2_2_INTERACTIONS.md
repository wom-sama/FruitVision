# FruitVision 2.2: tương tác, cộng đồng và tham khảo cung/cầu

Mã nguồn bổ sung nhóm thảo luận công khai cho tài khoản đã duyệt và bảng cung/cầu theo bài đăng được công khai. Giá là dữ liệu chào bán do người dùng nhập; không sinh giá mẫu hay dự đoán giá AI. Tình trạng triển khai và biên nhận kiểm thử của máy đang chạy phải được đối chiếu riêng; ghi chú này không tự xác nhận APK, điện thoại hoặc một bản clone mới đã nghiệm thu.

## Chạy trên PC Windows khác

Yêu cầu Windows x64, PowerShell 7 và .NET 10 SDK. Các script PostgreSQL/API hiện lấy đường dẫn theo thư mục dự án; không cần đường dẫn C:/E: của người phát triển. Từ thư mục `server` trong bản clone:

```powershell
./scripts/Install-Runtimes.ps1
dotnet restore FruitVision.slnx --locked-mode
dotnet build src/FruitVision.Api/FruitVision.Api.csproj -c Release
./scripts/Start-Server.ps1
Invoke-RestMethod http://127.0.0.1:5098/health/ready
```

Installer tải các runtime Windows đã ghim, kiểm hash và đặt dưới `.tools`. `Start-Server.ps1` khởi tạo cluster riêng, chạy migration, cấp quyền dữ liệu tối thiểu rồi khởi động API. Tài khoản demo/mật khẩu ngẫu nhiên của **chính máy mới** nằm ở `.local/demo-accounts.json`; không sao chép secret, PID, database, log hoặc `.local/runtime.json` từ máy phát triển. `.local` và `.tools` không thuộc bản phát hành Git. Không ghi đè cluster/config có sẵn để chữa lỗi khởi động; đọc log riêng và xác định nguyên nhân.

API chạy được khi chưa bật AI: lúc đó `aiReady:false` và tác vụ AI trả `503`. URL trong README/`PUBLIC_URL.txt` hoặc biên nhận cũ thuộc một máy/lần chạy trước. Nếu cần truy cập từ điện thoại, dùng `Install-Public.ps1` rồi `Start-Public.ps1` trên PC mới và lấy URL mới; PC/API/tunnel phải tiếp tục chạy. Đây là hostname tạm, không phải hosting cố định. Không mở PostgreSQL hoặc thư mục media ra Internet.

## Bật AI mà không dùng môi trường riêng của người phát triển

Kho Git phải giữ bố cục `server/ai/worker.py` và `app/android/app/src/main/assets/` với model, `detector_metadata.json`, `model_metadata.json`, `SOURCE_ATTRIBUTION.json`, `YOLOX_LICENSE.txt`. Worker đọc metadata tại bố cục này kể cả khi `ModelPath` trỏ đến một bản sao khác. Không cần thay, tải lại hoặc huấn luyện trọng số. Model hiện tại có SHA-256:

```text
8a69c66a9444c18c98a7e3e58a44f4dddda9eb4583dd4448f430ff9e8db27c41
```

Sau khi cài CPython **3.11 x64**, từ `server` chạy installer riêng (thay đường dẫn Python theo máy mới):

```powershell
./scripts/Install-AiRuntime.ps1 -PythonExecutable 'C:\Python311\python.exe' -Configure
./scripts/Stop-Server.ps1
./scripts/Start-Server.ps1
```

Cần chạy bước khởi tạo backend trước để có `.local/runtime.json`. Installer tạo `.tools/ai-venv`, cài từ PyPI chính thức theo bảy phiên bản trong [requirements-ai.txt](../ai/requirements-ai.txt), kiểm Python/import/model SHA/metadata/ORT và suy luận một ảnh trung tính. `-Configure` sao lưu config trong chính `.local`, giữ nguyên kết nối/secret, ghi nguyên tử các đường dẫn tính từ clone vào khối `Ai`. Không cần ổ E: hoặc thư viện riêng của người phát triển. Script dừng khi gặp môi trường cài dở, Python sai hoặc preflight thất bại; không tự thay model.

Cấu hình dùng `PythonPath=.tools/ai-venv/Scripts/python.exe`, `PythonModulePath=.tools/ai-venv/Lib/site-packages`, `PythonExtraModulePath=''`, worker/model theo bố cục clone và dữ liệu dưới `.local/ai`; các giá trị thực trong JSON đều là đường dẫn tuyệt đối. Các bản sao config vẫn chứa secret, cần ở thư mục ACL riêng và không đưa lên Git. Không in nội dung config để chia sẻ lỗi.

Sau restart, kiểm `/health/ready`, đăng nhập tài khoản đã duyệt, đọc `/api/v1/ai/capabilities`, rồi gửi **một ảnh thật** để xác nhận toàn bộ tác vụ hoàn tất. `aiReady:true` kiểm tài nguyên đã cấu hình, không thay thế tác vụ thực. Hợp đồng/giới hạn AI và giấy phép phi thương mại ở [../ai/README.md](../ai/README.md).

Installer mới đã thực sự tạo venv riêng sạch và chạy real ORT preflight trên **dự án hiện tại**, không phụ thuộc thư mục E:. Kết quả đó không xác nhận toàn bộ bản clone/auth/API/HTTPS đã chạy trên một PC khác. Installer không tự restart API hay thay cấu hình khi thiếu `-Configure`.

## Hợp đồng cộng đồng

Mọi vai trò Admin/Producer/Trader/Consumer đang hoạt động và `Approved` đều có thể xem nhóm đang mở, tạo nhóm hoặc tham gia. Tài khoản Pending không được truy cập. Các route:

| Route | Hành vi |
|---|---|
| `GET /api/v1/community/groups?region&productCode&limit&after` | Nhóm công khai đang mở, mới nhất trước; `limit` mặc định 20/tối đa 50, cursor theo nhóm đang thấy |
| `POST /api/v1/community/groups` | `{title,region,productCode?}`; tên 5–160 ký tự, khu vực 2–120; người tạo tự là chủ/thành viên |
| `GET /api/v1/community/groups/{id}` | Metadata, `memberCount`, `isMember`, `currentRole` |
| `POST .../{id}/join` | Body `{}`; thêm chính người gọi, `201` lần đầu/`200` khi đã tham gia |
| `POST .../{id}/leave` | Body `{}`; idempotent; chủ nhóm cần đóng trước khi rời |
| `POST .../{id}/close` | Chỉ chủ nhóm/Admin; không nhận thành viên hoặc tin nhắn mới |

Mỗi chủ sở hữu tối đa 10 nhóm mở; mỗi nhóm tối đa 50 thành viên. Giao dịch/khóa DB tuần tự hóa tranh chấp giới hạn. Không thể dùng ID hội thoại Direct hoặc nhét `userId`/`participantIds` vào body để thêm người khác. Thành viên nhóm đóng vẫn đọc được lịch sử; người đã rời không còn quyền đọc/gửi tin. Tin nhắn dùng hợp đồng hội thoại sẵn có.

`CommunityChanged` phát tới nhóm hub `approved`, `ConversationCreated` phát riêng tới người vừa tham gia. Sự kiện gửi sau commit và chỉ là thông báo best effort; lỗi/cancellation thông báo không đảo trạng thái đã ghi DB. Sau reconnect hãy lấy lại danh sách/metadata bằng REST. Dispatcher tin nhắn tra lại thành viên hiện tại khi gửi, không dựa vào membership hub đã cũ.

## Bảng cung/cầu và giá tham khảo

`GET /api/v1/market/summary?region&productCode` là public read, tổng hợp **chỉ** bài `Published` của tác giả hoạt động, đã duyệt. Khu vực lấy từ bài, hoặc hồ sơ tác giả nếu bài cũ chưa lưu khu vực. Bộ lọc giữ nhãn khu vực người dùng đã nhập, không tự dựng danh sách tỉnh/canonical địa danh. Quá 500 nhóm nông sản/khu vực sẽ yêu cầu lọc hẹp hơn, không âm thầm bỏ phần còn lại.

Mỗi item có `productCode`, `productName`, `region`, `supplyEstimatedKg`, `demandEstimatedKg`, `supplyPostCount`, `demandPostCount`, `contributorCount`, `referencePriceVndPerKg`, `priceMinVndPerKg`, `priceMaxVndPerKg`, `priceSampleCount`, `lastUpdated`. Top-level có `region`, `productCode`, `asOf`, `source`, `isForecast`, `items`, `limitations`.

`source=published-user-asking-prices`, `isForecast=false` mô tả **giá chào tham khảo**, không biến lượng cung/cầu thành tồn kho. Giá tham chiếu chỉ lấy bài **Supply** có khoảng giá hợp lệ: trung vị điểm giữa khoảng chào bán, kèm giá thấp nhất/cao nhất và số bài có giá. Giá hỏi mua Demand không tham gia giá chào bán tham khảo. Không có mẫu thì cả ba giá là `null`, số mẫu 0. Lượng cung/cầu là **dự báo tự khai**, không phải giao dịch, giá chính thức, dự đoán AI hoặc cam kết giao hàng. Nhiều bài có thể cùng nói về một lô; tổng lượng chưa khử trùng vật lý.

## Kịch bản demo có dữ liệu thật do người dùng nhập

1. Producer đăng dự kiến cung 20 kg xoài ở một khu vực và khoảng chào bán 20.000–30.000 VND/kg; Admin duyệt Published. Consumer thấy cung dự kiến 20 kg, giá tham khảo 25.000, một mẫu giá.
2. Trader đăng nhu cầu mua trong cùng khu vực, Admin duyệt. Consumer thấy thêm cầu dự kiến; khoảng hỏi mua không thay giá tham khảo bên cung.
3. Producer tạo nhóm, Consumer tham gia và gửi tin. Chủ nhóm đóng; lịch sử còn cho thành viên, gửi/join mới bị chặn. Thành viên rời nhóm thì không đọc được tin tiếp theo.
4. Thử tài khoản Pending, hội thoại Direct của người khác và bài chưa duyệt: không được lộ nội dung riêng/cộng sai vào dashboard.

Các số ở kịch bản là dữ liệu người demo tự nhập theo bước, không phải feed giá thị trường dựng sẵn. Seed không có khoảng giá thì dashboard phải hiện thiếu dữ liệu giá. Bản này chưa thực hiện giữ hàng, tồn kho, đơn mua bán hoàn tất, giao nhận, thanh toán hoặc giải quyết tranh chấp; AI đếm ảnh/video không tự tạo kg/tồn kho.

