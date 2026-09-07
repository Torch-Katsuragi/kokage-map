# maplibre_android は filter / expression を JNI 経由でリフレクション的に使う。
# R8 が Expression$Converter 等を削ると、filter 付き addLayer が
# ClassNotFoundException で落ち、地図のレイヤが一枚も積めなくなる（2026-09-07 実機で確認）。
-keep class org.maplibre.android.style.expressions.** { *; }
-keep class org.maplibre.android.style.layers.** { *; }
-keep class org.maplibre.android.style.sources.** { *; }
