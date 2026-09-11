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
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:vector_math/vector_math.dart' as vm;

import '../terrain_camera.dart';
import '../terrain_mesh.dart';
import '../terrain_painter.dart';
import '../terrain_world_painter.dart' show TerrainTileDrawable;
import 'gpu_geometry.dart';

/// 世界（複数タイル）を `package:flutter_gpu` で描く（Android / iOS / desktop。web は stub）
///
/// スパイク `TerrainGpuRenderer` を「タイルの世界」に広げたもの。
/// - 地形: タイルのビルダー（[TerrainMeshBuilder]）ごとに頂点・インデックスをデバイスバッファに一度だけ上げる。
///   毎フレーム変えるのはタイルごとの mvp（カメラ中心基準の正射影 × タイル原点の平行移動）だけ
/// - 面・線: タイルの静的シーンのリストごとに、育ったぶんだけ足す（1 回の追加 = 1 バッファ）。育ち切ったら 1 本に畳む
/// - 動的なもの（軌跡・向き・描画中）は毎フレーム host buffer に流す（少ない）
/// - 深度バッファがあるので painter's algorithm（帯・象限走査・pitch 上限）は要らない。
///   面と線は深度を書かず、少し手前に寄せて地形との z-fight を避ける
/// - 点とラベルは Canvas 側（[TerrainWorldPainter]）のまま。ヒットテスト・投影も Dart 側のまま
///
/// 描いた結果は `GpuImageSurface` の `ui.Image` で、Canvas に `drawImageRect` する。
/// 設計は docs/technical/terrain-3d.md「flutter_gpu を TerrainWorld に」
class TerrainGpuWorldRenderer {
  TerrainGpuWorldRenderer._(this._terrainPipeline, this._polygonPipeline, this._linePipeline)
      : _hostBuffer = gpu.gpuContext.createHostBuffer(blockLengthInBytes: 64 * 1024);

  static const shaderBundleAsset = 'build/shaderbundles/terrain.shaderbundle';

  /// このプラットフォームで使えるか（web は false）
  static bool get isSupported => true;

  /// シェーダ束を読んでパイプラインを組む。Impeller / Flutter GPU が無効なら例外
  static Future<TerrainGpuWorldRenderer> create() async {
    final lib = await gpu.ShaderLibrary.fromAsset(shaderBundleAsset);
    if (lib == null) {
      throw StateError('シェーダ束が無い: $shaderBundleAsset（hook/build.dart が走っていない）');
    }
    gpu.Shader shader(String name) => lib[name] ?? (throw StateError('シェーダが無い: $name'));
    final terrain = gpu.gpuContext.createRenderPipeline(
      shader('TerrainVertex'),
      shader('TerrainFragment'),
      vertexLayout: const gpu.VertexLayout(
        buffers: [
          gpu.VertexBuffer(
            strideInBytes: GpuTerrainGeometry.strideInBytes,
            attributes: [
              gpu.VertexAttribute(name: 'position', format: gpu.VertexFormat.float32x3),
              gpu.VertexAttribute(name: 'uv', format: gpu.VertexFormat.float32x2, offsetInBytes: 12),
              gpu.VertexAttribute(name: 'shade', format: gpu.VertexFormat.float32, offsetInBytes: 20),
            ],
          ),
        ],
      ),
    );
    final polygon = gpu.gpuContext.createRenderPipeline(
      shader('PolygonVertex'),
      shader('PolygonFragment'),
      vertexLayout: const gpu.VertexLayout(
        buffers: [
          gpu.VertexBuffer(
            strideInBytes: GpuPolygonGeometry.strideInBytes,
            attributes: [
              gpu.VertexAttribute(name: 'position', format: gpu.VertexFormat.float32x3),
              gpu.VertexAttribute(name: 'color', format: gpu.VertexFormat.float32x4, offsetInBytes: 12),
            ],
          ),
        ],
      ),
    );
    final line = gpu.gpuContext.createRenderPipeline(
      shader('LineVertex'),
      shader('LineFragment'),
      vertexLayout: const gpu.VertexLayout(
        buffers: [
          gpu.VertexBuffer(
            strideInBytes: GpuLineGeometry.strideInBytes,
            attributes: [
              gpu.VertexAttribute(name: 'a', format: gpu.VertexFormat.float32x3),
              gpu.VertexAttribute(name: 'b', format: gpu.VertexFormat.float32x3, offsetInBytes: 12),
              gpu.VertexAttribute(name: 't', format: gpu.VertexFormat.float32, offsetInBytes: 24),
              gpu.VertexAttribute(name: 'side', format: gpu.VertexFormat.float32, offsetInBytes: 28),
              gpu.VertexAttribute(name: 'width', format: gpu.VertexFormat.float32, offsetInBytes: 32),
              gpu.VertexAttribute(name: 'color', format: gpu.VertexFormat.float32x4, offsetInBytes: 36),
            ],
          ),
        ],
      ),
    );
    return TerrainGpuWorldRenderer._(terrain, polygon, line);
  }

