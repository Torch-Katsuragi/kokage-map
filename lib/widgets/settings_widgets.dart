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
/// 設定画面用の共通ウィジェットテンプレート
///
/// 設定画面のUIを統一するための再利用可能なコンポーネント群。
/// 背景地図設定画面のスタイルをベースとしています。
library;

import 'package:flex_color_picker/flex_color_picker.dart';
import 'package:flutter/material.dart';

import '../core/settings_schema.dart';
import '../i18n/strings.g.dart';
import '../tutorial/tutorial.dart';

/// 設定セクション（カード形式）
///
/// 設定項目をグループ化するためのカードコンポーネント。
/// [title] と [children] を指定してセクションを構成します。
///
/// スクロール負担を下げるため、[collapsible] を true にすると
/// セクションを折りたたみ（タップで展開）できるようになります。
class SettingsSection extends StatefulWidget {
  final String title;
  final List<Widget> children;
  final IconData? icon;
  final Color? iconColor;
  final Widget? trailing;
  final bool collapsible;
  final bool initiallyExpanded;

  const SettingsSection({
    super.key,
    required this.title,
    required this.children,
    this.icon,
    this.iconColor,
    this.trailing,
    this.collapsible = false,
    this.initiallyExpanded = true,
  });

  @override
  State<SettingsSection> createState() => _SettingsSectionState();
}

class _SettingsSectionState extends State<SettingsSection> {
  late bool _expanded = widget.initiallyExpanded;

  void _toggleExpanded() => setState(() => _expanded = !_expanded);

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 1.0,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // セクションヘッダー
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: widget.collapsible ? _toggleExpanded : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    if (widget.icon != null) ...[
                      Icon(
                        widget.icon,
                        color: widget.iconColor ?? Colors.blue,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: Text(
                        widget.title,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    if (widget.trailing != null) ...[
                      widget.trailing!,
                      const SizedBox(width: 8),
                    ],
                    if (widget.collapsible)
                      AnimatedRotation(
                        duration: const Duration(milliseconds: 150),
                        turns: _expanded ? 0.5 : 0.0,
                        child: const Icon(Icons.expand_more),
                      ),
                  ],
                ),
              ),
            ),
            if (!widget.collapsible || _expanded) ...[
              const SizedBox(height: 12),
              ...widget.children,
            ],
          ],
        ),
      ),
    );
  }
}

/// 強調表示セクション
///
/// 重要な機能や操作を目立たせるためのセクション。
/// 背景色付きで視覚的に区別されます。
class SettingsHighlightSection extends StatelessWidget {
  final String title;
  final String? description;
  final IconData icon;
  final Color iconColor;
  final Color backgroundColor;
  final Widget actionButton;

  const SettingsHighlightSection({
    super.key,
    required this.title,
    this.description,
    required this.icon,
    this.iconColor = Colors.blue,
    required this.backgroundColor,
    required this.actionButton,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 4,
      color: backgroundColor,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: iconColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            if (description != null) ...[
              const SizedBox(height: 8),
              Text(description!, style: const TextStyle(fontSize: 14)),
            ],
            const SizedBox(height: 16),
            SizedBox(width: double.infinity, child: actionButton),
          ],
        ),
      ),
    );
  }
}

/// タイルの題と副題。無効なら灰色にする
Widget _tileText(String text, {required bool enabled}) =>
    Text(text, style: enabled ? null : const TextStyle(color: Colors.grey));

/// 設定タイル（基本）
///
/// アイコン、タイトル、サブタイトルを持つ基本的な設定項目。
class SettingsTile extends StatelessWidget {
  final IconData? leadingIcon;
  final Color? leadingIconColor;
  final String title;
  final String? subtitle;
  final Widget? trailing;

  const SettingsTile({
    super.key,
    this.leadingIcon,
    this.leadingIconColor,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: leadingIcon != null
          ? Icon(leadingIcon, color: leadingIconColor ?? Colors.blue)
          : null,
      title: Text(title),
      subtitle: subtitle != null ? Text(subtitle!) : null,
      trailing: trailing,
    );
  }
}

