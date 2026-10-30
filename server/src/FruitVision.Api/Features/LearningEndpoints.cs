namespace FruitVision.Api.Features;

public static class LearningEndpoints
{
    public static void MapLearning(this WebApplication app)
    {
        // Reading this static resource never creates an AI job or grants Seller permissions.
        app.MapGet("/api/v1/learning/mango", () => Results.Ok(new
        {
            schemaVersion = 1,
            productCode = "mango",
            title = "Tìm hiểu về xoài",
            summary = "Đọc và trao đổi quan sát về xoài. Nội dung này không kết luận chất lượng hay độ an toàn của một quả cụ thể.",
            modelScope = new
            {
                acceptedSpecies = "mango",
                objectLabel = "Xoài (dự đoán)",
                stageBasis = "source-two-stage",
                stages = new[]
                {
                    new { code = -1, label = "Chưa xác định", description = "Mô hình chưa đủ tự tin để gán một trong hai nhãn giai đoạn nguồn; không được đổi nhãn này thành xoài hư." },
                    new { code = 0, label = "Xanh / chưa chín", description = "Nhãn giai đoạn của dữ liệu nguồn mà mô hình dự đoán; không xác nhận độ chín của phần thịt bên trong." },
                    new { code = 1, label = "Chín", description = "Nhãn giai đoạn của dữ liệu nguồn mà mô hình dự đoán; không chứng minh vị ngọt, chất lượng hoặc an toàn thực phẩm." }
                }
            },
            sections = new[]
            {
                new
                {
                    id = "visible-observation", title = "Quan sát phần bên ngoài",
                    body = "Ảnh cho thấy màu vỏ, hình dạng và những dấu hiệu nhìn thấy trên bề mặt. Chỉ màu vỏ bên ngoài không đủ để xác nhận giống xoài, độ chín hay chất lượng bên trong. Khi trao đổi, hãy mô tả điều nhìn thấy thay vì khẳng định phần không quan sát được."
                },
                new
                {
                    id = "source-stages", title = "Hiểu đúng nhãn của mô hình",
                    body = "Tuyến AI hiện tại chỉ sử dụng hai nhãn giai đoạn nguồn: Xanh / chưa chín và Chín. Chưa xác định là trạng thái không đủ tự tin. Mô hình này không đưa ra năm mức chín và không có kết luận xoài hư. Một nhãn dự đoán có thể sai."
                },
                new
                {
                    id = "counts", title = "Đọc số đếm đúng đơn vị",
                    body = "Số đối tượng thấy đồng thời, số track xác nhận và số lần qua vạch trong video là các đại lượng khác nhau. Theo dõi hình học có thể mất ID hoặc tạo ID mới khi che khuất, quay lại hoặc camera chuyển động. Những số này không phải khối lượng, tồn kho hay số quả vật lý duy nhất được bảo đảm."
                },
                new
                {
                    id = "community", title = "Học và trao đổi trong cộng đồng",
                    body = "Bạn có thể đọc, đặt câu hỏi và trao đổi quan sát về xoài trong cộng đồng. Hãy tách điều quan sát được, nhãn mô hình và ý kiến cá nhân. Đọc tài liệu này không yêu cầu chạy phân tích ảnh; quyền AI của người sản xuất và thương lái được quản lý riêng."
                }
            },
            limitations = new[]
            {
                "Nội dung học tập và nhãn mô hình không xác nhận giống, độ chín bên trong, hư hỏng hoặc an toàn thực phẩm.",
                "Bộ lọc chỉ giữ đối tượng được dự đoán là xoài; vẫn có thể bỏ sót xoài hoặc nhận nhầm loài khác. Không phát hiện xoài đạt ngưỡng không chứng minh không có xoài.",
                "Mô hình chỉ dùng cho bản trình diễn phi thương mại; hai nhãn từ dữ liệu nguồn không phải độ chính xác được xác nhận ngoài thực tế.",
                "Chất lượng video còn hạn chế; không có bảo đảm đếm đúng mọi quả hoặc đạt 30 FPS trên điện thoại.",
                "Chưa có phân loại xoài hư, giao dịch hoặc thanh toán, dự báo giá, kết nối cảm biến IoT hay phân tích chất lượng nâng cao trong phạm vi này."
            }
        })).RequireAuthorization("Approved").WithTags("Tìm hiểu về xoài");
    }
}
