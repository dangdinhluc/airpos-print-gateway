class StarMarkup {
  const StarMarkup._();

  static String receipt(String text) {
    final lines = <String>[
      '[font: b]',
      '[linespacing: min]',
      '[align: center]',
    ];
    for (final raw in text.split('\n')) {
      final line = raw.replaceAll(RegExp(r'^[\x01-\x08]+'), '').trimRight();
      if (line.isEmpty) continue;
      if (RegExp(r'^[-─]{3,}$').hasMatch(line)) {
        lines.add('[fixedWidth: text --------------------------------]');
        continue;
      }
      final pair = RegExp(r'^(.*?)\s+(¥[0-9][0-9,]*)\s*$').firstMatch(line);
      if (pair != null && pair.group(1)!.trim().isNotEmpty) {
        lines.add('[align: left]');
        lines.add(
          '[column: left ${pair.group(1)!.trimRight()}; right ${pair.group(2)!}]',
        );
        continue;
      }
      lines.add('[align: center]');
      lines.add(line.trim());
    }
    lines.add('[cut: feed; partial]');
    return lines.join('\n');
  }
}
