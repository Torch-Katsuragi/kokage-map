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
import '../../models/nodes/feature_node.dart';
import '../../models/qgis_form.dart';
import '../../providers/notification_providers.dart';
import '../../utils/attribute_columns.dart';
import '../qgis_form/qgis_field_input.dart';
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

  /// 欄の今の値（打っている途中も含む）
  final Map<String, Object?> _values = {};

  /// 読み込んだとき（または最後に保存したとき）の値。確定したとき、これと違えば保存する
  final Map<String, Object?> _loaded = {};

  /// 保存しなかった欄の理由（QGIS の必須の制約など）
  final Map<String, String> _errors = {};

  AttributeTableController get ctrl => widget.controller;

  @override
  void initState() {
    super.initState();
    _loadCurrentFeature();
  }

  @override
  void didUpdateWidget(AttributeFormView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) _loadCurrentFeature();
  }

  @override
  void dispose() {
    _commitAll(); // 閉じる前の入力を捨てない
    super.dispose();
  }

  void _loadCurrentFeature() {
    _values.clear();
    _loaded.clear();
    _errors.clear();
    if (ctrl.features.isEmpty) return;
    _currentIndex = _currentIndex.clamp(0, ctrl.features.length - 1);
    final feature = ctrl.features[_currentIndex];
    for (final col in ctrl.columnNames) {
      _values[col] = _loaded[col] = ctrl.valueOf(feature, col);
    }
  }

  static String _key(Object? v) => v?.toString() ?? '';

  /// 変わっていれば保存する。以前は Enter を押したときしか保存せず、
  /// 欄を離れたりレコードを移ったりすると入力が捨てられていた（2026-09-24、Fold で気づいた）
  void _commit(String col) {
    if (!_values.containsKey(col) || _key(_values[col]) == _key(_loaded[col])) return;
    if (_currentIndex >= ctrl.features.length) return;
    final feature = ctrl.features[_currentIndex];
    final value = normalizeAttributeInput(ctrl.columnSqlType(col), _values[col]);
    _loaded[col] = value;
    unawaited(_save(feature, col, value));
  }

  Future<void> _save(FeatureNode feature, String col, Object? value) async {
    final error = await ctrl.saveAttributeChange(feature, col, value);
    if (error != null) {
      ref.read(notificationCenterProvider.notifier).add(title: error, level: NotificationLevel.error);
      // 書かなかった。次に同じ値で確定したときも確かめ直す
      _loaded[col] = readAttribute(feature, col);
    }
    if (!mounted || ctrl.features.indexOf(feature) != _currentIndex) return;
    setState(() {
      if (error == null) {
        _errors.remove(col);
      } else {
        _errors[col] = error;
      }
      // 更新のときに当て直す既定値（最終更新日時など）が入った列を読み直す
      for (final f in ctrl.qgisForm?.fields.values ?? const <QgisFieldForm>[]) {
        if (f.applyDefaultOnUpdate && f.name != col && _values.containsKey(f.name)) {
          _values[f.name] = _loaded[f.name] = readAttribute(feature, f.name);
        }
      }
    });
  }

  void _commitAll() {
    for (final col in _values.keys.toList()) {
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

        // フォームフィールド（QGIS の配置・編集ウィジェットがあればそれに合わせる）
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(8),
            children: [
              for (final row in qgisFormRows(ctrl.qgisForm, ctrl.columnNames))
                switch (row) {
                  QgisFormHeader() => QgisFormHeaderView(row),
                  QgisFormFieldRow(:final column, :final depth) => Padding(
                      padding: EdgeInsets.only(bottom: 8, left: depth * 8.0),
                      child: QgisFieldInput(
                        key: ValueKey('$featureId/$column'),
                        column: column,
                        field: ctrl.qgisForm?[column],
                        sqlType: ctrl.columnSqlType(column),
                        value: _values[column],
                        enabled: ctrl.canEdit(column),
                        options: ctrl.formOptions[column],
                        errorText: _errors[column],
                        onChanged: (v, {required commit}) {
                          _values[column] = v;
                          if (commit) {
                            _commit(column);
                            setState(() {});
                          }
                        },
                      ),
                    ),
                },
            ],
          ),
        ),
      ],
    );
  }
}