  final gpu.RenderPipeline _terrainPipeline;
  final gpu.RenderPipeline _polygonPipeline;
  final gpu.RenderPipeline _linePipeline;
  final gpu.HostBuffer _hostBuffer;

  gpu.GpuImageSurface? _surface;
  gpu.Texture? _depth;
  int _surfaceWidth = 0;
  int _surfaceHeight = 0;
  gpu.Texture? _white;

  /// 地形の頂点（ビルダーごと。縁が変わるとビルダーが別物になるので自然に入れ替わる）
  final Map<TerrainMeshBuilder, _TerrainBuffers> _terrain = {};

  /// タイルのテクスチャ（`ui.Image` を包む。コピーしない）
  final Map<ui.Image, _TextureEntry> _textures = {};

  /// 静的な面・線（シーンのリストごと。育ったぶんを足す）
  final Map<List<LiftedPolygon>, _Parts> _polygons = {};
  final Map<List<LiftedPolyline>, _Parts> _lines = {};

  static const _sweepMs = 3000;
  int _lastSweep = 0;

  /// テクスチャを別経路で上げ終えたとき（描き直しの合図）
  VoidCallback? onTextureReady;

  /// 直近のフレームの計測
  Duration lastEncode = Duration.zero;
  Duration lastUpload = Duration.zero;
  int lastDrawCalls = 0;
  int lastUploads = 0;
  String? lastError;

  /// 最後のフレームで使った正射影（カメラ中心基準）。`FrameInfo` の中身
  final Float32List _base = Float32List(16);
  final Float32List _tileMvp = Float32List(16);
  final Float32List _lineInfo = Float32List(20);

