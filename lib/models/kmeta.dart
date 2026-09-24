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
// Root Maps: フォルダメタデータモデル
// 各フォルダに配置される.kmeta.jsonの読み書き・継承マージを担当

import 'dart:convert';
import 'package:flutter/material.dart';
import '../core/fs/k_file_system.dart';
import '../utils/app_logger.dart';

/// .kmeta.jsonファイル名
const String kMetaFileName = '.kmeta.json';

/// 現在のスキーマバージョン
const int kMetaSchemaVersion = 2;

/// レイヤースタイル設定（個別レイヤー用）
class KMetaLayerStyle {
  final double? pointSize;
  final Color? pointColor;
  final double? lineWidth;
  final Color? lineColor;
  final double? polygonBorderWidth;
  final Color? polygonBorderColor;
  final Color? polygonFillColor;
  final double? polygonFillOpacity;
  final double? polygonBorderOpacity;
  final bool? labelEnabled;
  final String? labelProperty;
  final double? labelFontSize;
  final Color? labelColor;
  final Color? labelHaloColor;
  final double? labelOpacity;

  const KMetaLayerStyle({
    this.pointSize,
    this.pointColor,
    this.lineWidth,
    this.lineColor,
    this.polygonBorderWidth,
    this.polygonBorderColor,
    this.polygonFillColor,
    this.polygonFillOpacity,
    this.polygonBorderOpacity,
    this.labelEnabled,
    this.labelProperty,
    this.labelFontSize,
    this.labelColor,
    this.labelHaloColor,
    this.labelOpacity,
  });

  KMetaLayerStyle copyWith({
    double? pointSize,
    Color? pointColor,
    double? lineWidth,
    Color? lineColor,
    double? polygonBorderWidth,
    Color? polygonBorderColor,
    Color? polygonFillColor,
    double? polygonFillOpacity,
    double? polygonBorderOpacity,
    bool? labelEnabled,
    String? labelProperty,
    double? labelFontSize,
    Color? labelColor,
    Color? labelHaloColor,
    double? labelOpacity,
  }) =>
      KMetaLayerStyle(
        pointSize: pointSize ?? this.pointSize,
        pointColor: pointColor ?? this.pointColor,
        lineWidth: lineWidth ?? this.lineWidth,
        lineColor: lineColor ?? this.lineColor,
        polygonBorderWidth: polygonBorderWidth ?? this.polygonBorderWidth,
        polygonBorderColor: polygonBorderColor ?? this.polygonBorderColor,
        polygonFillColor: polygonFillColor ?? this.polygonFillColor,
        polygonFillOpacity: polygonFillOpacity ?? this.polygonFillOpacity,
        polygonBorderOpacity: polygonBorderOpacity ?? this.polygonBorderOpacity,
        labelEnabled: labelEnabled ?? this.labelEnabled,
        labelProperty: labelProperty ?? this.labelProperty,
        labelFontSize: labelFontSize ?? this.labelFontSize,
        labelColor: labelColor ?? this.labelColor,
        labelHaloColor: labelHaloColor ?? this.labelHaloColor,
        labelOpacity: labelOpacity ?? this.labelOpacity,
      );

  /// JSONからパース
  factory KMetaLayerStyle.fromJson(Map<String, dynamic> json) {
    return KMetaLayerStyle(
      pointSize: (json['pointSize'] as num?)?.toDouble(),
      pointColor: _parseColor(json['pointColor']),
      lineWidth: (json['lineWidth'] as num?)?.toDouble(),
      lineColor: _parseColor(json['lineColor']),
      polygonBorderWidth: (json['polygonBorderWidth'] as num?)?.toDouble(),
      polygonBorderColor: _parseColor(json['polygonBorderColor']),
      polygonFillColor: _parseColor(json['polygonFillColor']),
      polygonFillOpacity: (json['polygonFillOpacity'] as num?)?.toDouble(),
      polygonBorderOpacity: (json['polygonBorderOpacity'] as num?)?.toDouble(),
      labelEnabled: json['labelEnabled'] as bool?,
      labelProperty: json['labelProperty'] as String?,
      labelFontSize: (json['labelFontSize'] as num?)?.toDouble(),
      labelColor: _parseColor(json['labelColor']),
      labelHaloColor: _parseColor(json['labelHaloColor']),
      labelOpacity: (json['labelOpacity'] as num?)?.toDouble(),
    );
  }

