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
import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:ui_web' as ui_web;

import 'package:flutter/foundation.dart';
import 'package:vector_math/vector_math.dart' as vm;
import 'package:web/web.dart' as web;

import '../terrain_appearance.dart';
import '../terrain_camera.dart';
import '../terrain_lifted.dart';
import '../terrain_mesh.dart';
import '../terrain_scene.dart';
import '../terrain_world_painter.dart' show TerrainTileDrawable;
import 'frame_projection.dart';
import 'gpu_geometry.dart';
import 'part_cache.dart';

/// web 版の GPU 描画系（WebGL2 を `package:web` で直接叩く）
///
/// Android の `terrain_gpu_world.dart`（flutter_gpu）と同じ API・同じ頂点データ（`gpu_geometry.dart`）で、
/// シェーダだけ GLSL ES 3.00 で書き直したもの。描画先は自前の `<canvas>`（[platformViewType] の `HtmlElementView`）で、
/// Flutter はその上に点とラベルを Canvas で描く（`render` は画像を返さない）。
/// ミップマップは `generateMipmap`、MSAA はマルチサンプルの renderbuffer から既定の framebuffer へ blit。
/// 設計は docs/technical/terrain-3d.md「web の GPU」
class TerrainGpuWorldRenderer {
  TerrainGpuWorldRenderer._(this._canvas, this._gl, this.platformViewType);

  static bool get isSupported => true;
  static int _instances = 0;

  /// WebGL2 の canvas を作って platform view として登録する。WebGL2 が無ければ例外
  static Future<TerrainGpuWorldRenderer> create() async {
    final canvas = web.HTMLCanvasElement()
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.pointerEvents = 'none';
    final attrs = <String, Object>{'alpha': true, 'premultipliedAlpha': true, 'antialias': false, 'depth': false, 'stencil': false};
    final gl = canvas.getContext('webgl2', attrs.jsify()) as web.WebGL2RenderingContext?;
    if (gl == null) throw StateError('WebGL2 が使えない');
    final viewType = 'kokage-terrain-gl-${_instances++}';
    ui_web.platformViewRegistry.registerViewFactory(viewType, (int viewId) => canvas);
    final r = TerrainGpuWorldRenderer._(canvas, gl, viewType);
    r._setup();
    return r;
  }

  /// `HtmlElementView(viewType: ...)` で地図面に置く canvas（Android 版は null）
  final String? platformViewType;

  final web.HTMLCanvasElement _canvas;
  final web.WebGL2RenderingContext _gl;

  late final _Program _terrain;
  late final _Program _polygon;
  late final _Program _line;
  late final _Program _point;
  web.WebGLTexture? _white;
  web.WebGLFramebuffer? _fbo;
  web.WebGLRenderbuffer? _color;
  web.WebGLRenderbuffer? _depth;
  int _w = 0;
  int _h = 0;
  bool _anisotropy = false;

  final Map<TerrainMeshBuilder, _TerrainBuffers> _terrainBuffers = {};
  final Map<Object, _TextureEntry> _textures = {};
  late final _polygons = GpuPartCache<LiftedPolygon, _PartBuffers>((p) => p.dispose(_gl));
  late final _lines = GpuPartCache<LiftedPolyline, _PartBuffers>((p) => p.dispose(_gl));
  late final _points = GpuPartCache<TerrainPoint, _PartBuffers>((p) => p.dispose(_gl));
  late final _segments = GpuPartCache<LiftedSegments, _PartBuffers>((p) => p.dispose(_gl));
  static const _sweepMs = 3000;
  int _lastSweep = 0;

  VoidCallback? onTextureReady;
  void Function(Object textureKey)? onTextureUploaded;
  Duration lastEncode = Duration.zero;
  Duration lastUpload = Duration.zero;
  int lastDrawCalls = 0;
  int lastUploads = 0;
  String? lastError;
  bool _loggedTexture = false;

  /// 切り分け用（スパイク画面から触る）: 深度テストを切る / MSAA を通さず直接 canvas に描く / 毎フレーム getError を見る
  static bool debugNoDepth = false;
  static bool debugDirect = false;
  static bool debugCheckErrors = false;
  static bool debugFlush = false;

  final Float32List _base = Float32List(16);

  int get terrainBufferCount => _terrainBuffers.length;
  int get textureCount => _textures.length;
  int get mippedTextureCount => _textures.values.where((e) => e.ready).length;
  bool get msaa => true;

  void pruneTextures(Set<Object> liveKeys) {
    _textures.removeWhere((k, v) {
      if (liveKeys.contains(k)) return false;
      if (v.texture != null) _gl.deleteTexture(v.texture);
      return true;
    });
  }

  void _setup() {
    final gl = _gl;
    _terrain = _Program(gl, _terrainVert, _terrainFrag, ['position', 'uv', 'shade', 'slope'], ['u_mvp', 'u_params', 'tex', 'ramp', 'u_color_a', 'u_color_b']);
    _polygon = _Program(gl, _polygonVert, _colorFrag, ['position', 'color'], ['u_mvp', 'u_params']);
    _line = _Program(gl, _lineVert, _lineFrag, ['a', 'b', 't', 'side', 'width', 'color', 'arc', 'dash'], ['u_mvp', 'u_viewport', 'u_pixel_ratio', 'u_params']);
    _point = _Program(gl, _pointVert, _pointFrag, ['position', 'corner', 'size', 'color', 'outline_color', 'marker_style'], ['u_mvp', 'u_viewport', 'u_pixel_ratio']);
    _anisotropy = gl.getExtension('EXT_texture_filter_anisotropic') != null;
    gl.pixelStorei(_G.UNPACK_PREMULTIPLY_ALPHA_WEBGL, 0);
  }

