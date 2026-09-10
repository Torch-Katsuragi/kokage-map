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
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:vector_math/vector_math.dart' as vm;

import '../dem_grid.dart';
import '../terrain_camera.dart';
import '../terrain_painter.dart' show PolygonBatch;
import 'terrain_gpu_stats.dart';

/// `package:flutter_gpu` で地形と面を描くスパイク（Android / iOS / desktop。web は stub）
///
/// 純 Dart の描画系（`TerrainPainter` / `TerrainWorldPainter`）が毎フレーム Dart で頂点を投影して
/// `Vertices.raw` にコピーしているのを、
/// 「頂点はデバイスバッファに一度だけ上げ、毎フレーム変えるのは mvp 行列だけ」に置き換える。
/// 深度バッファがあるので painter's algorithm（象限走査・帯分割・pitch 上限）も要らない。
/// 結果はテクスチャに描いて `ui.Image` として Canvas に合成する。ラベル・ヒットテストは Dart 側のまま。
///
/// 設計は Vault `3D化の詰め_2026-09-07` 12 節、計測は docs/technical/terrain-3d.md。
class TerrainGpuRenderer {
  TerrainGpuRenderer._(this._terrainPipeline, this._polygonPipeline)
      : _hostBuffer = gpu.gpuContext.createHostBuffer(blockLengthInBytes: 4096);

  static const shaderBundleAsset = 'build/shaderbundles/terrain.shaderbundle';

  /// このプラットフォームで使えるか（web は false）
  static bool get isSupported => true;

