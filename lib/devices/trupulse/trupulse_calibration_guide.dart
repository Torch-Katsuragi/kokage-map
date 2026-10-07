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
/// TruPulse キャリブレーション ガイド画面
///
/// デバイス本体で実行するキャリブレーション手順を
/// ステップバイステップで案内する（アプリからのコマンド送信なし）。
/// 手順は TruPulse 360R マニュアル Section 4 に基づく。
library;

import 'package:flutter/material.dart';
import '../../i18n/strings.g.dart';
import 'trupulse_service.dart';

enum CalibrationType { tilt, compass }

class TruPulseCalibrationGuide extends StatefulWidget {
  final TruPulseService service;
  final CalibrationType type;

  const TruPulseCalibrationGuide({
    super.key,
    required this.service,
    required this.type,
  });

  @override
  State<TruPulseCalibrationGuide> createState() =>
      _TruPulseCalibrationGuideState();
}

class _TruPulseCalibrationGuideState extends State<TruPulseCalibrationGuide> {
  bool get _isTilt => widget.type == CalibrationType.tilt;
  int _currentStep = 0;

  /// 手順 3〜8 のアイコンは両方の較正で共通
  static const _commonIcons = [
    Icons.looks_one,
    Icons.looks_two,
    Icons.looks_3,
    Icons.looks_4,
    Icons.looks_5,
    Icons.check_circle_outline,
  ];

  /// 手順の一覧。Tilt はマニュアル p.24-26、Compass は p.32-34。
  /// 言語が変わりうるので build ごとに 1 回だけ組む
  List<_Step> _buildSteps() {
    final List<IconData> icons;
    final List<(String, String)> texts;
    if (_isTilt) {
      final g = t.trupulse.guide.tilt;
      icons = const [Icons.settings, Icons.phone_android, ..._commonIcons];
      texts = [
        (g.step1Title, g.step1Detail),
        (g.step2Title, g.step2Detail),
        (g.step3Title, g.step3Detail),
        (g.step4Title, g.step4Detail),
        (g.step5Title, g.step5Detail),
        (g.step6Title, g.step6Detail),
        (g.step7Title, g.step7Detail),
        (g.step8Title, g.step8Detail),
      ];
    } else {
      final g = t.trupulse.guide.compass;
      icons = const [Icons.warning_amber, Icons.settings, ..._commonIcons];
      texts = [
        (g.step1Title, g.step1Detail),
        (g.step2Title, g.step2Detail),
        (g.step3Title, g.step3Detail),
        (g.step4Title, g.step4Detail),
        (g.step5Title, g.step5Detail),
        (g.step6Title, g.step6Detail),
        (g.step7Title, g.step7Detail),
        (g.step8Title, g.step8Detail),
      ];
    }
    return [
      for (var i = 0; i < texts.length; i++)
        _Step(icon: icons[i], title: texts[i].$1, detail: texts[i].$2),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final steps = _buildSteps();
    final title = _isTilt
        ? t.trupulse.detail.tiltCalibration
        : t.trupulse.detail.compassCalibration;

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(4),
          child: LinearProgressIndicator(
            value: (_currentStep + 1) / steps.length,
          ),
        ),
      ),
      body: Column(
        children: [
          _buildStepHeader(theme, steps),
          const Divider(height: 1),
          Expanded(child: _buildStepDetail(theme, steps)),
          _buildNavigation(steps.length),
        ],
      ),
    );
  }

  /// 番号・「n / N」・手順名・アイコン
  Widget _buildStepHeader(ThemeData theme, List<_Step> steps) {
    final step = steps[_currentStep];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        children: [
          CircleAvatar(
            radius: 20,
            backgroundColor: theme.colorScheme.primaryContainer,
            child: Text(
              '${_currentStep + 1}',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 18,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.trupulse.guide.stepOf(
                    current: _currentStep + 1,
                    total: steps.length,
                  ),
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  step.title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          Icon(step.icon, size: 32, color: theme.colorScheme.primary),
        ],
      ),
    );
  }

  /// 今の手順の説明と、全手順の一覧
  Widget _buildStepDetail(ThemeData theme, List<_Step> steps) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              steps[_currentStep].detail,
              style: const TextStyle(fontSize: 14, height: 1.6),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            t.trupulse.guide.allSteps,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          for (int i = 0; i < steps.length; i++)
            _miniStepRow(i, steps[i].title, theme),
        ],
      ),
    );
  }

  /// 戻る / 次へ / 完了
  Widget _buildNavigation(int stepCount) {
    final isFirst = _currentStep == 0;
    final isLast = _currentStep == stepCount - 1;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          if (!isFirst)
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => setState(() => _currentStep--),
                icon: const Icon(Icons.arrow_back),
                label: Text(t.trupulse.guide.back),
              ),
            ),
          if (!isFirst && !isLast) const SizedBox(width: 12),
          Expanded(
            child: isLast
                ? FilledButton.icon(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.check),
                    label: Text(t.trupulse.guide.done),
                  )
                : FilledButton.icon(
                    onPressed: () => setState(() => _currentStep++),
                    icon: const Icon(Icons.arrow_forward),
                    label: Text(t.trupulse.guide.next),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _miniStepRow(int index, String title, ThemeData theme) {
    final isCurrent = index == _currentStep;
    final isPast = index < _currentStep;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: InkWell(
        onTap: () => setState(() => _currentStep = index),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
          child: Row(
            children: [
              CircleAvatar(
                radius: 12,
                backgroundColor: isCurrent
                    ? theme.colorScheme.primary
                    : isPast
                    ? theme.colorScheme.primaryContainer
                    : theme.colorScheme.surfaceContainerHighest,
                child: Text(
                  '${index + 1}',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: isCurrent
                        ? theme.colorScheme.onPrimary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: isCurrent ? FontWeight.w600 : null,
                    color: isCurrent
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (isPast)
                Icon(Icons.check, size: 16, color: theme.colorScheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}

class _Step {
  final IconData icon;
  final String title;
  final String detail;
  const _Step({required this.icon, required this.title, required this.detail});
}