  /// 1 フレーム描く。戻り値は Canvas に `drawImageRect` する画像（サーフェスが持つので dispose しない）。
  /// [tiles] は描画順を問わない（深度バッファ）。[heightRange] は世界の標高の範囲（深度の正規化）
  ui.Image? render(
    TerrainCamera camera,
    ui.Size size,
    List<TerrainTileDrawable> tiles, {
    required double pixelRatio,
    required (double, double) heightRange,
    required double centerHeight,
  }) {
    if (tiles.isEmpty) return null;
    final sw = Stopwatch()..start();
    final w = math.max(1, (size.width * pixelRatio).round());
    final h = math.max(1, (size.height * pixelRatio).round());
    if (_surface == null || _surfaceWidth != w || _surfaceHeight != h) {
      _surface = gpu.gpuContext.createImageSurface(w, h);
      var depthFormat = gpu.gpuContext.defaultDepthStencilFormat;
      if (depthFormat == gpu.PixelFormat.unknown) depthFormat = gpu.PixelFormat.d32FloatS8UInt;
      _depth = gpu.gpuContext.createTexture(
        gpu.StorageMode.deviceTransient,
        w,
        h,
        format: depthFormat,
        enableShaderReadUsage: false,
      );
      _surfaceWidth = w;
      _surfaceHeight = h;
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    lastUploads = 0;
    lastUpload = Duration.zero;

    // 1. バッファを揃える（無いものだけ上げる）
    final entries = <_TileEntry>[];
    for (final t in tiles) {
      final builder = t.builder;
      if (builder == null) continue;
      var tb = _terrain[builder];
      if (tb == null) {
        final u = Stopwatch()..start();
        final g = builder.gpuGeometry();
        tb = _TerrainBuffers(
          vertices: gpu.gpuContext.createDeviceBufferWithCopy(ByteData.view(g.vertices.buffer)),
          indices: gpu.gpuContext.createDeviceBufferWithCopy(ByteData.view(g.indices.buffer)),
          indexCount: g.indexCount,
          minZ: g.minZ,
          maxZ: g.maxZ,
        );
        _terrain[builder] = tb;
        lastUpload += u.elapsed;
        lastUploads++;
      }
      tb.lastUsed = nowMs;
      final tex = _textureFor(t.texture, nowMs);
      final polys = t.polygons.isEmpty ? null : _partsFor(_polygons, t.polygons, nowMs, _packPolygons);
      final lines = t.lines.isEmpty ? null : _partsFor(_lines, t.lines, nowMs, _packLines);
      entries.add(_TileEntry(t, tb, tex, polys, lines));
    }
    if (entries.isEmpty) return null;

    // 2. カメラ中心基準の正射影。深度はタイルの箱（xy）× 標高の範囲で [0, 1] に正規化
    final cosB = math.cos(camera.bearing);
    final sinB = math.sin(camera.bearing);
    final cosP = math.cos(camera.pitch);
    final sinP = math.sin(camera.pitch);
    final zs = camera.zScale;
    final pc = camera.project(0, 0, centerHeight);
    final kx = 2 * camera.scale / size.width;
    final ky = 2 * camera.scale / size.height;
    var dMin = double.infinity;
    var dMax = -double.infinity;
    var zLo = heightRange.$1;
    var zHi = heightRange.$2;
    for (final e in entries) {
      if (e.terrain.minZ < zLo) zLo = e.terrain.minZ;
      if (e.terrain.maxZ > zHi) zHi = e.terrain.maxZ;
    }
    final zPad = math.max(10.0, (zHi - zLo) * 0.05);
    zLo -= zPad;
    zHi += zPad;
    for (final e in entries) {
      final ox = e.tile.originX - camera.centerX;
      final oy = e.tile.originY - camera.centerY;
      final dem = e.tile.mesh.dem;
      for (final x in [ox, ox + dem.width]) {
        for (final y in [oy, oy + dem.height]) {
          for (final z in [zLo, zHi]) {
            final d = camera.depth(x, y, z);
            if (d < dMin) dMin = d;
            if (d > dMax) dMax = d;
          }
        }
      }
    }
    final span = math.max(1e-3, dMax - dMin);
    final pad = span * 0.02;
    final kz = 1 / (span + 2 * pad);
    final d0 = dMin - pad;
    final m = _base;
    m.fillRange(0, 16, 0);
    m[0] = kx * cosB;
    m[4] = -kx * sinB;
    m[12] = -kx * pc.dx;
    m[1] = ky * sinB * cosP;
    m[5] = ky * cosB * cosP;
    m[9] = ky * zs * sinP;
    m[13] = ky * pc.dy;
    m[2] = kz * sinB * sinP;
    m[6] = kz * cosB * sinP;
    m[10] = -kz * zs * cosP;
    m[14] = -kz * d0;
    m[15] = 1;

    // 3. タイルごとの mvp（原点の平行移動を畳む）を host buffer に並べる
    _hostBuffer.reset();
    for (final e in entries) {
      final ox = e.tile.originX - camera.centerX;
      final oy = e.tile.originY - camera.centerY;
      final tm = _tileMvp..setAll(0, m);
      tm[12] += m[0] * ox + m[4] * oy;
      tm[13] += m[1] * ox + m[5] * oy;
      tm[14] += m[2] * ox + m[6] * oy;
      e.terrainInfo = _hostBuffer.emplace(ByteData.view(Float32List.fromList(tm).buffer));
      // 面と線は地形と同じ高さにあるので、少し手前に寄せて z-fight を避ける。
      // 面の頂点は細かい DEM で持ち上げ、地形は step で間引いているので、そのぶん（セル幅の半分）は食い違う
      final dem = e.tile.mesh.dem;
      final biasMeters = 2 + dem.cellSize * e.tile.mesh.step * 0.5;
      final bias = kz * biasMeters;
      if (e.polygons != null || e.tile.dynamicPolygons.isNotEmpty) {
        tm[14] -= bias;
        e.polygonInfo = _hostBuffer.emplace(ByteData.view(Float32List.fromList(tm).buffer));
        tm[14] += bias;
      }
      if (e.lines != null || e.tile.dynamicLines.isNotEmpty) {
        final li = _lineInfo;
        li.setAll(0, tm);
        li[14] -= bias * 1.5;
        li[16] = w.toDouble();
        li[17] = h.toDouble();
        li[18] = pixelRatio;
        li[19] = 0;
        e.lineInfo = _hostBuffer.emplace(ByteData.view(Float32List.fromList(li).buffer));
      }
    }

    // 4. 描く
    var draws = 0;
    final commandBuffer = gpu.gpuContext.createCommandBuffer();
    final frame = _surface!.acquireNextFrame();
    final pass = commandBuffer.createRenderPass(
      gpu.RenderTarget.singleColor(
        gpu.ColorAttachment(texture: frame.colorTexture, clearValue: vm.Vector4(0, 0, 0, 0)),
        depthStencilAttachment: gpu.DepthStencilAttachment(texture: _depth!, depthClearValue: 1.0),
      ),
    );
    final sampler = gpu.SamplerOptions(minFilter: gpu.MinMagFilter.linear, magFilter: gpu.MinMagFilter.linear);
    final texSlot = _terrainPipeline.fragmentShader.getUniformSlot('tex');
    final terrainInfoSlot = _terrainPipeline.vertexShader.getUniformSlot('FrameInfo');
    pass.bindPipeline(_terrainPipeline);
    pass.setDepthWriteEnable(true);
    pass.setDepthCompareOperation(gpu.CompareFunction.lessEqual);
    pass.setCullMode(gpu.CullMode.none);
    pass.setColorBlendEnable(false);
    for (final e in entries) {
      pass.bindVertexBuffer(gpu.BufferView(e.terrain.vertices, offsetInBytes: 0, lengthInBytes: e.terrain.vertices.sizeInBytes));
      pass.bindIndexBuffer(gpu.BufferView(e.terrain.indices, offsetInBytes: 0, lengthInBytes: e.terrain.indices.sizeInBytes), gpu.IndexType.int32);
      pass.bindUniform(terrainInfoSlot, e.terrainInfo!);
      pass.bindTexture(texSlot, e.texture, sampler: sampler);
      pass.drawIndexed(e.terrain.indexCount);
      draws++;
    }

    pass.clearBindings();
    pass.bindPipeline(_polygonPipeline);
    pass.setDepthWriteEnable(false);
    pass.setDepthCompareOperation(gpu.CompareFunction.lessEqual);
    pass.setCullMode(gpu.CullMode.none);
    pass.setColorBlendEnable(true);
    final polygonInfoSlot = _polygonPipeline.vertexShader.getUniformSlot('FrameInfo');
    for (final e in entries) {
      final info = e.polygonInfo;
      if (info == null) continue;
      pass.bindUniform(polygonInfoSlot, info);
      final parts = e.polygons;
      if (parts != null) {
        for (final p in parts.parts) {
          pass.bindVertexBuffer(gpu.BufferView(p.vertices, offsetInBytes: 0, lengthInBytes: p.vertices.sizeInBytes));
          pass.draw(p.count);
          draws++;
        }
      }
      if (e.tile.dynamicPolygons.isNotEmpty) {
        final packed = GpuPolygonGeometry.packPolygons(e.tile.dynamicPolygons);
        if (packed.isNotEmpty) {
          pass.bindVertexBuffer(_hostBuffer.emplace(ByteData.view(packed.buffer)));
          pass.draw(GpuPolygonGeometry.vertexCountOf(packed));
          draws++;
        }
      }
    }

    pass.clearBindings();
    pass.bindPipeline(_linePipeline);
    pass.setDepthWriteEnable(false);
    pass.setDepthCompareOperation(gpu.CompareFunction.lessEqual);
    pass.setCullMode(gpu.CullMode.none);
    pass.setColorBlendEnable(true);
    final lineInfoSlot = _linePipeline.vertexShader.getUniformSlot('FrameInfo');
    for (final e in entries) {
      final info = e.lineInfo;
      if (info == null) continue;
      pass.bindUniform(lineInfoSlot, info);
      final parts = e.lines;
      if (parts != null) {
        for (final p in parts.parts) {
          pass.bindVertexBuffer(gpu.BufferView(p.vertices, offsetInBytes: 0, lengthInBytes: p.vertices.sizeInBytes));
          pass.bindIndexBuffer(gpu.BufferView(p.indices!, offsetInBytes: 0, lengthInBytes: p.indices!.sizeInBytes), gpu.IndexType.int32);
          pass.drawIndexed(p.count);
          draws++;
        }
      }
      if (e.tile.dynamicLines.isNotEmpty) {
        final g = GpuLineGeometry.pack(polylines: e.tile.dynamicLines);
        if (!g.isEmpty) {
          pass.bindVertexBuffer(_hostBuffer.emplace(ByteData.view(g.vertices.buffer)));
          pass.bindIndexBuffer(_hostBuffer.emplace(ByteData.view(g.indices.buffer)), gpu.IndexType.int32);
          pass.drawIndexed(g.indexCount);
          draws++;
        }
      }
    }
    frame.present(commandBuffer);
    commandBuffer.submit();
    sw.stop();
    lastEncode = sw.elapsed - lastUpload;
    lastDrawCalls = draws;
    _sweep(nowMs);
    return _surface!.currentImage;
  }

  /// タイルのテクスチャ。`ui.Image` を包めれば（`Picture.toImage` 由来）コピー無し。
  /// 包めなければバイト列で別経路に上げ、届くまでは白
  gpu.Texture _textureFor(ui.Image? image, int nowMs) {
    if (image == null) return _whiteTexture();
    var entry = _textures[image];
    if (entry == null) {
      entry = _TextureEntry();
      _textures[image] = entry;
      try {
        entry.texture = gpu.Texture.fromImage(gpu.gpuContext, image);
      } catch (_) {
        entry.texture = null;
        _uploadTextureBytes(image, entry);
      }
    }
    entry.lastUsed = nowMs;
    return entry.texture ?? _whiteTexture();
  }

  Future<void> _uploadTextureBytes(ui.Image image, _TextureEntry entry) async {
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (bytes == null || !_textures.containsKey(image)) return;
      final tex = gpu.gpuContext.createTexture(
        gpu.StorageMode.hostVisible,
        image.width,
        image.height,
        format: gpu.PixelFormat.r8g8b8a8UNormInt,
        enableRenderTargetUsage: false,
      );
      tex.overwrite(bytes);
      entry.texture = tex;
      onTextureReady?.call();
    } catch (e) {
      lastError = 'texture: $e';
    }
  }

