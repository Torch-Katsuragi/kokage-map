// 利用者の背景地図（任意の XYZ / WMS の URL。2026-10-11）
//
// 設定画面の「URL から背景地図を追加」と `.qgs` の読み戻しの両方から入る。定義は端末の prefs
// （`basemap_custom_providers`）に持ち、id は URL から決まる（同じ URL は 1 つ）。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/models/basemap_layer.dart';
import 'package:root_maps/models/basemap_provider.dart';
import 'package:root_maps/services/basemap_service.dart';
import 'package:root_maps/services/qgis/qgs_base_map_import.dart';
import 'package:root_maps/services/qgis/qgs_raster_source.dart';
import 'package:shared_preferences/shared_preferences.dart';

BaseMapProvider _forest() => BaseMapProvider.custom(
      name: '森林計画対象森林',
      urlTemplate: 'https://forest.example.go.jp/xyz/{z}/{x}/{y}.png',
      minZoom: 8,
      maxZoom: 17,
      attribution: '林野庁',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    BaseMapProvider.customProviders = const [];
    SharedPreferences.setMockInitialValues({});
  });

  group('URL テンプレート', () {
    test('{z}/{x}/{y} を埋める', () {
      expect(BaseMapProvider.expandTileUrl('https://a.example/{z}/{x}/{y}.png', 3, 5, 2), 'https://a.example/3/5/2.png');
    });

    test('TMS: {-y} は南から数える。tms の印があれば {y} も', () {
      // z3 は 8 行。北から 2 行目 → 南から 5
      expect(BaseMapProvider.expandTileUrl('https://a.example/{z}/{x}/{-y}.png', 3, 5, 2), 'https://a.example/3/5/5.png');
      expect(BaseMapProvider.expandTileUrl('https://a.example/{z}/{x}/{y}.png', 3, 5, 2, tms: true), 'https://a.example/3/5/5.png');
      final p = BaseMapProvider.custom(name: 't', urlTemplate: 'https://a.example/{z}/{x}/{y}.png', tms: true);
      expect(p.tileUrl(0, 0, 0), 'https://a.example/0/0/0.png');
      expect(p.tileUrl(1, 0, 0), 'https://a.example/1/0/1.png');
    });

    test('{bbox-epsg-3857}: タイルの範囲（Web メルカトルの m）', () {
      final url = BaseMapProvider.expandTileUrl('https://w.example/wms?BBOX={bbox-epsg-3857}', 1, 1, 0);
      expect(url, 'https://w.example/wms?BBOX=0.000,0.000,20037508.343,20037508.343');
      final z0 = BaseMapProvider.expandTileUrl('{bbox-epsg-3857}', 0, 0, 0);
      expect(z0, '-20037508.343,-20037508.343,20037508.343,20037508.343');
    });

    test('使える URL か・規約で使えないタイルか', () {
      expect(BaseMapProvider.isValidTemplate('https://a.example/{z}/{x}/{y}.png'), isTrue);
      expect(BaseMapProvider.isValidTemplate('https://a.example/{z}/{x}/{-y}.png'), isTrue);
      expect(BaseMapProvider.isValidTemplate('https://w.example/wms?BBOX={bbox-epsg-3857}'), isTrue);
      expect(BaseMapProvider.isValidTemplate('https://a.example/{z}/{x}.png'), isFalse);
      expect(BaseMapProvider.isValidTemplate('ftp://a.example/{z}/{x}/{y}.png'), isFalse);
      expect(BaseMapProvider.isForbiddenTileHost('https://mt1.google.com/vt/lyrs=s&x={x}&y={y}&z={z}'), isTrue);
      expect(BaseMapProvider.isForbiddenTileHost('https://ecn.t3.tiles.virtualearth.net/tiles/a{q}.jpeg'), isTrue);
      expect(BaseMapProvider.isForbiddenTileHost('https://cyberjapandata.gsi.go.jp/xyz/std/{z}/{x}/{y}.png'), isFalse);
      expect(BaseMapProvider.isForbiddenTileHost('https://notgoogle.example/{z}/{x}/{y}.png'), isFalse);
    });
  });

  group('定義と prefs', () {
    test('id は URL から（http/https・ホストの大小を無視）。FNV-1a そのもの（web と同じ値）', () {
      final a = BaseMapProvider.customIdFor('https://tiles.example.com/v1/{z}/{x}/{y}.png');
      expect(a, 'custom_ef5a973c');
      expect(BaseMapProvider.customIdFor('http://Tiles.Example.com/v1/{z}/{x}/{y}.png'), a);
      expect(BaseMapProvider.customIdFor('https://tiles.example.com/v1/{z}/{x}/{y}.png', tms: true), isNot(a));
    });

    test('JSON の往復', () {
      final p = _forest();
      final back = BaseMapProvider.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, Object?>)!;
      expect(back.id, p.id);
      expect(back.name, '森林計画対象森林');
      expect(back.urlTemplate, p.urlTemplate);
      expect((back.minZoom, back.maxZoom), (8, 17));
      expect(back.attribution, '林野庁');
      expect(back.isCustom, isTrue);
      expect(back.cacheId, p.id, reason: 'タイルキャッシュは自分の id で持つ');
      expect(BaseMapProvider.fromJson(const {'url': 'not a url'}), isNull);
    });

    test('足すと prefs に書かれ、読み直せる。同じ URL は足さずに既存を返す', () async {
      final svc = BaseMapService();
      final added = await svc.addCustomProvider(_forest());
      expect(BaseMapProvider.getProviderById(added.id), same(added));
      expect(BaseMapProvider.findByTileUrl('http://forest.example.go.jp/xyz/{z}/{x}/{y}.png'), same(added));

      final again = await svc.addCustomProvider(BaseMapProvider.custom(
        name: '別の名前',
        urlTemplate: 'https://FOREST.example.go.jp/xyz/{z}/{x}/{y}.png',
      ));
      expect(again, same(added));
      expect(BaseMapProvider.customProviders, hasLength(1));

      // 組み込みと同じ URL は組み込みのほう
      final gsi = await svc.addCustomProvider(
        BaseMapProvider.custom(name: 'x', urlTemplate: 'https://cyberjapandata.gsi.go.jp/xyz/std/{z}/{x}/{y}.png'),
      );
      expect(gsi.id, 'gsi_std');

      final prefs = await SharedPreferences.getInstance();
      final decoded = BaseMapService.decodeCustomProviders(prefs.getString(BaseMapService.customProvidersPrefsKey));
      expect(decoded.map((p) => p.id), [added.id]);
      expect(decoded.single.attribution, '林野庁');

      // レイヤとしても読み戻せる（定義が先に入っていれば）
      final layer = BaseMapLayer.fromJson(BaseMapLayer(providerId: added.id, opacity: 40).toJson());
      expect(layer?.provider?.name, '森林計画対象森林');

      await svc.removeCustomProvider(added.id);
      expect(BaseMapProvider.getProviderById(added.id), isNull);
      expect(BaseMapService.decodeCustomProviders(prefs.getString(BaseMapService.customProvidersPrefsKey)), isEmpty);
    });

    test('壊れた prefs は空として読む', () {
      expect(BaseMapService.decodeCustomProviders('{oops'), isEmpty);
      expect(BaseMapService.decodeCustomProviders(null), isEmpty);
    });
  });

  group('.qgs からの読み戻し（一覧に無い URL）', () {
    final custom = _forest();
    final incoming = QgsBaseMap(providerId: custom.id, layerName: '森林', visible: true, opacity: 70, custom: custom);
    const current = [BaseMapLayer(providerId: 'gsi_std')];

    test('利用者の地図として上に足す', () {
      final r = QgsBaseMapImport.merge(current, [incoming], const {});
      expect(r.added, [custom.id]);
      expect(r.layers.last, BaseMapLayer(providerId: custom.id, opacity: 70));
    });

    test('同じ URL が何枚あっても 1 枚。一度足したものは消されていても戻さない', () {
      expect(QgsBaseMapImport.merge(current, [incoming, incoming], const {}).added, hasLength(1));
      final r = QgsBaseMapImport.merge(current, [incoming], {custom.id});
      expect(r.added, isEmpty);
      expect(r.layers, current);
    });

    test('apply: 定義を端末に入れて足し、2 回目は足さない', () async {
      final svc = BaseMapService();
      await svc.setLayers(current);
      final names = await QgsBaseMapImport.apply([incoming], service: svc);
      expect(names, ['森林計画対象森林']);
      expect(svc.layers.map((l) => l.providerId), ['gsi_std', custom.id]);
      expect(BaseMapProvider.customProviders.map((p) => p.id), [custom.id]);

      await svc.removeCustomProvider(custom.id);
      expect(await QgsBaseMapImport.apply([incoming], service: svc), isEmpty, reason: '消したものは戻さない');
      expect(BaseMapProvider.customProviders, isEmpty);
    });

    test('WMS の URI を GetMap のテンプレートに。WMTS・layers 無しは null', () {
      final t = QgsRasterSource.wmsGetMapTemplate(
        'contextualWMSLegend=0&crs=EPSG:6674&dpiMode=7&format=image/jpeg&layers=a&layers=b%20c&styles=&styles=&url=https://w.example/ows?map=x',
      )!;
      expect(
        t,
        'https://w.example/ows?map=x&SERVICE=WMS&VERSION=1.3.0&REQUEST=GetMap&LAYERS=a,b+c&STYLES=,'
        '&FORMAT=image%2Fjpeg&TRANSPARENT=TRUE&CRS=EPSG:3857&WIDTH=256&HEIGHT=256&BBOX={bbox-epsg-3857}',
      );
      expect(BaseMapProvider.isValidTemplate(t), isTrue);
      expect(QgsRasterSource.wmsGetMapTemplate('crs=EPSG:3857&format=image/png&layers=a&styles=&tileMatrixSet=g&url=https://w.example/wmts'), isNull);
      expect(QgsRasterSource.wmsGetMapTemplate('crs=EPSG:3857&format=image/png&styles=&url=https://w.example/wms'), isNull);
    });
  });
}