  /// JSONへシリアライズ
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};
    if (pointSize != null) json['pointSize'] = pointSize;
    if (pointColor != null) json['pointColor'] = _colorToHex(pointColor!);
    if (lineWidth != null) json['lineWidth'] = lineWidth;
    if (lineColor != null) json['lineColor'] = _colorToHex(lineColor!);
    if (polygonBorderWidth != null) {
      json['polygonBorderWidth'] = polygonBorderWidth;
    }
    if (polygonBorderColor != null) {
      json['polygonBorderColor'] = _colorToHex(polygonBorderColor!);
    }
    if (polygonFillColor != null) {
      json['polygonFillColor'] = _colorToHex(polygonFillColor!);
    }
    if (polygonFillOpacity != null) {
      json['polygonFillOpacity'] = polygonFillOpacity;
    }
    if (polygonBorderOpacity != null) {
      json['polygonBorderOpacity'] = polygonBorderOpacity;
    }
    if (labelEnabled != null) json['labelEnabled'] = labelEnabled;
    if (labelProperty != null) json['labelProperty'] = labelProperty;
    if (labelFontSize != null) json['labelFontSize'] = labelFontSize;
    if (labelColor != null) json['labelColor'] = _colorToHex(labelColor!);
    if (labelHaloColor != null) {
      json['labelHaloColor'] = _colorToHex(labelHaloColor!);
    }
    if (labelOpacity != null) json['labelOpacity'] = labelOpacity;
    return json;
  }

  /// 親スタイルとマージ（子の設定が優先）
  KMetaLayerStyle mergeWith(KMetaLayerStyle? parent) {
    if (parent == null) return this;
    return KMetaLayerStyle(
      pointSize: pointSize ?? parent.pointSize,
      pointColor: pointColor ?? parent.pointColor,
      lineWidth: lineWidth ?? parent.lineWidth,
      lineColor: lineColor ?? parent.lineColor,
      polygonBorderWidth: polygonBorderWidth ?? parent.polygonBorderWidth,
      polygonBorderColor: polygonBorderColor ?? parent.polygonBorderColor,
      polygonFillColor: polygonFillColor ?? parent.polygonFillColor,
      polygonFillOpacity: polygonFillOpacity ?? parent.polygonFillOpacity,
      polygonBorderOpacity: polygonBorderOpacity ?? parent.polygonBorderOpacity,
      labelEnabled: labelEnabled ?? parent.labelEnabled,
      labelProperty: labelProperty ?? parent.labelProperty,
      labelFontSize: labelFontSize ?? parent.labelFontSize,
      labelColor: labelColor ?? parent.labelColor,
      labelHaloColor: labelHaloColor ?? parent.labelHaloColor,
      labelOpacity: labelOpacity ?? parent.labelOpacity,
    );
  }

  /// 空かどうか
  bool get isEmpty =>
      pointSize == null &&
      pointColor == null &&
      lineWidth == null &&
      lineColor == null &&
      polygonBorderWidth == null &&
      polygonBorderColor == null &&
      polygonFillColor == null &&
      polygonFillOpacity == null &&
      polygonBorderOpacity == null &&
      labelEnabled == null &&
      labelProperty == null &&
      labelFontSize == null &&
      labelColor == null &&
      labelHaloColor == null &&
      labelOpacity == null;
}

/// 可視性設定
class KMetaVisibility {
  /// レイヤーキー（gpkgName/layerName形式） → 可視状態
  final Map<String, bool> layers;

  /// GeoPackageファイル名 → 可視状態
  final Map<String, bool> geopackages;

  /// フォルダ名 → 可視状態
  final Map<String, bool> folders;

  /// 画像ファイル名 → 可視状態
  final Map<String, bool> images;

  /// Viewキー（gpkgName/layerName/viewName形式） → 可視状態
  final Map<String, bool> views;