  gpu.Texture _whiteTexture() {
    return _white ??= () {
      final tex = gpu.gpuContext.createTexture(
        gpu.StorageMode.hostVisible,
        1,
        1,
        format: gpu.PixelFormat.r8g8b8a8UNormInt,
        enableRenderTargetUsage: false,
      );
      tex.overwrite(ByteData.view(Uint8List.fromList([255, 255, 255, 255]).buffer));
      return tex;
    }();
  }

  /// [list] の育ったぶんを 1 バッファ足す。1 秒育っていなければ 1 本に畳む（描画呼び出しを減らす）
  _Parts _partsFor<T>(Map<List<T>, _Parts> cache, List<T> list, int nowMs, _PartBuffers? Function(List<T>, int) pack) {
    var parts = cache[list];
    if (parts == null) {
      parts = _Parts();
      cache[list] = parts;
    }
    if (list.length > parts.packed) {
      final u = Stopwatch()..start();
      final p = pack(list, parts.packed);
      if (p != null) parts.parts.add(p);
      parts.packed = list.length;
      parts.lastGrowMs = nowMs;
      lastUpload += u.elapsed;
      lastUploads++;
    } else if (parts.parts.length > 1 && nowMs - parts.lastGrowMs > 1000) {
      final u = Stopwatch()..start();
      final p = pack(list, 0);
      parts.parts
        ..clear()
        ..addAll([?p]);
      lastUpload += u.elapsed;
      lastUploads++;
    }
    parts.lastUsed = nowMs;
    return parts;
  }

