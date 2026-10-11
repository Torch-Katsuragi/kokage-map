// こかげマップが読んだ行で使っていた鍵（id・fid・geometry）と同じ名前のふつうの列を持つ gpkg をテスト用に作る。
//
// 林業のデータには「id」（林小班の番号など）という列がよくある。主キーが fid の表や主キーの無い表で、
// 以前はその列が地物番号に上書きされて見えていた。
import 'package:latlong2/latlong.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 作る gpkg の形。表は [table]、点 2 つ（name は a・b）
enum CollidingColumnsGpkg {
  /// 主キーは fid（1・2）、ふつうの列 id（101・102）
  fidPkWithId('主キー fid + 列 id'),

  /// 主キー無し（rowid 1・2）、ふつうの列 id（101・102）と fid（201・202）
  noPkWithIdAndFid('主キー無し + 列 id・fid');

  const CollidingColumnsGpkg(this.label);

  final String label;

  static const table = 'stands';

  /// 地物番号（読み順）
  static const featureIds = [1, 2];

  /// 列 id の値（読み順）
  static const idValues = [101, 102];

  /// 列 fid の値（読み順）。主キーの無い表ではふつうの列
  List<int> get fidValues => this == fidPkWithId ? featureIds : const [201, 202];

  /// 主キー（無ければ rowid）
  String get primaryKey => this == fidPkWithId ? 'fid' : 'rowid';

  /// [path] に作る
  Future<void> write(String path) async {
    final gpkg = GeoPackageFile(const ['colliding.gpkg'], absolutePath: path);
    await gpkg.addLayer(table, GeometryType.point);
    await gpkg.addAttributeColumns(table, {'name': 'TEXT', 'id': 'INTEGER'});
    await gpkg.addPointWithAttributes(table, const LatLng(33.93, 135.96), {'name': 'a'});
    await gpkg.addPointWithAttributes(table, const LatLng(33.94, 135.97), {'name': 'b'});
    await gpkg.flushChanges();
    await gpkg.dispose();

    final db = await openDatabase(path, singleInstance: false);
    await db.execute('UPDATE $table SET id = fid + 100');
    if (this == noPkWithIdAndFid) {
      // GDAL は「no integer primary key」として rowid を FID にし、fid・id の列はふつうの属性にする
      await db.execute('CREATE TABLE tmp (geom POINT, name TEXT, id INTEGER, fid INTEGER)');
      await db.execute('INSERT INTO tmp SELECT geom, name, id, fid + 200 FROM $table ORDER BY fid');
      await db.execute('DROP TABLE $table');
      await db.execute('ALTER TABLE tmp RENAME TO $table');
    }
    await db.close();
  }
}

/// 形の列が geom で、geometry というふつうの文字の列（g-a・g-b）を持つ gpkg を [path] に作る。表は [CollidingColumnsGpkg.table]。
///
/// 以前は読んだ行の geometry に解いた形を入れていて、この列は属性表・情報パネルに出なかった
Future<void> writeGeometryAttributeGpkg(String path) async {
  const table = CollidingColumnsGpkg.table;
  final gpkg = GeoPackageFile(const ['colliding.gpkg'], absolutePath: path);
  await gpkg.addLayer(table, GeometryType.point);
  await gpkg.addAttributeColumns(table, {'name': 'TEXT', 'geometry': 'TEXT'});
  await gpkg.addPointWithAttributes(table, const LatLng(33.93, 135.96), {'name': 'a'});
  await gpkg.addPointWithAttributes(table, const LatLng(33.94, 135.97), {'name': 'b'});
  await gpkg.flushChanges();
  await gpkg.dispose();

  final db = await openDatabase(path, singleInstance: false);
  await db.execute("UPDATE $table SET geometry = 'g-' || name");
  await db.close();
}
