// dart:ffi も js_interop も無い環境の空実装（gdal_provider.dart の条件 export の既定）。
import 'gdal.dart';

Gdal createGdal() => throw UnsupportedError('GDAL はこのプラットフォームでは使えない');
