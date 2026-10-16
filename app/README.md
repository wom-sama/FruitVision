# FruitVision — Flutter project

Mở thư mục này bằng Android Studio với plugin Flutter. Model ONNX đã nằm trong `android/app/src/main/assets`; không cần môi trường Python, dữ liệu training hay server để chạy app.

Hướng dẫn đầy đủ: [README dự án](../README.md), [cài và build Android](../docs/INSTALL_ANDROID.md). Phạm vi tối ưu và kiểm chứng: [tối ưu](../docs/optimizations/README.md).

```sh
flutter pub get
flutter analyze
flutter test
flutter build apk --release --split-per-abi --build-name=1.3.5 --build-number=5009 --android-project-arg=force-version-code-ignoring-abi=true
```

APK Android 8.0/API 26 trở lên, model xử lý hoàn toàn offline. Chọn đúng APK ARM64/ARM32/x86_64 cho thiết bị. Các số đo máy ảo không phải cam kết tốc độ hoặc pin trên điện thoại thật.
