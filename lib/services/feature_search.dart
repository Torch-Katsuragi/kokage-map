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
// こかげマップ: 見えているレイヤの属性を横断して探す（林班番号・名前など）
//
// 1. 打った文字の表記ゆれ（全角・半角・大文字小文字・ひらがな／カタカナ）を数通り作り、
//    レイヤごとに SQLite の LIKE で当てる（件数に上限。1 万件のレイヤでも全行を Dart に持ってこない）
// 2. 当たった行の値を正規化して照らし直し、どの列で当たったかと順位（一致・前方一致・部分一致）を決める
//
// ⚠ 1 つの値の中で全角と半角が混ざっている（「第１2林班」など）と LIKE の段で漏れる

import 'dart:typed_data';

import '../models/nodes/feature_node.dart';
import '../models/nodes/layer_node.dart';
import '../utils/app_logger.dart';

/// 検索用の文字の正規化
class SearchText {
  SearchText._();

  static const _halfKana =
      '｡｢｣､･ｦｧｨｩｪｫｬｭｮｯｰｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜﾝ';
  static const _fullKana =
      '。「」、・ヲァィゥェォャュョッーアイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワン';
  static final Map<int, int> _halfToFull = {
    for (var i = 0; i < _halfKana.length; i++) _halfKana.codeUnitAt(i): _fullKana.codeUnitAt(i),
  };
  static final Map<int, int> _fullToHalf = {for (final e in _halfToFull.entries) e.value: e.key};

  static const int _dakuten = 0xFF9E; // ﾞ
  static const int _handakuten = 0xFF9F; // ﾟ

  /// 濁点が付く全角カタカナ（カ〜ト・ハ〜ホ）か
  static bool _takesDakuten(int c) =>
      (c >= 0x30AB && c <= 0x30C1 && (c - 0x30AB).isEven) || // カキクケコサシスセソタチ（ツテトは下）
      c == 0x30C4 || c == 0x30C6 || c == 0x30C8 ||
      (c >= 0x30CF && c <= 0x30DB && (c - 0x30CF) % 3 == 0);

  static bool _takesHandakuten(int c) => c >= 0x30CF && c <= 0x30DB && (c - 0x30CF) % 3 == 0;

  /// 比べるための形: 英数記号は半角・小文字、半角カナは全角、ひらがなはカタカナ、全角空白は半角、前後の空白は落とす
  static String normalize(String s) {
    final out = StringBuffer();
    final cs = s.codeUnits;
    for (var i = 0; i < cs.length; i++) {
      var c = cs[i];
      if (c >= 0xFF01 && c <= 0xFF5E) {
        c -= 0xFEE0;
      } else if (c == 0x3000) {
        c = 0x20;
      } else if (_halfToFull.containsKey(c)) {
        c = _halfToFull[c]!;
        final next = i + 1 < cs.length ? cs[i + 1] : 0;
        if (next == _dakuten && (_takesDakuten(c) || c == 0x30A6)) {
          c = c == 0x30A6 ? 0x30F4 : c + 1;
          i++;
        } else if (next == _handakuten && _takesHandakuten(c)) {
          c += 2;
          i++;
        }
      } else if (c >= 0x3041 && c <= 0x3096) {
        c += 0x60;
      }
      if (c >= 0x41 && c <= 0x5A) c += 0x20;
      out.writeCharCode(c);
    }
    return out.toString().trim();
  }

  /// 半角英数記号 → 全角
  static String toFullWidthAscii(String s) => String.fromCharCodes([
    for (final c in s.codeUnits)
      if (c >= 0x21 && c <= 0x7E) c + 0xFEE0 else if (c == 0x20) 0x3000 else c,
  ]);

  /// カタカナ → ひらがな
  static String toHiragana(String s) => String.fromCharCodes([
    for (final c in s.codeUnits)
      if (c >= 0x30A1 && c <= 0x30F6) c - 0x60 else c,
  ]);

  /// 全角カタカナ → 半角カナ（濁点・半濁点は分ける）
  static String toHalfKana(String s) {
    final out = <int>[];
    for (final c in s.codeUnits) {
      final h = _fullToHalf[c];
      if (h != null) {
        out.add(h);
      } else if (c == 0x30F4) {
        out..add(_fullToHalf[0x30A6]!)..add(_dakuten);
      } else if (_fullToHalf.containsKey(c - 1) && _takesDakuten(c - 1)) {
        out..add(_fullToHalf[c - 1]!)..add(_dakuten);
      } else if (_fullToHalf.containsKey(c - 2) && _takesHandakuten(c - 2)) {
        out..add(_fullToHalf[c - 2]!)..add(_handakuten);
      } else {
        out.add(c);
      }
    }
    return String.fromCharCodes(out);
  }

  /// データベースに書かれていそうな表記を数通り作る（全角・半角、大文字・小文字、ひらがな・カタカナ・半角カナ）
  static List<String> variants(String query) {
    final n = normalize(query);
    if (n.isEmpty) return const [];
    final forms = <String>{query.trim()};
    for (final base in {n, toHiragana(n)}) {
      for (final c in {base, base.toUpperCase()}) {
        forms..add(c)..add(toFullWidthAscii(c))..add(toHalfKana(c));
      }
    }
    return forms.toList();
  }
}

