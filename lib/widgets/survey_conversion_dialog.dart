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
/// 測量ポイント→ライン/ポリゴン変換ダイアログ
///
/// survey_stn チェーンを解決し、補正オプション（偏角・閉合補正・高さ）を
/// 選択したうえでライン/ポリゴンに変換する。
library;

import 'package:flutter/material.dart';
import '../i18n/strings.g.dart';
import '../models/nodes/layer_node.dart';
import '../presentation/node_presenter.dart';
import '../services/survey/survey_chain_resolver.dart';
import '../services/survey/traverse_adjuster.dart';
import '../utils/wmm_declination.dart';

/// ダイアログの戻り値
class SurveyConversionResult {
  final LayerNode targetLayer;
  final TraverseChain chain;
  final TraverseAdjustmentOptions options;
  final String? featureName;

  /// 閉合トラバースとして処理するか（起点に接続して閉合差を補正）
  final bool closePath;

  const SurveyConversionResult({
    required this.targetLayer,
    required this.chain,
    required this.options,
    this.featureName,
    this.closePath = false,
  });
}

class SurveyConversionDialog extends StatefulWidget {
  final PointLayerNode sourceLayer;
  final List<TraverseChain> chains;
  final List<LayerNode> availableLayers;

  const SurveyConversionDialog({
    super.key,
    required this.sourceLayer,
    required this.chains,
    required this.availableLayers,
  });

  @override
  State<SurveyConversionDialog> createState() => _SurveyConversionDialogState();
}

class _SurveyConversionDialogState extends State<SurveyConversionDialog> {
  late TraverseChain _selectedChain;
  late LayerNode _selectedLayer;
  bool _closePath = false;
  AdjustmentMethod _method = AdjustmentMethod.none;
  bool _useDeclination = true;
  bool _useHeightCorrection = false;
  final _declinationCtrl = TextEditingController(text: '0.0');
  final _instrumentHeightCtrl = TextEditingController(text: '0.0');
  final _targetHeightCtrl = TextEditingController(text: '0.0');
  final _nameCtrl = TextEditingController();

  /// OFFなら必ず0 -- テキストフィールドの値は無視する
  double get _declination =>
      _useDeclination ? (double.tryParse(_declinationCtrl.text) ?? 0) : 0;

  @override
  void initState() {
    super.initState();
    _selectedChain = widget.chains.first;
    _selectedLayer = widget.availableLayers.first;
    _nameCtrl.text = widget.sourceLayer.name;
    _updateDeclinationFromChain(_selectedChain);
  }

  void _updateDeclinationFromChain(TraverseChain chain) {
    final origin = chain.origin.point;
    final dec = WmmDeclination.calculate(origin.latitude, origin.longitude);
    _declinationCtrl.text = dec.toStringAsFixed(1);
  }