  /// 1 フレーム描く。canvas に直接描くので画像は返さない（呼び出し側は何も敷かない）
  ui.Image? render(
    TerrainCamera camera,
    ui.Size size,
    List<TerrainTileDrawable> tiles, {
    required double pixelRatio,
    required (double, double) heightRange,
    required double centerHeight,
  }) {
    if (tiles.isEmpty) return null;
    final gl = _gl;
    final sw = Stopwatch()..start();
    final w = math.max(1, (size.width * pixelRatio).round());
    final h = math.max(1, (size.height * pixelRatio).round());
    if (w != _w || h != _h) _resize(w, h);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    lastUploads = 0;
    lastUpload = Duration.zero;

    // 1. バッファを揃える
    final entries = <_TileEntry>[];
    for (final t in tiles) {
      final builder = t.builder;
      if (builder == null) continue;
      var tb = _terrainBuffers[builder];
      if (tb == null) {
        final u = Stopwatch()..start();
        final g = builder.gpuGeometry();
        tb = _TerrainBuffers(
          vertices: _upload(gl, _G.ARRAY_BUFFER, g.vertices.toJS),
          indices: _upload(gl, _G.ELEMENT_ARRAY_BUFFER, g.indices.toJS),
          indexCount: g.indexCount,
          minZ: g.minZ,
          maxZ: g.maxZ,
        );
        _terrainBuffers[builder] = tb;
        lastUpload += u.elapsed;
        lastUploads++;
      }
      tb.lastUsed = nowMs;
      final tex = _textureFor(t.textureKey, t.texture, t.previousTextureKey);
      final polys = t.polygons.isEmpty ? null : _partsFor(_polygons, t.polygons, nowMs, _packPolygons);
      final lines = t.lines.isEmpty ? null : _partsFor(_lines, t.lines, nowMs, _packLines);
      final dem = t.mesh.dem;
      final points = t.points.isEmpty
          ? null
          : _partsFor(_points, t.points, nowMs, (list, from) => _packPoints(list, from, (x, y) => dem.elevationAt(x + dem.originX, y + dem.originY)));
      final segments = t.segmentSets.isEmpty ? null : _partsFor(_segments, t.segmentSets, nowMs, _packSegments);
      entries.add(_TileEntry(t, tb, tex, polys, lines, points, segments));
    }
    if (entries.isEmpty) return null;

    // 2. カメラ中心基準の投影（[writeBaseProjection]。Android 版・web 版で共通）
    final persp = camera.perspective && camera.viewport != ui.Size.zero;
    final m = _base;
    final kz = writeBaseProjection(
      m,
      camera,
      size,
      centerHeight: centerHeight,
      heightRange: heightRange,
      tiles: [
        for (final e in entries)
          (
            originX: e.tile.originX,
            originY: e.tile.originY,
            width: e.tile.mesh.dem.width,
            height: e.tile.mesh.dem.height,
            minZ: e.terrain.minZ,
            maxZ: e.terrain.maxZ,
          ),
      ],
    );
    // Impeller の NDC z ∈ [0, 1] に合わせた行列を WebGL の [-1, 1] へ（z' = 2z − w）
    final toGl = vm.Matrix4.identity()
      ..setEntry(2, 2, 2)
      ..setEntry(2, 3, -1);
    final mg = toGl.multiplied(vm.Matrix4.fromFloat32List(m)).storage;
    m.setAll(0, mg);

    for (final e in entries) {
      final ox = e.tile.originX - camera.centerX;
      final oy = e.tile.originY - camera.centerY;
      final tm = Float32List.fromList(m);
      tm[12] += m[0] * ox + m[4] * oy;
      tm[13] += m[1] * ox + m[5] * oy;
      tm[14] += m[2] * ox + m[6] * oy;
      tm[15] += m[3] * ox + m[7] * oy;
      e.terrainMvp = tm;
      final dem = e.tile.mesh.dem;
      final biasMeters = 2 + dem.cellSize * e.tile.mesh.step * 0.5;
      final bias = 2 * (persp ? 0.0005 * camera.eyeDistance : kz * biasMeters);
      e.polygonMvp = Float32List.fromList(tm)..[14] -= bias;
      e.lineMvp = Float32List.fromList(tm)..[14] -= bias * 1.5;
    }

    // 3. 描く
    gl.bindFramebuffer(_G.FRAMEBUFFER, debugDirect ? null : _fbo);
    gl.viewport(0, 0, w, h);
    if (persp) {
      gl.clearColor(0.78, 0.86, 0.95, 1);
    } else {
      gl.clearColor(0, 0, 0, 0);
    }
    gl.clearDepth(1);
    gl.depthMask(true); // ⚠ clear は書き込みマスクに従う。前のフレームの面・線で false のままだと深度が残り、回すと地形が欠ける
    gl.clear(_G.COLOR_BUFFER_BIT | _G.DEPTH_BUFFER_BIT);
    if (debugNoDepth) {
      gl.disable(_G.DEPTH_TEST);
    } else {
      gl.enable(_G.DEPTH_TEST);
    }
    gl.depthFunc(_G.LEQUAL);
    gl.disable(_G.CULL_FACE);
    var draws = 0;

    // 地形
    gl.useProgram(_terrain.program);
    gl.depthMask(true);
    gl.disable(_G.BLEND);
    final eyeDist = persp ? camera.eyeDistance : 0.0;
    final params = (
      TerrainShading.blend == TerrainShadeBlend.overlay ? 1.0 : 0.0,
      eyeDist * TerrainCamera.fogStartFactor,
      eyeDist * TerrainCamera.fogEndFactor,
      persp ? 1.0 : 0.0,
    );
    gl.uniform4f(_terrain.uniform('u_params'), params.$1, params.$2, params.$3, params.$4);
    gl.uniform1i(_terrain.uniform('tex'), 0);
    // 色分け（TerrainAppearance）
    var zMin = double.infinity;
    var zMax = -double.infinity;
    for (final e in entries) {
      if (e.terrain.minZ < zMin) zMin = e.terrain.minZ;
      if (e.terrain.maxZ > zMax) zMax = e.terrain.maxZ;
    }
    gl.uniform4f(
      _terrain.uniform('u_color_a'),
      TerrainAppearance.colored ? TerrainAppearance.colorMode.index.toDouble() : 0,
      TerrainAppearance.colorStrength,
      zMin.isFinite ? zMin : 0,
      zMax.isFinite ? zMax : 1,
    );
    gl.uniform4f(_terrain.uniform('u_color_b'), TerrainAppearance.slopeMaxDeg, 0, 0, 0);
    gl.uniform1i(_terrain.uniform('ramp'), 1);
    gl.activeTexture(_G.TEXTURE1);
    gl.bindTexture(_G.TEXTURE_2D, _rampTexture());
    gl.activeTexture(_G.TEXTURE0);
    for (final e in entries) {
      gl.bindBuffer(_G.ARRAY_BUFFER, e.terrain.vertices);
      _terrain.attribs(gl, GpuTerrainGeometry.strideInBytes, [('position', 3, 0), ('uv', 2, 12), ('shade', 1, 20), ('slope', 1, 24)]);
      gl.bindBuffer(_G.ELEMENT_ARRAY_BUFFER, e.terrain.indices);
      gl.uniformMatrix4fv(_terrain.uniform('u_mvp'), false, e.terrainMvp!.toJS);
      gl.bindTexture(_G.TEXTURE_2D, e.texture);
      gl.drawElements(_G.TRIANGLES, e.terrain.indexCount, _G.UNSIGNED_INT, 0);
      draws++;
    }

    // 面
    gl.depthMask(false);
    gl.enable(_G.BLEND);
    gl.blendFunc(_G.ONE, _G.ONE_MINUS_SRC_ALPHA);
    gl.useProgram(_polygon.program);
    gl.uniform4f(_polygon.uniform('u_params'), params.$1, params.$2, params.$3, params.$4);
    for (final e in entries) {
      if (e.polygons == null && e.tile.dynamicPolygons.isEmpty) continue;
      gl.uniformMatrix4fv(_polygon.uniform('u_mvp'), false, e.polygonMvp!.toJS);
      final parts = e.polygons;
      if (parts != null) {
        for (final p in parts.parts) {
          gl.bindBuffer(_G.ARRAY_BUFFER, p.vertices);
          _polygon.attribs(gl, GpuPolygonGeometry.strideInBytes, [('position', 3, 0), ('color', 4, 12)]);
          gl.drawArrays(_G.TRIANGLES, 0, p.count);
          draws++;
        }
      }
      if (e.tile.dynamicPolygons.isNotEmpty) {
        final packed = GpuPolygonGeometry.packPolygons(e.tile.dynamicPolygons);
        if (packed.isNotEmpty) {
          final buf = _upload(gl, _G.ARRAY_BUFFER, packed.toJS, dynamic: true);
          _polygon.attribs(gl, GpuPolygonGeometry.strideInBytes, [('position', 3, 0), ('color', 4, 12)]);
          gl.drawArrays(_G.TRIANGLES, 0, GpuPolygonGeometry.vertexCountOf(packed));
          gl.deleteBuffer(buf);
          draws++;
        }
      }
    }

    // 線
    gl.useProgram(_line.program);
    gl.uniform2f(_line.uniform('u_viewport'), w.toDouble(), h.toDouble());
    gl.uniform1f(_line.uniform('u_pixel_ratio'), pixelRatio);
    gl.uniform4f(_line.uniform('u_params'), params.$1, params.$2, params.$3, params.$4);
    const lineAttribs = [
      ('a', 3, 0),
      ('b', 3, 12),
      ('t', 1, 24),
      ('side', 1, 28),
      ('width', 1, 32),
      ('color', 4, 36),
      ('arc', 2, 52),
      ('dash', 4, 60),
    ];
    for (final e in entries) {
      if (e.lines == null && e.segments == null && e.tile.dynamicLines.isEmpty) continue;
      gl.uniformMatrix4fv(_line.uniform('u_mvp'), false, e.lineMvp!.toJS);
      for (final parts in [e.segments, e.lines]) {
        if (parts == null) continue;
        for (final p in parts.parts) {
          gl.bindBuffer(_G.ARRAY_BUFFER, p.vertices);
          _line.attribs(gl, GpuLineGeometry.strideInBytes, lineAttribs);
          gl.bindBuffer(_G.ELEMENT_ARRAY_BUFFER, p.indices);
          gl.drawElements(_G.TRIANGLES, p.count, _G.UNSIGNED_INT, 0);
          draws++;
        }
      }
      if (e.tile.dynamicLines.isNotEmpty) {
        final g = GpuLineGeometry.pack(polylines: e.tile.dynamicLines);
        if (!g.isEmpty) {
          final vb = _upload(gl, _G.ARRAY_BUFFER, g.vertices.toJS, dynamic: true);
          final ib = _upload(gl, _G.ELEMENT_ARRAY_BUFFER, g.indices.toJS, dynamic: true);
          _line.attribs(gl, GpuLineGeometry.strideInBytes, lineAttribs);
          gl.drawElements(_G.TRIANGLES, g.indexCount, _G.UNSIGNED_INT, 0);
          gl.deleteBuffer(vb);
          gl.deleteBuffer(ib);
          draws++;
        }
      }
    }

    // 点
    gl.useProgram(_point.program);
    gl.uniform2f(_point.uniform('u_viewport'), w.toDouble(), h.toDouble());
    gl.uniform1f(_point.uniform('u_pixel_ratio'), pixelRatio);
    const pointAttribs = [
      ('position', 3, 0),
      ('corner', 2, 12),
      ('size', 1, 20),
      ('color', 4, 24),
      ('outline_color', 4, 40),
      ('marker_style', 4, 56),
    ];
    for (final e in entries) {
      final parts = e.points;
      if (parts == null) continue;
      gl.uniformMatrix4fv(_point.uniform('u_mvp'), false, e.lineMvp!.toJS);
      for (final p in parts.parts) {
        gl.bindBuffer(_G.ARRAY_BUFFER, p.vertices);
        _point.attribs(gl, GpuPointGeometry.strideInBytes, pointAttribs);
        gl.bindBuffer(_G.ELEMENT_ARRAY_BUFFER, p.indices);
        gl.drawElements(_G.TRIANGLES, p.count, _G.UNSIGNED_INT, 0);
        draws++;
      }
    }

    // 4. MSAA を既定の framebuffer（canvas）へ
    if (!debugDirect) {
      gl.bindFramebuffer(_G.READ_FRAMEBUFFER, _fbo);
      gl.bindFramebuffer(_G.DRAW_FRAMEBUFFER, null);
      gl.blitFramebuffer(0, 0, w, h, 0, 0, w, h, _G.COLOR_BUFFER_BIT, _G.NEAREST);
      gl.bindFramebuffer(_G.FRAMEBUFFER, null);
    }
    if (debugFlush) gl.flush();
    if (debugCheckErrors) {
      final err = gl.getError();
      if (err != 0) lastError = 'gl error 0x${err.toRadixString(16)} (frame ${DateTime.now().millisecondsSinceEpoch})';
    }

    sw.stop();
    lastEncode = sw.elapsed - lastUpload;
    lastDrawCalls = draws;
    _sweep(nowMs);
    return null;
  }

