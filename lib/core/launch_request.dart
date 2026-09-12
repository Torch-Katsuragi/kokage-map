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
// こかげマップ: 外から「どのプロジェクトを・どこを・どう見せるか」を指示する起動要求
//
// データはローカルにあるので、AI や CLI は .gpkg / .kmeta.json / .qgs を直接書き換え、
// アプリには「開いて」「ここを見せて」「読み直して」だけ頼めばよい。その口がこれ。
//
//   /map?project=<絶対パス>&lat=33.9&lon=135.57&zoom=15&bearing=30&pitch=45&reload=1
//
//   Android: `adb shell am start -n com.k_root.k_maps/.MainActivity --es route "/map?..."`
//            起動中なら onNewIntent → MethodChannel で同じ文字列が届く
//   web:     `https://.../#/map?lat=...&zoom=...`（hashchange で起動中にも届く。project は無視）
//   CLI:     `tool/kokage.py open|reload|url`（上を包んだだけ）
//
// 起動時の要求は [consumePending] で 1 回だけ取り出す（HomeScreen がプロジェクトを開き、
// MapPage がカメラを合わせる）。起動中に届いた要求は [incoming] に流れる。

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import '../utils/app_logger.dart';
import 'launch_request_io.dart'
    if (dart.library.js_interop) 'launch_request_web.dart' as impl;

class LaunchRequest {
  const LaunchRequest({
    this.project,
    this.lat,
    this.lon,
    this.zoom,
    this.bearing,
    this.pitch,
    this.reload = false,
  });

  /// 開くプロジェクトフォルダ（絶対パス）。web では使えない
  final String? project;
  final double? lat;
  final double? lon;
  final double? zoom;

  /// 方位（度、北が 0・時計回り）
  final double? bearing;

  /// 傾き（度、0 が真上）
  final double? pitch;

  /// プロジェクトをディスクから読み直す
  final bool reload;

  bool get hasCenter => lat != null && lon != null;
  LatLng? get center => hasCenter ? LatLng(lat!, lon!) : null;
  bool get hasCamera => hasCenter || zoom != null || bearing != null || pitch != null;
  bool get isEmpty => project == null && !hasCamera && !reload;

  /// `/map?...`・`#/map?...`・URL 全体 のどれからでも読む。`/map` に当たらなければ null
  static LaunchRequest? tryParse(String? route) {
    if (route == null || route.isEmpty) return null;
    var s = route.trim();
    // URL 全体なら fragment を取り出す（web の `https://host/#/map?...`）
    final hash = s.indexOf('#');
    if (hash >= 0) s = s.substring(hash + 1);
    if (!s.startsWith('/map')) return null;
    final rest = s.substring('/map'.length);
    if (rest.isNotEmpty && !rest.startsWith('?')) return null; // `/mapfoo` は違う
    final q = Uri.splitQueryString(rest.isEmpty ? '' : rest.substring(1));
    double? num(String k) => double.tryParse(q[k] ?? '');
    final req = LaunchRequest(
      project: (q['project']?.trim().isEmpty ?? true) ? null : q['project']!.trim(),
      lat: num('lat'),
      lon: num('lon') ?? num('lng'),
      zoom: num('zoom') ?? num('z'),
      bearing: num('bearing'),
      pitch: num('pitch'),
      reload: q['reload'] == '1' || q['reload'] == 'true',
    );
    return req;
  }

  /// 逆: 要求 → `/map?...`（CLI や web の URL 作りに）
  String toRoute() {
    final q = <String, String>{
      'project': ?project,
      if (lat != null) 'lat': lat!.toString(),
      if (lon != null) 'lon': lon!.toString(),
      if (zoom != null) 'zoom': zoom!.toString(),
      if (bearing != null) 'bearing': bearing!.toString(),
      if (pitch != null) 'pitch': pitch!.toString(),
      if (reload) 'reload': '1',
    };
    return q.isEmpty ? '/map' : '/map?${Uri(queryParameters: q).query}';
  }

  @override
  String toString() => 'LaunchRequest(${toRoute()})';

  // ── 起動時の要求と、起動中に届く要求 ─────────────────────

  static LaunchRequest? _pending;
  static bool _initialized = false;

  /// 起動中に届いた要求（Android の onNewIntent、web の hashchange）
  static final ValueNotifier<LaunchRequest?> incoming = ValueNotifier(null);

  /// 起動時に 1 回呼ぶ。起動ルートを読み、以後の到着を [incoming] に流す
  static void init() {
    if (_initialized) return;
    _initialized = true;
    final route = impl.initialRoute() ?? PlatformDispatcher.instance.defaultRouteName;
    _pending = tryParse(route);
    if (_pending != null) AppLogger.debug('[Launch] 起動要求 $_pending');
    impl.listenRoutes((r) {
      final req = tryParse(r);
      if (req == null || req.isEmpty) return;
      AppLogger.debug('[Launch] 到着 $req');
      incoming.value = req;
    });
  }

  /// 起動時の要求を覗く（消費しない）
  static LaunchRequest? get pending => _pending;

  /// 起動時の要求を取り出す（2 回目からは null）
  static LaunchRequest? consumePending() {
    final p = _pending;
    _pending = null;
    return p;
  }

  /// テスト用
  @visibleForTesting
  static void setPendingForTest(LaunchRequest? req) {
    _pending = req;
    _initialized = true;
  }
}
