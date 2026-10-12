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
// こかげマップ: 見えているレイヤの属性を探して、選んだ地物へ飛ぶ（レイヤ一覧のタイトルバーの虫眼鏡から）

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../i18n/strings.g.dart';
import '../models/nodes/feature_node.dart';
import '../models/nodes/layer_node.dart';
import '../presentation/feature_display_name.dart';
import '../presentation/node_presenter.dart';
import '../providers/ui_state_providers.dart';
import '../services/feature_search.dart';

/// 検索の窓を開き、選んだ地物を返す（閉じたら null）
Future<FeatureNode?> showFeatureSearchDialog(BuildContext context, WidgetRef ref) {
  final layers = <LayerNode>[
    for (final l in ref.read(folderTreeProvider)?.getVisibleLayerNodes() ?? const [])
      if (l is LayerNode && !l.isDisposed && l.hasVisibleView) l,
  ];
  return showDialog<FeatureNode>(
    context: context,
    builder: (_) => FeatureSearchDialog(layers: layers),
  );
}

class FeatureSearchDialog extends StatefulWidget {
  const FeatureSearchDialog({super.key, required this.layers});

  final List<LayerNode> layers;

  @override
  State<FeatureSearchDialog> createState() => _FeatureSearchDialogState();
}

class _FeatureSearchDialogState extends State<FeatureSearchDialog> {
  static const _limit = 100;

  final _controller = TextEditingController();
  Timer? _debounce;
  FeatureSearchResult? _result;
  bool _busy = false;

  /// 打つたびに走らせないよう、手が止まってから探す。古い問い合わせの結果は捨てる
  int _run = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), _search);
  }

  Future<void> _search() async {
    _debounce?.cancel();
    final q = _controller.text;
    final run = ++_run;
    if (SearchText.normalize(q).isEmpty) {
      setState(() {
        _result = null;
        _busy = false;
      });
      return;
    }
    setState(() => _busy = true);
    final r = await FeatureSearch.search(widget.layers, q, limit: _limit);
    if (!mounted || run != _run) return;
    setState(() {
      _result = r;
      _busy = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tr = t.map.search;
    final r = _result;
    return AlertDialog(
      title: Text(tr.title),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      content: SizedBox(
        width: 420,
        height: 420,
        child: Column(
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              decoration: InputDecoration(
                hintText: tr.hint,
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                border: const OutlineInputBorder(),
              ),
              textInputAction: TextInputAction.search,
              onChanged: _onChanged,
              onSubmitted: (_) => _search(),
            ),
            const SizedBox(height: 6),
            if (_busy) const LinearProgressIndicator(minHeight: 2) else const SizedBox(height: 2),
            const SizedBox(height: 4),
            Expanded(child: _buildBody(r)),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(t.common.close)),
      ],
    );
  }

  Widget _buildBody(FeatureSearchResult? r) {
    final tr = t.map.search;
    Widget note(String s) => Align(
      alignment: Alignment.topLeft,
      child: Text(s, style: const TextStyle(color: Colors.black54, fontSize: 13)),
    );
    if (widget.layers.isEmpty) return note(tr.noLayers);
    if (r == null) return note(tr.scope);
    if (r.hits.isEmpty) return note(tr.noHits);
    return Column(
      children: [
        if (r.truncated) note(tr.truncated(n: r.hits.length)),
        Expanded(
          child: ListView.separated(
            itemCount: r.hits.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final h = r.hits[i];
              // 表示名（無ければ当たった列以外の列）で見分ける。name 列の無いレイヤで「名前なし」が並んでいた
              final id = featureIdentifier(h.feature, excludeColumn: h.column, exclude: h.value);
              return ListTile(
                dense: true,
                leading: Icon(NodePresenter.getIcon(h.feature), size: 20),
                title: Text('${h.column}: ${h.value}', maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  id == null ? h.layer.name : '${h.layer.name} › $id',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.of(context).pop(h.feature),
              );
            },
          ),
        ),
      ],
    );
  }
}