  void _resize(int w, int h) {
    final gl = _gl;
    _canvas.width = w;
    _canvas.height = h;
    _w = w;
    _h = h;
    if (_fbo != null) {
      gl.deleteFramebuffer(_fbo);
      gl.deleteRenderbuffer(_color);
      gl.deleteRenderbuffer(_depth);
    }
    final samples = math.min(4, (gl.getParameter(_G.MAX_SAMPLES) as JSNumber?)?.toDartInt ?? 0);
    _fbo = gl.createFramebuffer();
    _color = gl.createRenderbuffer();
    _depth = gl.createRenderbuffer();
    gl.bindRenderbuffer(_G.RENDERBUFFER, _color);
    gl.renderbufferStorageMultisample(_G.RENDERBUFFER, samples, _G.RGBA8, w, h);
    gl.bindRenderbuffer(_G.RENDERBUFFER, _depth);
    gl.renderbufferStorageMultisample(_G.RENDERBUFFER, samples, _G.DEPTH_COMPONENT24, w, h);
    gl.bindFramebuffer(_G.FRAMEBUFFER, _fbo);
    gl.framebufferRenderbuffer(_G.FRAMEBUFFER, _G.COLOR_ATTACHMENT0, _G.RENDERBUFFER, _color);
    gl.framebufferRenderbuffer(_G.FRAMEBUFFER, _G.DEPTH_ATTACHMENT, _G.RENDERBUFFER, _depth);
    gl.bindFramebuffer(_G.FRAMEBUFFER, null);
  }

