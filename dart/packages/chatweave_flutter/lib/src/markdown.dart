import 'default_boundary.dart';
import 'localizations.dart';

import 'package:chatweave_core/chatweave_core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import 'theme.dart';

bool allowedLink(String href, [bool Function(Uri)? allow]) {
  final uri = Uri.tryParse(href);
  if (uri == null ||
      const {'javascript', 'data', 'file'}.contains(uri.scheme.toLowerCase()))
    return false;
  return (uri.scheme == 'https' && uri.host.isNotEmpty) ||
      (allow?.call(uri) ?? false);
}

/// Runs before the Markdown parser, including image/HTML/link syntax.
/// Code spans and fenced code are passed through byte-for-byte.
String safeMarkdown(
  String source, {
  bool Function(Uri)? isAllowedLink,
  String imageLabel = '图片：',
}) {
  final output = StringBuffer();
  var fenced = false;
  for (final line in source.split('\n')) {
    if (RegExp(r'^\s*(```|~~~)').hasMatch(line)) {
      fenced = !fenced;
      output.writeln(line);
      continue;
    }
    if (fenced) {
      output.writeln(line);
      continue;
    }
    // Scan code separately because String.split discards capture groups.
    var offset = 0;
    final code = RegExp(r'(`+)(.*?)\1');
    String clean(String text) {
      var result = text.replaceAllMapped(RegExp(r'!\[([^\]]*)\]\(([^)]*)\)'), (
        m,
      ) {
        final href = m[2]!;
        return allowedLink(href, isAllowedLink)
            ? '[$imageLabel${m[1]}] [$href]($href)'
            : '[$imageLabel${m[1]}] $href';
      });
      result = result.replaceAllMapped(
        RegExp(r'\[([^\]]+)\]\(([^)]*)\)'),
        (m) => allowedLink(m[2]!, isAllowedLink) ? m[0]! : '${m[1]} (${m[2]})',
      );
      result = result.replaceAll('<', '&lt;').replaceAll('>', '&gt;');
      result = result.replaceAllMapped(
        RegExp(r'^(\s*[-+*]\s+)\[([ xX])\]'),
        (m) => '${m[1]}\\[${m[2]}\\]',
      );
      result = result.replaceAllMapped(
        RegExp(r'\[\^([^\]]+)\]'),
        (m) => '\\[\\^${m[1]}\\]',
      );
      return result;
    }

    for (final match in code.allMatches(line)) {
      output.write(clean(line.substring(offset, match.start)));
      output.write(match[0]);
      offset = match.end;
    }
    output.write(clean(line.substring(offset)));
    output.writeln();
    // Keep this local to parsing; no image builders or network widgets are used.
  }
  return output.toString();
}

List<md.Node> parseSafeMarkdown(
  String source, {
  bool Function(Uri)? isAllowedLink,
  String imageLabel = '图片：',
}) {
  final document = md.Document(
    extensionSet: md.ExtensionSet([
      ...md.ExtensionSet.commonMark.blockSyntaxes,
      const md.TableSyntax(),
    ], md.ExtensionSet.commonMark.inlineSyntaxes),
    encodeHtml: false,
  );
  final parsed = document.parseLines(
    safeMarkdown(
      source,
      isAllowedLink: isAllowedLink,
      imageLabel: imageLabel,
    ).split('\n'),
  );
  const allowed = {
    'p',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'strong',
    'em',
    'blockquote',
    'ul',
    'ol',
    'li',
    'hr',
    'pre',
    'code',
    'a',
    'br',
    'table',
    'thead',
    'tbody',
    'tr',
    'th',
    'td',
  };
  md.Node restrict(md.Node node) {
    if (node is! md.Element) return node;
    if (node.tag == 'pre' || node.tag == 'code') return node;
    if (node.tag == 'img')
      return md.Text('[$imageLabel${node.attributes['alt'] ?? ''}]');
    if (!allowed.contains(node.tag)) return md.Text(node.textContent);
    if (node.tag == 'a' &&
        !allowedLink(node.attributes['href'] ?? '', isAllowedLink)) {
      return md.Text('${node.textContent} (${node.attributes['href'] ?? ''})');
    }
    if (node.tag == 'table') {
      final head = node.children
          ?.whereType<md.Element>()
          .where((n) => n.tag == 'thead')
          .firstOrNull;
      final row = head?.children?.whereType<md.Element>().firstOrNull;
      if ((row?.children?.length ?? 0) > 8) return md.Text(node.textContent);
    }
    final result = md.Element(
      node.tag,
      (node.children ?? []).map(restrict).toList(),
    );
    result.attributes.addAll(node.attributes);
    return result;
  }

  return parsed.map(restrict).toList();
}

