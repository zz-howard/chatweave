import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:chatweave_flutter/chatweave_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  await loadVerifiedTestFont();
  await testMain();
}

Future<void> loadVerifiedTestFont({String fontDirectory = 'test/fonts'}) async {
  final manifest =
      jsonDecode(File('$fontDirectory/manifest.json').readAsStringSync())
          as Map<String, dynamic>;
  final bytes = File('$fontDirectory/ChatWeaveTestSans.otf').readAsBytesSync();
  if (sha256.convert(bytes).toString() != manifest['outputSha256']) {
    throw StateError('ChatWeave test font SHA-256 mismatch');
  }
  // TestWidgetsFlutterBinding uses Ahem in default styles, including the
  // library's inherited TextStyles. Replace only the test font registration.
  for (final family in ['Ahem', 'Roboto', 'ChatWeaveTestSans']) {
    final loader = FontLoader(family)
      ..addFont(Future<ByteData>.value(
          ByteData.sublistView(Uint8List.fromList(bytes))));
    await loader.load();
  }
}

ChatWeaveThemeData testFontTheme(bool dark) {
  final base = dark
      ? ChatWeaveThemeData.neutralDark()
      : ChatWeaveThemeData.neutralLight();
  return ChatWeaveThemeData(
      brightness: base.brightness,
      surface: base.surface,
      onSurface: base.onSurface,
      muted: base.muted,
      outline: base.outline,
      accent: base.accent,
      onAccent: base.onAccent,
      warning: base.warning,
      critical: base.critical,
      chartPalette: base.chartPalette,
      body: base.body.copyWith(fontFamily: 'ChatWeaveTestSans'),
      caption: base.caption.copyWith(fontFamily: 'ChatWeaveTestSans'),
      title: base.title.copyWith(fontFamily: 'ChatWeaveTestSans'),
      numeric: base.numeric.copyWith(fontFamily: 'ChatWeaveTestSans'),
      spacing: base.spacing,
      radius: base.radius);
}