  web.WebGLTexture _textureFor(Object key, ui.Image? image, Object? previousKey) {
    var entry = _textures[key];
    if (entry == null) {
      if (image == null) return _whiteTexture();
      entry = _TextureEntry();
      _textures[key] = entry;
      unawaited(_uploadTexture(key, image, entry));
    }
    // 転送中は前の世代を描く（焼き直しのたびに基図ごと白く抜けない）。前の世代も無ければ白
    return entry.texture ?? _textures[previousKey]?.texture ?? _whiteTexture();
  }

  /// [key] の世代が GPU に上がっているか（呼び出し側が前の世代を捨ててよいかの判断に使う）
  bool isTextureReady(Object key) => _textures[key]?.ready ?? false;

  Future<void> _uploadTexture(Object key, ui.Image image, _TextureEntry entry) async {
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (bytes == null || !identical(_textures[key], entry)) return;
        final gl = _gl;
      final tex = gl.createTexture()!;
      gl.bindTexture(_G.TEXTURE_2D, tex);
      final u8 = bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
      gl.texImage2D(_G.TEXTURE_2D, 0, _G.RGBA, image.width.toJS, image.height.toJS, 0.toJS, _G.RGBA, _G.UNSIGNED_BYTE, u8.toJS);
      gl.generateMipmap(_G.TEXTURE_2D);
      gl.texParameteri(_G.TEXTURE_2D, _G.TEXTURE_MIN_FILTER, _G.LINEAR_MIPMAP_LINEAR);
      gl.texParameteri(_G.TEXTURE_2D, _G.TEXTURE_MAG_FILTER, _G.LINEAR);
      gl.texParameteri(_G.TEXTURE_2D, _G.TEXTURE_WRAP_S, _G.CLAMP_TO_EDGE);
      gl.texParameteri(_G.TEXTURE_2D, _G.TEXTURE_WRAP_T, _G.CLAMP_TO_EDGE);
      if (_anisotropy) gl.texParameterf(_G.TEXTURE_2D, 0x84FE, 4); // TEXTURE_MAX_ANISOTROPY_EXT
      entry.texture = tex;
      entry.ready = true;
      if (!_loggedTexture) {
        _loggedTexture = true;
        debugPrint('[3D] webgl2 texture ${image.width}x${image.height} mips auto anisotropy $_anisotropy');
      }
      onTextureUploaded?.call(key);
      onTextureReady?.call();
    } catch (e) {
      lastError = 'texture: $e';
      debugPrint('[3D] webgl2 texture の作成に失敗: $e');
    }
  }

  web.WebGLTexture _whiteTexture() {
    if (_white != null) return _white!;
    final gl = _gl;
    final tex = gl.createTexture()!;
    gl.bindTexture(_G.TEXTURE_2D, tex);
    gl.texImage2D(_G.TEXTURE_2D, 0, _G.RGBA, 1.toJS, 1.toJS, 0.toJS, _G.RGBA, _G.UNSIGNED_BYTE, Uint8List.fromList([255, 255, 255, 255]).toJS);
    gl.texParameteri(_G.TEXTURE_2D, _G.TEXTURE_MIN_FILTER, _G.NEAREST);
    gl.texParameteri(_G.TEXTURE_2D, _G.TEXTURE_MAG_FILTER, _G.NEAREST);
    _white = tex;
    return tex;
  }

  /// 束のバッファ（[GpuPartCache.partsFor]）。上げ直した時間は計測に足す
  GpuParts<_PartBuffers> _partsFor<T>(
    GpuPartCache<T, _PartBuffers> cache,
    List<T> list,
    int nowMs,
    _PartBuffers? Function(List<T>, int) pack,
  ) {
    final (parts, took) = cache.partsFor(list, nowMs, pack);
    if (took != null) {
      lastUpload += took;
      lastUploads++;
    }
    return parts;
  }

  _PartBuffers? _packPolygons(List<LiftedPolygon> polygons, int from) {
    final packed = GpuPolygonGeometry.packPolygons(polygons, from: from);
    if (packed.isEmpty) return null;
    return _PartBuffers(vertices: _upload(_gl, _G.ARRAY_BUFFER, packed.toJS), count: GpuPolygonGeometry.vertexCountOf(packed));
  }

  _PartBuffers? _packSegments(List<LiftedSegments> sets, int from) {
    final g = GpuLineGeometry.pack(segmentSets: sets.getRange(from, sets.length));
    if (g.isEmpty) return null;
    return _PartBuffers(
      vertices: _upload(_gl, _G.ARRAY_BUFFER, g.vertices.toJS),
      indices: _upload(_gl, _G.ELEMENT_ARRAY_BUFFER, g.indices.toJS),
      count: g.indexCount,
    );
  }

  /// 色分けのランプ（256×1）。設定が変わったら作り直す
  web.WebGLTexture? _ramp;
  int _rampRevision = -1;

  web.WebGLTexture _rampTexture() {
    final rev = TerrainAppearance.revision.value;
    if (_ramp == null || _rampRevision != rev) {
      final gl = _gl;
      if (_ramp != null) gl.deleteTexture(_ramp);
      final tex = gl.createTexture()!;
      gl.bindTexture(_G.TEXTURE_2D, tex);
      gl.texImage2D(_G.TEXTURE_2D, 0, _G.RGBA, 256.toJS, 1.toJS, 0.toJS, _G.RGBA, _G.UNSIGNED_BYTE, TerrainAppearance.rampBytes().toJS);
      gl.texParameteri(_G.TEXTURE_2D, _G.TEXTURE_MIN_FILTER, _G.LINEAR);
      gl.texParameteri(_G.TEXTURE_2D, _G.TEXTURE_MAG_FILTER, _G.LINEAR);
      gl.texParameteri(_G.TEXTURE_2D, _G.TEXTURE_WRAP_S, _G.CLAMP_TO_EDGE);
      gl.texParameteri(_G.TEXTURE_2D, _G.TEXTURE_WRAP_T, _G.CLAMP_TO_EDGE);
      _ramp = tex;
      _rampRevision = rev;
    }
    return _ramp!;
  }

  _PartBuffers? _packLines(List<LiftedPolyline> lines, int from) {
    final g = GpuLineGeometry.pack(polylines: lines.getRange(from, lines.length));
    if (g.isEmpty) return null;
    return _PartBuffers(
      vertices: _upload(_gl, _G.ARRAY_BUFFER, g.vertices.toJS),
      indices: _upload(_gl, _G.ELEMENT_ARRAY_BUFFER, g.indices.toJS),
      count: g.indexCount,
    );
  }

  _PartBuffers? _packPoints(List<TerrainPoint> points, int from, double Function(double, double) elevationAt) {
    final g = GpuPointGeometry.pack(points, from: from, elevationAt: elevationAt);
    if (g.isEmpty) return null;
    return _PartBuffers(
      vertices: _upload(_gl, _G.ARRAY_BUFFER, g.vertices.toJS),
      indices: _upload(_gl, _G.ELEMENT_ARRAY_BUFFER, g.indices.toJS),
      count: g.indexCount,
    );
  }

  static web.WebGLBuffer _upload(web.WebGL2RenderingContext gl, int target, JSAny data, {bool dynamic = false}) {
    final buf = gl.createBuffer()!;
    gl.bindBuffer(target, buf);
    gl.bufferData(target, data, dynamic ? _G.STREAM_DRAW : _G.STATIC_DRAW);
    return buf;
  }

  void _sweep(int nowMs) {
    if (nowMs - _lastSweep < 1000) return;
    _lastSweep = nowMs;
    final gl = _gl;
    _terrainBuffers.removeWhere((_, v) {
      if (nowMs - v.lastUsed <= _sweepMs) return false;
      gl.deleteBuffer(v.vertices);
      gl.deleteBuffer(v.indices);
      return true;
    });
    for (final c in [_polygons, _lines, _points, _segments]) {
      c.sweep(nowMs, _sweepMs);
    }
  }

  void dispose() {
    final gl = _gl;
    for (final v in _terrainBuffers.values) {
      gl.deleteBuffer(v.vertices);
      gl.deleteBuffer(v.indices);
    }
    _terrainBuffers.clear();
    for (final v in _textures.values) {
      if (v.texture != null) gl.deleteTexture(v.texture);
    }
    _textures.clear();
    for (final c in [_polygons, _lines, _points, _segments]) {
      c.clear();
    }
    if (_fbo != null) {
      gl.deleteFramebuffer(_fbo);
      gl.deleteRenderbuffer(_color);
      gl.deleteRenderbuffer(_depth);
      _fbo = null;
    }
  }
}

