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

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/strings.g.dart';
import '../../models/app_notification.dart';
import '../../providers/notification_providers.dart';
import '../../utils/attribute_columns.dart';
import 'attribute_table_controller.dart';

/// 個別フィーチャの属性をフォーム形式で表示
class AttributeFormView extends ConsumerStatefulWidget {
  final AttributeTableController controller;

  const AttributeFormView({super.key, required this.controller});

  @override
  ConsumerState<AttributeFormView> createState() => _AttributeFormViewState();
}

class _AttributeFormViewState extends ConsumerState<AttributeFormView> {
  int _currentIndex = 0;
  final Map<String, TextEditingController> _fieldControllers = {};

  /// 読み込んだときの値。欄を離れたとき、これと違えば保存する
  final Map<String, String> _loaded = {};

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
    _commitAll(); // 閉じる前の入力を捨てない
    _disposeControllers();
    super.dispose();
  }

  void _loadCurrentFeature() {
    if (ctrl.features.isEmpty) return;
    _currentIndex = _currentIndex.clamp(0, ctrl.features.length - 1);
    final feature = ctrl.features[_currentIndex];

    for (final col in ctrl.columnNames) {
      final text = readAttribute(feature, col)?.toString() ?? '';
      _fieldControllers[col]?.text = text;
      _loaded[col] = _fieldControllers[col]?.text ?? '';
    }
  }

  Future<void> _saveField(String field, String value) async {
    if (_currentIndex >= ctrl.features.length) return;
    final feature = ctrl.features[_currentIndex];
    final error = await ctrl.saveAttributeChange(feature, field, value);
    if (error != null) {
      ref
          .read(notificationCenterProvider.notifier)
          .add(title: error, level: NotificationLevel.error);
    }
  }

  /// 変わっていれば保存する。以前は Enter を押したときしか保存せず、
  /// 欄を離れたりレコードを移ったりすると入力が捨てられていた（2026-09-24、Fold で気づいた）
  void _commit(String col) {
    final text = _fieldControllers[col]?.text;
    if (text == null || text == _loaded[col]) return;
    final value = isNumericSqlType(ctrl.columnSqlType(col))
        ? toHalfWidthNumber(text)
        : text;
    _loaded[col] = text;
    unawaited(_saveField(col, value));
  }

  void _commitAll() {
    for (final col in _fieldControllers.keys) {
      _commit(col);
    }
  }

  void _goTo(int index) {
    if (index < 0 || index >= ctrl.features.length) return;
    _commitAll();
    setState(() {
      _currentIndex = index;
      _loadCurrentFeature();
    });
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
                onPressed: _currentIndex > 0
                    ? () => _goTo(_currentIndex - 1)
                    : null,
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
                onPressed: _currentIndex < ctrl.features.length - 1
                    ? () => _goTo(_currentIndex + 1)
                    : null,
              ),
              IconButton(
                iconSize: 14,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                icon: const Icon(Icons.last_page),
                onPressed: _currentIndex < ctrl.features.length - 1
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
              final isEditable = !isReadOnlyColumn(col);
              final sqlType = ctrl.columnSqlType(col);
              final numeric = isNumericSqlType(sqlType);
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Focus(
                  onFocusChange: (focused) {
                    if (!focused && isEditable) _commit(col);
                  },
                  child: TextField(
                    controller: _fieldControllers[col],
                    readOnly: !isEditable,
                    keyboardType: numeric
                        ? TextInputType.numberWithOptions(
                            signed: true,
                            decimal: !isIntegerSqlType(sqlType),
                          )
                        : null,
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
                      suffixIcon: !isEditable
                          ? const Icon(Icons.lock, size: 14, color: Colors.grey)
                          : null,
                    ),
                    onSubmitted: isEditable ? (_) => _commit(col) : null,
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