/// 検索の 1 件
class FeatureSearchHit {
  FeatureSearchHit({
    required this.layer,
    required this.feature,
    required this.column,
    required this.value,
    required this.rank,
  });

  final LayerNode layer;
  final FeatureNode feature;

  /// 当たった列と値
  final String column;
  final String value;

  /// 0 = 値がそのまま一致、1 = 前方一致、2 = 部分一致
  final int rank;
}

/// 検索の結果（[truncated] は上限で切ったとき）
class FeatureSearchResult {
  const FeatureSearchResult(this.hits, {this.truncated = false});
  final List<FeatureSearchHit> hits;
  final bool truncated;
}

class FeatureSearch {
  FeatureSearch._();

  /// 値が [normalizedQuery] に当たるか。当たれば順位（[FeatureSearchHit.rank]）、外れなら null
  static int? rankOf(Object? value, String normalizedQuery) {
    if (value == null || value is Uint8List || value is List<int>) return null;
    final v = SearchText.normalize(value.toString());
    if (v == normalizedQuery) return 0;
    if (v.startsWith(normalizedQuery)) return 1;
    if (v.contains(normalizedQuery)) return 2;
    return null;
  }

  /// [layer] の結合した列の値から探す（地物ごとに表を引くだけ。表は読み込みのときに Map にしてある）
  static List<FeatureSearchHit> _searchJoined(LayerNode layer, String normalizedQuery, int perLayer) {
    final hits = <FeatureSearchHit>[];
    for (final f in layer.features) {
      final Map<String, dynamic>? props;
      try {
        props = f.turfFeature.properties;
      } catch (_) {
        continue;
      }
      FeatureSearchHit? best;
      for (final j in layer.joins) {
        final values = j.valuesFor(props?[j.join.targetField]);
        if (values == null) continue;
        for (var i = 0; i < values.length; i++) {
          final r = rankOf(values[i], normalizedQuery);
          if (r != null && (best == null || r < best.rank)) {
            best = FeatureSearchHit(layer: layer, feature: f, column: j.fieldNames[i], value: values[i].toString(), rank: r);
          }
        }
      }
      if (best != null) hits.add(best);
      if (hits.length >= perLayer) break;
    }
    return hits;
  }

  /// [layers] の属性から [query] を探す。レイヤごとに [perLayer] 行まで、全体で [limit] 件まで
  static Future<FeatureSearchResult> search(
    List<LayerNode> layers,
    String query, {
    int perLayer = 200,
    int limit = 100,
  }) async {
    final n = SearchText.normalize(query);
    final forms = SearchText.variants(query);
    if (forms.isEmpty) return const FeatureSearchResult([]);
    final hits = <FeatureSearchHit>[];
    var truncated = false;
    for (final layer in layers) {
      if (layer.isDisposed) continue;
      List<Map<String, Object?>> rows;
      try {
        rows = await layer.geoPackageFile.searchAttributeRows(layer.layerName, forms, limit: perLayer);
      } catch (e) {
        AppLogger.debug('[Search] ${layer.layerName}: $e');
        continue;
      }
      if (rows.length >= perLayer) truncated = true;
      // 結合した表の列（森林簿の樹種など）は gpkg に無いので、読み込んである地物の値を見る
      final joined = layer.joins.isEmpty ? const <FeatureSearchHit>[] : _searchJoined(layer, n, perLayer);
      if (joined.length >= perLayer) truncated = true;
      if (rows.isEmpty && joined.isEmpty) continue;
      // 地図に読み込んである地物だけ（消灯した View の地物は出さない）
      final byId = {for (final f in layer.features) f.rowId: f};
      final hitIds = <int>{};
      for (final row in rows) {
        final f = byId[row['__id']];
        if (f == null) continue;
        FeatureSearchHit? best;
        for (final e in row.entries) {
          if (e.key == '__id') continue;
          final r = rankOf(e.value, n);
          if (r != null && (best == null || r < best.rank)) {
            best = FeatureSearchHit(layer: layer, feature: f, column: e.key, value: e.value.toString(), rank: r);
          }
        }
        if (best != null) {
          hits.add(best);
          hitIds.add(f.rowId);
        }
      }
      for (final hit in joined) {
        if (!hitIds.contains(hit.feature.rowId)) hits.add(hit);
      }
    }
    // 一致 → 前方一致 → 部分一致。同じ順位ならレイヤ順・行順のまま（sort は安定でないので添字で並べる）
    final indexed = [for (var i = 0; i < hits.length; i++) (i, hits[i])]
      ..sort((a, b) => a.$2.rank != b.$2.rank ? a.$2.rank.compareTo(b.$2.rank) : a.$1.compareTo(b.$1));
    if (indexed.length > limit) truncated = true;
    return FeatureSearchResult([for (final e in indexed.take(limit)) e.$2], truncated: truncated);
  }
}
