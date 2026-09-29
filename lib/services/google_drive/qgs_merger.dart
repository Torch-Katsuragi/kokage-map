// Copyright (C) 2024-2026 Torch-Katsuragi
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program; if not, write to the Free Software Foundation, Inc.,
// 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
// こかげマップ: 両方の端末で変わった `<dir名>.qgs` を 3-way で合わせる
//
// 設計は [[docs/technical/project-format-design#正典を `.qgs` に移す（2026-09-06 決定・設計）]] の7条。
// `.qgs` のうちアプリの管轄はフォルダ設定（`kokage/meta` の JSON）で、QGIS が読む部分は
// そこから [QgsProjectBuilder] が書き直せる。なので合わせるのは設定の JSON だけにする。
//
// - JSON はキーごとに合わせる（可視性・スタイル・View は「レイヤ → 値」の辞書なので、
//   別々のレイヤを変えたなら両方残る）。片側だけが変えたらそちら、両側が同じ値ならそれ
// - 両側が同じキーを別の値にしたら、この端末の値を残して [QgsMergeResult.conflicts] に返す
//   （gpkg の行単位マージと同じ方針）。リストと値は丸ごと 1 つの値として扱う
// - リンク情報（`sync`）は端末ごとのものなので、この端末のものを残す
// - 入れ物（QGIS が保存した印刷レイアウト等）はこの端末のものを使う。QGIS が読む部分は、
//   合わせたあと自動更新が設定から書き直す
// - どちらかを最後に書いたのがこかげマップでない（QGIS で保存された）なら合わせない。
//   設定の JSON が QGIS 側の変更を反映していないので、キーごとに合わせても QGIS の変更が消える

import 'dart:convert';

import '../../utils/app_logger.dart';
import '../qgis/qgs_document.dart';
import '../qgis/qgs_meta_store.dart';

class QgsMergeResult {
  const QgsMergeResult(this.xml, this.conflicts);

  /// 合わせた `.qgs`
  final String xml;

  /// 両側が別の値にしたキー（`views/a.gpkg/trees` のような JSON 上の道筋）。この端末の値を残した
  final List<String> conflicts;
}

abstract final class QgsMerger {
  /// [base]（最後に同期した版）・[mine]（この端末）・[theirs]（Drive）を合わせる。
  /// 合わせられなければ null（呼び出し側は衝突のまま残す）。
  static Future<QgsMergeResult?> merge({
    required String base,
    required String mine,
    required String theirs,
  }) async {
    final QgsDocument docMine;
    final QgsDocument docTheirs;
    final QgsDocument docBase;
    try {
      docMine = QgsDocument.parse(mine);
      docTheirs = QgsDocument.parse(theirs);
      docBase = QgsDocument.parse(base);
    } on Object catch (e) {
      AppLogger.debug('[QgsMerger] XML として読めない: $e');
      return null;
    }
    if (!docMine.lastWrittenByKokage || !docTheirs.lastWrittenByKokage) {
      AppLogger.debug('[QgsMerger] QGIS で保存された側がある。設定の JSON では合わせない');
      return null;
    }
    final m = _json(docMine.kokageMeta);
    final t = _json(docTheirs.kokageMeta);
    if (m == null || t == null) return null;
    final b = _json(docBase.kokageMeta) ?? const <String, Object?>{};

    final conflicts = <String>[];
    final merged = merge3(b, m, t, '', conflicts) as Map<String, Object?>;
    // リンク情報はこの端末のもの
    if (m.containsKey('sync')) {
      merged['sync'] = m['sync'];
    } else {
      merged.remove('sync');
    }
    conflicts.removeWhere((c) => c == 'sync' || c.startsWith('sync/'));

    docMine.kokageMeta = jsonEncode(merged);
    final stamp = docMine.stamp!;
    docMine.setStamp(
      KokageStamp(
        schemaVersion: kQgsSchemaVersion,
        app: await QgsMetaStore.appLabel(),
        savedAt: DateTime.now(),
        dirName: stamp.dirName,
        savedBy: stamp.savedBy,
      ),
    );
    return QgsMergeResult(docMine.toXmlString(), conflicts);
  }

  static Map<String, Object?>? _json(String? text) {
    if (text == null) return null;
    try {
      final v = jsonDecode(text);
      return v is Map<String, Object?> ? v : null;
    } on Object {
      return null;
    }
  }

  /// JSON の 3-way マージ。[absent] はキーが無いこと（消した）を表す。
  static Object? merge3(Object? base, Object? mine, Object? theirs, String path, List<String> conflicts) {
    if (_eq(mine, theirs)) return mine;
    if (_eq(base, mine)) return theirs;
    if (_eq(base, theirs)) return mine;
    if (mine is Map && theirs is Map) {
      final b = base is Map ? base : const <String, Object?>{};
      final out = <String, Object?>{};
      for (final k in <Object?>{...mine.keys, ...theirs.keys}) {
        final key = k.toString();
        final v = merge3(
          b.containsKey(key) ? b[key] : absent,
          mine.containsKey(key) ? mine[key] : absent,
          theirs.containsKey(key) ? theirs[key] : absent,
          path.isEmpty ? key : '$path/$key',
          conflicts,
        );
        if (!identical(v, absent)) out[key] = v;
      }
      return out;
    }
    conflicts.add(path);
    return mine;
  }

  /// キーが無いことを表す印
  static const Object absent = _Absent();

  static bool _eq(Object? a, Object? b) {
    if (identical(a, b)) return true;
    if (identical(a, absent) || identical(b, absent)) return false;
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final k in a.keys) {
        if (!b.containsKey(k) || !_eq(a[k], b[k])) return false;
      }
      return true;
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_eq(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }
}

class _Absent {
  const _Absent();
}
