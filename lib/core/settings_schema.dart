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
/// 宣言的設定フレームワーク
///
/// 設定項目をSettingDefで宣言するだけで、
/// SharedPreferences永続化・KMetaフォールバック・UI自動生成を提供。
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/kmeta.dart';

// ============================================================
// 設定定義（sealed class）
// ============================================================

/// 設定項目の基底クラス
sealed class SettingDef {
  final String key;
  final String title;
  final String? description;

  const SettingDef({required this.key, required this.title, this.description});
}

/// double値スライダー設定
class DoubleDef extends SettingDef {
  final double defaultValue;
  final double min;
  final double max;
  final int divisions;
  final String Function(double)? formatter;
  final double? Function(KMetaLayerStyle)? kmetaGetter;

  const DoubleDef({
    required super.key,
    required super.title,
    super.description,
    required this.defaultValue,
    required this.min,
    required this.max,
    required this.divisions,
    this.formatter,
    this.kmetaGetter,
  });

  String formatValue(double v) => formatter?.call(v) ?? v.toStringAsFixed(1);
}

/// bool値スイッチ設定
class SwitchDef extends SettingDef {
  final bool defaultValue;
  final IconData? icon;
  final bool? Function(KMetaLayerStyle)? kmetaGetter;

  const SwitchDef({
    required super.key,
    required super.title,
    super.description,
    required this.defaultValue,
    this.icon,
    this.kmetaGetter,
  });
}

/// Color値設定（SharedPreferencesにはARGB32 intで保存）
class ColorDef extends SettingDef {
  final int defaultArgb;
  final Color? Function(KMetaLayerStyle)? kmetaGetter;

  const ColorDef({
    required super.key,
    required super.title,
    super.description,
    required this.defaultArgb,
    this.kmetaGetter,
  });

  Color get defaultColor => Color(defaultArgb);
}

/// int値スライダー設定
class IntDef extends SettingDef {
  final int defaultValue;
  final int min;
  final int max;
  final String Function(int)? formatter;

  const IntDef({
    required super.key,
    required super.title,
    super.description,
    required this.defaultValue,
    required this.min,
    required this.max,
    this.formatter,
  });

  int get divisions => max - min;
  String formatValue(int v) => formatter?.call(v) ?? v.toString();
}

/// 画面側が自由に描く項目（ストアには値を持たない）。
/// [builder] の第 3 引数は「値を変えた」の通知（保存と再描画）
class CustomDef extends SettingDef {
  final Widget Function(
    BuildContext context,
    SettingsStore store,
    VoidCallback onChanged,
  )
  builder;

  const CustomDef({
    required super.key,
    required super.title,
    super.description,
    required this.builder,
  });
}

/// String値設定
class StringDef extends SettingDef {
  final String defaultValue;
  final String? Function(KMetaLayerStyle)? kmetaGetter;

  const StringDef({
    required super.key,
    required super.title,
    super.description,
    required this.defaultValue,
    this.kmetaGetter,
  });
}

// ============================================================
// セクション定義
// ============================================================

/// 設定セクションの定義
class SettingSectionDef {
  /// 画面側が「どの節か」を見分けるためのキー（表示名は翻訳で変わるので使わない）
  final String? id;
  final String title;
  final IconData? icon;
  final Color? iconColor;
  final String? description;
  final List<SettingDef> items;
  final bool collapsible;
  final bool initiallyExpanded;
  final bool globalOnly;

  const SettingSectionDef({
    this.id,
    required this.title,
    this.icon,
    this.iconColor,
    this.description,
    required this.items,
    this.collapsible = true,
    this.initiallyExpanded = false,
    this.globalOnly = false,
  });
}

// ============================================================
// 汎用ストア
// ============================================================

/// SharedPreferences + KMetaオーバーレイの二層設定ストア
///
/// 値の解決順: overlay(KMeta) > SharedPreferences > defaultValue
class SettingsStore extends ChangeNotifier {
  final List<SettingSectionDef> sections;
  SharedPreferences? _prefs;
  Map<String, dynamic>? _overlay;

  SettingsStore(this.sections);

  /// 全SettingDefのフラットリスト
  Iterable<SettingDef> get allDefs => sections.expand((s) => s.items);

  bool get hasOverlay => _overlay != null;

  // ---------- 読み込み ----------

  Future<void> load() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  // ---------- 値取得（overlay > prefs > default）----------

  double getDouble(DoubleDef def) {
    if (_overlay?.containsKey(def.key) == true) {
      return (_overlay![def.key] as num).toDouble();
    }
    return _globalDouble(def);
  }

  bool getBool(SwitchDef def) {
    if (_overlay?.containsKey(def.key) == true) {
      return _overlay![def.key] as bool;
    }
    return _globalBool(def);
  }

  Color getColor(ColorDef def) {
    if (_overlay?.containsKey(def.key) == true) {
      final v = _overlay![def.key];
      if (v is Color) return v;
      if (v is int) return Color(v);
    }
    return _globalColor(def);
  }

  int getInt(IntDef def) {
    if (_overlay?.containsKey(def.key) == true) {
      return _overlay![def.key] as int;
    }
    return _globalInt(def);
  }