  @override
  void dispose() {
    _declinationCtrl.dispose();
    _instrumentHeightCtrl.dispose();
    _targetHeightCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  String _layerTypeLabel(LayerNode layer) {
    if (layer is LineLayerNode) return t.surveyConversion.lineType;
    if (layer is PolygonLayerNode) return t.surveyConversion.polygonType;
    return t.surveyConversion.unknownType;
  }

  @override
  Widget build(BuildContext context) {
    final preview = TraverseAdjuster.previewClosure(
      _selectedChain,
      declination: _declination,
    );
    final typeLabel = _layerTypeLabel(_selectedLayer);

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.straighten, color: Colors.blue),
          const SizedBox(width: 8),
          Text(t.surveyConversion.title),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // チェーン選択（複数チェーンがある場合）
              if (widget.chains.length > 1) ...[
                _SectionHeader(t.surveyConversion.surveyChain),
                DropdownButtonFormField<TraverseChain>(
                  // ignore: deprecated_member_use
                  value: _selectedChain,
                  items: widget.chains.asMap().entries.map((e) {
                    final c = e.value;
                    return DropdownMenuItem(
                      value: c,
                      child: Text(t.surveyConversion.chainInfo(index: '${e.key + 1}', count: '${c.length}', distance: c.totalDistance.toStringAsFixed(1))),
                    );
                  }).toList(),
                  onChanged: (v) {
                    if (v != null) {
                      setState(() => _selectedChain = v);
                      _updateDeclinationFromChain(v);
                    }
                  },
                ),
                const SizedBox(height: 12),
              ],

              // チェーン情報
              _ClosureInfoCard(
                chain: _selectedChain,
                closureError: preview.error,
                totalDistance: preview.distance,
                closureRatioN: preview.ratioN,
              ),
              const SizedBox(height: 16),

              // 変換先レイヤー
              _SectionHeader(t.surveyConversion.targetLayer),
              _LayerDropdown(
                layers: widget.availableLayers,
                selected: _selectedLayer,
                onChanged: (v) => setState(() => _selectedLayer = v),
                labelBuilder: _layerTypeLabel,
              ),
              const SizedBox(height: 12),

              // フィーチャ名
              TextField(
                controller: _nameCtrl,
                decoration: InputDecoration(
                  labelText: t.surveyConversion.featureNameOpt,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 16),

              // 閉合オプション
              SwitchListTile(
                title: Text(t.surveyConversion.closeTraverse),
                subtitle: Text(
                  t.surveyConversion.closeTraverseDesc,
                  style: const TextStyle(fontSize: 11),
                ),
                value: _closePath,
                dense: true,
                contentPadding: EdgeInsets.zero,
                onChanged: (v) => setState(() {
                  _closePath = v;
                  _method = v ? AdjustmentMethod.bowditch : AdjustmentMethod.none;
                }),
              ),

              // 閉合補正方式（閉合ON時のみ: Bowditch / Transit の2択）
              if (_closePath) ...[
                _SectionHeader(t.surveyConversion.closureAdjustment),
                ...[AdjustmentMethod.bowditch, AdjustmentMethod.transit]
                    .map((m) => RadioListTile<AdjustmentMethod>(
                          title: Text(_methodLabel(m)),
                          subtitle: Text(_methodDescription(m), style: const TextStyle(fontSize: 11)),
                          value: m,
                          // ignore: deprecated_member_use
                          groupValue: _method,
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          // ignore: deprecated_member_use
                          onChanged: (v) {
                            if (v != null) setState(() => _method = v);
                          },
                        )),
              ],
              const SizedBox(height: 12),

              // 磁気偏角トグル
              SwitchListTile(
                title: Text(t.surveyConversion.declinationCorrection),
                subtitle: Text(
                  t.surveyConversion.declinationDesc,
                  style: const TextStyle(fontSize: 11),
                ),
                value: _useDeclination,
                dense: true,
                contentPadding: EdgeInsets.zero,
                onChanged: (v) => setState(() => _useDeclination = v),
              ),
              if (_useDeclination) ...[
                Row(
                  children: [
                    SizedBox(
                      width: 100,
                      child: TextField(
                        controller: _declinationCtrl,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                        decoration: const InputDecoration(
                          suffixText: '\u00b0',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        t.surveyConversion.declinationAutoDesc,
                        style: const TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 12),

              // 器械高・目標高トグル
              SwitchListTile(
                title: Text(t.surveyConversion.heightCorrection),
                subtitle: Text(
                  t.surveyConversion.heightCorrectionDesc,
                  style: const TextStyle(fontSize: 11),
                ),
                value: _useHeightCorrection,
                dense: true,
                contentPadding: EdgeInsets.zero,
                onChanged: (v) => setState(() => _useHeightCorrection = v),
              ),
              if (_useHeightCorrection)
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _instrumentHeightCtrl,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: InputDecoration(
                          labelText: t.surveyConversion.instrumentHeight,
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _targetHeightCtrl,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: InputDecoration(
                          labelText: t.surveyConversion.targetHeight,
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.common.cancel),
        ),
        ElevatedButton.icon(
          onPressed: () {
            final name = _nameCtrl.text.trim();
            Navigator.pop(
              context,
              SurveyConversionResult(
                targetLayer: _selectedLayer,
                chain: _selectedChain,
                options: TraverseAdjustmentOptions(
                  method: _closePath ? _method : AdjustmentMethod.none,
                  declination: _useDeclination
                      ? (double.tryParse(_declinationCtrl.text) ?? 0)
                      : 0,
                  instrumentHeight: _useHeightCorrection
                      ? (double.tryParse(_instrumentHeightCtrl.text) ?? 0)
                      : 0,
                  targetHeight: _useHeightCorrection
                      ? (double.tryParse(_targetHeightCtrl.text) ?? 0)
                      : 0,
                ),
                featureName: name.isNotEmpty ? name : null,
                closePath: _closePath,
              ),
            );
          },
          icon: Icon(_selectedLayer is PolygonLayerNode ? Icons.pentagon_outlined : Icons.show_chart),
          label: Text(t.surveyConversion.convertTo(type: typeLabel)),
        ),
      ],
    );
  }

  String _methodLabel(AdjustmentMethod m) => switch (m) {
        AdjustmentMethod.none => t.surveyConversion.noAdjustment,
        AdjustmentMethod.bowditch => t.surveyConversion.bowditch,
        AdjustmentMethod.transit => t.surveyConversion.transit,
      };

  String _methodDescription(AdjustmentMethod m) => switch (m) {
        AdjustmentMethod.none => t.surveyConversion.noAdjustmentDesc,
        AdjustmentMethod.bowditch => t.surveyConversion.bowditchDesc,
        AdjustmentMethod.transit => t.surveyConversion.transitDesc,
      };
}

// =========================================================
// Sub-widgets
// =========================================================

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(text, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
    );
  }
}

class _ClosureInfoCard extends StatelessWidget {
  final TraverseChain chain;
  final double closureError;
  final double totalDistance;
  final double closureRatioN;

  const _ClosureInfoCard({
    required this.chain,
    required this.closureError,
    required this.totalDistance,
    required this.closureRatioN,
  });

  @override
  Widget build(BuildContext context) {
    final isGoodClosure = closureRatioN > 500;
    final ratioText = closureRatioN.isInfinite
        ? t.surveyConversion.perfectClosure
        : '1/${closureRatioN.toStringAsFixed(0)}';

    return Card(
      color: isGoodClosure ? Colors.green.shade50 : Colors.orange.shade50,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isGoodClosure ? Icons.check_circle : Icons.warning,
                  size: 16,
                  color: isGoodClosure ? Colors.green : Colors.orange,
                ),
                const SizedBox(width: 4),
                Text(
                  t.surveyConversion.chainPoints(count: '${chain.length}'),
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                _StatChip(t.surveyConversion.pathLength, '${totalDistance.toStringAsFixed(1)}m'),
                _StatChip(t.surveyConversion.closureError, '${closureError.toStringAsFixed(3)}m'),
                _StatChip(t.surveyConversion.closureRatio, ratioText),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final String value;
  const _StatChip(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(label, style: const TextStyle(fontSize: 9, color: Colors.grey)),
          Text(value, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _LayerDropdown extends StatelessWidget {
  final List<LayerNode> layers;
  final LayerNode selected;
  final ValueChanged<LayerNode> onChanged;
  final String Function(LayerNode) labelBuilder;

  const _LayerDropdown({
    required this.layers,
    required this.selected,
    required this.onChanged,
    required this.labelBuilder,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<LayerNode>(
          value: selected,
          isExpanded: true,
          items: layers.map((layer) {
            final typeLabel = labelBuilder(layer);
            return DropdownMenuItem(
              value: layer,
              child: Row(
                children: [
                  NodePresenter.buildIcon(layer, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${layer.geoPackageNode.name} / ${layer.name} ($typeLabel)',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    );
  }
}