  const KMetaVisibility({
    this.layers = const {},
    this.geopackages = const {},
    this.folders = const {},
    this.images = const {},
    this.views = const {},
  });

  /// JSONからパース
  factory KMetaVisibility.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const KMetaVisibility();
    return KMetaVisibility(
      layers: _parseBoolMap(json['layers']),
      geopackages: _parseBoolMap(json['geopackages']),
      folders: _parseBoolMap(json['folders']),
      images: _parseBoolMap(json['images']),
      views: _parseBoolMap(json['views']),
    );
  }

  static Map<String, bool> _parseBoolMap(dynamic value) {
    if (value is! Map<String, dynamic>) return {};
    return value.map((k, v) => MapEntry(k, v as bool));
  }

  /// JSONへシリアライズ
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};
    if (layers.isNotEmpty) json['layers'] = layers;
    if (geopackages.isNotEmpty) json['geopackages'] = geopackages;
    if (folders.isNotEmpty) json['folders'] = folders;
    if (images.isNotEmpty) json['images'] = images;
    if (views.isNotEmpty) json['views'] = views;
    return json;
  }

  /// 親設定とマージ
  KMetaVisibility mergeWith(KMetaVisibility? parent) {
    if (parent == null) return this;
    return KMetaVisibility(
      layers: {...parent.layers, ...layers},
      geopackages: {...parent.geopackages, ...geopackages},
      folders: {...parent.folders, ...folders},
      images: {...parent.images, ...images},
    );
  }

  /// 空かどうか
  bool get isEmpty =>
      layers.isEmpty &&
      geopackages.isEmpty &&
      folders.isEmpty &&
      images.isEmpty &&
      views.isEmpty;
}

/// スタイル設定（デフォルト＋レイヤー個別）
/// View: 親レイヤに対する「フィルタ＋スタイル」の集合体。
///
/// > [!IMPORTANT] View は見せ方であって、データではない
/// > フィーチャは Layer に属する。View は同じ Layer を別の条件・別の見た目で
/// > 何枚も見せるための定義。同じ Layer に対して複数の View を作り、
/// > 同時に表示できる。並べ替えは**同一 Layer 内でのみ**許す
/// > （dir構造の拘束を保つため。z順は常に dir 構造から決まる）。
///
/// QGIS の「レイヤ」と 1:1 で対応する唯一の概念。
/// dir / GeoPackage / Layer はすべて QGIS のレイヤグループになる。
/// 設計の全体像は [[docs/technical/project-format-design]]。
class KMetaView {
  const KMetaView({required this.name, this.filter, this.style});

  /// View名。**同一レイヤ内で一意**であること（キーの一部になる）
  final String name;

  /// フィルタ。SQL の WHERE 句（QGIS の subset string と同じ書き方）。
  /// null / 空文字なら絞り込み無し。
  final String? filter;

  /// この View の見た目。null なら親レイヤ／既定のスタイルに従う。
  final KMetaLayerStyle? style;

  factory KMetaView.fromJson(Map<String, dynamic> json) {
    final styleJson = json['style'] as Map<String, dynamic>?;
    return KMetaView(
      name: json['name'] as String? ?? '',
      filter: json['filter'] as String?,
      style: styleJson == null ? null : KMetaLayerStyle.fromJson(styleJson),
    );
  }

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{'name': name};
    if (filter != null && filter!.isNotEmpty) json['filter'] = filter;
    if (style != null && !style!.isEmpty) json['style'] = style!.toJson();
    return json;
  }

  KMetaView copyWith({String? name, String? filter, KMetaLayerStyle? style}) =>
      KMetaView(
        name: name ?? this.name,
        filter: filter ?? this.filter,
        style: style ?? this.style,
      );

  @override
  String toString() => 'KMetaView($name, filter=$filter)';
}

class KMetaStyles {
  /// デフォルトスタイル
  final KMetaLayerStyle? defaultStyle;

  /// レイヤー名 → スタイル
  final Map<String, KMetaLayerStyle> layers;

  const KMetaStyles({this.defaultStyle, this.layers = const {}});