/// シェーダ 1 組と、属性・uniform の位置
class _Program {
  _Program(web.WebGL2RenderingContext gl, String vert, String frag, List<String> attribNames, List<String> uniformNames) {
    final vs = _compile(gl, _G.VERTEX_SHADER, vert);
    final fs = _compile(gl, _G.FRAGMENT_SHADER, frag);
    program = gl.createProgram()!;
    gl.attachShader(program, vs);
    gl.attachShader(program, fs);
    gl.linkProgram(program);
    if (!((gl.getProgramParameter(program, _G.LINK_STATUS) as JSBoolean?)?.toDart ?? false)) {
      throw StateError('シェーダのリンクに失敗: ${gl.getProgramInfoLog(program)}');
    }
    for (final a in attribNames) {
      _attribs[a] = gl.getAttribLocation(program, a);
    }
    for (final u in uniformNames) {
      _uniforms[u] = gl.getUniformLocation(program, u);
    }
  }

  late final web.WebGLProgram program;
  final Map<String, int> _attribs = {};
  final Map<String, web.WebGLUniformLocation?> _uniforms = {};

  web.WebGLUniformLocation? uniform(String name) => _uniforms[name];

  /// 束ねた頂点バッファの属性を有効にする（(名前, 要素数, バイト位置)）。
  /// 前のプログラムが有効にした余りの属性は切る（有効なままだと別のバッファを指したまま範囲検査に掛かる）
  void attribs(web.WebGL2RenderingContext gl, int stride, List<(String, int, int)> layout) {
    var used = 0;
    for (final (name, n, offset) in layout) {
      final loc = _attribs[name]!;
      if (loc < 0) continue;
      gl.enableVertexAttribArray(loc);
      gl.vertexAttribPointer(loc, n, _G.FLOAT, false, stride, offset);
      used |= 1 << loc;
    }
    for (var loc = 0; loc < _maxAttribs; loc++) {
      if (used & (1 << loc) == 0 && _enabled & (1 << loc) != 0) gl.disableVertexAttribArray(loc);
    }
    _enabled = used;
  }

