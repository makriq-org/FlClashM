import 'package:flclashx/common/common.dart';
import 'package:flclashx/common/yaml_highlight.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/state.dart';
import 'package:flclashx/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

typedef TextEditingValueChangeBuilder = Widget Function(TextEditingValue value);

class EditorPage extends ConsumerStatefulWidget {
  const EditorPage({
    super.key,
    required this.title,
    required this.content,
    this.titleEditable = false,
    this.onSave,
    this.onPop,
    this.supportRemoteDownload = false,
    this.languages = const [Language.yaml],
  });

  final String title;
  final String content;
  final List<Language> languages;
  final bool supportRemoteDownload;
  final bool titleEditable;
  final Function(BuildContext context, String title, String content)? onSave;
  final Future<bool> Function(
      BuildContext context, String title, String content)? onPop;

  @override
  ConsumerState<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends ConsumerState<EditorPage> {
  late TextEditingController _controller;
  late TextEditingController _titleController;
  late ScrollController _scrollController;
  bool _showSearch = false;
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller = widget.languages.contains(Language.yaml)
        ? YamlHighlightController(text: widget.content)
        : TextEditingController(text: widget.content);
    _titleController = TextEditingController(text: widget.title);
    _scrollController = ScrollController();
  }

  @override
  void dispose() {
    _controller.dispose();
    _titleController.dispose();
    _scrollController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  Widget _wrapTitleController(TextEditingValueChangeBuilder builder) =>
      ValueListenableBuilder(
        valueListenable: _titleController,
        builder: (_, value, ___) => builder(value),
      );

  Widget _wrapController(TextEditingValueChangeBuilder builder) =>
      ValueListenableBuilder(
        valueListenable: _controller,
        builder: (_, value, ___) => builder(value),
      );

  TextStyle get _editorStyle => TextStyle(
        fontSize: context.textTheme.bodyLarge?.fontSize?.ap,
        fontFamily: FontFamily.jetBrainsMono.value,
        height: 1.5,
      );

  void _toggleSearch() {
    setState(() {
      _showSearch = !_showSearch;
      if (_showSearch) {
        Future.microtask(() => _searchFocusNode.requestFocus());
      } else if (_controller is YamlHighlightController) {
        (_controller as YamlHighlightController).setSearch('', [], -1);
      }
    });
  }

  Future<void> _handleImport() async {
    final option = await globalState.showCommonDialog<ImportOption>(
      child: const _ImportOptionsDialog(),
    );
    if (option == null) return;
    if (option == ImportOption.file) {
      final file = await picker.pickerFile();
      if (file == null) return;
      _controller.text = String.fromCharCodes(file.bytes?.toList() ?? []);
      return;
    }
    final url = await globalState.showCommonDialog(
      child: InputDialog(
        title: "导入",
        value: "",
        labelText: appLocalizations.url,
        validator: (value) {
          if (value == null || value.isEmpty) {
            return appLocalizations.emptyTip(appLocalizations.value);
          }
          if (!value.isUrl) {
            return appLocalizations.urlTip(appLocalizations.value);
          }
          return null;
        },
      ),
    );
    if (url == null) return;
    final res = await request.getTextResponseForUrl(url);
    _controller.text = res.data;
  }

  @override
  Widget build(BuildContext context) {
    return CommonPopScope(
      onPop: () async {
        if (widget.onPop == null) return true;
        final res = await widget.onPop!(
            context, _titleController.text, _controller.text);
        if (res && context.mounted) return true;
        return false;
      },
      child: CommonScaffold(
        disableBackground: true,
        appBar: AppBar(
          title: TextField(
            enabled: widget.titleEditable,
            controller: _titleController,
            decoration: InputDecoration(
              border: const _NoInputBorder(),
              hintText: appLocalizations.unnamed,
            ),
            style: context.textTheme.titleLarge,
            autofocus: false,
          ),
          actions: genActions([
            if (widget.onSave != null)
              _wrapController(
                (_) => _wrapTitleController(
                  (_) => IconButton(
                    onPressed: _controller.text != widget.content ||
                            _titleController.text != widget.title
                        ? () => widget.onSave!(
                            context, _titleController.text, _controller.text)
                        : null,
                    icon: const Icon(Icons.save_sharp),
                  ),
                ),
              ),
            if (widget.supportRemoteDownload)
              IconButton(
                onPressed: _handleImport,
                icon: const Icon(Icons.arrow_downward),
              ),
            IconButton(
              onPressed: _toggleSearch,
              icon: const Icon(Icons.search),
            ),
          ]),
        ),
        body: Column(
          children: [
            if (_showSearch)
              _SearchBar(
                searchController: _searchController,
                focusNode: _searchFocusNode,
                editorController: _controller,
                scrollController: _scrollController,
                onClose: _toggleSearch,
              ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return SingleChildScrollView(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _LineGutter(
                          controller: _controller,
                          style: _editorStyle,
                          totalWidth: constraints.maxWidth,
                        ),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.only(right: 16),
                            child: TextField(
                              controller: _controller,
                              maxLines: null,
                              style: _editorStyle,
                              decoration: const InputDecoration(
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LineGutter extends StatelessWidget {
  const _LineGutter({
    required this.controller,
    required this.style,
    required this.totalWidth,
  });

  final TextEditingController controller;
  final TextStyle style;
  final double totalWidth;

  static const _padLeft = 12.0;
  static const _padRight = 8.0;
  static const _textPadRight = 16.0;

  @override
  Widget build(BuildContext context) {
    final gutterColor = context.colorScheme.onSurface.withValues(alpha: 0.38);
    final gutterStyle = style.copyWith(color: gutterColor);
    final textScaler = MediaQuery.textScalerOf(context);

    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final lines = value.text.split('\n');
        final digits = lines.length.toString().length.clamp(2, 6);

        final digitPainter = TextPainter(
          text: TextSpan(text: '0' * (digits + 1), style: gutterStyle),
          textDirection: TextDirection.ltr,
          textScaler: textScaler,
        )..layout();
        final gutterContentWidth = digitPainter.width.ceilToDouble();
        digitPainter.dispose();

        final gutterWidth = _padLeft + gutterContentWidth + _padRight;
        final textAreaWidth = totalWidth - gutterWidth - _textPadRight;

        final painter = TextPainter(
          textDirection: TextDirection.ltr,
          textScaler: textScaler,
        );

        final children = <Widget>[];
        for (var i = 0; i < lines.length; i++) {
          painter.text = TextSpan(
            text: lines[i].isEmpty ? ' ' : lines[i],
            style: style,
          );
          painter.layout(
            maxWidth: textAreaWidth > 0 ? textAreaWidth : double.infinity,
          );
          children.add(SizedBox(
            height: painter.height,
            child: Text('${i + 1}', style: gutterStyle),
          ));
        }
        painter.dispose();

        return SizedBox(
          width: gutterWidth,
          child: Padding(
            padding: const EdgeInsets.only(left: _padLeft, right: _padRight),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: children,
            ),
          ),
        );
      },
    );
  }
}

class _SearchBar extends StatefulWidget {
  const _SearchBar({
    required this.searchController,
    required this.focusNode,
    required this.editorController,
    required this.scrollController,
    required this.onClose,
  });

  final TextEditingController searchController;
  final FocusNode focusNode;
  final TextEditingController editorController;
  final ScrollController scrollController;
  final VoidCallback onClose;

  @override
  State<_SearchBar> createState() => _SearchBarState();
}

class _SearchBarState extends State<_SearchBar> {
  List<int> _matches = [];
  int _current = -1;

  void _notifyHighlight() {
    final ctrl = widget.editorController;
    if (ctrl is YamlHighlightController) {
      ctrl.setSearch(widget.searchController.text, _matches, _current);
    }
  }

  void _search(String query) {
    if (query.isEmpty) {
      setState(() { _matches = []; _current = -1; });
      _notifyHighlight();
      return;
    }
    final text = widget.editorController.text.toLowerCase();
    final q = query.toLowerCase();
    final matches = <int>[];
    var start = 0;
    while (true) {
      final idx = text.indexOf(q, start);
      if (idx == -1) break;
      matches.add(idx);
      start = idx + 1;
    }
    setState(() {
      _matches = matches;
      _current = matches.isNotEmpty ? 0 : -1;
    });
    _notifyHighlight();
    _goToMatch();
  }

  void _next() {
    if (_matches.isEmpty) return;
    setState(() => _current = (_current + 1) % _matches.length);
    _notifyHighlight();
    _goToMatch();
  }

  void _prev() {
    if (_matches.isEmpty) return;
    setState(() =>
        _current = (_current - 1 + _matches.length) % _matches.length);
    _notifyHighlight();
    _goToMatch();
  }

  void _goToMatch() {
    if (_current < 0 || _current >= _matches.length) return;
    final pos = _matches[_current];
    final len = widget.searchController.text.length;
    widget.editorController.selection =
        TextSelection(baseOffset: pos, extentOffset: pos + len);

    if (!widget.scrollController.hasClients) return;
    final text = widget.editorController.text;
    final linesBefore = '\n'.allMatches(text.substring(0, pos)).length;
    final lineHeight = (Theme.of(context).textTheme.bodyLarge?.fontSize ?? 14) * 1.5;
    final target = linesBefore * lineHeight;
    final maxScroll = widget.scrollController.position.maxScrollExtent;
    final viewportHeight = widget.scrollController.position.viewportDimension;
    widget.scrollController.animateTo(
      (target - viewportHeight / 3).clamp(0.0, maxScroll),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final result = _matches.isNotEmpty
        ? '${_current + 1}/${_matches.length}'
        : appLocalizations.none;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: widget.searchController,
              focusNode: widget.focusNode,
              maxLines: 1,
              decoration: InputDecoration(
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                hintText: appLocalizations.search,
              ),
              style: Theme.of(context).textTheme.bodyMedium,
              onChanged: _search,
              onSubmitted: (_) => _next(),
            ),
          ),
          const SizedBox(width: 8),
          Text(result, style: Theme.of(context).textTheme.bodySmall),
          IconButton(
            icon: const Icon(Icons.arrow_upward, size: 16),
            visualDensity: VisualDensity.compact,
            onPressed: _matches.isNotEmpty ? _prev : null,
          ),
          IconButton(
            icon: const Icon(Icons.arrow_downward, size: 16),
            visualDensity: VisualDensity.compact,
            onPressed: _matches.isNotEmpty ? _next : null,
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            visualDensity: VisualDensity.compact,
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }
}

class _NoInputBorder extends InputBorder {
  const _NoInputBorder() : super(borderSide: BorderSide.none);
  @override
  _NoInputBorder copyWith({BorderSide? borderSide}) => const _NoInputBorder();
  @override
  bool get isOutline => false;
  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;
  @override
  _NoInputBorder scale(double t) => const _NoInputBorder();
  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addRect(rect);
  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addRect(rect);
  @override
  void paintInterior(Canvas canvas, Rect rect, Paint paint,
      {TextDirection? textDirection}) {
    canvas.drawRect(rect, paint);
  }
  @override
  bool get preferPaintInterior => true;
  @override
  void paint(Canvas canvas, Rect rect,
      {double? gapStart,
      double gapExtent = 0.0,
      double gapPercentage = 0.0,
      TextDirection? textDirection}) {}
}

class _ImportOptionsDialog extends StatefulWidget {
  const _ImportOptionsDialog();
  @override
  State<_ImportOptionsDialog> createState() => _ImportOptionsDialogState();
}

class _ImportOptionsDialogState extends State<_ImportOptionsDialog> {
  void _handleOnTab(ImportOption value) => Navigator.of(context).pop(value);

  @override
  Widget build(BuildContext context) => CommonDialog(
        title: appLocalizations.import,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 16),
        child: Wrap(
          children: [
            ListItem(
              onTap: () => _handleOnTab(ImportOption.url),
              title: Text(appLocalizations.importUrl),
            ),
            ListItem(
              onTap: () => _handleOnTab(ImportOption.file),
              title: Text(appLocalizations.importFile),
            ),
          ],
        ),
      );
}
