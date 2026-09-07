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
// Root Maps: 属性フォームビュー
// 個別フィーチャの属性をフォーム形式で表示・編集

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/strings.g.dart';
import '../../models/app_notification.dart';
import '../../providers/notification_providers.dart';
import 'attribute_table_controller.dart';

/// 個別フィーチャの属性をフォーム形式で表示
class AttributeFormView extends ConsumerStatefulWidget {
  final AttributeTableController controller;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  const AttributeFormView({
    super.key,
    required this.controller,
    this.onPrevious,
    this.onNext,
  });

  @override
  ConsumerState<AttributeFormView> createState() => _AttributeFormViewState();
}

class _AttributeFormViewState extends ConsumerState<AttributeFormView> {
  int _currentIndex = 0;
  final Map<String, TextEditingController> _fieldControllers = {};

  AttributeTableController get ctrl => widget.controller;

  @override
  void initState() {
    super.initState();
    _initFieldControllers();
  }

  @override
  void didUpdateWidget(AttributeFormView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _disposeControllers();
      _initFieldControllers();
    }
  }

  void _initFieldControllers() {
    _fieldControllers.clear();
    for (final col in ctrl.columnNames) {
      _fieldControllers[col] = TextEditingController();
    }
    _loadCurrentFeature();
  }

  void _disposeControllers() {
    for (final c in _fieldControllers.values) {
      c.dispose();
    }
    _fieldControllers.clear();
  }

  @override
  void dispose() {
    _disposeControllers();
    super.dispose();
  }

  Future<void> _loadCurrentFeature() async {
    if (ctrl.features.isEmpty) return;
    _currentIndex = _currentIndex.clamp(0, ctrl.features.length - 1);
    final feature = ctrl.features[_currentIndex];

    for (final col in ctrl.columnNames) {
      try {
        final value = await feature.getAttributeValue(col);
        _fieldControllers[col]?.text = value?.toString() ?? '';
      } catch (_) {
        _fieldControllers[col]?.text = '';
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _saveField(String field, String value) async {
    if (_currentIndex >= ctrl.features.length) return;
    final feature = ctrl.features[_currentIndex];
    final error = await ctrl.saveAttributeChange(feature, field, value);
    if (error != null) {
      ref.read(notificationCenterProvider.notifier).add(
        title: error,
        level: NotificationLevel.error,
      );
    }
  }

  void _goTo(int index) {
    if (index < 0 || index >= ctrl.features.length) return;
    _currentIndex = index;
    _loadCurrentFeature();
  }

  @override
  Widget build(BuildContext context) {
    if (ctrl.features.isEmpty) {
      return Center(child: Text(t.attributeTable.noFeatures));
    }

    final feature = ctrl.features[_currentIndex];
    final featureId = feature.rowId;

    return Column(
      children: [
        // ナビゲーションバー
        Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            border: Border(
              bottom: BorderSide(
                color: Theme.of(context).dividerColor,
                width: 0.5,
              ),
            ),
          ),
          child: Row(
            children: [
              IconButton(
                iconSize: 14,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                icon: const Icon(Icons.first_page),
                onPressed: _currentIndex > 0 ? () => _goTo(0) : null,
              ),
              IconButton(
                iconSize: 14,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                icon: const Icon(Icons.chevron_left),
                onPressed:
                    _currentIndex > 0 ? () => _goTo(_currentIndex - 1) : null,
              ),
              Text(
                '${_currentIndex + 1} / ${ctrl.features.length}  (ID: $featureId)',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
              IconButton(
                iconSize: 14,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                icon: const Icon(Icons.chevron_right),
                onPressed:
                    _currentIndex < ctrl.features.length - 1
                        ? () => _goTo(_currentIndex + 1)
                        : null,
              ),
              IconButton(
                iconSize: 14,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                icon: const Icon(Icons.last_page),
                onPressed:
                    _currentIndex < ctrl.features.length - 1
                        ? () => _goTo(ctrl.features.length - 1)
                        : null,
              ),
            ],
          ),
        ),

        // フォームフィールド
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(8),
            itemCount: ctrl.columnNames.length,
            itemBuilder: (context, index) {
              final col = ctrl.columnNames[index];
              final isEditable =
                  !col.startsWith('_') &&
                  col.toLowerCase() != 'id' &&
                  col.toLowerCase() != 'fid' &&
                  col.toLowerCase() != 'geom' &&
                  col.toLowerCase() != 'geometry';

              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: TextField(
                  controller: _fieldControllers[col],
                  readOnly: !isEditable,
                  style: TextStyle(
                    fontSize: 12,
                    color: isEditable ? null : Colors.grey.shade600,
                  ),
                  decoration: InputDecoration(
                    labelText: col,
                    labelStyle: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: isEditable ? Colors.blue.shade700 : Colors.grey,
                    ),
                    border: const OutlineInputBorder(),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                    suffixIcon:
                        !isEditable
                            ? const Icon(
                              Icons.lock,
                              size: 14,
                              color: Colors.grey,
                            )
                            : null,
                  ),
                  onSubmitted:
                      isEditable ? (value) => _saveField(col, value) : null,
                  onChanged:
                      isEditable
                          ? (value) {
                            // デバウンスで遅延保存
                          }
                          : null,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