  static const _maxAttribs = 12;
  static int _enabled = 0; // コンテキスト全体の状態なので static

  static web.WebGLShader _compile(web.WebGL2RenderingContext gl, int type, String src) {
    final sh = gl.createShader(type)!;
    gl.shaderSource(sh, src);
    gl.compileShader(sh);
    if (!((gl.getShaderParameter(sh, _G.COMPILE_STATUS) as JSBoolean?)?.toDart ?? false)) {
      throw StateError('シェーダのコンパイルに失敗: ${gl.getShaderInfoLog(sh)}\n$src');
    }
    return sh;
  }
}

class _TerrainBuffers {
  _TerrainBuffers({required this.vertices, required this.indices, required this.indexCount, required this.minZ, required this.maxZ});
  final web.WebGLBuffer vertices;
  final web.WebGLBuffer indices;
  final int indexCount;
  final double minZ;
  final double maxZ;
  int lastUsed = 0;
}

class _TextureEntry {
  web.WebGLTexture? texture;
  bool ready = false;
}

class _PartBuffers {
  _PartBuffers({required this.vertices, this.indices, required this.count});
  final web.WebGLBuffer vertices;
  final web.WebGLBuffer? indices;
  final int count;
  void dispose(web.WebGL2RenderingContext gl) {
    gl.deleteBuffer(vertices);
    if (indices != null) gl.deleteBuffer(indices);
  }
}

class _TileEntry {
  _TileEntry(this.tile, this.terrain, this.texture, this.polygons, this.lines, this.points, this.segments);
  final TerrainTileDrawable tile;
  final _TerrainBuffers terrain;
  final web.WebGLTexture texture;
  final GpuParts<_PartBuffers>? polygons;
  final GpuParts<_PartBuffers>? lines;
  final GpuParts<_PartBuffers>? points;
  final GpuParts<_PartBuffers>? segments;
  Float32List? terrainMvp;
  Float32List? polygonMvp;
  Float32List? lineMvp;
}

/// WebGL の定数（`web.WebGL2RenderingContext.X` の短縮）
typedef _G = web.WebGL2RenderingContext;

// ── シェーダ（GLSL ES 3.00。shaders/*.vert|frag と同じ計算） ──

const _terrainVert = '''#version 300 es
uniform mat4 u_mvp;
in vec3 position;
in vec2 uv;
in float shade;
in float slope;
out vec2 v_uv;
out float v_shade;
out float v_w;
out float v_slope;
out float v_height;
void main() {
  v_uv = uv;
  v_shade = shade;
  v_slope = slope;
  v_height = position.z;
  gl_Position = u_mvp * vec4(position, 1.0);
  v_w = gl_Position.w;
}
''';

