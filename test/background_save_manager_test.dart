// BackgroundSaveManagerとGeoPackageFileの統合テスト
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/providers/app_container.dart';
import 'package:root_maps/providers/project_providers.dart';
import 'package:root_maps/utils/background_save_manager.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';

void main() {
  group('BackgroundSaveManager Tests', () {
    late Directory tempDir;
    late GeoPackageFile geoPackageFile;
    late BackgroundSaveManager saveManager;

    setUpAll(() async {
      // ホストVM上のテストでは sqflite の実装が無いため FFI 版を差し込む
      // （main.dart のデスクトップ分岐と同じ初期化）
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;

      // テスト用の一時ディレクトリを作成
      tempDir = await Directory.systemTemp.createTemp('k_maps_test');
      // プロバイダーコンテナを初期化
      appContainer = ProviderContainer();
      appContainer.read(projectRootDirProvider.notifier).set(tempDir.path);

      saveManager = BackgroundSaveManager.instance;
    });

    setUp(() async {
      // 各テストで新しいGeoPackageFileを作成
      // projectRootDir はコンストラクタ引数で明示的に渡す（プロバイダ経由ではない）
      geoPackageFile = GeoPackageFile(
        ['test_file.gpkg'],
        projectRootDir: tempDir.path,
      );
      await geoPackageFile.createEmptyDatabase();

      // テスト用レイヤーを作成
      // addLayer は fid/geom のみ作る（QGIS互換の最小スキーマ）ので、
      // 属性カラムは明示的に足す。アプリ側も同じ手順を踏む。
      await geoPackageFile.addLayer('test_points', GeometryType.point);
      await geoPackageFile.addAttributeColumns('test_points', {
        'name': 'TEXT',
        'description': 'TEXT',
      });
    });

    tearDown(() async {
      // テスト後のクリーンアップ
      await geoPackageFile.dispose();
    });

    tearDownAll(() async {
      // テスト用ディレクトリを削除
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('シングルトンインスタンスの取得', () {
      final instance1 = BackgroundSaveManager.instance;
      final instance2 = BackgroundSaveManager();

      expect(instance1, equals(instance2));
      expect(identical(instance1, instance2), isTrue);
    });

    test('単一属性の遅延更新', () async {
      // 点フィーチャを追加
      const point = LatLng(35.6762, 139.6503);
      final pointId = await geoPackageFile.addPoint(
        'test_points',
        point,
        name: 'Test Point',
        description: 'Original description',
      );

      expect(pointId, isNotNull);

      // 属性更新をキューに追加
      geoPackageFile.queueAttributeUpdate(
        'test_points',
        pointId!,
        'description',
        'Updated description',
      );

      // 変更をフラッシュ
      await geoPackageFile.flushChanges();

      // 更新された属性を確認
      final updatedDescription = await geoPackageFile.getFeatureAttribute(
        'test_points',
        pointId,
        'description',
      );

      expect(updatedDescription, equals('Updated description'));
    });

    test('複数属性の一括遅延更新', () async {
      // 点フィーチャを追加
      const point = LatLng(35.6762, 139.6503);
      final pointId = await geoPackageFile.addPoint(
        'test_points',
        point,
        name: 'Test Point',
        description: 'Original description',
      );

      expect(pointId, isNotNull);

      // 複数属性の更新をキューに追加
      geoPackageFile.queueAttributeUpdates('test_points', pointId!, {
        'name': 'Updated Point',
        'description': 'Updated description',
      });

      // 変更をフラッシュ
      await geoPackageFile.flushChanges();

      // 更新された属性を確認
      final attributes = await geoPackageFile.getFeatureAttributes(
        'test_points',
        pointId,
      );

      expect(attributes?['name'], equals('Updated Point'));
      expect(attributes?['description'], equals('Updated description'));
    });

    test('複数のGeoPackageFileの同時管理', () async {
      // 2つ目のGeoPackageFileを作成
      final geoPackageFile2 = GeoPackageFile(
        ['test_file2.gpkg'],
        projectRootDir: tempDir.path,
      );
      await geoPackageFile2.createEmptyDatabase();
      await geoPackageFile2.addLayer('test_points2', GeometryType.point);
      await geoPackageFile2.addAttributeColumns('test_points2', {
        'name': 'TEXT',
        'description': 'TEXT',
      });

      try {
        // 両方のファイルに点を追加
        const point1 = LatLng(35.6762, 139.6503);
        const point2 = LatLng(35.6586, 139.7454);

        final pointId1 = await geoPackageFile.addPoint(
          'test_points',
          point1,
          name: 'Point 1',
        );

        final pointId2 = await geoPackageFile2.addPoint(
          'test_points2',
          point2,
          name: 'Point 2',
        );

        expect(pointId1, isNotNull);
        expect(pointId2, isNotNull);

        // 両方のファイルの属性を同時に更新
        geoPackageFile.queueAttributeUpdate(
          'test_points',
          pointId1!,
          'description',
          'Updated from file 1',
        );

        geoPackageFile2.queueAttributeUpdate(
          'test_points2',
          pointId2!,
          'description',
          'Updated from file 2',
        );

        // 全ての変更をフラッシュ
        await saveManager.flushAllChanges();

        // 両方のファイルの更新を確認
        final desc1 = await geoPackageFile.getFeatureAttribute(
          'test_points',
          pointId1,
          'description',
        );

        final desc2 = await geoPackageFile2.getFeatureAttribute(
          'test_points2',
          pointId2,
          'description',
        );

        expect(desc1, equals('Updated from file 1'));
        expect(desc2, equals('Updated from file 2'));
      } finally {
        await geoPackageFile2.dispose();
      }
    });

    test('pending changesの状態確認', () async {
      // 点フィーチャを追加
      const point = LatLng(35.6762, 139.6503);
      final pointId = await geoPackageFile.addPoint(
        'test_points',
        point,
        name: 'Test Point',
      );

      expect(pointId, isNotNull);

      // 属性更新をキューに追加（フラッシュしない）
      geoPackageFile.queueAttributeUpdate(
        'test_points',
        pointId!,
        'description',
        'Pending update',
      );

      // pending changesの状態を確認
      final status = saveManager.getPendingChangesStatus();
      expect(status[geoPackageFile], equals(1));

      // フラッシュ後はpending changesがクリアされる
      await geoPackageFile.flushChanges();

      final statusAfterFlush = saveManager.getPendingChangesStatus();
      expect(statusAfterFlush[geoPackageFile] ?? 0, equals(0));
    });

    test('GeoPackageFileのdispose処理', () async {
      // 点フィーチャを追加
      const point = LatLng(35.6762, 139.6503);
      final pointId = await geoPackageFile.addPoint(
        'test_points',
        point,
        name: 'Test Point',
      );

      expect(pointId, isNotNull);

      // 属性更新をキューに追加
      geoPackageFile.queueAttributeUpdate(
        'test_points',
        pointId!,
        'description',
        'Pending update',
      );

      // disposeでpending changesがクリアされることを確認
      await geoPackageFile.dispose();

      final status = saveManager.getPendingChangesStatus();
      expect(status.containsKey(geoPackageFile), isFalse);
    });
  });
}
