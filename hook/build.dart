// Flutter GPU のシェーダ束（terrain.shaderbundle）をビルド時に作る build hook。
// `flutter build` / `flutter run` が自動で呼ぶ。出力は build/shaderbundles/terrain.shaderbundle
// （pubspec.yaml の assets に載せてある）。設計は docs/technical/terrain-3d.md「flutter_gpu スパイク」
import 'package:flutter_gpu_shaders/build.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    await buildShaderBundleJson(
      buildInput: input,
      buildOutput: output,
      manifestFileName: 'terrain.shaderbundle.json',
    );
  });
}