const _terrainFrag = '''#version 300 es
precision mediump float;
uniform sampler2D tex;
uniform sampler2D ramp;
uniform vec4 u_params;
uniform vec4 u_color_a;
uniform vec4 u_color_b;
in vec2 v_uv;
in float v_shade;
in float v_w;
in float v_slope;
in float v_height;
out vec4 frag_color;
const vec3 kSky = vec3(0.78, 0.86, 0.95);
void main() {
  vec4 c = texture(tex, v_uv);
  float a = max(c.a, 1e-4);
  vec3 base = c.rgb / a;
  if (u_color_a.x > 0.5) {
    float t = u_color_a.x > 1.5
        ? clamp((v_height - u_color_a.z) / max(u_color_a.w - u_color_a.z, 1.0), 0.0, 1.0)
        : clamp(v_slope * 90.0 / max(u_color_b.x, 1.0), 0.0, 1.0);
    vec3 rc = texture(ramp, vec2(t, 0.5)).rgb;
    base = mix(base, rc, u_color_a.y);
  }
  vec3 g = vec3(v_shade);
  vec3 lo = 2.0 * base * g;
  vec3 hi = 1.0 - 2.0 * (1.0 - base) * (1.0 - g);
  vec3 overlay = mix(lo, hi, step(0.5, base));
  vec3 multiply = base * clamp(2.0 * v_shade, 0.0, 1.0);
  vec3 o = mix(multiply, overlay, u_params.x);
  if (u_params.w > 0.5) {
    float fog = smoothstep(u_params.y, u_params.z, v_w);
    o = mix(o, kSky, fog);
  }
  frag_color = vec4(o * c.a, c.a);
}
''';

const _polygonVert = '''#version 300 es
uniform mat4 u_mvp;
in vec3 position;
in vec4 color;
out vec4 v_color;
out float v_w;
void main() {
  v_color = color;
  gl_Position = u_mvp * vec4(position, 1.0);
  v_w = gl_Position.w;
}
''';

const _colorFrag = '''#version 300 es
precision mediump float;
uniform vec4 u_params;
in vec4 v_color;
in float v_w;
out vec4 frag_color;
void main() {
  float a = v_color.a;
  if (u_params.w > 0.5) a *= 1.0 - smoothstep(u_params.y, u_params.z, v_w);
  frag_color = vec4(v_color.rgb * a, a);
}
''';

const _lineVert = '''#version 300 es
precision highp float;
uniform mat4 u_mvp;
uniform vec2 u_viewport;
uniform float u_pixel_ratio;
in vec3 a;
in vec3 b;
in float t;
in float side;
in float width;
in vec4 color;
in vec2 arc;
in vec4 dash;
out vec4 v_color;
out vec2 v_local;
out vec2 v_extent;
out float v_w;
out float v_arc_lpx;
out vec4 v_dash;
void main() {
  vec4 pa = u_mvp * vec4(a, 1.0);
  vec4 pb = u_mvp * vec4(b, 1.0);
  vec2 half_viewport = u_viewport * 0.5;
  vec2 sa = pa.xy / pa.w * half_viewport;
  vec2 sb = pb.xy / pb.w * half_viewport;
  vec2 dir = sb - sa;
  float len = length(dir);
  dir = len > 0.0001 ? dir / len : vec2(1.0, 0.0);
  vec2 normal = vec2(-dir.y, dir.x);
  vec4 p = mix(pa, pb, t);
  float pr = max(u_pixel_ratio, 0.001);
  float half_width = width * pr * 0.5;
  float along = t * 2.0 - 1.0;
  vec2 offset = (normal * side + dir * along) * half_width;
  p.xy += offset / half_viewport * p.w;
  gl_Position = p;
  v_color = color;
  v_local = vec2(t * len + along * half_width, side * half_width);
  v_extent = vec2(len, half_width);
  v_w = p.w;
  float horiz_px_per_m = length(vec2(u_mvp[0].x, u_mvp[1].x)) * half_viewport.x / max(abs(p.w), 0.001);
  float lpx_per_m = horiz_px_per_m / pr;
  v_arc_lpx = mix(arc.x, arc.y, t) * lpx_per_m + along * (width * 0.5);
  v_dash = dash;
}
''';

const _lineFrag = '''#version 300 es
precision highp float;
uniform vec4 u_params;
in vec4 v_color;
in vec2 v_local;
in vec2 v_extent;
in float v_w;
in float v_arc_lpx;
in vec4 v_dash;
out vec4 frag_color;

float dash_interval_alpha(float s, float center, float half_len, float period) {
  float d = abs(mod(s - center + 0.5 * period, period) - 0.5 * period) - half_len;
  return 1.0 - smoothstep(-0.5, 0.5, d);
}

float eval_dash_alpha(float s, vec4 d) {
  float on1 = d.x;
  float off1 = d.y;
  if (abs(d.z) < 0.01) {
    float p = max(on1 + off1, 1.0);
    return dash_interval_alpha(s, 0.5 * on1, 0.5 * on1, p);
  }
  if (d.z > 0.0) {
    float on2 = d.z;
    float off2 = max(d.w, 0.5);
    float p = max(on1 + off1 + on2 + off2, 1.0);
    float a1 = dash_interval_alpha(s, 0.5 * on1, 0.5 * on1, p);
    float a2 = dash_interval_alpha(s, on1 + off1 + 0.5 * on2, 0.5 * on2, p);
    return max(a1, a2);
  }
  float on2 = -d.z;
  float off2 = max(d.w, 0.5);
  float p = max(on1 + off1 + 2.0 * (on2 + off2), 1.0);
  float a1 = dash_interval_alpha(s, 0.5 * on1, 0.5 * on1, p);
  float a2 = dash_interval_alpha(s, on1 + off1 + 0.5 * on2, 0.5 * on2, p);
  float a3 = dash_interval_alpha(s, on1 + off1 + on2 + off2 + 0.5 * on2, 0.5 * on2, p);
  return max(a1, max(a2, a3));
}

void main() {
  float len = v_extent.x;
  float hw = v_extent.y;
  float ax = clamp(v_local.x, 0.0, len);
  float d = length(vec2(v_local.x - ax, v_local.y));
  float alpha = 1.0 - smoothstep(hw - 1.0, hw, d);
  if (v_dash.x > 0.0) {
    alpha *= eval_dash_alpha(v_arc_lpx, v_dash);
  }
  if (alpha <= 0.001) discard;
  float a = v_color.a * alpha;
  if (u_params.w > 0.5) a *= 1.0 - smoothstep(u_params.y, u_params.z, v_w);
  frag_color = vec4(v_color.rgb * a, a);
}
''';

