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
// lib/widgets/geometry_conversion_dialogs.dart
// ジオメトリ変換ダイアログウィジェット
import 'package:flutter/material.dart';

import '../i18n/strings.g.dart';
import '../models/nodes/layer_node.dart';
import '../presentation/node_presenter.dart';

/// ポイント→ライン/ポリゴン変換ダイアログ
class ConvertPointsToGeometryDialog extends StatefulWidget {
  final PointLayerNode sourceLayer;
  final List<LayerNode> availableLayers;

  const ConvertPointsToGeometryDialog({
    super.key,
    required this.sourceLayer,
    required this.availableLayers,
  });

  @override
  State<ConvertPointsToGeometryDialog> createState() => _ConvertPointsToGeometryDialogState();
}

class _ConvertPointsToGeometryDialogState extends State<ConvertPointsToGeometryDialog> {
  late LayerNode _selectedLayer;

  @override
  void initState() {
    super.initState();
    _selectedLayer = widget.availableLayers.first;
  }

  String _getLayerTypeLabel(LayerNode layer) {
    if (layer is LineLayerNode) {
      return t.geometryConversion.lineType;
    } else if (layer is PolygonLayerNode) {
      return t.geometryConversion.polygonType;
    }
    return t.geometryConversion.unknownType;
  }

  @override
  Widget build(BuildContext context) {
    final selectedTypeLabel = _getLayerTypeLabel(_selectedLayer);
    
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.transform, color: Colors.blue),
          const SizedBox(width: 8),
          Text(t.geometryConversion.pointConversion),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t.geometryConversion.convertDesc(count: '${widget.sourceLayer.features.length}', layer: widget.sourceLayer.name, type: selectedTypeLabel),
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 16),
            
            // レイヤー選択
            Text(
              t.geometryConversion.targetLayerLabel,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade300),
                borderRadius: BorderRadius.circular(8),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<LayerNode>(
                  value: _selectedLayer,
                  isExpanded: true,
                  items: widget.availableLayers.map((layer) {
                    final typeLabel = _getLayerTypeLabel(layer);
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
                  onChanged: (value) {
                    if (value != null) {
                      setState(() {
                        _selectedLayer = value;
                      });
                    }
                  },
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: Text(t.common.cancel),
        ),
        ElevatedButton.icon(
          onPressed: () => Navigator.of(context).pop(_selectedLayer),
          icon: const Icon(Icons.check),
          label: Text(t.geometryConversion.convert),
        ),
      ],
    );
  }
}
