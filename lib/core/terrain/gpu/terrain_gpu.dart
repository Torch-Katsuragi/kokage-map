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

/// GPU 描画系の差し替え: Android / desktop は `package:flutter_gpu`（dart:ffi 依存）、web は WebGL2（`package:web`）。
/// どちらも同じクラス名 `TerrainGpuWorldRenderer` と同じ API を持つ
library;

export 'gpu_geometry.dart';
export 'terrain_gpu_renderer_stub.dart' if (dart.library.ffi) 'terrain_gpu_renderer.dart';
export 'terrain_gpu_stats.dart';
export 'terrain_gpu_world_stub.dart'
    if (dart.library.ffi) 'terrain_gpu_world.dart'
    if (dart.library.js_interop) 'terrain_gpu_world_web.dart';
