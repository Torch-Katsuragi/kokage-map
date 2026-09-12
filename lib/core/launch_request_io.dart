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
// こかげマップ: 起動要求（native）。起動時のルートは Flutter が `--route` / intent extra `route` から
// defaultRouteName に入れる。起動中に届く分は MainActivity.onNewIntent → MethodChannel

import 'package:flutter/services.dart';

const _channel = MethodChannel('com.k_root.k_maps/launch');

/// 起動時のルート。native は defaultRouteName に任せる（呼び出し側がそちらを読む）
String? initialRoute() => null;

void listenRoutes(void Function(String route) onRoute) {
  _channel.setMethodCallHandler((call) async {
    if (call.method == 'route') {
      final route = call.arguments;
      if (route is String) onRoute(route);
    }
  });
}
