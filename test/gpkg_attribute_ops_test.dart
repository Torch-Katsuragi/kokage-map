// GeoPackage の属性まわりの一括操作（属性表の検索・置換・統計、列の追加・改名・削除）と、
// 主キーの無い外部の表の扱い
//
// 実物の GeoPackage を使う（gpkg_rename_test.dart と同じ作り）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;
  late GeoPackageFile gpkg;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('gpkg_attr_ops_');
    gpkg = GeoPackageFile(const ['t.gpkg'], absolutePath: '${tmp.path}/t.gpkg');
    await gpkg.addLayer('pts', GeometryType.point);
    await gpkg.addAttributeColumns('pts', {'name': 'TEXT', 'h': 'REAL', 'n': 'INTEGER'});
  });

  tearDown(() async {
    await gpkg.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<List<int>> addRows(List<Map<String, dynamic>> rows) async {
    final ids = <int>[];
    for (final (i, r) in rows.indexed) {
      ids.add((await gpkg.addPointWithAttributes('pts', LatLng(34 + i / 1000, 135), r))!);
    }
    await gpkg.flushChanges();
    return ids;
  }

  Future<Object?> value(int id, String col) => gpkg.getFeatureAttribute('pts', id, col);

  group('置換', () {
    test('一致する部分だけ置き換え、置き換えた行の数を返す', () async {
      final ids = await addRows([
        {'name': '1林班-い'},
        {'name': '2林班-ろ'},
        {'name': '沢'},
      ]);
      expect(await gpkg.replaceText('pts', 'name', '林班', 'りんぱん'), 2);
      expect(await value(ids[0], 'name'), '1りんぱん-い');
      expect(await value(ids[1], 'name'), '2りんぱん-ろ');
      expect(await value(ids[2], 'name'), '沢');
    });

    // LIKE は英字の大小を区別せず % と _ を文字として扱わないので、置き換わらない行まで数えていた（2026-10-12）
    test('英字の大小が違う行と、% や _ を含む語に似ているだけの行は数えない', () async {
      final ids = await addRows([
        {'name': 'abc'},
        {'name': 'ABC'},
        {'name': '50%off'},
        {'name': '5000'},
        {'name': 'a_b'},
        {'name': 'axb'},
      ]);
      expect(await gpkg.replaceText('pts', 'name', 'abc', 'x'), 1);
      expect(await value(ids[1], 'name'), 'ABC');
      expect(await gpkg.replaceText('pts', 'name', '50%', '60%'), 1);
      expect(await value(ids[2], 'name'), '60%off');
      expect(await value(ids[3], 'name'), '5000');
      expect(await gpkg.replaceText('pts', 'name', 'a_b', 'c'), 1);
      expect(await value(ids[5], 'name'), 'axb');
    });

    test('数値の列を置き換えても数値のまま', () async {
      final ids = await addRows([
        {'h': 12.5, 'n': 105},
      ]);
      expect(await gpkg.replaceText('pts', 'n', '05', '07'), 1);
      expect(await value(ids[0], 'n'), 107);
      expect(await gpkg.replaceText('pts', 'h', '.5', '.75'), 1);
      expect(await value(ids[0], 'h'), 12.75);
    });

    test('空の検索語は何もしない', () async {
      await addRows([
        {'name': 'a'},
      ]);
      expect(await gpkg.replaceText('pts', 'name', '', 'x'), 0);
    });
  });

  group('検索・統計', () {
    test('どれかの列に含む行の番号を返す', () async {
      final ids = await addRows([
        {'name': 'スギ', 'n': 12},
        {'name': 'ヒノキ', 'n': 3},
        {'name': 'スギ2', 'n': 120},
      ]);
      expect(await gpkg.searchText('pts', 'スギ', ['name']), [ids[0], ids[2]]);
      expect(await gpkg.searchText('pts', '12', ['name', 'n']), [ids[0], ids[2]]);
      expect(await gpkg.searchText('pts', '', ['name']), isEmpty);
    });

    test('統計: 数値だけ足し、空は数えない', () async {
      await addRows([
        {'h': 1.5},
        {'h': 2.5},
        {'h': null},
        {'h': 2.5},
      ]);
      final s = await gpkg.getColumnStatistics('pts', 'h');
      expect(s['count'], 3);
      expect(s['sum'], 6.5);
      expect(s['min'], 1.5);
      expect(s['max'], 2.5);
      expect(s['unique'], 2);
    });
  });

  group('列', () {
    test('改名・削除しても値と残りの列はそのまま', () async {
      final ids = await addRows([
        {'name': 'a', 'h': 1.0},
      ]);
      await gpkg.renameColumn('pts', 'name', '名前');
      expect(await gpkg.getTableColumns('pts'), containsAll(['名前', 'h']));
      expect(await value(ids[0], '名前'), 'a');
      await gpkg.dropColumn('pts', 'h');
      expect(await gpkg.getTableColumns('pts'), isNot(contains('h')));
      expect(await value(ids[0], '名前'), 'a');
    });

    test('列名の引用符・セミコロンは落とし、あれば足さない', () async {
      await gpkg.addAttributeColumns('pts', {'a"b;c': 'TEXT'});
      expect(await gpkg.getTableColumns('pts'), contains('ab_c'));
      await gpkg.addAttributeColumns('pts', {'name': 'TEXT'}); // 既にある
      final names = await gpkg.getTableColumns('pts');
      expect(names.where((c) => c == 'name'), hasLength(1));
    });

    test('属性の列の情報は形の列を含めない', () async {
      final info = await gpkg.getAttributeColumnInfo('pts');
      final names = [for (final c in info) c['name']];
      expect(names, containsAll(['fid', 'name', 'h', 'n']));
      expect(names, isNot(contains('geom')));
      expect(info.firstWhere((c) => c['name'] == 'fid')['primaryKey'], isTrue);
      expect(info.firstWhere((c) => c['name'] == 'h')['type'], 'REAL');
    });
  });

  group('主キー', () {
    Future<void> rawTable(String sql, [List<String> inserts = const []]) async {
      final db = await gpkg.getDatabase();
      await db.execute(sql);
      for (final s in inserts) {
        await db.execute(s);
      }
    }

    test('fid が主キーの表は fid', () async {
      expect(await gpkg.getPrimaryKeyColumn('pts'), 'fid');
    });

    test('旧形式の id 主キーはそのまま id', () async {
      await rawTable('CREATE TABLE old (id INTEGER PRIMARY KEY AUTOINCREMENT, geom BLOB, name TEXT)');
      expect(await gpkg.getPrimaryKeyColumn('old'), 'id');
    });

    // GDAL と同じく、主キーが無ければ fid・id という名前の列があっても rowid を地物番号にする
    test('主キーの無い表は fid・id 列があっても rowid', () async {
      await rawTable('CREATE TABLE f (fid INTEGER, geom BLOB)');
      await rawTable('CREATE TABLE i (id INTEGER, geom BLOB)');
      expect(await gpkg.getPrimaryKeyColumn('f'), 'rowid');
      expect(await gpkg.getPrimaryKeyColumn('i'), 'rowid');
    });

    // 以前は fid 列を足して行番号を写していた（開いただけでファイルが変わる。2026-10-12）
    test('主キーも fid も id も無い表は rowid を使い、列を足さない', () async {
      await rawTable('CREATE TABLE bare (geom BLOB, name TEXT)', [
        "INSERT INTO bare (name) VALUES ('a')",
        "INSERT INTO bare (name) VALUES ('b')",
      ]);
      expect(await gpkg.getPrimaryKeyColumn('bare'), 'rowid');
      expect(await gpkg.getTableColumns('bare'), ['geom', 'name']);
    });

    test('主キーの列は属性表の列から外せる', () async {
      final all = await gpkg.getColumnNames('pts', getAll: true);
      final noPk = await gpkg.getColumnNames('pts', getAll: true, skipPrimaryKey: true);
      expect(all, contains('fid'));
      expect(noPk, isNot(contains('fid')));
      expect(all, isNot(contains('geom')));
    });
  });
}