  /// JSONからパース
  factory KMetaStyles.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const KMetaStyles();
    return KMetaStyles(
      defaultStyle:
          json['default'] != null
              ? KMetaLayerStyle.fromJson(
                json['default'] as Map<String, dynamic>,
              )
              : null,
      layers:
          (json['layers'] as Map<String, dynamic>?)?.map(
            (k, v) => MapEntry(
              k,
              KMetaLayerStyle.fromJson(v as Map<String, dynamic>),
            ),
          ) ??
          {},
    );
  }

  /// JSONへシリアライズ
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};
    if (defaultStyle != null && !defaultStyle!.isEmpty) {
      json['default'] = defaultStyle!.toJson();
    }
    if (layers.isNotEmpty) {
      json['layers'] = layers.map((k, v) => MapEntry(k, v.toJson()));
    }
    return json;
  }

  /// 親設定とマージ
  /// 注意: layersは継承しない（各フォルダで独立管理）
  /// defaultStyleのみ親から継承される
  KMetaStyles mergeWith(KMetaStyles? parent) {
    if (parent == null) return this;
    return KMetaStyles(
      defaultStyle:
          defaultStyle?.mergeWith(parent.defaultStyle) ?? parent.defaultStyle,
      layers: layers, // 継承しない（自フォルダの設定のみ）
    );
  }

  /// 空かどうか
  bool get isEmpty =>
      (defaultStyle == null || defaultStyle!.isEmpty) && layers.isEmpty;
}

/// レイアウト設定
class KMetaLayout {
  /// 並び順（レイヤー/GeoPackage/フォルダ名のリスト）
  final List<String>? sortOrder;

  /// 展開状態
  final bool? expanded;

  const KMetaLayout({this.sortOrder, this.expanded});

  /// JSONからパース
  factory KMetaLayout.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const KMetaLayout();
    return KMetaLayout(
      sortOrder: (json['sortOrder'] as List<dynamic>?)?.cast<String>(),
      expanded: json['expanded'] as bool?,
    );
  }

  /// JSONへシリアライズ
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};
    if (sortOrder != null) json['sortOrder'] = sortOrder;
    if (expanded != null) json['expanded'] = expanded;
    return json;
  }

  /// 親設定とマージ
  KMetaLayout mergeWith(KMetaLayout? parent) {
    if (parent == null) return this;
    return KMetaLayout(
      sortOrder: sortOrder ?? parent.sortOrder,
      expanded: expanded ?? parent.expanded,
    );
  }

  /// 空かどうか
  bool get isEmpty => sortOrder == null && expanded == null;
}

/// 同期対象ファイルの情報
class KMetaSyncFile {
  /// DriveファイルID
  final String driveFileId;

  /// 最終同期時刻（同期完了時点のDateTime.now()）。ローカルの変更判定（ファイルの mtime と比べる）に使う
  final DateTime? lastSyncedTime;

  /// 最後に同期したときの Drive 側の `modifiedTime`（Drive サーバーの時計）。
  /// リモートの変更判定はこれと比べる。端末の時計（[lastSyncedTime]）と比べると、
  /// 端末の時計が進んでいる分だけ相手の変更を見落とし、上書きして消す（2026-09-24）
  final DateTime? remoteModifiedTime;

  const KMetaSyncFile({
    required this.driveFileId,
    this.lastSyncedTime,
    this.remoteModifiedTime,
  });

  /// 最後の同期より後に Drive 側が変わったか（Drive の時刻どうしで比べる）。
  /// [remoteModifiedTime] の無い古い帳簿は、以前どおり [lastSyncedTime] と比べる
  bool isRemoteNewer(DateTime driveModified) {
    final r = remoteModifiedTime;
    if (r != null) return driveModified.isAfter(r);
    final l = lastSyncedTime;
    return l != null && driveModified.isAfter(l);
  }

