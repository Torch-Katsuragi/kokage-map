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

import '../terrain_camera.dart';
import '../terrain_mesh.dart';
import '../terrain_painter.dart';
import '../terrain_scene.dart';
import '../terrain_world_painter.dart' show TerrainTileDrawable;
import 'gpu_geometry.dart';

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
  final Map<List<LiftedPolygon>, _Parts> _polygons = {};
  final Map<List<LiftedPolyline>, _Parts> _lines = {};
  final Map<List<TerrainPoint>, _Parts> _points = {};
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
    _terrain = _Program(gl, _terrainVert, _terrainFrag, ['position', 'uv', 'shade'], ['u_mvp', 'u_params', 'tex']);
    _polygon = _Program(gl, _polygonVert, _colorFrag, ['position', 'color'], ['u_mvp', 'u_params']);
    _line = _Program(gl, _lineVert, _lineFrag, ['a', 'b', 't', 'side', 'width', 'color'], ['u_mvp', 'u_viewport', 'u_pixel_ratio', 'u_params']);
    _point = _Program(gl, _pointVert, _pointFrag, ['position', 'corner', 'size', 'color'], ['u_mvp', 'u_viewport', 'u_pixel_ratio']);
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
      final tex = _textureFor(t.textureKey, t.texture);
      final polys = t.polygons.isEmpty ? null : _partsFor(_polygons, t.polygons, nowMs, _packPolygons);
      final lines = t.lines.isEmpty ? null : _partsFor(_lines, t.lines, nowMs, _packLines);
      final dem = t.mesh.dem;
      final points = t.points.isEmpty
          ? null
          : _partsFor(_points, t.points, nowMs, (list, from) => _packPoints(list, from, (x, y) => dem.elevationAt(x + dem.originX, y + dem.originY)));
      entries.add(_TileEntry(t, tb, tex, polys, lines, points));
    }
    if (entries.isEmpty) return null;

    // 2. 投影（Android 版と同じ式）
    final zs = camera.zScale;
    final persp = camera.perspective && camera.viewport != ui.Size.zero;
    final m = _base;
    var kz = 0.0;
    if (persp) {
      final toUnit = vm.Matrix4.identity()
        ..setEntry(2, 2, 0.5)
        ..setEntry(2, 3, 0.5);
      final model = vm.Matrix4.identity()..setEntry(2, 2, zs);
      // WebGL の NDC z は [-1, 1] なので toUnit は要らないが、深度バイアスの式を Android と揃えるため [0,1] に畳んでから戻す
      final mvp = toUnit.multiplied(camera.perspectiveViewProjection(centerHeight)).multiplied(model);
      m.setAll(0, mvp.storage);
    } else {
      final cosB = math.cos(camera.bearing);
      final sinB = math.sin(camera.bearing);
      final cosP = math.cos(camera.pitch);
      final sinP = math.sin(camera.pitch);
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
      kz = 1 / (span + 2 * pad);
      final d0 = dMin - pad;
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
    }
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
    gl.activeTexture(_G.TEXTURE0);
    for (final e in entries) {
      gl.bindBuffer(_G.ARRAY_BUFFER, e.terrain.vertices);
      _terrain.attribs(gl, GpuTerrainGeometry.strideInBytes, [('position', 3, 0), ('uv', 2, 12), ('shade', 1, 20)]);
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
    const lineAttribs = [('a', 3, 0), ('b', 3, 12), ('t', 1, 24), ('side', 1, 28), ('width', 1, 32), ('color', 4, 36)];
    for (final e in entries) {
      if (e.lines == null && e.tile.dynamicLines.isEmpty) continue;
      gl.uniformMatrix4fv(_line.uniform('u_mvp'), false, e.lineMvp!.toJS);
      final parts = e.lines;
      if (parts != null) {
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
    for (final e in entries) {
      final parts = e.points;
      if (parts == null) continue;
      gl.uniformMatrix4fv(_point.uniform('u_mvp'), false, e.lineMvp!.toJS);
      for (final p in parts.parts) {
        gl.bindBuffer(_G.ARRAY_BUFFER, p.vertices);
        _point.attribs(gl, GpuPointGeometry.strideInBytes, [('position', 3, 0), ('corner', 2, 12), ('size', 1, 20), ('color', 4, 24)]);
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

  web.WebGLTexture _textureFor(Object key, ui.Image? image) {
    var entry = _textures[key];
    if (entry == null) {
      if (image == null) return _whiteTexture();
      entry = _TextureEntry();
      _textures[key] = entry;
      unawaited(_uploadTexture(key, image, entry));
    }
    return entry.texture ?? _whiteTexture();
  }

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
      for (final p in parts.parts) {
        p.dispose(_gl);
      }
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

  _PartBuffers? _packPolygons(List<LiftedPolygon> polygons, int from) {
    final packed = GpuPolygonGeometry.packPolygons(polygons, from: from);
    if (packed.isEmpty) return null;
    return _PartBuffers(vertices: _upload(_gl, _G.ARRAY_BUFFER, packed.toJS), count: GpuPolygonGeometry.vertexCountOf(packed));
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
    for (final cache in [_polygons, _lines, _points]) {
      cache.removeWhere((_, v) {
        if (nowMs - v.lastUsed <= _sweepMs) return false;
        for (final p in v.parts) {
          p.dispose(gl);
        }
        return true;
      });
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
    for (final cache in [_polygons, _lines, _points]) {
      for (final v in cache.values) {
        for (final p in v.parts) {
          p.dispose(gl);
        }
      }
      cache.clear();
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

  static const _maxAttribs = 8;
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

class _Parts {
  final List<_PartBuffers> parts = [];
  int packed = 0;
  int lastGrowMs = 0;
  int lastUsed = 0;
}

class _TileEntry {
  _TileEntry(this.tile, this.terrain, this.texture, this.polygons, this.lines, this.points);
  final TerrainTileDrawable tile;
  final _TerrainBuffers terrain;
  final web.WebGLTexture texture;
  final _Parts? polygons;
  final _Parts? lines;
  final _Parts? points;
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
out vec2 v_uv;
out float v_shade;
out float v_w;
void main() {
  v_uv = uv;
  v_shade = shade;
  gl_Position = u_mvp * vec4(position, 1.0);
  v_w = gl_Position.w;
}
''';

const _terrainFrag = '''#version 300 es
precision mediump float;
uniform sampler2D tex;
uniform vec4 u_params;
in vec2 v_uv;
in float v_shade;
in float v_w;
out vec4 frag_color;
const vec3 kSky = vec3(0.78, 0.86, 0.95);
void main() {
  vec4 c = texture(tex, v_uv);
  float a = max(c.a, 1e-4);
  vec3 base = c.rgb / a;
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
uniform mat4 u_mvp;
uniform vec2 u_viewport;
uniform float u_pixel_ratio;
in vec3 a;
in vec3 b;
in float t;
in float side;
in float width;
in vec4 color;
out vec4 v_color;
out vec2 v_local;
out vec2 v_extent;
out float v_w;
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
  float half_width = width * u_pixel_ratio * 0.5;
  float along = t * 2.0 - 1.0;
  vec2 offset = (normal * side + dir * along) * half_width;
  p.xy += offset / half_viewport * p.w;
  gl_Position = p;
  v_color = color;
  v_local = vec2(t * len + along * half_width, side * half_width);
  v_extent = vec2(len, half_width);
  v_w = p.w;
}
''';

const _lineFrag = '''#version 300 es
precision mediump float;
uniform vec4 u_params;
in vec4 v_color;
in vec2 v_local;
in vec2 v_extent;
in float v_w;
out vec4 frag_color;
void main() {
  float len = v_extent.x;
  float hw = v_extent.y;
  float ax = clamp(v_local.x, 0.0, len);
  float d = length(vec2(v_local.x - ax, v_local.y));
  float alpha = 1.0 - smoothstep(hw - 1.0, hw, d);
  if (alpha <= 0.0) discard;
  float a = v_color.a * alpha;
  if (u_params.w > 0.5) a *= 1.0 - smoothstep(u_params.y, u_params.z, v_w);
  frag_color = vec4(v_color.rgb * a, a);
}
''';

const _pointVert = '''#version 300 es
uniform mat4 u_mvp;
uniform vec2 u_viewport;
uniform float u_pixel_ratio;
in vec3 position;
in vec2 corner;
in float size;
in vec4 color;
out vec4 v_color;
out vec2 v_offset;
out vec2 v_radius;
void main() {
  vec4 p = u_mvp * vec4(position, 1.0);
  float r = size * u_pixel_ratio;
  float edge = 1.5 * u_pixel_ratio;
  float extent = r + edge * 0.5 + 1.0;
  vec2 half_viewport = u_viewport * 0.5;
  p.xy += corner * extent / half_viewport * p.w;
  gl_Position = p;
  v_color = color;
  v_offset = corner * extent;
  v_radius = vec2(r, edge);
}
''';

const _pointFrag = '''#version 300 es
precision mediump float;
in vec4 v_color;
in vec2 v_offset;
in vec2 v_radius;
out vec4 frag_color;
void main() {
  float d = length(v_offset);
  float r = v_radius.x;
  float edge = v_radius.y;
  float outer = r + edge * 0.5;
  float alpha = 1.0 - smoothstep(outer - 1.0, outer, d);
  if (alpha <= 0.0) discard;
  float ring = smoothstep(r - edge * 0.5 - 0.5, r - edge * 0.5 + 0.5, d);
  vec4 c = mix(v_color, vec4(1.0), ring);
  float a = c.a * alpha;
  frag_color = vec4(c.rgb * a, a);
}
''';
