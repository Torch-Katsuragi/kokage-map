// ホスト VM テスト用の GDAL の在処。見つからなければ null（そのテストは skip）。
//
// - 環境変数 KOKAGE_GDAL_LIB があればそれ（PROJ_DATA / GDAL_DATA も環境変数から）
// - Windows: QGIS 同梱の gdal*.dll（`C:\Program Files\QGIS *\bin`。新しい版から探す）。依存 DLL は同じ bin から読む
// - Linux（CI）: apt の libgdal（`libgdal-dev` が入れる libgdal.so）
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:root_maps/core/gdal/gdal_ffi.dart';

GdalFfiConfig? findHostGdal() {
  final env = Platform.environment;
  final override = env['KOKAGE_GDAL_LIB'];
  if (override != null && override.isNotEmpty) {
    return GdalFfiConfig(
      libraryPath: override,
      dllSearchDir: Platform.isWindows ? p.dirname(override) : null,
      projDataDir: env['PROJ_DATA'],
      gdalDataDir: env['GDAL_DATA'],
    );
  }
  if (Platform.isWindows) return _findQgis();
  if (Platform.isLinux) {
    for (final c in const ['/usr/lib/x86_64-linux-gnu/libgdal.so', '/usr/lib/libgdal.so', '/usr/local/lib/libgdal.so']) {
      if (File(c).existsSync()) return GdalFfiConfig(libraryPath: c);
    }
  }
  return null;
}

GdalFfiConfig? _findQgis() {
  final pf = Platform.environment['ProgramFiles'] ?? r'C:\Program Files';
  final root = Directory(pf);
  if (!root.existsSync()) return null;
  final qgis = root.listSync().whereType<Directory>().where((d) => p.basename(d.path).startsWith('QGIS ')).toList()
    ..sort((a, b) => _versionKey(p.basename(b.path)).compareTo(_versionKey(p.basename(a.path))));
  for (final q in qgis) {
    final bin = Directory(p.join(q.path, 'bin'));
    if (!bin.existsSync()) continue;
    final dll = bin
        .listSync()
        .whereType<File>()
        .where((f) => RegExp(r'^gdal\d+\.dll$', caseSensitive: false).hasMatch(p.basename(f.path)))
        .firstOrNull;
    if (dll == null) continue;
    final proj = p.join(q.path, 'share', 'proj');
    final gdalData = p.join(q.path, 'apps', 'gdal', 'share', 'gdal');
    return GdalFfiConfig(
      libraryPath: dll.path,
      dllSearchDir: bin.path,
      projDataDir: Directory(proj).existsSync() ? proj : null,
      gdalDataDir: Directory(gdalData).existsSync() ? gdalData : null,
    );
  }
  return null;
}

/// "QGIS 4.2.2" → 比べられる文字列（各桁を 4 桁に揃える）
String _versionKey(String name) =>
    RegExp(r'\d+').allMatches(name).map((m) => m.group(0)!.padLeft(4, '0')).join('.');
