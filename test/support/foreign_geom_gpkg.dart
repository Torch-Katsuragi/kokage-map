// 形の列が geom 以外の gpkg（ほかのソフトが書いたもの）をテスト用に作る。
//
// - GeoPandas / Fiona: 形の列は geometry、主キーは fid
// - ArcGIS Pro: 形の列は Shape（大文字を含む）、主キーは OBJECTID
//
// GDAL と同じく rtree（rtree_<表>_<形の列>）・gpkg_extensions・ST_ 関数のトリガーを持たせる
import 'package:root_maps/utils/wkb_utils.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 作る gpkg の形
class ForeignGeomGpkg {
  const ForeignGeomGpkg(this.label, {required this.table, required this.geomColumn, required this.pk, this.extraColumns = const {}});

  final String label;
  final String table;
  final String geomColumn;
  final String pk;

  /// 形・主キー・name のほかの列（列名 → 型）。値は [rows] に書く
  final Map<String, String> extraColumns;

  String get rtree => 'rtree_${table}_$geomColumn';

  /// 最初から入っている地物（経度・緯度・name・[extraColumns] の値）
  static const rows = [
    (lon: 135.96, lat: 33.93, name: 'a'),
    (lon: 135.97, lat: 33.94, name: 'b'),
  ];

  /// GeoPandas（to_file の既定）。geom という名前のふつうの属性の列も持たせる
  static const geopandas = ForeignGeomGpkg(
    'GeoPandas（geometry）',
    table: 'parcels',
    geomColumn: 'geometry',
    pk: 'fid',
    extraColumns: {'geom': 'TEXT'},
  );

  /// ArcGIS Pro
  static const arcgis = ForeignGeomGpkg('ArcGIS Pro（Shape）', table: 'Stands', geomColumn: 'Shape', pk: 'OBJECTID');

  static const all = [geopandas, arcgis];

  /// [path] に作る（点 2 つ、rtree つき）
  Future<void> write(String path) async {
    final db = await openDatabase(path, singleInstance: false);
    await db.execute('PRAGMA application_id = 0x47504B47');
    await db.execute('PRAGMA user_version = 10400');
    await db.execute('''CREATE TABLE gpkg_spatial_ref_sys (srs_name TEXT NOT NULL, srs_id INTEGER PRIMARY KEY,
      organization TEXT NOT NULL, organization_coordsys_id INTEGER NOT NULL, definition TEXT NOT NULL, description TEXT)''');
    await db.execute(
      "INSERT INTO gpkg_spatial_ref_sys VALUES ('WGS 84', 4326, 'EPSG', 4326, "
      "'GEOGCS[\"WGS 84\",DATUM[\"WGS_1984\",SPHEROID[\"WGS 84\",6378137,298.257223563]],PRIMEM[\"Greenwich\",0],UNIT[\"degree\",0.0174532925199433]]', NULL)",
    );
    await db.execute("INSERT INTO gpkg_spatial_ref_sys VALUES ('Undefined cartesian SRS', -1, 'NONE', -1, 'undefined', NULL)");
    await db.execute("INSERT INTO gpkg_spatial_ref_sys VALUES ('Undefined geographic SRS', 0, 'NONE', 0, 'undefined', NULL)");
    await db.execute('''CREATE TABLE gpkg_contents (table_name TEXT NOT NULL PRIMARY KEY, data_type TEXT NOT NULL,
      identifier TEXT UNIQUE, description TEXT DEFAULT '', last_change DATETIME NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      min_x DOUBLE, min_y DOUBLE, max_x DOUBLE, max_y DOUBLE, srs_id INTEGER)''');
    await db.execute('''CREATE TABLE gpkg_geometry_columns (table_name TEXT NOT NULL, column_name TEXT NOT NULL,
      geometry_type_name TEXT NOT NULL, srs_id INTEGER NOT NULL, z TINYINT NOT NULL, m TINYINT NOT NULL,
      CONSTRAINT pk_geom_cols PRIMARY KEY (table_name, column_name))''');
    await db.execute('''CREATE TABLE gpkg_extensions (table_name TEXT, column_name TEXT, extension_name TEXT NOT NULL,
      definition TEXT NOT NULL, scope TEXT NOT NULL)''');

    final extra = [for (final MapEntry(:key, :value) in extraColumns.entries) ', "$key" $value'].join();
    await db.execute(
      'CREATE TABLE "$table" ("$pk" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, "$geomColumn" POINT, name TEXT$extra)',
    );
    await db.execute(
      'INSERT INTO gpkg_contents (table_name, data_type, identifier, min_x, min_y, max_x, max_y, srs_id) '
      "VALUES ('$table', 'features', '$table', 135.96, 33.93, 135.97, 33.94, 4326)",
    );
    await db.execute("INSERT INTO gpkg_geometry_columns VALUES ('$table', '$geomColumn', 'POINT', 4326, 0, 0)");
    await db.execute(
      "INSERT INTO gpkg_extensions VALUES ('$table', '$geomColumn', 'gpkg_rtree_index', "
      "'http://www.geopackage.org/spec120/#extension_rtree', 'write-only')",
    );
    await db.execute('CREATE VIRTUAL TABLE "$rtree" USING rtree(id, minx, maxx, miny, maxy)');
    for (final r in rows) {
      final id = await db.rawInsert(
        'INSERT INTO "$table" ("$geomColumn", name${extraColumns.keys.map((c) => ', "$c"').join()}) '
        'VALUES (?, ?${', ?' * extraColumns.length})',
        [createWkbPoint(r.lon, r.lat), r.name, for (final c in extraColumns.keys) '$c-${r.name}'],
      );
      await db.execute('INSERT INTO "$rtree" VALUES (?, ?, ?, ?, ?)', [id, r.lon, r.lon, r.lat, r.lat]);
    }
    // GDAL のトリガー（抜粋）。sqflite には ST_ 関数が無いので行を入れたあとに作る（こかげマップは書き込み前に落とす）
    await db.execute('''CREATE TRIGGER "${rtree}_insert" AFTER INSERT ON "$table"
      WHEN (new."$geomColumn" NOT NULL AND NOT ST_IsEmpty(NEW."$geomColumn"))
      BEGIN INSERT OR REPLACE INTO "$rtree" VALUES (NEW."$pk",
        ST_MinX(NEW."$geomColumn"), ST_MaxX(NEW."$geomColumn"), ST_MinY(NEW."$geomColumn"), ST_MaxY(NEW."$geomColumn")); END''');
    await db.execute('''CREATE TRIGGER "${rtree}_delete" AFTER DELETE ON "$table"
      WHEN old."$geomColumn" NOT NULL
      BEGIN DELETE FROM "$rtree" WHERE id = OLD."$pk"; END''');

    await db.close();
  }
}