  static _PartBuffers? _packPolygons(List<LiftedPolygon> polygons, int from) {
    final packed = GpuPolygonGeometry.packPolygons(polygons, from: from);
    if (packed.isEmpty) return null;
    return _PartBuffers(
      vertices: gpu.gpuContext.createDeviceBufferWithCopy(ByteData.view(packed.buffer)),
      count: GpuPolygonGeometry.vertexCountOf(packed),
    );
  }

  static _PartBuffers? _packLines(List<LiftedPolyline> lines, int from) {
    final g = GpuLineGeometry.pack(polylines: lines.getRange(from, lines.length));
    if (g.isEmpty) return null;
    return _PartBuffers(
      vertices: gpu.gpuContext.createDeviceBufferWithCopy(ByteData.view(g.vertices.buffer)),
      indices: gpu.gpuContext.createDeviceBufferWithCopy(ByteData.view(g.indices.buffer)),
      count: g.indexCount,
    );
  }

  /// しばらく描いていないバッファを手放す（1 秒に 1 回）。DeviceBuffer に dispose は無く GC 任せ
  void _sweep(int nowMs) {
    if (nowMs - _lastSweep < 1000) return;
    _lastSweep = nowMs;
    _terrain.removeWhere((_, v) => nowMs - v.lastUsed > _sweepMs);
    _textures.removeWhere((_, v) => nowMs - v.lastUsed > _sweepMs);
    _polygons.removeWhere((_, v) => nowMs - v.lastUsed > _sweepMs);
    _lines.removeWhere((_, v) => nowMs - v.lastUsed > _sweepMs);
  }