  String getString(StringDef def) {
    if (_overlay?.containsKey(def.key) == true) {
      return _overlay![def.key] as String;
    }
    return _globalString(def);
  }

  // ---------- KMetaフォールバック付き値取得（map_page.dart用）----------

  double resolveDouble(DoubleDef def, KMetaLayerStyle? kmeta) =>
      _fromKmeta(def.kmetaGetter, kmeta) ?? _globalDouble(def);

  bool resolveBool(SwitchDef def, KMetaLayerStyle? kmeta) =>
      _fromKmeta(def.kmetaGetter, kmeta) ?? _globalBool(def);

  Color resolveColor(ColorDef def, KMetaLayerStyle? kmeta) =>
      _fromKmeta(def.kmetaGetter, kmeta) ?? _globalColor(def);

  String resolveString(StringDef def, KMetaLayerStyle? kmeta) =>
      _fromKmeta(def.kmetaGetter, kmeta) ?? _globalString(def);

  static T? _fromKmeta<T>(
    T? Function(KMetaLayerStyle)? getter,
    KMetaLayerStyle? kmeta,
  ) => kmeta == null || getter == null ? null : getter(kmeta);

  // ---------- グローバル値（prefs > default）----------

  double _globalDouble(DoubleDef d) =>
      _prefs?.getDouble(d.key) ?? d.defaultValue;
  bool _globalBool(SwitchDef s) => _prefs?.getBool(s.key) ?? s.defaultValue;
  int _globalInt(IntDef i) => _prefs?.getInt(i.key) ?? i.defaultValue;
  String _globalString(StringDef s) =>
      _prefs?.getString(s.key) ?? s.defaultValue;
  Color _globalColor(ColorDef c) {
    final stored = _prefs?.getInt(c.key);
    return stored != null ? Color(stored) : c.defaultColor;
  }

  // ---------- 値設定 ----------

  Future<void> setDouble(DoubleDef def, double value) =>
      _set(def.key, value, () => _prefs?.setDouble(def.key, value));

  Future<void> setBool(SwitchDef def, bool value) =>
      _set(def.key, value, () => _prefs?.setBool(def.key, value));

  Future<void> setColor(ColorDef def, Color value) =>
      _set(def.key, value, () => _prefs?.setInt(def.key, value.toARGB32()));

  Future<void> setInt(IntDef def, int value) =>
      _set(def.key, value, () => _prefs?.setInt(def.key, value));

  Future<void> setString(StringDef def, String value) =>
      _set(def.key, value, () => _prefs?.setString(def.key, value));

  /// overlay があればそこへ、無ければ prefs へ書いて通知
  Future<void> _set(
    String key,
    Object value,
    Future<bool>? Function() persist,
  ) async {
    if (_overlay != null) {
      _overlay![key] = value;
    } else {
      await persist();
    }
    notifyListeners();
  }

  // ---------- リセット ----------

  Future<void> resetAll() async {
    for (final def in allDefs) {
      switch (def) {
        case final DoubleDef d:
          await setDouble(d, d.defaultValue);
        case final SwitchDef s:
          await setBool(s, s.defaultValue);
        case final ColorDef c:
          await setColor(c, c.defaultColor);
        case final IntDef i:
          await setInt(i, i.defaultValue);
        case final StringDef s:
          await setString(s, s.defaultValue);
        case CustomDef():
          break; // 値を持たない
      }
    }
  }

  // ---------- KMeta オーバーレイ ----------

  /// KMetaLayerStyleからoverlayに値を読み込み（個別レイヤーモード）
  void loadOverlay(KMetaLayerStyle? style) {
    _overlay = {};
    if (style == null) {
      _fillOverlayFromGlobal();
      return;
    }
    // KMeta値を読み込み、ない場合はグローバル値をフォールバック
    for (final def in allDefs) {
      final dynamic kmetaVal = switch (def) {
        final DoubleDef d => d.kmetaGetter?.call(style),
        final SwitchDef s => s.kmetaGetter?.call(style),
        final ColorDef c => c.kmetaGetter?.call(style),
        final StringDef s => s.kmetaGetter?.call(style),
        IntDef _ || CustomDef _ => null,
      };
      if (kmetaVal != null) {
        _overlay![def.key] = kmetaVal;
      } else {
        // グローバル値をフォールバック
        _overlay![def.key] = _getGlobalValue(def);
      }
    }
  }

  /// overlayをクリア（グローバルモードに戻る）
  void clearOverlay() {
    _overlay = null;
  }

  /// グローバル値を取得（prefsまたはdefault）
  dynamic _getGlobalValue(SettingDef def) => switch (def) {
    final DoubleDef d => _globalDouble(d),
    final SwitchDef s => _globalBool(s),
    final ColorDef c => _globalColor(c),
    final IntDef i => _globalInt(i),
    final StringDef s => _globalString(s),
    CustomDef _ => null,
  };

  /// overlayにグローバル値を充填
  void _fillOverlayFromGlobal() {
    _overlay ??= {};
    for (final def in allDefs) {
      if (!_overlay!.containsKey(def.key)) {
        _overlay![def.key] = _getGlobalValue(def);
      }
    }
  }
}