  factory KMetaSyncFile.fromJson(Map<String, dynamic> json) {
    // 後方互換性：古いlastSyncedModifiedTimeも読み込む
    final legacyTime =
        json['lastSyncedModifiedTime'] != null
            ? DateTime.tryParse(json['lastSyncedModifiedTime'] as String)
            : null;
    // expectedParentId は廃止済み（読み捨て）
    return KMetaSyncFile(
      driveFileId: json['driveFileId'] as String,
      lastSyncedTime:
          json['lastSyncedTime'] != null
              ? DateTime.tryParse(json['lastSyncedTime'] as String)
              : legacyTime, // フォールバック
      remoteModifiedTime: json['remoteModifiedTime'] != null
          ? DateTime.tryParse(json['remoteModifiedTime'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{'driveFileId': driveFileId};
    if (lastSyncedTime != null) {
      json['lastSyncedTime'] = lastSyncedTime!.toIso8601String();
    }
    if (remoteModifiedTime != null) {
      // Drive の時刻は UTC のまま持つ（端末のタイムゾーンに引きずられない）
      json['remoteModifiedTime'] = remoteModifiedTime!.toUtc().toIso8601String();
    }
    return json;
  }

  /// コピーを作成（一部フィールドを更新）
  KMetaSyncFile copyWith({
    String? driveFileId,
    DateTime? lastSyncedTime,
    DateTime? remoteModifiedTime,
  }) {
    return KMetaSyncFile(
      driveFileId: driveFileId ?? this.driveFileId,
      lastSyncedTime: lastSyncedTime ?? this.lastSyncedTime,
      remoteModifiedTime: remoteModifiedTime ?? this.remoteModifiedTime,
    );
  }
}

/// 同期設定（Google Drive連携用）
class KMetaSync {
  /// Google DriveのフォルダID
  final String? driveId;

  /// Driveフォルダ名（表示用）
  final String? driveFolderName;

  /// Drive共有URL（元のURL）
  final String? driveUrl;

  /// 読み取り専用か
  final bool? isReadOnly;

  /// 最終同期日時
  final DateTime? lastSynced;

  /// 最後に同期したDriveリビジョンID
  final String? driveRevisionId;

  /// このデバイスの識別子（ローカル専用、同期対象外）
  final String? deviceId;

  /// 同期対象ファイル（ファイル名 → ファイル情報）
  final Map<String, KMetaSyncFile> files;

  const KMetaSync({
    this.driveId,
    this.driveFolderName,
    this.driveUrl,
    this.isReadOnly,
    this.lastSynced,
    this.driveRevisionId,
    this.deviceId,
    this.files = const {},
  });

  /// JSONからパース
  factory KMetaSync.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const KMetaSync();

    // filesフィールドをパース
    final filesJson = json['files'] as Map<String, dynamic>?;
    final files = <String, KMetaSyncFile>{};
    if (filesJson != null) {
      for (final entry in filesJson.entries) {
        files[entry.key] = KMetaSyncFile.fromJson(
          entry.value as Map<String, dynamic>,
        );
      }
    }

    return KMetaSync(
      driveId: json['driveId'] as String?,
      driveFolderName: json['driveFolderName'] as String?,
      driveUrl: json['driveUrl'] as String?,
      isReadOnly: json['isReadOnly'] as bool?,
      lastSynced:
          json['lastSynced'] != null
              ? DateTime.tryParse(json['lastSynced'] as String)
              : null,
      driveRevisionId: json['driveRevisionId'] as String?,
      deviceId: json['deviceId'] as String?,
      files: files,
    );
  }

  /// JSONへシリアライズ（全フィールド含む）
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};
    if (driveId != null) json['driveId'] = driveId;
    if (driveFolderName != null) json['driveFolderName'] = driveFolderName;
    if (driveUrl != null) json['driveUrl'] = driveUrl;
    if (isReadOnly != null) json['isReadOnly'] = isReadOnly;
    if (lastSynced != null) json['lastSynced'] = lastSynced!.toIso8601String();
    if (driveRevisionId != null) json['driveRevisionId'] = driveRevisionId;
    if (deviceId != null) json['deviceId'] = deviceId;
    if (files.isNotEmpty) {
      json['files'] = files.map((k, v) => MapEntry(k, v.toJson()));
    }
    return json;
  }

