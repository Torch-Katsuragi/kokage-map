// 行単位マージの衝突を、あとから相手（クラウド）の値に戻す。
//
// 同期は止めずに「後から合わせた側が勝つ」で自動で解き、通知から 1 回の操作で取り消せるようにする
// （2026-09-24 に採用。docs/technical/drive-geodiff-sync.md「衝突の UI」）。
// 戻せるのは同じ列の値の衝突だけ（ジオメトリを含む）。削除がらみは行全体が要るので戻さない。
// 戻した値はローカルの変更になり、次の同期でクラウドにも上がる。
import 'dart:convert';
import 'dart:typed_data';

import '../../models/geopackage/geopackage_file.dart';
import '../../utils/app_logger.dart';
import 'gpkg_merger.dart';

abstract final class ConflictRestorer {
  /// [conflicts] のうち戻せるものを相手の値に戻す。戻した数を返す。
  static Future<int> restoreTheirs(List<GpkgConflict> conflicts) async {
    final byFile = <String, List<GpkgConflict>>{};
    for (final c in conflicts.where((c) => c.restorable)) {
      (byFile[c.filePath!] ??= []).add(c);
    }
    var restored = 0;
    for (final entry in byFile.entries) {
      final gpkg = GeoPackageFile(const ['restore.gpkg'], absolutePath: entry.key);
      try {
        final db = await gpkg.getDatabase();
        final infoCache = <String, List<Map<String, Object?>>>{};
        for (final c in entry.value) {
          final info = infoCache[c.table] ??= await db.rawQuery('PRAGMA table_info("${c.table.replaceAll('"', '""')}")');
          final col = info.where((r) => r['cid'] == c.column).firstOrNull;
          final pk = info.where((r) => (r['pk'] as int? ?? 0) > 0).firstOrNull;
          if (col == null || pk == null) continue;
          final value = _decode(c.theirs, (col['type'] as String?) ?? '');
          final ok = await gpkg.setColumnValue(
            c.table,
            pk['name']! as String,
            int.tryParse(c.fid) ?? c.fid,
            col['name']! as String,
            value,
          );
          if (ok) restored++;
        }
      } catch (e) {
        AppLogger.debug('[ConflictRestorer] ${entry.key} を戻せなかった: $e');
        rethrow;
      } finally {
        await gpkg.dispose(); // トリガーを戻し、rtree と範囲を焼き直す
      }
    }
    return restored;
  }

  static const _blobTypes = {
    'BLOB', 'GEOMETRY', 'POINT', 'LINESTRING', 'POLYGON', 'MULTIPOINT', 'MULTILINESTRING', 'MULTIPOLYGON',
    'GEOMETRYCOLLECTION', 'CIRCULARSTRING', 'COMPOUNDCURVE', 'CURVEPOLYGON', 'MULTICURVE', 'MULTISURFACE', 'CURVE', 'SURFACE',
  };

  /// geodiff の JSON では blob は base64 の文字列になっている
  static Object? _decode(Object? v, String declaredType) {
    if (v is String && _blobTypes.contains(declaredType.toUpperCase())) {
      try {
        return Uint8List.fromList(base64Decode(v));
      } catch (_) {
        return v;
      }
    }
    return v;
  }
}