  /// シェーダ束を読んでパイプラインを組む。Impeller / Flutter GPU が無効なら例外
  static Future<TerrainGpuRenderer> create() async {
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
            strideInBytes: _terrainStride,
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
            strideInBytes: _polygonStride,
            attributes: [
              gpu.VertexAttribute(name: 'position', format: gpu.VertexFormat.float32x3),
              gpu.VertexAttribute(name: 'color', format: gpu.VertexFormat.float32x4, offsetInBytes: 12),
            ],
          ),
        ],
      ),
    );
    return TerrainGpuRenderer._(terrain, polygon);
  }

  /// 地形の頂点: position(3) + uv(2) + shade(1)
  static const _terrainStride = 24;

  /// 面の頂点: position(3) + rgba(4)
  static const _polygonStride = 28;

  final gpu.RenderPipeline _terrainPipeline;
  final gpu.RenderPipeline _polygonPipeline;
  final gpu.HostBuffer _hostBuffer;

  gpu.DeviceBuffer? _terrainVertices;
  gpu.DeviceBuffer? _terrainIndices;
  int _terrainIndexCount = 0;
  int _terrainVertexCount = 0;
  gpu.Texture? _texture;

  gpu.DeviceBuffer? _polygonVertices;
  int _polygonVertexCount = 0;

  gpu.GpuImageSurface? _surface;
  gpu.Texture? _depth;
  int _surfaceWidth = 0;
  int _surfaceHeight = 0;

  /// 深度の範囲を決めるための DEM の箱（原点基準）
  double _extentX = 0;
  double _extentY = 0;
  double _minZ = 0;
  double _maxZ = 0;

  /// 最後のフレームの mvp（ラベルなど Dart 側で画面座標が要るものに使う）
  final Float32List _mvp = Float32List(16);
  bool _hasMvp = false;

  final stats = TerrainGpuStats();

  int get terrainVertexCount => _terrainVertexCount;
  int get polygonVertexCount => _polygonVertexCount;

  /// DEM を頂点バッファに上げる（一度だけ。カメラに依らない）
  ///
  /// [step] は格子の間引き（1 = 全点）。陰影は `TerrainMeshBuilder` と同じ中央差分の法線 × 光源
  void setTerrain(DemGrid dem, {int step = 1, int lightAzimuthDeg = 315, int lightAltitudeDeg = 45}) {
    final cols = (dem.cols - 1) ~/ step + 1;
    final rows = (dem.rows - 1) ~/ step + 1;
    final cell = dem.cellSize * step;
    final heights = Float32List(cols * rows);
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        heights[r * cols + c] = dem.heightAtIndex(c * step, r * step);
      }
    }
    final az = lightAzimuthDeg * math.pi / 180;
    final alt = lightAltitudeDeg * math.pi / 180;
    final lx = math.sin(az) * math.cos(alt);
    final ly = math.cos(az) * math.cos(alt);
    final lz = math.sin(alt);
    final data = Float32List(cols * rows * 6);
    var o = 0;
    var minZ = double.infinity;
    var maxZ = -double.infinity;
    for (var r = 0; r < rows; r++) {
      final rS = r == 0 ? 0 : r - 1;
      final rN = r == rows - 1 ? rows - 1 : r + 1;
      for (var c = 0; c < cols; c++) {
        final cW = c == 0 ? 0 : c - 1;
        final cE = c == cols - 1 ? cols - 1 : c + 1;
        final h = heights[r * cols + c];
        final nx = -(heights[r * cols + cE] - heights[r * cols + cW]) / ((cE - cW) * cell);
        final ny = -(heights[rN * cols + c] - heights[rS * cols + c]) / ((rN - rS) * cell);
        final len = math.sqrt(nx * nx + ny * ny + 1);
        final dot = (nx * lx + ny * ly + lz) / len;
        final shade = (0.35 + 0.65 * dot.clamp(0.0, 1.0)).clamp(0.0, 1.0);
        final x = c * cell;
        final y = r * cell;
        data[o] = x;
        data[o + 1] = y;
        data[o + 2] = h;
        // 画像は北が上なので v を反転
        data[o + 3] = x / dem.width;
        data[o + 4] = 1 - y / dem.height;
        data[o + 5] = shade;
        o += 6;
        if (h < minZ) minZ = h;
        if (h > maxZ) maxZ = h;
      }
    }
    final cellCols = cols - 1;
    final cellRows = rows - 1;
    final indices = Uint32List(cellCols * cellRows * 6);
    var k = 0;
    for (var r = 0; r < cellRows; r++) {
      for (var c = 0; c < cellCols; c++) {
        final sw = r * cols + c;
        final se = sw + 1;
        final nw = sw + cols;
        final ne = nw + 1;
        indices[k++] = sw;
        indices[k++] = se;
        indices[k++] = nw;
        indices[k++] = se;
        indices[k++] = ne;
        indices[k++] = nw;
      }
    }
    _terrainVertices = gpu.gpuContext.createDeviceBufferWithCopy(ByteData.view(data.buffer));
    _terrainIndices = gpu.gpuContext.createDeviceBufferWithCopy(ByteData.view(indices.buffer));
    _terrainIndexCount = indices.length;
    _terrainVertexCount = cols * rows;
    _extentX = dem.width;
    _extentY = dem.height;
    _minZ = minZ;
    _maxZ = maxZ;
  }

  /// 背景テクスチャ（premultiplied RGBA を一度だけ上げる）
  ///
  /// 製品では `gpu.Texture.fromImage` でコピー無しに包める（`toImage` 由来の画像に限る）が、
  /// スパイクでは出所を問わず動くようにバイト列で上げる
  Future<void> setTexture(ui.Image image) async {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (bytes == null) throw StateError('テクスチャのバイト列が取れない');
    final tex = gpu.gpuContext.createTexture(
      gpu.StorageMode.hostVisible,
      image.width,
      image.height,
      format: gpu.PixelFormat.r8g8b8a8UNormInt,
      enableRenderTargetUsage: false,
    );
    tex.overwrite(bytes);
    _texture = tex;
  }

  /// 面の束（座標は DEM 原点基準）を頂点バッファに上げる（一度だけ）
  void setPolygons(List<PolygonBatch> batches) {
    var n = 0;
    for (final b in batches) {
      n += b.xyz.length ~/ 3;
    }
    final data = Float32List(n * 7);
    var o = 0;
    for (final b in batches) {
      final xyz = b.xyz;
      final colors = b.colors;
      for (var v = 0; v < colors.length; v++) {
        final argb = colors[v];
        data[o] = xyz[v * 3];
        data[o + 1] = xyz[v * 3 + 1];
        data[o + 2] = xyz[v * 3 + 2];
        data[o + 3] = ((argb >> 16) & 0xFF) / 255;
        data[o + 4] = ((argb >> 8) & 0xFF) / 255;
        data[o + 5] = (argb & 0xFF) / 255;
        data[o + 6] = ((argb >> 24) & 0xFF) / 255;
        o += 7;
      }
    }
    _polygonVertices = n == 0 ? null : gpu.gpuContext.createDeviceBufferWithCopy(ByteData.view(data.buffer));
    _polygonVertexCount = n;
  }

  /// 1 フレーム描く。戻り値は Canvas に `drawImageRect` する画像（サーフェスが持つので dispose しない）
  ///
  /// [size] は論理 px、[pixelRatio] で物理解像度にする。[origin] は DEM 原点（世界座標）。
  /// [perspective] なら透視投影（画面中心の倍率が [camera.scale] に一致する距離に視点を置く）
  ui.Image? render(
    TerrainCamera camera,
    ui.Size size, {
    required ui.Offset origin,
    required double centerHeight,
    double pixelRatio = 1,
    bool perspective = false,
    double fovDeg = 50,
  }) {
    if (_terrainVertices == null || _texture == null) return null;
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
    if (perspective) {
      _perspectiveMvp(camera, size, origin: origin, centerHeight: centerHeight, fovDeg: fovDeg, out: _mvp);
    } else {
      _orthographicMvp(camera, size, origin: origin, centerHeight: centerHeight, out: _mvp);
    }
    _hasMvp = true;
    _hostBuffer.reset();
    final mvpView = _hostBuffer.emplace(ByteData.view(_mvp.buffer));
    // 面は地形と同じ高さにあるので、深度を少し手前に寄せて z-fight を避ける
    final biased = Float32List.fromList(_mvp);
    biased[14] -= 0.0005 * biased[15];
    final biasedView = _hostBuffer.emplace(ByteData.view(biased.buffer));
    final tUniform = sw.elapsed;

    final commandBuffer = gpu.gpuContext.createCommandBuffer();
    final frame = _surface!.acquireNextFrame();
    final pass = commandBuffer.createRenderPass(
      gpu.RenderTarget.singleColor(
        gpu.ColorAttachment(texture: frame.colorTexture, clearValue: vm.Vector4(0, 0, 0, 0)),
        depthStencilAttachment: gpu.DepthStencilAttachment(texture: _depth!, depthClearValue: 1.0),
      ),
    );
    var draws = 0;

    pass.bindPipeline(_terrainPipeline);
    pass.setDepthWriteEnable(true);
    pass.setDepthCompareOperation(gpu.CompareFunction.lessEqual);
    pass.setCullMode(gpu.CullMode.none);
    pass.setColorBlendEnable(false);
    pass.bindVertexBuffer(
      gpu.BufferView(_terrainVertices!, offsetInBytes: 0, lengthInBytes: _terrainVertices!.sizeInBytes),
    );
    pass.bindIndexBuffer(
      gpu.BufferView(_terrainIndices!, offsetInBytes: 0, lengthInBytes: _terrainIndices!.sizeInBytes),
      gpu.IndexType.int32,
    );
    pass.bindUniform(_terrainPipeline.vertexShader.getUniformSlot('FrameInfo'), mvpView);
    pass.bindTexture(
      _terrainPipeline.fragmentShader.getUniformSlot('tex'),
      _texture!,
      sampler: gpu.SamplerOptions(minFilter: gpu.MinMagFilter.linear, magFilter: gpu.MinMagFilter.linear),
    );
    pass.drawIndexed(_terrainIndexCount);
    draws++;

    if (_polygonVertices != null) {
      pass.clearBindings();
      pass.bindPipeline(_polygonPipeline);
      pass.setDepthWriteEnable(false);
      pass.setDepthCompareOperation(gpu.CompareFunction.lessEqual);
      pass.setCullMode(gpu.CullMode.none);
      pass.setColorBlendEnable(true);
      pass.bindVertexBuffer(
        gpu.BufferView(_polygonVertices!, offsetInBytes: 0, lengthInBytes: _polygonVertices!.sizeInBytes),
      );
      pass.bindUniform(_polygonPipeline.vertexShader.getUniformSlot('FrameInfo'), biasedView);
      pass.draw(_polygonVertexCount);
      draws++;
    }
    frame.present(commandBuffer);
    commandBuffer.submit();
    sw.stop();
    stats
      ..uniform = tUniform
      ..encode = sw.elapsed - tUniform
      ..drawCalls = draws
      ..terrainVertices = _terrainVertexCount
      ..polygonVertices = _polygonVertexCount;
    return _surface!.currentImage;
  }

  /// 最後の mvp で DEM 原点基準の点を画面座標（論理 px）に落とす。画面の裏側なら null
  ui.Offset? toScreen(double x, double y, double z, ui.Size size) {
    if (!_hasMvp) return null;
    final m = _mvp;
    final cx = m[0] * x + m[4] * y + m[8] * z + m[12];
    final cy = m[1] * x + m[5] * y + m[9] * z + m[13];
    final cw = m[3] * x + m[7] * y + m[11] * z + m[15];
    if (cw <= 1e-6) return null;
    return ui.Offset((cx / cw + 1) / 2 * size.width, (1 - cy / cw) / 2 * size.height);
  }

  /// 正射影。`TerrainCamera.project` と同じ幾何（真上 = 2D 地図）を行列にしたもの。
  /// 奥行き `depth` は視線方向の距離（`TerrainCamera.depth`）を DEM の箱の範囲で [0, 1] に正規化
  void _orthographicMvp(
    TerrainCamera camera,
    ui.Size size, {
    required ui.Offset origin,
    required double centerHeight,
    required Float32List out,
  }) {
    final cosB = math.cos(camera.bearing);
    final sinB = math.sin(camera.bearing);
    final cosP = math.cos(camera.pitch);
    final sinP = math.sin(camera.pitch);
    final zs = camera.zScale;
    final pc = camera.project(camera.centerX - origin.dx, camera.centerY - origin.dy, centerHeight);
    final kx = 2 * camera.scale / size.width;
    final ky = 2 * camera.scale / size.height;
    // 深度の範囲: DEM の箱の 8 隅
    var dMin = double.infinity;
    var dMax = -double.infinity;
    for (final x in [0.0, _extentX]) {
      for (final y in [0.0, _extentY]) {
        for (final z in [_minZ, _maxZ]) {
          final d = camera.depth(x, y, z);
          if (d < dMin) dMin = d;
          if (d > dMax) dMax = d;
        }
      }
    }
    final span = math.max(1e-3, dMax - dMin);
    final pad = span * 0.02;
    final kz = 1 / (span + 2 * pad);
    final d0 = dMin - pad;
    out.fillRange(0, 16, 0);
    // 行 0: X = kx·(cosB·x − sinB·y) − kx·pcx
    out[0] = kx * cosB;
    out[4] = -kx * sinB;
    out[12] = -kx * pc.dx;
    // 行 1: Y = ky·(sinB·cosP·x + cosB·cosP·y + zs·sinP·z) + ky·pcy（NDC は上が +）
    out[1] = ky * sinB * cosP;
    out[5] = ky * cosB * cosP;
    out[9] = ky * zs * sinP;
    out[13] = ky * pc.dy;
    // 行 2: Z = kz·(sinB·sinP·x + cosB·sinP·y − zs·cosP·z − d0)
    out[2] = kz * sinB * sinP;
    out[6] = kz * cosB * sinP;
    out[10] = -kz * zs * cosP;
    out[14] = -kz * d0;
    out[15] = 1;
  }

  /// 透視投影。画面中心（高さ [centerHeight]）で 1 m = [camera.scale] px になる距離に視点を置く
  void _perspectiveMvp(
    TerrainCamera camera,
    ui.Size size, {
    required ui.Offset origin,
    required double centerHeight,
    required double fovDeg,
    required Float32List out,
  }) {
    final fov = fovDeg * math.pi / 180;
    final dist = (size.height / 2) / camera.scale / math.tan(fov / 2);
    final sinB = math.sin(camera.bearing);
    final cosB = math.cos(camera.bearing);
    final sinP = math.sin(camera.pitch);
    final cosP = math.cos(camera.pitch);
    final zs = camera.zScale;
    final cx = camera.centerX - origin.dx;
    final cy = camera.centerY - origin.dy;
    // 標高は zs 倍した空間で扱う（Mercator の水平の伸びに合わせる）
    final target = vm.Vector3(cx, cy, centerHeight * zs);
    final eye = vm.Vector3(cx - sinB * dist * sinP, cy - cosB * dist * sinP, centerHeight * zs + dist * cosP);
    final view = vm.makeViewMatrix(eye, target, vm.Vector3(0, 0, 1));
    final near = math.max(1.0, dist * 0.02);
    final far = dist * 60;
    final proj = vm.makePerspectiveMatrix(fov, size.width / size.height, near, far);
    // OpenGL の z ∈ [−1, 1] を Impeller の [0, 1] に
    final toUnit = vm.Matrix4.identity()
      ..setEntry(2, 2, 0.5)
      ..setEntry(2, 3, 0.5);
    final model = vm.Matrix4.identity()..setEntry(2, 2, zs);
    final mvp = toUnit * proj * view * model;
    out.setAll(0, mvp.storage);
  }

  /// GPU 側のバッファは GC 任せ（DeviceBuffer に dispose が無い）。サーフェスの参照だけ切る
  void dispose() {
    _surface = null;
    _depth = null;
    _terrainVertices = null;
    _terrainIndices = null;
    _polygonVertices = null;
    _texture = null;
  }
}