  /// 同期用JSONへシリアライズ（deviceIdを除外）
  /// Driveにアップロードする際はこちらを使用
  Map<String, dynamic> toJsonForSync() {
    final json = <String, dynamic>{};
    if (driveId != null) json['driveId'] = driveId;
    if (driveFolderName != null) json['driveFolderName'] = driveFolderName;
    if (driveUrl != null) json['driveUrl'] = driveUrl;
    if (isReadOnly != null) json['isReadOnly'] = isReadOnly;
    if (lastSynced != null) json['lastSynced'] = lastSynced!.toIso8601String();
    if (driveRevisionId != null) json['driveRevisionId'] = driveRevisionId;
    // deviceIdは同期対象外なので含めない
    if (files.isNotEmpty) {
      json['files'] = files.map((k, v) => MapEntry(k, v.toJson()));
    }
    return json;
  }

  /// 親設定とマージ（同期設定は継承しない = 各フォルダ独立）
  KMetaSync mergeWith(KMetaSync? parent) => this;

  /// 共有ファイルに書くぶん（リンク情報だけ）。帳簿は [SyncLedger] へ
  KMetaSync linkOnly() => KMetaSync(
    driveId: driveId,
    driveFolderName: driveFolderName,
    driveUrl: driveUrl,
    isReadOnly: isReadOnly,
  );

  /// 帳簿（端末ごとの状態）を含んでいるか
  bool get hasBookkeeping =>
      lastSynced != null || driveRevisionId != null || deviceId != null || files.isNotEmpty;

  /// 空かどうか
  bool get isEmpty =>
      driveId == null &&
      driveFolderName == null &&
      lastSynced == null &&
      driveRevisionId == null &&
      deviceId == null &&
      files.isEmpty;

  /// Drive連携済みかどうか
  bool get isLinked => driveId != null;

  /// コピーを作成（一部設定を変更）
  KMetaSync copyWith({
    String? driveId,
    String? driveFolderName,
    String? driveUrl,
    bool? isReadOnly,
    DateTime? lastSynced,
    String? driveRevisionId,
    String? deviceId,
    Map<String, KMetaSyncFile>? files,
  }) {
    return KMetaSync(
      driveId: driveId ?? this.driveId,
      driveFolderName: driveFolderName ?? this.driveFolderName,
      driveUrl: driveUrl ?? this.driveUrl,
      isReadOnly: isReadOnly ?? this.isReadOnly,
      lastSynced: lastSynced ?? this.lastSynced,
      driveRevisionId: driveRevisionId ?? this.driveRevisionId,
      deviceId: deviceId ?? this.deviceId,
      files: files ?? this.files,
    );
  }
}

/// 画像オーバーレイの変換パラメータ
class KMetaImageOverlay {
  /// 画像の中心座標（経度）
  final double centerLng;

  /// 画像の中心座標（緯度）
  final double centerLat;

  /// スケール（メートル/ピクセル）
  final double scale;

  /// 回転角度（度、時計回り）
  final double rotation;


  /// 画像幅（ピクセル）
  final int imageWidth;

  /// 画像高さ（ピクセル）
  final int imageHeight;

  const KMetaImageOverlay({
    required this.centerLng,
    required this.centerLat,
    this.scale = 1.0,
    this.rotation = 0.0,

    required this.imageWidth,
    required this.imageHeight,
  });

  /// JSONからパース
  factory KMetaImageOverlay.fromJson(Map<String, dynamic> json) {
    return KMetaImageOverlay(
      centerLng: (json['centerLng'] as num).toDouble(),
      centerLat: (json['centerLat'] as num).toDouble(),
      scale: (json['scale'] as num?)?.toDouble() ?? 1.0,
      rotation: (json['rotation'] as num?)?.toDouble() ?? 0.0,

      imageWidth: json['imageWidth'] as int,
      imageHeight: json['imageHeight'] as int,
    );
  }

  /// JSONへシリアライズ
  Map<String, dynamic> toJson() {
    return {
      'centerLng': centerLng,
      'centerLat': centerLat,
      'scale': scale,
      'rotation': rotation,

      'imageWidth': imageWidth,
      'imageHeight': imageHeight,
    };
  }

