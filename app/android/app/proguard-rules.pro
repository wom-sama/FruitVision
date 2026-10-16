# ORT JNI resolves Java classes/constructors by their original names.
# https://onnxruntime.ai/docs/build/android.html
-keep class ai.onnxruntime.** { *; }
# JNI entry points use the exact preprocessor class/method names.
-keep class vn.mangodemo.mango_offline.NativePreprocessor { *; }