const _pointVert = '''#version 300 es
precision highp float;
uniform mat4 u_mvp;
uniform vec2 u_viewport;
uniform float u_pixel_ratio;
in vec3 position;
in vec2 corner;
in float size;
in vec4 color;
in vec4 outline_color;
in vec4 marker_style;
out vec4 v_color;
out vec4 v_outline_color;
out vec2 v_offset;
out vec3 v_style;
void main() {
  vec4 p = u_mvp * vec4(position, 1.0);
  float r = size * u_pixel_ratio;
  float edge = max(marker_style.x, 0.0) * u_pixel_ratio;
  float extent = r * 1.2 + edge * 0.5 + 1.5;
  vec2 half_viewport = u_viewport * 0.5;
  p.xy += corner * extent / half_viewport * p.w;
  gl_Position = p;
  v_color = color;
  v_outline_color = outline_color;
  vec2 raw_off = corner * extent;
  float ang = marker_style.z;
  float ca = cos(ang);
  float sa = sin(ang);
  v_offset = vec2(ca * raw_off.x - sa * raw_off.y, sa * raw_off.x + ca * raw_off.y);
  v_style = vec3(r, edge, marker_style.y);
}
''';

const _pointFrag = '''#version 300 es
precision highp float;
in vec4 v_color;
in vec4 v_outline_color;
in vec2 v_offset;
in vec3 v_style;
out vec4 frag_color;

float sd_box(vec2 p, vec2 b) {
  vec2 d = abs(p) - b;
  return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

float sd_equilateral_triangle(vec2 p, float r) {
  const float k = 1.7320508;
  vec2 tp = vec2(abs(p.x) - r * 0.8660254, p.y + r * 0.5);
  if (tp.x + k * tp.y > 0.0) {
    tp = vec2(tp.x - k * tp.y, -k * tp.x - tp.y) * 0.5;
  }
  tp.x -= clamp(tp.x, -r * 1.7320508, 0.0);
  return -length(tp) * sign(tp.y);
}

float sd_star5(vec2 p, float r, float rf) {
  const vec2 k1 = vec2(0.809016994375, -0.587785252292);
  const vec2 k2 = vec2(-0.809016994375, -0.587785252292);
  vec2 sp = vec2(abs(p.x), p.y);
  sp -= 2.0 * max(dot(k1, sp), 0.0) * k1;
  sp -= 2.0 * max(dot(k2, sp), 0.0) * k2;
  sp.x = abs(sp.x);
  sp.y -= r;
  vec2 ba = rf * vec2(-k1.y, k1.x) - vec2(0.0, 1.0);
  float h = clamp(dot(sp, ba) / dot(ba, ba), 0.0, r);
  return length(sp - ba * h) * sign(sp.y * ba.x - sp.x * ba.y);
}

float sd_marker(vec2 q, float r, int shape) {
  if (shape == 1) return sd_box(q, vec2(r * 0.88));
  if (shape == 2) {
    vec2 rq = vec2((q.x + q.y) * 0.70710678, (q.y - q.x) * 0.70710678);
    return sd_box(rq, vec2(r * 1.08 * 0.70710678));
  }
  if (shape == 3) return sd_equilateral_triangle(q, r * 1.12);
  if (shape == 4) return sd_star5(q, r * 1.15, 0.42);
  if (shape == 5) {
    float th = max(r * 0.28, 1.0);
    return min(sd_box(q, vec2(r, th)), sd_box(q, vec2(th, r)));
  }
  if (shape == 6) {
    vec2 rq = vec2((q.x + q.y) * 0.70710678, (q.y - q.x) * 0.70710678);
    float th = max(r * 0.28, 1.0);
    return min(sd_box(rq, vec2(r, th)), sd_box(rq, vec2(th, r)));
  }
  return length(q) - r;
}

void main() {
  float r = v_style.x;
  float edge = v_style.y;
  int shape = int(v_style.z + 0.5);
  float d = sd_marker(v_offset, r, shape);

  if (edge > 0.01 && v_outline_color.a > 0.0) {
    float outer = edge * 0.5;
    float alpha = 1.0 - smoothstep(outer - 1.0, outer, d);
    if (alpha <= 0.001) discard;
    float ring = smoothstep(-edge * 0.5 - 0.5, -edge * 0.5 + 0.5, d);
    vec4 pm_fill = vec4(v_color.rgb * v_color.a, v_color.a);
    vec4 pm_out = vec4(v_outline_color.rgb * v_outline_color.a, v_outline_color.a);
    vec4 pm = mix(pm_fill, pm_out, ring) * alpha;
    if (pm.a <= 0.001) discard;
    frag_color = pm;
  } else {
    float alpha = 1.0 - smoothstep(-1.0, 0.0, d);
    float a = v_color.a * alpha;
    if (a <= 0.001) discard;
    frag_color = vec4(v_color.rgb * a, a);
  }
}
''';
