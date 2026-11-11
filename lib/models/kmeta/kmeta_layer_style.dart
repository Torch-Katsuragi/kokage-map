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
// こかげマップ: フォルダ設定のレイヤスタイル定義（個別スタイル・フォルダ内スタイル一覧）

import 'package:flutter/material.dart';

import '../qgis_renderer.dart';

/// レイヤースタイル設定（個別レイヤー用）
class KMetaLayerStyle {
  final double? pointSize;
  final Color? pointColor;
  final double? pointOpacity;
  final double? lineWidth;
  final Color? lineColor;
  final double? lineOpacity;
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

  /// QGIS 側で単一シンボル以外（`categorizedSymbol` / `graduatedSymbol` / `RuleRenderer` …）に
  /// 設定されているときの種類。null なら単一シンボル（アプリで色や太さを編集できる）。
  ///
  /// 地物ごとの色は [qgisRendererDef] から決め（読めなければ代表の色）、`.qgs` のレンダラは触らない（不変条件4）。
  /// スタイル画面はこのとき色・太さを編集させない（変えても QGIS に届かず、見た目が食い違うため）
  final String? qgisRenderer;

  /// [qgisRenderer] の中身（分類の項目・段階の範囲・ルールとそれぞれのシンボル）。地物ごとの色はここから決める。
  /// `.qgs` のレンダラを読んだ写しで、QGIS で保存し直されるたびに読み戻しが差し替える
  final QgisRenderer? qgisRendererDef;

  const KMetaLayerStyle({
    this.pointSize,
    this.pointColor,
    this.pointOpacity,
    this.lineWidth,
    this.lineColor,
    this.lineOpacity,
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
    this.qgisRenderer,
    this.qgisRendererDef,
  });

  KMetaLayerStyle copyWith({
    double? pointSize,
    Color? pointColor,
    double? pointOpacity,
    double? lineWidth,
    Color? lineColor,
    double? lineOpacity,
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
    String? qgisRenderer,
    QgisRenderer? qgisRendererDef,
  }) =>
      KMetaLayerStyle(
        pointSize: pointSize ?? this.pointSize,
        pointColor: pointColor ?? this.pointColor,
        pointOpacity: pointOpacity ?? this.pointOpacity,
        lineWidth: lineWidth ?? this.lineWidth,
        lineColor: lineColor ?? this.lineColor,
        lineOpacity: lineOpacity ?? this.lineOpacity,
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
        qgisRenderer: qgisRenderer ?? this.qgisRenderer,
        qgisRendererDef: qgisRendererDef ?? this.qgisRendererDef,
      );

  /// JSONからパース
  factory KMetaLayerStyle.fromJson(Map<String, dynamic> json) {
    return KMetaLayerStyle(
      pointSize: (json['pointSize'] as num?)?.toDouble(),
      pointColor: _parseColor(json['pointColor']),
      pointOpacity: (json['pointOpacity'] as num?)?.toDouble(),
      lineWidth: (json['lineWidth'] as num?)?.toDouble(),
      lineColor: _parseColor(json['lineColor']),
      lineOpacity: (json['lineOpacity'] as num?)?.toDouble(),
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
      qgisRenderer: json['qgisRenderer'] as String?,
      qgisRendererDef: QgisRenderer.tryFromJson(json['qgisRendererDef']),
    );
  }

  /// JSONへシリアライズ（null の項目は書かない）
  Map<String, dynamic> toJson() => {
    if (pointSize != null) 'pointSize': pointSize,
    if (pointColor != null) 'pointColor': _colorToHex(pointColor!),
    if (pointOpacity != null) 'pointOpacity': pointOpacity,
    if (lineWidth != null) 'lineWidth': lineWidth,
    if (lineColor != null) 'lineColor': _colorToHex(lineColor!),
    if (lineOpacity != null) 'lineOpacity': lineOpacity,
    if (polygonBorderWidth != null) 'polygonBorderWidth': polygonBorderWidth,
    if (polygonBorderColor != null) 'polygonBorderColor': _colorToHex(polygonBorderColor!),
    if (polygonFillColor != null) 'polygonFillColor': _colorToHex(polygonFillColor!),
    if (polygonFillOpacity != null) 'polygonFillOpacity': polygonFillOpacity,
    if (polygonBorderOpacity != null) 'polygonBorderOpacity': polygonBorderOpacity,
    if (labelEnabled != null) 'labelEnabled': labelEnabled,
    if (labelProperty != null) 'labelProperty': labelProperty,
    if (labelFontSize != null) 'labelFontSize': labelFontSize,
    if (labelColor != null) 'labelColor': _colorToHex(labelColor!),
    if (labelHaloColor != null) 'labelHaloColor': _colorToHex(labelHaloColor!),
    if (labelOpacity != null) 'labelOpacity': labelOpacity,
    if (qgisRenderer != null) 'qgisRenderer': qgisRenderer,
    if (qgisRendererDef != null) 'qgisRendererDef': qgisRendererDef!.toJson(),
  };

  /// 親スタイルとマージ（子の設定が優先）
  KMetaLayerStyle mergeWith(KMetaLayerStyle? parent) {
    if (parent == null) return this;
    return KMetaLayerStyle(
      pointSize: pointSize ?? parent.pointSize,
      pointColor: pointColor ?? parent.pointColor,
      pointOpacity: pointOpacity ?? parent.pointOpacity,
      lineWidth: lineWidth ?? parent.lineWidth,
      lineColor: lineColor ?? parent.lineColor,
      lineOpacity: lineOpacity ?? parent.lineOpacity,
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
      qgisRenderer: qgisRenderer ?? parent.qgisRenderer,
      // 印と中身は組で持つ（子が印を持つなら子の中身。親の別のレンダラの中身を混ぜない）
      qgisRendererDef: qgisRenderer != null ? qgisRendererDef : parent.qgisRendererDef,
    );
  }

  /// 空かどうか
  bool get isEmpty =>
      pointSize == null &&
      pointColor == null &&
      pointOpacity == null &&
      lineWidth == null &&
      lineColor == null &&
      lineOpacity == null &&
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
      labelOpacity == null &&
      qgisRenderer == null &&
      qgisRendererDef == null;

  /// 描き分けの印と中身を外したもの（QGIS で単一シンボルに戻されたとき）
  KMetaLayerStyle withoutQgisRenderer() {
    final json = toJson()
      ..remove('qgisRenderer')
      ..remove('qgisRendererDef');
    return KMetaLayerStyle.fromJson(json);
  }
}

/// スタイル設定（デフォルト＋レイヤー個別）
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
      defaultStyle: json['default'] != null
          ? KMetaLayerStyle.fromJson(json['default'] as Map<String, dynamic>)
          : null,
      layers: (json['layers'] as Map<String, dynamic>?)?.map(
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

  /// 空かどうか
  bool get isEmpty =>
      (defaultStyle == null || defaultStyle!.isEmpty) && layers.isEmpty;
}

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