class IncrementalDocument {
  IncrementalDocument({this.isAllowedLink, this.imageLabel = '图片：'});
  final String imageLabel;
  final bool Function(Uri)? isAllowedLink;
  final List<String> stable = [];
  final List<List<md.Node>> stableNodes = [];
  List<md.Node> tailNodes = [];
  String tail = '';
  int tailParseCount = 0;
  int stableParseCount = 0;
  String _source = '';
  bool _complete = false;
  String _parsedTail = '';
  List<md.Node> _parsedNodes = [];
  bool _global = false;
  int fullParseCount = 0;
  int parsedCharacters = 0;
  void update(String source, {bool complete = false}) {
    if (source == _source && (!complete || _complete)) return;
    _complete = complete;
    final append = source.startsWith(_source);
    if (!append) {
      stable.clear();
      stableNodes.clear();
      tail = '';
      _source = '';
      _parsedTail = '';
      _parsedNodes = [];
      _global = false;
    }
    // Lists may span blank lines; references can change links in prior paragraphs.
    final global = RegExp(r'(^|\n) {0,3}(?:[-+*] |[0-9]+[.)] |\[[^\]]+\]:)')
        .hasMatch(source);
    if (global && !_global) {
      stable.clear();
      stableNodes.clear();
      tail = '';
      _source = '';
      _parsedTail = '';
      _parsedNodes = [];
    }
    _global = global;
    tail += source.substring(_source.length);
    _source = source;
    var fenced = false;
    var boundary = 0;
    var offset = 0;
    if (!_global) {
      for (final line in tail.split('\n')) {
        if (RegExp(r'^\s*(```|~~~)').hasMatch(line)) fenced = !fenced;
        offset += line.length + 1;
        if (!fenced && line.isEmpty && offset <= tail.length) boundary = offset;
      }
    }
    if (boundary > 0) {
      final sealed = tail.substring(0, boundary);
      stable.add(sealed);
      stableNodes.add(
        parseSafeMarkdown(
          sealed,
          isAllowedLink: isAllowedLink,
          imageLabel: imageLabel,
        ),
      );
      stableParseCount++;
      parsedCharacters += sealed.length;
      tail = tail.substring(boundary);
      _parsedTail = '';
      _parsedNodes = [];
    }
    // Geometric parsing bounds the total parser input for an unbroken tail.
    // Between parses, show every new character as literal text. Finalization
    // always reparses so loose lists and forward references are exact.
    if (complete ||
        _parsedTail.isEmpty ||
        tail.length - _parsedTail.length >=
            (_parsedTail.length < 256 ? 256 : _parsedTail.length)) {
      _parsedNodes = parseSafeMarkdown(
        tail,
        isAllowedLink: isAllowedLink,
        imageLabel: imageLabel,
      );
      _parsedTail = tail;
      tailParseCount++;
      if (_global) fullParseCount++;
      parsedCharacters += tail.length;
    }
    tailNodes = [..._parsedNodes];
    if (tail.length > _parsedTail.length) {
      final literal = md.Text(tail.substring(_parsedTail.length));
      final last = tailNodes.lastOrNull;
      if (last is md.Element && last.tag == 'p') {
        final merged = md.Element('p', [...?last.children, literal]);
        merged.attributes.addAll(last.attributes);
        tailNodes[tailNodes.length - 1] = merged;
      } else {
        tailNodes.add(md.Element('p', [literal]));
      }
    }
  }
}

class MarkdownBlockView extends StatefulWidget {
  const MarkdownBlockView({
    super.key,
    required this.text,
    this.complete = true,
    this.isAllowedLink,
    this.onLinkTap,
  });
  final String text;
  final bool complete;
  final bool Function(Uri)? isAllowedLink;
  final void Function(Uri)? onLinkTap;
  @override
  State<MarkdownBlockView> createState() => _MarkdownBlockViewState();
}

class _MarkdownBlockViewState extends State<MarkdownBlockView>
    implements MarkdownBuilderDelegate {
  late IncrementalDocument document;
  final _recognizers = <TapGestureRecognizer>[];
  @override
  void initState() {
    super.initState();
    document = IncrementalDocument(isAllowedLink: widget.isAllowedLink);
  }

  @override
  void didUpdateWidget(MarkdownBlockView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isAllowedLink != widget.isAllowedLink) {
      document = IncrementalDocument(isAllowedLink: widget.isAllowedLink);
    }
  }

  @override
  Widget build(BuildContext context) =>
      guardedDefaultBuild(context, () => buildDefault(context));

  Widget buildDefault(BuildContext context) {
    final imageLabel = cw(context, '图片：');
    if (document.imageLabel != imageLabel) {
      document = IncrementalDocument(
        isAllowedLink: widget.isAllowedLink,
        imageLabel: imageLabel,
      );
    }
    document.update(widget.text, complete: widget.complete);
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
    final builder = MarkdownBuilder(
      delegate: this,
      selectable: false,
      styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
        p: ChatWeaveTheme.of(context)
            .body
            .copyWith(color: ChatWeaveTheme.of(context).onSurface),
      ),
      imageDirectory: null,
      imageBuilder: null,
      checkboxBuilder: null,
      bulletBuilder: null,
      builders: const {},
      paddingBuilders: const {},
      listItemCrossAxisAlignment: MarkdownListItemCrossAxisAlignment.start,
      softLineBreak: true,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final nodes in [...document.stableNodes, document.tailNodes])
          ...builder.build(nodes),
      ],
    );
  }

  @override
  GestureRecognizer createLink(String text, String? href, String title) {
    final recognizer = TapGestureRecognizer()
      ..onTap = () async {
        if (href == null || !allowedLink(href, widget.isAllowedLink)) return;
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const DefaultLabel('打开链接'),
            content: SelectableText(href),
            actions: [
              ChatWeaveTextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const DefaultLabel('取消'),
              ),
              ChatWeaveTextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const DefaultLabel('打开'),
              ),
            ],
          ),
        );
        if (confirmed == true) widget.onLinkTap?.call(Uri.parse(href));
      };
    _recognizers.add(recognizer);
    return recognizer;
  }

  @override
  TextSpan formatText(MarkdownStyleSheet styleSheet, String code) =>
      TextSpan(text: code, style: styleSheet.code);
  @override
  void dispose() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    super.dispose();
  }
}

String plainTextSummary(Message message, int maxChars) {
  final text = message.blocks
      .map(
        (b) => b.type == 'markdown'
            ? parseSafeMarkdown(b.data['text'] as String? ?? '')
                .map((n) => n.textContent)
                .join('\n')
            : b['fallbackText'] as String? ?? '',
      )
      .join('\n');
  return String.fromCharCodes(text.runes.take(maxChars < 0 ? 0 : maxChars));
}