  int get terrainBufferCount => _terrain.length;
  int get textureCount => _textures.length;

  /// 全部手放す（レイヤを閉じるとき）
  void dispose() {
    _terrain.clear();
    _textures.clear();
    _polygons.clear();
    _lines.clear();
    _surface = null;
    _depth = null;
    _white = null;
  }
}

class _TerrainBuffers {
  _TerrainBuffers({required this.vertices, required this.indices, required this.indexCount, required this.minZ, required this.maxZ});

  final gpu.DeviceBuffer vertices;
  final gpu.DeviceBuffer indices;
  final int indexCount;
  final double minZ;
  final double maxZ;
  int lastUsed = 0;
}

class _TextureEntry {
  gpu.Texture? texture;
  int lastUsed = 0;
}

class _PartBuffers {
  _PartBuffers({required this.vertices, this.indices, required this.count});

  final gpu.DeviceBuffer vertices;
  final gpu.DeviceBuffer? indices;

  /// 頂点数（インデックス無し）またはインデックス数
  final int count;
}

class _Parts {
  final List<_PartBuffers> parts = [];
  int packed = 0;
  int lastGrowMs = 0;
  int lastUsed = 0;
}

class _TileEntry {
  _TileEntry(this.tile, this.terrain, this.texture, this.polygons, this.lines);

  final TerrainTileDrawable tile;
  final _TerrainBuffers terrain;
  final gpu.Texture texture;
  final _Parts? polygons;
  final _Parts? lines;
  gpu.BufferView? terrainInfo;
  gpu.BufferView? polygonInfo;
  gpu.BufferView? lineInfo;
}