  /// コピーを作成
  KMetaImageOverlay copyWith({
    double? centerLng,
    double? centerLat,
    double? scale,
    double? rotation,

    int? imageWidth,
    int? imageHeight,
  }) {
    return KMetaImageOverlay(
      centerLng: centerLng ?? this.centerLng,
      centerLat: centerLat ?? this.centerLat,
      scale: scale ?? this.scale,
      rotation: rotation ?? this.rotation,

      imageWidth: imageWidth ?? this.imageWidth,
      imageHeight: imageHeight ?? this.imageHeight,
    );
  }
}

/// フォルダメタデータ（.kmeta.json）
class KMeta {
  /// スキーマバージョン
  final int version;

  /// 可視性設定
  final KMetaVisibility visibility;

  /// スタイル設定
  final KMetaStyles styles;

  /// レイアウト設定
  final KMetaLayout layout;

  /// 同期設定
  final KMetaSync sync;

  /// 画像オーバーレイ設定（画像ファイル名 → 変換パラメータ）
  final Map<String, KMetaImageOverlay> imageOverlays;

  /// View定義（レイヤキー `gpkgName/layerName` → View の並び）
  ///
  /// **順序に意味がある。** 同一レイヤ内の z順はこのリストの順。
  /// キーが無い＝そのレイヤに View が定義されていない、という意味で、
  /// そのときアプリは「既定のView」を1つだけ暗黙に持つ（[LayerNode] 参照）。
  final Map<String, List<KMetaView>> views;

  const KMeta({
    this.version = kMetaSchemaVersion,
    this.visibility = const KMetaVisibility(),
    this.styles = const KMetaStyles(),
    this.layout = const KMetaLayout(),
    this.sync = const KMetaSync(),
    this.imageOverlays = const {},
    this.views = const {},
  });

  /// 空のメタデータ
  static const KMeta empty = KMeta();

  /// JSONからパース
  factory KMeta.fromJson(Map<String, dynamic> json) {
    // 画像オーバーレイをパース
    final overlaysJson = json['imageOverlays'] as Map<String, dynamic>?;
    final overlays = <String, KMetaImageOverlay>{};
    if (overlaysJson != null) {
      for (final entry in overlaysJson.entries) {
        overlays[entry.key] = KMetaImageOverlay.fromJson(
          entry.value as Map<String, dynamic>,
        );
      }
    }

    // View定義をパース
    final viewsJson = json['views'] as Map<String, dynamic>?;
    final views = <String, List<KMetaView>>{};
    if (viewsJson != null) {
      for (final entry in viewsJson.entries) {
        final list = entry.value;
        if (list is! List) continue;
        views[entry.key] = [
          for (final v in list)
            if (v is Map<String, dynamic>) KMetaView.fromJson(v),
        ];
      }
    }

    return KMeta(
      version: json['version'] as int? ?? kMetaSchemaVersion,
      visibility: KMetaVisibility.fromJson(
        json['visibility'] as Map<String, dynamic>?,
      ),
      styles: KMetaStyles.fromJson(json['styles'] as Map<String, dynamic>?),
      layout: KMetaLayout.fromJson(json['layout'] as Map<String, dynamic>?),
      sync: KMetaSync.fromJson(json['sync'] as Map<String, dynamic>?),
      imageOverlays: overlays,
      views: views,
    );
  }