/// スイッチ付き設定タイル
///
/// ON/OFF の切り替えを行う設定項目。
class SettingsSwitchTile extends StatelessWidget {
  final IconData? leadingIcon;
  final Color? activeIconColor;
  final Color? inactiveIconColor;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  const SettingsSwitchTile({
    super.key,
    this.leadingIcon,
    this.activeIconColor,
    this.inactiveIconColor,
    required this.title,
    this.subtitle,
    required this.value,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      secondary: leadingIcon != null
          ? Icon(
              leadingIcon,
              color: value
                  ? (activeIconColor ?? Colors.green)
                  : (inactiveIconColor ?? Colors.grey),
            )
          : null,
      title: Text(title),
      subtitle: subtitle != null ? Text(subtitle!) : null,
      value: value,
      onChanged: onChanged,
    );
  }
}

/// 選択可能な設定タイル
///
/// 複数の選択肢から1つを選ぶ設定項目。
class SettingsSelectionTile extends StatelessWidget {
  final IconData? leadingIcon;
  final Color? leadingIconColor;
  final String title;
  final String? subtitle;
  final bool isSelected;
  final VoidCallback? onTap;

  const SettingsSelectionTile({
    super.key,
    this.leadingIcon,
    this.leadingIconColor,
    required this.title,
    this.subtitle,
    required this.isSelected,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: leadingIcon != null
          ? Icon(
              leadingIcon,
              color: isSelected ? (leadingIconColor ?? Colors.blue) : Colors.grey,
            )
          : null,
      title: Text(
        title,
        style: TextStyle(
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      subtitle: subtitle != null ? Text(subtitle!) : null,
      trailing: isSelected
          ? const Icon(Icons.check_circle, color: Colors.blue)
          : null,
      onTap: onTap,
    );
  }
}

/// アクションボタン付き設定タイル
///
/// 右側にボタンを配置した設定項目。
class SettingsActionTile extends StatelessWidget {
  final IconData? leadingIcon;
  final Color? leadingIconColor;
  final String title;
  final String? subtitle;
  final String buttonLabel;
  final Color? buttonColor;
  final VoidCallback? onPressed;
  final bool enabled;

  const SettingsActionTile({
    super.key,
    this.leadingIcon,
    this.leadingIconColor,
    required this.title,
    this.subtitle,
    required this.buttonLabel,
    this.buttonColor,
    this.onPressed,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: leadingIcon != null
          ? Icon(
              leadingIcon,
              color: enabled ? (leadingIconColor ?? Colors.blue) : Colors.grey,
            )
          : null,
      title: _tileText(title, enabled: enabled),
      subtitle: subtitle != null ? _tileText(subtitle!, enabled: enabled) : null,
      trailing: ElevatedButton(
        onPressed: enabled ? onPressed : null,
        style: settingsButtonStyle(buttonColor ?? Colors.blue),
        child: Text(buttonLabel),
      ),
    );
  }
}

/// 情報表示行
///
/// ラベルと値のペアを表示するシンプルな行。
class SettingsInfoRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  final FontWeight? valueFontWeight;

  const SettingsInfoRow({
    super.key,
    required this.label,
    required this.value,
    this.valueColor,
    this.valueFontWeight,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text(
            value,
            style: TextStyle(
              fontWeight: valueFontWeight ?? FontWeight.bold,
              color: valueColor,
            ),
          ),
        ],
      ),
    );
  }
}

/// エラー表示カード
///
/// エラーメッセージを目立つ形で表示。
class SettingsErrorCard extends StatelessWidget {
  final String message;

  const SettingsErrorCard({
    super.key,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.red[50],
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Icon(Icons.error, color: Colors.red),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(color: Colors.red),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// セクション冒頭の説明文（灰色・小さめ）
class SettingsDescription extends StatelessWidget {
  final String text;
  final EdgeInsetsGeometry padding;

  const SettingsDescription(
    this.text, {
    super.key,
    this.padding = const EdgeInsets.symmetric(horizontal: 12),
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Text(
        text,
        style: TextStyle(fontSize: 13, color: Colors.grey[600], height: 1.4),
      ),
    );
  }
}

/// セクション内の地の文（行間広め）
class SettingsParagraph extends StatelessWidget {
  final String text;
  final Color? color;

  const SettingsParagraph(this.text, {super.key, this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Text(text, style: TextStyle(height: 1.5, color: color)),
    );
  }
}

/// 「情報」セクション（灰色の補足文だけ）
class SettingsInfoSection extends StatelessWidget {
  final String text;

  const SettingsInfoSection(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsSection(
      title: t.settings.info,
      icon: Icons.info_outline,
      iconColor: Colors.grey,
      children: [SettingsParagraph(text, color: Colors.grey)],
    );
  }
}

/// 色付きの塗りボタン（文字は白）
ButtonStyle settingsButtonStyle(Color color, {EdgeInsetsGeometry? padding}) =>
    ElevatedButton.styleFrom(
      backgroundColor: color,
      foregroundColor: Colors.white,
      padding: padding,
    );

/// 「キャンセル／[confirmLabel]」の確認ダイアログ。確定なら true
Future<bool> showSettingsConfirmDialog(
  BuildContext context, {
  Widget? icon,
  required String title,
  required String message,
  required String confirmLabel,
  ButtonStyle? confirmStyle,
}) async {
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          icon: icon,
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(t.common.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              style: confirmStyle,
              child: Text(confirmLabel),
            ),
          ],
        ),
      ) ??
      false;
}

