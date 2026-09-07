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
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../tools/gps_tool.dart';
import '../tools/map_tool.dart';
import '../tools/overlay_transform_tool.dart';
import '../tools/pan_tool.dart';
import '../tools/pen_tool.dart';
import '../tools/select_tool.dart';

part 'tool_providers.g.dart';

@Riverpod(keepAlive: true)
PanTool panTool(Ref ref) => PanTool(ref);

@Riverpod(keepAlive: true)
PenTool penTool(Ref ref) => PenTool(ref);

@Riverpod(keepAlive: true)
SelectTool selectTool(Ref ref) => SelectTool(ref);

@Riverpod(keepAlive: true)
GpsTool gpsTool(Ref ref) => GpsTool(ref);

@Riverpod(keepAlive: true)
OverlayTransformTool overlayTransformTool(Ref ref) => OverlayTransformTool(ref);

@Riverpod(keepAlive: true)
class CurrentTool extends _$CurrentTool {
  @override
  MapTool build() => ref.read(panToolProvider);

  void set(MapTool tool) {
    if (state == tool) return;
    state.onDeactivate();
    state = tool;
    tool.onActivate();
  }
}