  /// JSONへシリアライズ
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{'version': version};
    if (!visibility.isEmpty) json['visibility'] = visibility.toJson();
    if (!styles.isEmpty) json['styles'] = styles.toJson();
    if (!layout.isEmpty) json['layout'] = layout.toJson();
    if (!sync.isEmpty) json['sync'] = sync.toJson();
    if (imageOverlays.isNotEmpty) {
      json['imageOverlays'] = imageOverlays.map(
        (k, v) => MapEntry(k, v.toJson()),
      );
    }
    if (views.isNotEmpty) {
      json['views'] = views.map(
        (k, v) => MapEntry(k, [for (final view in v) view.toJson()]),
      );
    }
    return json;
  }

  /// 親メタデータとマージ（継承処理）
  KMeta mergeWith(KMeta? parent) {
    if (parent == null) return this;
    return KMeta(
      version: version,
      visibility: visibility.mergeWith(parent.visibility),
      styles: styles.mergeWith(parent.styles),
      layout: layout.mergeWith(parent.layout),
      sync: sync.mergeWith(parent.sync),
      imageOverlays: imageOverlays, // 継承しない（各フォルダ独立管理）
    );
  }

  /// ファイルから読み込み
  static Future<KMeta?> loadFromFile(String folderPath) async {
    try {
      final path = '$folderPath/$kMetaFileName';
      if (!await fs.exists(path)) {
        return null;
      }
      final content = await fs.readAsString(path);
      final json = jsonDecode(content) as Map<String, dynamic>;
      return KMeta.fromJson(json);
    } catch (e) {
      AppLogger.debug('[KMeta] Error loading from $folderPath: $e');
      return null;
    }
  }

  /// ファイルに保存
  Future<bool> saveToFile(String folderPath) async {
    try {
      final json = toJson();
      final content = const JsonEncoder.withIndent('  ').convert(json);
      final path = '$folderPath/$kMetaFileName';
      // 中身が同じなら書かない（更新時刻が進むと Drive 同期が毎回アップロードする。2026-09-24）
      if (await fs.exists(path) && await fs.readAsString(path) == content) return true;
      await fs.writeAsString(path, content);
      AppLogger.debug('[KMeta] Saved to $folderPath');
      return true;
    } catch (e) {
      AppLogger.debug('[KMeta] Error saving to $folderPath: $e');
      return false;
    }
  }

  /// 空かどうか
  bool get isEmpty =>
      visibility.isEmpty && styles.isEmpty && layout.isEmpty && sync.isEmpty &&
      imageOverlays.isEmpty && views.isEmpty;

  /// レイヤのView定義。定義が無ければ空リスト（＝既定のView1枚とみなす側の責務）
  List<KMetaView> getViews(String layerKey) => views[layerKey] ?? const [];

  /// Viewの可視状態を取得
  /// [viewKey] は `gpkgName/layerName/viewName` 形式
  bool? getViewVisibility(String viewKey) => visibility.views[viewKey];

  /// 特定レイヤーのスタイルを取得（デフォルト適用済み）
  /// [layerKey] はgpkgName/layerName形式（例: "survey.gpkg/points"）
  KMetaLayerStyle? getLayerStyle(String layerKey) {
    final layerStyle = styles.layers[layerKey];
    if (layerStyle != null) {
      return layerStyle.mergeWith(styles.defaultStyle);
    }
    return styles.defaultStyle;
  }

  /// レイヤーの可視状態を取得
  bool? getLayerVisibility(String layerName) => visibility.layers[layerName];

  /// GeoPackageの可視状態を取得
  bool? getGeoPackageVisibility(String gpkgName) =>
      visibility.geopackages[gpkgName];

  /// コピーを作成（一部設定を変更）
  KMeta copyWith({
    int? version,
    KMetaVisibility? visibility,
    KMetaStyles? styles,
    KMetaLayout? layout,
    KMetaSync? sync,
    Map<String, KMetaImageOverlay>? imageOverlays,
    Map<String, List<KMetaView>>? views,
  }) {
    return KMeta(
      version: version ?? this.version,
      visibility: visibility ?? this.visibility,
      styles: styles ?? this.styles,
      layout: layout ?? this.layout,
      sync: sync ?? this.sync,
      imageOverlays: imageOverlays ?? this.imageOverlays,
      views: views ?? this.views,
    );
  }
}

// ========== ユーティリティ関数 ==========

/// 色文字列（#RRGGBB または #AARRGGBB）をColorに変換
Color? _parseColor(dynamic value) {
  if (value == null) return null;
  if (value is int) return Color(value);
  if (value is String) {
    final hex = value.replaceFirst('#', '');
    if (hex.length == 6) {
      return Color(int.parse('FF$hex', radix: 16));
    } else if (hex.length == 8) {
      return Color(int.parse(hex, radix: 16));
    }
  }
  return null;
}

/// Colorを#AARRGGBB形式の文字列に変換
String _colorToHex(Color color) {
  return '#${color.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';
}