/// 設定画面の共通Scaffold
///
/// 統一されたAppBarスタイルを提供。
class SettingsScaffold extends StatelessWidget {
  final String title;
  final bool isEmbedded;
  final List<Widget>? actions;
  final Widget body;
  final bool isLoading;

  const SettingsScaffold({
    super.key,
    required this.title,
    this.isEmbedded = false,
    this.actions,
    required this.body,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        automaticallyImplyLeading: !isEmbedded,
        actions: actions,
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : body,
    );
  }
}

/// 設定画面の共通ボディ
///
/// スクロール可能なパディング付きコンテンツ。
class SettingsBody extends StatelessWidget {
  final List<Widget> sections;
  final double spacing;

  const SettingsBody({
    super.key,
    required this.sections,
    this.spacing = 16,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (int i = 0; i < sections.length; i++) ...[
            sections[i],
            if (i < sections.length - 1) SizedBox(height: spacing),
          ],
        ],
      ),
    );
  }
}

// ============================================================
// DataDrivenSettingsScreen
// ============================================================

/// SettingsStoreの定義からUIを自動生成する設定画面
class DataDrivenSettingsScreen extends StatefulWidget {
  final String title;
  final SettingsStore store;
  final bool isEmbedded;

  /// 自動生成セクションの前に挿入するカスタムウィジェット
  final List<Widget> Function(SettingsStore store)? customSections;

  /// リセット処理のカスタマイズ（nullならstore.resetAll()を使用）
  final Future<void> Function()? onReset;

  /// store.load()後の追加初期化処理（KMetaオーバーレイ読み込み等）
  final Future<void> Function()? onInit;

  /// 値変更時のコールバック（KMeta自動保存等）
  final VoidCallback? onValueChanged;

  /// セクションフィルタ（表示するセクションを制御）
  final bool Function(SettingSectionDef)? sectionFilter;

  const DataDrivenSettingsScreen({
    super.key,
    required this.title,
    required this.store,
    this.isEmbedded = false,
    this.customSections,
    this.onReset,
    this.onInit,
    this.onValueChanged,
    this.sectionFilter,
  });

  @override
  State<DataDrivenSettingsScreen> createState() =>
      _DataDrivenSettingsScreenState();
}

class _DataDrivenSettingsScreenState extends State<DataDrivenSettingsScreen> {
  bool _isLoading = true;

  SettingsStore get _store => widget.store;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await _store.load();
    if (widget.onInit != null) await widget.onInit!();
    if (mounted) setState(() => _isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    return SettingsScaffold(
      title: widget.title,
      isEmbedded: widget.isEmbedded,
      isLoading: _isLoading,
      actions: [
        IconButton(
          icon: const Icon(Icons.restore),
          tooltip: t.settingsWidget.resetToDefault,
          onPressed: () async {
            if (widget.onReset != null) {
              await widget.onReset!();
            } else {
              await _store.resetAll();
            }
            setState(() {});
          },
        ),
      ],
      body: SettingsBody(
        sections: [
          if (widget.customSections != null)
            ...widget.customSections!(_store),
          ..._buildSections(),
        ],
      ),
    );
  }

  /// 値が変わったら知らせて描き直す
  void _changed() {
    widget.onValueChanged?.call();
    setState(() {});
  }

  List<Widget> _buildSections() {
    return _store.sections
        .where((s) => !s.globalOnly || !_store.hasOverlay)
        .where((s) => widget.sectionFilter?.call(s) ?? true)
        .map(_buildSection)
        .toList();
  }

