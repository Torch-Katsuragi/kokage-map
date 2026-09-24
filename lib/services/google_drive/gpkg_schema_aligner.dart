// geodiff の rebase の前に、片側だけが足した列を残り 2 つにも足してスキーマをそろえる。
//
// geodiff はスキーマが変わった変更集合を作れない（`GeoPackage Table schemas are not the same`）。
// 現場で属性の列を足すのはよくあるので、**片側だけが末尾に列を足した**場合に限り、
// base・相手・こちらの 3 つに同じ列を ALTER TABLE ADD COLUMN で足してから rebase する。
// それ以外（両側が別々の列を足した、列を消した・変えた、テーブルの増減）は触らず、今までどおり衝突に退く。
//
// 呼ぶ前にアプリの接続を閉じておくこと（3 つとも、この中で sqflite で開いて閉じる）。
import 'package:sqflite/sqflite.dart';

import '../../utils/app_logger.dart';

class _Col {
  const _Col(this.name, this.type, this.notNull, this.dflt, this.pk);
  final String name;
  final String type;
  final bool notNull;
  final Object? dflt;
  final int pk;

  bool sameAs(_Col o) => name == o.name && type.toUpperCase() == o.type.toUpperCase() && notNull == o.notNull && '$dflt' == '${o.dflt}' && pk == o.pk;

  String addColumnSql(String table) {
    final b = StringBuffer('ALTER TABLE "${table.replaceAll('"', '""')}" ADD COLUMN "${name.replaceAll('"', '""')}"');
    if (type.isNotEmpty) b.write(' $type');
    if (dflt != null) b.write(' DEFAULT $dflt');
    if (notNull) b.write(' NOT NULL');
    return b.toString();
  }
}

class SchemaAlignResult {
  const SchemaAlignResult(this.added);

  /// 足した列（`<テーブル>.<列>`）。空ならそろえる必要が無かった／そろえられなかった
  final List<String> added;
}

abstract final class GpkgSchemaAligner {
  /// [base]・[theirs]・[mine] のスキーマをそろえる（片側だけの列の追加に限る）。足した列を返す。
  static Future<SchemaAlignResult> align({
    required String base,
    required String theirs,
    required String mine,
  }) async {
    final added = <String>[];
    try {
      final sb = await _schema(base);
      final st = await _schema(theirs);
      final sm = await _schema(mine);
      for (final table in sb.keys) {
        final b = sb[table]!;
        final t = st[table];
        final m = sm[table];
        if (t == null || m == null) continue; // テーブルの増減はそろえない
        final tAdd = _appendedTo(b, t);
        final mAdd = _appendedTo(b, m);
        if (tAdd == null || mAdd == null) continue; // 追加以外の変更がある
        if (tAdd.isEmpty && mAdd.isEmpty) continue;
        if (tAdd.isNotEmpty && mAdd.isNotEmpty && !_sameList(tAdd, mAdd)) {
          AppLogger.debug('[SchemaAligner] $table: 両側が別々の列を足している。そろえない');
          continue;
        }
        final cols = tAdd.isNotEmpty ? tAdd : mAdd;
        if (cols.any((c) => c.notNull && c.dflt == null)) {
          AppLogger.debug('[SchemaAligner] $table: 既定値の無い NOT NULL 列は後から足せない。そろえない');
          continue;
        }
        // 足りない側に足す（相手が足した → base とこちら、こちらが足した → base と相手、両方同じ → base だけ）
        final targets = <String>[
          base,
          if (tAdd.isNotEmpty && mAdd.isEmpty) mine,
          if (mAdd.isNotEmpty && tAdd.isEmpty) theirs,
        ];
        for (final path in targets) {
          final db = await openDatabase(path, singleInstance: false);
          try {
            for (final c in cols) {
              await db.execute(c.addColumnSql(table));
            }
          } finally {
            await db.close();
          }
        }
        added.addAll(cols.map((c) => '$table.${c.name}'));
      }
    } catch (e) {
      AppLogger.debug('[SchemaAligner] そろえられなかった: $e');
    }
    if (added.isNotEmpty) AppLogger.debug('[SchemaAligner] 列をそろえた: $added');
    return SchemaAlignResult(added);
  }

  /// [after] が [before] の末尾に列を足しただけなら、足した列（無ければ空）。それ以外の変更があれば null
  static List<_Col>? _appendedTo(List<_Col> before, List<_Col> after) {
    if (after.length < before.length) return null;
    for (var i = 0; i < before.length; i++) {
      if (!before[i].sameAs(after[i])) return null;
    }
    return after.sublist(before.length);
  }

  static bool _sameList(List<_Col> a, List<_Col> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!a[i].sameAs(b[i])) return false;
    }
    return true;
  }

  /// 地物テーブル（gpkg_contents に載っているもの）の列
  static Future<Map<String, List<_Col>>> _schema(String path) async {
    final db = await openDatabase(path, readOnly: true, singleInstance: false);
    try {
      final out = <String, List<_Col>>{};
      final tables = await db.rawQuery("SELECT table_name FROM gpkg_contents WHERE data_type IN ('features', 'attributes')");
      for (final r in tables) {
        final t = r['table_name'] as String;
        final info = await db.rawQuery('PRAGMA table_info("${t.replaceAll('"', '""')}")');
        out[t] = [
          for (final c in info)
            _Col(c['name']! as String, (c['type'] as String?) ?? '', (c['notnull'] as int? ?? 0) == 1, c['dflt_value'], c['pk'] as int? ?? 0),
        ];
      }
      return out;
    } finally {
      await db.close();
    }
  }
}