  Widget _buildSection(SettingSectionDef section) {
    return SettingsSection(
      key: TutorialTargets.settingSection(section.id),
      title: section.title,
      icon: section.icon,
      iconColor: section.iconColor,
      collapsible: section.collapsible,
      initiallyExpanded: section.initiallyExpanded,
      children: [
        if (section.description != null) ...[
          SettingsDescription(
            section.description!,
            padding: const EdgeInsets.symmetric(horizontal: 16),
          ),
          const SizedBox(height: 8),
        ],
        for (int i = 0; i < section.items.length; i++) ...[
          if (i > 0) const Divider(),
          _buildSettingTile(section.items[i]),
        ],
      ],
    );
  }

  Widget _buildSettingTile(SettingDef def) => switch (def) {
    final DoubleDef d => _buildDoubleTile(d),
    final SwitchDef s => _buildSwitchTile(s),
    final ColorDef c => _buildColorTile(c),
    final IntDef i => _buildIntTile(i),
    final StringDef s => _buildStringTile(s),
    final CustomDef c => c.builder(context, _store, _changed),
  };

  /// 題と値の行・説明・スライダー（数値の項目で共通）
  Widget _sliderTile({
    required String title,
    required String valueLabel,
    required String? description,
    required Slider slider,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SettingsInfoRow(label: title, value: valueLabel),
        ),
        if (description != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              description,
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ),
        slider,
      ],
    );
  }

  Widget _buildDoubleTile(DoubleDef def) {
    final value = _store.getDouble(def);
    return _sliderTile(
      title: def.title,
      valueLabel: def.formatValue(value),
      description: def.description,
      slider: Slider(
        value: value,
        min: def.min,
        max: def.max,
        divisions: def.divisions,
        onChanged: (v) {
          _store.setDouble(def, double.parse(v.toStringAsFixed(2)));
          _changed();
        },
      ),
    );
  }

  Widget _buildSwitchTile(SwitchDef def) {
    return SettingsSwitchTile(
      leadingIcon: def.icon,
      title: def.title,
      subtitle: def.description,
      value: _store.getBool(def),
      onChanged: (v) {
        _store.setBool(def, v);
        _changed();
      },
    );
  }

  Widget _buildColorTile(ColorDef def) {
    final color = _store.getColor(def);
    return ListTile(
      key: TutorialTargets.settingTile(def.key),
      title: Text(def.title),
      subtitle: def.description != null ? Text(def.description!) : null,
      trailing: GestureDetector(
        onTap: () => _showColorPicker(def, color),
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey.shade400),
          ),
        ),
      ),
    );
  }

  Widget _buildIntTile(IntDef def) {
    final value = _store.getInt(def);
    return _sliderTile(
      title: def.title,
      valueLabel: def.formatValue(value),
      description: def.description,
      slider: Slider(
        value: value.toDouble(),
        min: def.min.toDouble(),
        max: def.max.toDouble(),
        divisions: def.divisions,
        onChanged: (v) {
          _store.setInt(def, v.round());
          _changed();
        },
      ),
    );
  }

  Widget _buildStringTile(StringDef def) {
    return ListTile(
      title: Text(def.title),
      subtitle: def.description != null ? Text(def.description!) : null,
      trailing: SizedBox(
        width: 140,
        child: TextField(
          controller: TextEditingController(text: _store.getString(def)),
          decoration: const InputDecoration(
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) {
            final trimmed = v.trim();
            if (trimmed.isNotEmpty) {
              _store.setString(def, trimmed);
              _changed();
            }
          },
        ),
      ),
    );
  }

  Future<void> _showColorPicker(ColorDef def, Color currentColor) async {
    final result = await showColorPickerDialog(
      context,
      currentColor,
      title: Text(t.settingsWidget.pickColor, style: const TextStyle(fontWeight: FontWeight.bold)),
      width: 44,
      height: 44,
      spacing: 6,
      runSpacing: 6,
      borderRadius: 8,
      wheelDiameter: 220,
      wheelWidth: 24,
      enableOpacity: false,
      showColorCode: true,
      colorCodeHasColor: true,
      pickersEnabled: const <ColorPickerType, bool>{
        ColorPickerType.both: false,
        ColorPickerType.primary: true,
        ColorPickerType.accent: false,
        ColorPickerType.bw: false,
        ColorPickerType.custom: false,
        ColorPickerType.wheel: true,
      },
      actionButtons: ColorPickerActionButtons(
        okButton: true,
        closeButton: true,
        dialogActionButtons: true,
        dialogOkButtonType: ColorPickerActionButtonType.elevated,
        dialogOkButtonLabel: t.common.ok,
        dialogCancelButtonLabel: t.common.cancel,
      ),
    );
    if (result != currentColor) {
      await _store.setColor(def, result);
      _changed();
    }
  }
}

