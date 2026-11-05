import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

import 'manage_models.dart';
import 'manage_rich_text.dart';
import 'manage_service.dart';

/// Formulário universal de criação/edição — renderiza os campos do schema
/// do bundle (GET /manage/schemas) sem nada hardcoded por setor.
/// kinds suportados: text, longtext, number, email, link, date, daterange,
/// bool, reference (single + multiple), image, file.
class ManageFormPage extends StatefulWidget {
  const ManageFormPage({super.key, required this.bundle, this.nid});

  final ManageBundle bundle;
  final int? nid;

  bool get editing => nid != null;

  @override
  State<ManageFormPage> createState() => _ManageFormPageState();
}

class _ManageFormPageState extends State<ManageFormPage> {
  final _formKey = GlobalKey<FormState>();
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, QuillController> _richControllers = {};
  final Map<String, bool> _bools = {};
  final Map<String, DateTime?> _dates = {};
  final Map<String, List<ManageOption>> _refSelections = {};
  final Map<String, List<String>> _fileUuids = {};
  List<ManageBundle> _allBundles = const [];
  final Map<String, List<ManageOption>> _refOptions = {};
  final Map<String, bool> _optionsLoading = {};

  bool _published = false;
  bool _loading = false;
  bool _saving = false;
  String? _error;

  bool get editing => widget.editing;

  @override
  void initState() {
    super.initState();
    ManageService.schemas().then((b) {
      if (mounted) setState(() => _allBundles = b);
    }).ignore();

    _initFields();
    if (editing) _loadDetail();
  }

  void _initFields() {
    for (final f in widget.bundle.fields) {
      switch (f.kind) {
        case 'bool':
          _bools[f.name] = false;
        case 'date':
          _dates[f.name] = null;
        case 'reference':
          _refSelections[f.name] = [];
        case 'image' || 'file':
          _fileUuids[f.name] = [];
        case 'longtext':
          _richControllers[f.name] = QuillController.basic();
        default:
          _controllers[f.name] = TextEditingController();
      }
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    for (final c in _richControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadDetail() async {
    setState(() => _loading = true);
    try {
      final detail =
          await ManageService.detail(widget.bundle.name, widget.nid!);
      if (!mounted) return;
      final values =
          Map<String, dynamic>.from(detail['values'] as Map? ?? {});
      final rels =
          Map<String, dynamic>.from(detail['relationships'] as Map? ?? {});
      setState(() {
        _published = detail['status'] == true;
        for (final f in widget.bundle.fields) {
          final raw = values[f.name];
          switch (f.kind) {
            case 'bool':
              _bools[f.name] = raw == true;
            case 'date':
              _dates[f.name] = _parseDate(raw);
            case 'daterange':
              final start = _controllers['${f.name}__start'] ??=
                  TextEditingController();
              final end = _controllers['${f.name}__end'] ??=
                  TextEditingController();
              if (raw is Map) {
                start.text = _dateText(_parseDate(raw['value']));
                end.text = _dateText(_parseDate(raw['end_value']));
              }
            case 'longtext':
              final html =
                  raw is Map ? (raw['value']?.toString() ?? '') : '${raw ?? ''}';
              _richControllers[f.name]?.document =
                  Document.fromDelta(ManageRichTextField.htmlToDelta(html));
            case 'link':
              _controllers[f.name]?.text =
                  raw is Map ? (raw['uri']?.toString() ?? '') : '${raw ?? ''}';
            case 'number':
              _controllers[f.name]?.text = _scalarText(raw);
            case 'reference':
              _prefillRefs(f, rels[f.name]);
            case 'image' || 'file':
              _fileUuids[f.name] = _relUuids(rels[f.name]);
            default:
              _controllers[f.name]?.text = _scalarText(raw);
          }
        }
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Não foi possível carregar o registro.';
        _loading = false;
      });
    }
  }

  /// Prefills a reference field by matching the stored uuids to the
  /// option list (options carry nid + uuid).
  Future<void> _prefillRefs(ManageField field, dynamic rel) async {
    final uuids = _relUuids(rel);
    if (uuids.isEmpty || field.target == null) return;
    final options = await _loadOptions(field, force: true);
    final matched = options
        .where((o) => uuids.contains(o.uuid))
        .toList();
    if (!mounted || matched.isEmpty) return;
    setState(() => _refSelections[field.name] = matched);
  }

  List<String> _relUuids(dynamic rel) {
    if (rel is! Map) return const [];
    final data = rel['data'];
    final list = data is List ? data : [?data];
    return list
        .whereType<Map>()
        .map((e) => e['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toList();
  }

  Future<List<ManageOption>> _loadOptions(ManageField field,
      {bool force = false}) async {
    if (field.target == null) return const [];
    if (!force && _refOptions[field.name] != null) {
      return _refOptions[field.name]!;
    }
    if (_optionsLoading[field.name] == true) {
      return _refOptions[field.name] ?? const [];
    }
    _optionsLoading[field.name] = true;
    final options = await ManageService.options(field.target!);
    if (mounted) {
      setState(() {
        _refOptions[field.name] = options;
        _optionsLoading[field.name] = false;
      });
    }
    return options;
  }

  /// Atributos multivalorados do JSON:API chegam como lista — une os
  /// valores em texto em vez de exibir "[]" literal no campo.
  String _scalarText(dynamic raw) {
    if (raw == null) return '';
    if (raw is List) {
      return raw
          .map((e) => e is Map ? '${e['value'] ?? e}' : '$e')
          .join(', ');
    }
    return '$raw';
  }

  DateTime? _parseDate(dynamic raw) {
    if (raw == null) return null;
    // JSON:API datetime vem como {"value": "AAAA-MM-DD"}.
    if (raw is Map) raw = raw['value'];
    if (raw == null) return null;
    final s = raw.toString();
    return DateTime.tryParse(s.length > 10 ? s : '${s}T00:00:00');
  }

  String _dateText(DateTime? d) =>
      d == null ? '' : d.toIso8601String().substring(0, 10);

  Future<void> _pickDate(String name) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dates[name] ?? now,
      firstDate: DateTime(now.year - 10),
      lastDate: DateTime(now.year + 10),
    );
    if (picked != null) setState(() => _dates[name] = picked);
  }

  Future<void> _pickDateController(TextEditingController c) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(c.text) ?? now,
      firstDate: DateTime(now.year - 10),
      lastDate: DateTime(now.year + 10),
    );
    if (picked != null) {
      c.text = picked.toIso8601String().substring(0, 10);
    }
  }

  Future<void> _pickFile(ManageField field) async {
    final file = await FilePicker.pickFile(
      type: field.kind == 'image' ? FileType.image : FileType.any,
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) return;
    try {
      final uuid = await ManageService.upload(
        widget.bundle.name,
        field.name,
        filename: file.name,
        bytes: bytes,
      );
      if (!mounted || uuid.isEmpty) return;
      setState(() {
        if (field.multiple) {
          _fileUuids[field.name]!.add(uuid);
        } else {
          _fileUuids[field.name] = [uuid];
        }
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Upload recusado pelo portal.')),
      );
    }
  }

  Map<String, dynamic> _collectValues() {
    final values = <String, dynamic>{};
    for (final f in widget.bundle.fields) {
      switch (f.kind) {
        case 'bool':
          values[f.name] = _bools[f.name] ?? false;
        case 'date':
          final d = _dates[f.name];
          if (d != null) values[f.name] = _dateText(d);
        case 'daterange':
          final start = _controllers['${f.name}__start']?.text.trim() ?? '';
          final end = _controllers['${f.name}__end']?.text.trim() ?? '';
          if (start.isNotEmpty || end.isNotEmpty) {
            values[f.name] = {'start': start, 'end': end};
          }
        case 'number':
          final text = _controllers[f.name]?.text.trim() ?? '';
          if (text.isNotEmpty) values[f.name] = int.tryParse(text) ?? text;
        case 'reference':
          final sel = _refSelections[f.name] ?? const [];
          if (sel.isNotEmpty) {
            values[f.name] =
                f.multiple ? sel.map((o) => o.id).toList() : sel.first.id;
          }
        case 'image' || 'file':
          final uuids = _fileUuids[f.name] ?? const [];
          if (uuids.isNotEmpty) {
            values[f.name] = f.multiple ? uuids : uuids.first;
          }
        case 'longtext':
          final html = ManageRichTextField.deltaToHtml(
            _richControllers[f.name]!,
          );
          if (html.trim().isNotEmpty) {
            values[f.name] = {'value': html, 'format': 'basic_html'};
          }
        default:
          final text = _controllers[f.name]?.text.trim() ?? '';
          if (text.isNotEmpty) values[f.name] = text;
      }
    }
    return values;
  }

  bool _validateAll() => _formKey.currentState?.validate() ?? false;

  Future<void> _save() async {
    if (_saving || !_validateAll()) return;
    // Validação manual dos campos que o Form não alcança (datas, refs).
    for (final f in widget.bundle.fields) {
      if (!f.required) continue;
      final missing = switch (f.kind) {
        'date' => _dates[f.name] == null,
        'reference' => (_refSelections[f.name] ?? const []).isEmpty,
        'image' || 'file' => (_fileUuids[f.name] ?? const []).isEmpty,
        'longtext' => (_richControllers[f.name]?.document
                    .toPlainText()
                    .trim() ??
                '')
            .isEmpty,
        _ => false,
      };
      if (missing) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Informe ${f.label}.')),
        );
        return;
      }
    }
    setState(() => _saving = true);
    try {
      await ManageService.save(
        widget.bundle.name,
        nid: widget.nid,
        values: _collectValues(),
        published: _published,
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'O portal recusou o salvamento. Confira os campos.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          editing
              ? 'Editar ${widget.bundle.labelSingular}'
              : 'Novo ${widget.bundle.labelSingular}',
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _listForm(),
    );
  }

  /// Formulário plano — as etapas do schema viram seções empilhadas,
  /// todas visíveis de uma vez (mesmo padrão da ficha de detalhe).
  /// Fichas são preenchidas progressivamente: nenhuma etapa trava a
  /// edição e a validação só acontece no salvamento final.
  Widget _listForm() {
    final groups = <({String label, List<ManageField> fields})>[
      if (widget.bundle.steps.isEmpty)
        (label: '', fields: widget.bundle.fields)
      else
        for (final s in widget.bundle.steps)
          if (s.id != 'review')
            (label: s.label, fields: _fieldsOf(s.id)),
    ];
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (_error != null) ...[_errorCard(), const SizedBox(height: 12)],
          for (final g in groups)
            if (g.fields.isNotEmpty)
              Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (g.label.isNotEmpty) ...[
                        Text(
                          g.label,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const Divider(height: 18),
                      ],
                      for (final f in g.fields) ...[
                        _buildField(f),
                        const SizedBox(height: 14),
                      ],
                    ],
                  ),
                ),
              ),
          _publishSwitch(),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.save_outlined),
            label: Text(_saving ? 'Salvando…' : 'Salvar'),
          ),
        ],
      ),
    );
  }

  Widget _errorCard() => Card(
        color: Theme.of(context).colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(_error!),
        ),
      );

  Widget _publishSwitch() => SwitchListTile(
        value: _published,
        onChanged: (v) => setState(() => _published = v),
        title: const Text('Publicado no site'),
        subtitle: const Text(
          'Desligado mantém como rascunho — só quem pode revisar publica.',
        ),
      );

  List<ManageField> _fieldsOf(String group) =>
      widget.bundle.fields.where((f) => f.group == group).toList();

  Widget _buildField(ManageField f) {
    return switch (f.kind) {
      'bool' => SwitchListTile(
          value: _bools[f.name] ?? false,
          onChanged: (v) => setState(() => _bools[f.name] = v),
          title: Text(f.label),
        ),
      'date' => TextFormField(
          controller: TextEditingController(text: _dateText(_dates[f.name]))
            ..addListener(() {}),
          readOnly: true,
          validator: (v) => f.required && (_dates[f.name] == null)
              ? 'Informe ${f.label}.'
              : null,
          onTap: () => _pickDate(f.name),
          decoration: _decoration(f).copyWith(
            suffixIcon: const Icon(Icons.calendar_month_outlined),
          ),
        ),
      'daterange' => Row(
          children: [
            Expanded(
              child: TextFormField(
                controller: _controllers.putIfAbsent(
                    '${f.name}__start', TextEditingController.new),
                readOnly: true,
                onTap: () =>
                    _pickDateController(_controllers['${f.name}__start']!),
                decoration:
                    _decoration(f, label: '${f.label} — início').copyWith(
                  suffixIcon: const Icon(Icons.calendar_month_outlined),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextFormField(
                controller: _controllers.putIfAbsent(
                    '${f.name}__end', TextEditingController.new),
                readOnly: true,
                onTap: () =>
                    _pickDateController(_controllers['${f.name}__end']!),
                decoration: _decoration(f, label: '${f.label} — fim').copyWith(
                  suffixIcon: const Icon(Icons.calendar_month_outlined),
                ),
              ),
            ),
          ],
        ),
      'number' => TextFormField(
          controller: _controllers[f.name],
          keyboardType: TextInputType.number,
          validator: (v) => f.required && (v?.trim().isEmpty ?? true)
              ? 'Informe ${f.label}.'
              : null,
          decoration: _decoration(f),
        ),
      'email' => TextFormField(
          controller: _controllers[f.name],
          keyboardType: TextInputType.emailAddress,
          validator: (v) {
            if ((v?.trim().isEmpty ?? true)) {
              return f.required ? 'Informe ${f.label}.' : null;
            }
            return v!.contains('@') ? null : 'E-mail inválido.';
          },
          decoration: _decoration(f),
        ),
      'link' => TextFormField(
          controller: _controllers[f.name],
          keyboardType: TextInputType.url,
          validator: (v) => f.required && (v?.trim().isEmpty ?? true)
              ? 'Informe ${f.label}.'
              : null,
          decoration: _decoration(f, hint: f.hint ?? 'https://…'),
        ),
      'longtext' => ManageRichTextField(
          controller: _richControllers[f.name]!,
          label: f.required ? '${f.label} *' : f.label,
          hint: f.hint,
        ),
      'reference' => _referenceField(f),
      'image' || 'file' => _fileField(f),
      _ => _personAwareTextField(f),
    };
  }

  /// Campos de pessoa (autor, coordenador, equipe, participantes) são
  /// texto no Drupal — a ação lateral preenche o nome a partir do
  /// cadastro de pesquisadores ou abre "Cadastrar novo" quando a conta
  /// pode criar perfis. Mantém o contrato: o campo continua texto.
  bool _isPersonField(ManageField f) {
    const patterns = [
      'autor', 'coordenador', 'pesquisador',
      'participante', 'equipe', 'responsavel',
    ];
    return patterns.any((p) => f.name.contains(p));
  }

  Widget _personAwareTextField(ManageField f) {
    return TextFormField(
      controller: _controllers[f.name],
      validator: (v) => f.required && (v?.trim().isEmpty ?? true)
          ? 'Informe ${f.label}.'
          : null,
      decoration: _isPersonField(f)
          ? _decoration(f).copyWith(
              suffixIcon: IconButton(
                tooltip: 'Escolher pesquisador',
                icon: const Icon(Icons.person_search_outlined),
                onPressed: () => _pickPerson(f),
              ),
            )
          : _decoration(f),
    );
  }

  Future<void> _pickPerson(ManageField f) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _PersonPickerSheet(
        canCreate: _allBundles
                .where((b) => b.name == 'perfil_pesquisador')
                .firstOrNull
                ?.canCreate ==
            true,
        onCreateNew: () => Navigator.of(context).push<bool>(
          MaterialPageRoute(
            builder: (_) => ManageFormPage(
              bundle: _allBundles
                  .where((b) => b.name == 'perfil_pesquisador')
                  .first,
            ),
          ),
        ),
      ),
    );
    if (!mounted || picked == null || picked.isEmpty) return;
    final ctrl = _controllers[f.name];
    if (ctrl == null) return;
    final current = ctrl.text.trim();
    setState(() {
      ctrl.text =
          current.isEmpty ? picked : '$current; $picked';
    });
  }

  InputDecoration _decoration(ManageField f, {String? label, String? hint}) =>
      InputDecoration(
        labelText: label ?? f.label + (f.required ? ' *' : ''),
        helperText: hint ?? f.hint,
        border: const OutlineInputBorder(),
      );

  Widget _referenceField(ManageField f) {
    return FutureBuilder<List<ManageOption>>(
      future: _loadOptions(f),
      builder: (context, snapshot) {
        final options = snapshot.data ?? const [];
        final selected = _refSelections[f.name] ?? [];
        final loading = snapshot.connectionState == ConnectionState.waiting;
        if (f.multiple) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 6,
                children: [
                  for (final opt in selected)
                    Chip(
                      label: Text(opt.label),
                      onDeleted: () => setState(
                        () => selected.removeWhere((o) => o.id == opt.id),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              DropdownButtonFormField<int>(
                decoration: _decoration(f),
                initialValue: null,
                hint: Text(
                  loading
                      ? 'Carregando opções…'
                      : 'Adicionar ${f.label.toLowerCase()}',
                ),
                items: [
                  for (final opt in options)
                    if (!selected.any((s) => s.id == opt.id))
                      DropdownMenuItem(value: opt.id, child: Text(opt.label)),
                ],
                onChanged: (id) {
                  final opt = options.firstWhere((o) => o.id == id,
                      orElse: () => const ManageOption(id: 0, uuid: '', label: ''));
                  if (opt.id == 0) return;
                  setState(() => selected.add(opt));
                },
              ),
              _createOptionButton(f),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<int>(
              decoration: _decoration(f),
              initialValue: selected.isEmpty ? null : selected.first.id,
              hint: Text(loading ? 'Carregando opções…' : 'Selecione'),
              validator: (v) =>
                  f.required && v == null ? 'Informe ${f.label}.' : null,
              items: [
                for (final opt in options)
                  DropdownMenuItem(
                      value: opt.id, child: Text(opt.label)),
              ],
              onChanged: (id) {
                final opt = options.firstWhere((o) => o.id == id,
                    orElse: () =>
                        const ManageOption(id: 0, uuid: '', label: ''));
                setState(() =>
                    _refSelections[f.name] = opt.id == 0 ? [] : [opt]);
              },
            ),
            _createOptionButton(f),
          ],
        );
      },
    );
  }

  /// "Cadastrar novo" — cria o item-alvo (ex.: pesquisador) sem sair do
  /// fluxo quando a conta pode criar aquele bundle; outros nós seguem
  /// só visualização/edição (permissões do portal).
  Widget _createOptionButton(ManageField f) {
    final target = f.target;
    if (target == null) {
      return const SizedBox.shrink();
    }
    if (target.startsWith('taxonomy_term:')) {
      // Vocabulários abertos (auto_create no Drupal): o operador cria o
      // termo no portal e ele já entra selecionado no campo.
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          icon: const Icon(Icons.add, size: 16),
          label: const Text('Cadastrar novo termo'),
          onPressed: () => _createTaxonomyTerm(f, target.substring(14)),
        ),
      );
    }
    if (!target.startsWith('node:')) {
      return const SizedBox.shrink();
    }
    final bundleName = target.substring(5);
    final bundle = _allBundles
        .where((b) => b.name == bundleName)
        .firstOrNull;
    if (bundle == null || !bundle.canCreate) {
      return const SizedBox.shrink();
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        icon: const Icon(Icons.add, size: 16),
        label: Text('Cadastrar novo(a) ${bundle.labelSingular}'),
        onPressed: () => _createTargetItem(f, bundle),
      ),
    );
  }

  Future<void> _createTargetItem(ManageField f, ManageBundle bundle) async {
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ManageFormPage(bundle: bundle),
      ),
    );
    if (created != true || !mounted) return;
    _refOptions.remove(f.name);
    final options = await _loadOptions(f, force: true);
    if (!mounted || options.isEmpty) return;
    // Seleciona o item recém-criado — vem primeiro por -changed.
    setState(() {
      final sel = _refSelections[f.name] ??= [];
      if (f.multiple) {
        sel.add(options.first);
      } else {
        _refSelections[f.name] = [options.first];
      }
    });
  }

  /// Cria um termo de taxonomia sem sair do fluxo (tags e vocabulários
  /// abertos). Se já existir termo com o mesmo nome, só seleciona —
  /// evita duplicar entrada no vocabulário.
  Future<void> _createTaxonomyTerm(ManageField f, String vocab) async {
    final ctrl = TextEditingController();
    final typed = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Novo(a) ${f.label}'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Nome do termo',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, ctrl.text),
            child: const Text('Cadastrar'),
          ),
        ],
      ),
    );
    final name = typed?.trim() ?? '';
    if (name.isEmpty || !mounted) return;
    try {
      ManageOption? opt;
      for (final o in _refOptions[f.name] ?? const <ManageOption>[]) {
        if (o.label.toLowerCase() == name.toLowerCase()) opt = o;
      }
      if (opt == null) {
        await ManageService.saveTerm(vocab, values: {'name': name});
        _refOptions.remove(f.name);
        for (final o in await _loadOptions(f, force: true)) {
          if (o.label.toLowerCase() == name.toLowerCase()) opt = o;
        }
      }
      if (opt == null || !mounted) return;
      final chosen = opt;
      setState(() {
        final sel = _refSelections[f.name] ??= [];
        if (f.multiple) {
          if (!sel.any((s) => s.id == chosen.id)) sel.add(chosen);
        } else {
          _refSelections[f.name] = [chosen];
        }
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('O portal recusou o novo termo.')),
      );
    }
  }

  Future<void> _pickFromLibrary(ManageField field) async {
    final mediaType = field.kind == 'image' ? 'image' : 'document';
    final picked = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => _MediaLibraryDialog(mediaType: mediaType),
    );
    if (picked == null || !mounted) return;
    final uuid = picked['file_uuid']?.toString() ?? '';
    if (uuid.isEmpty) return;
    setState(() {
      if (field.multiple) {
        _fileUuids[field.name]!.add(uuid);
      } else {
        _fileUuids[field.name] = [uuid];
      }
    });
  }

  Widget _fileField(ManageField f) {
    final uuids = _fileUuids[f.name] ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final uuid in uuids)
          Chip(
            avatar: Icon(
              f.kind == 'image'
                  ? Icons.image_outlined
                  : Icons.attach_file_outlined,
              size: 18,
            ),
            label: Text('Anexado (${uuid.substring(0, 8)}…)'),
            onDeleted: () =>
                setState(() => _fileUuids[f.name]!.remove(uuid)),
          ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: () => _pickFile(f),
              icon: const Icon(Icons.upload_file_outlined),
              label: Text(
                f.multiple ? 'Enviar ${f.label}' : 'Escolher ${f.label}',
              ),
            ),
            OutlinedButton.icon(
              onPressed: () => _pickFromLibrary(f),
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('Biblioteca'),
            ),
          ],
        ),
      ],
    );
  }
}

/// Modal da biblioteca de mídia — lista mídias existentes (media entities)
/// e devolve o file_uuid do item escolhido.
class _MediaLibraryDialog extends StatefulWidget {
  const _MediaLibraryDialog({required this.mediaType});

  final String mediaType;

  @override
  State<_MediaLibraryDialog> createState() => _MediaLibraryDialogState();
}

class _MediaLibraryDialogState extends State<_MediaLibraryDialog> {
  List<Map<String, dynamic>> _items = const [];
  bool _loading = true;
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final items = await ManageService.media(
        widget.mediaType,
        search: _search.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.mediaType == 'image'
            ? 'Biblioteca de imagens'
            : 'Biblioteca de documentos',
      ),
      content: SizedBox(
        width: 480,
        height: 420,
        child: Column(
          children: [
            TextField(
              controller: _search,
              decoration: const InputDecoration(
                hintText: 'Buscar por nome',
                prefixIcon: Icon(Icons.search),
                isDense: true,
              ),
              onSubmitted: (_) => _load(),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _items.isEmpty
                      ? const Center(child: Text('Nenhuma mídia encontrada.'))
                      : ListView.builder(
                          itemCount: _items.length,
                          itemBuilder: (context, i) {
                            final item = _items[i];
                            return ListTile(
                              leading: widget.mediaType == 'image'
                                  ? const Icon(Icons.image_outlined)
                                  : const Icon(Icons.insert_drive_file_outlined),
                              title: Text(item['name']?.toString() ?? ''),
                              onTap: () => Navigator.pop(context, item),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
      ],
    );
  }
}


/// Seletor de pesquisador — lista os perfis cadastrados para preencher
/// campos de texto (autor/coordenador/equipe) sem digitar o nome. A
/// opção "Cadastrar novo" abre o formulário do perfil quando a conta
/// tem permissão de criação; bundles sem criação só selecionam.
class _PersonPickerSheet extends StatefulWidget {
  const _PersonPickerSheet({
    required this.canCreate,
    required this.onCreateNew,
  });

  final bool canCreate;
  final Future<bool?> Function() onCreateNew;

  @override
  State<_PersonPickerSheet> createState() => _PersonPickerSheetState();
}

class _PersonPickerSheetState extends State<_PersonPickerSheet> {
  final _search = TextEditingController();
  List<ManageOption> _options = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final options =
          await ManageService.options('node:perfil_pesquisador');
      if (!mounted) return;
      setState(() {
        _options = options;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Não foi possível consultar os pesquisadores.';
      });
    }
  }

  List<ManageOption> get _filtered {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return _options;
    return _options
        .where((o) => o.label.toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SizedBox(
          height: 420,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  'Escolher pesquisador',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20),
                child: TextField(
                  controller: _search,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Buscar pelo nome',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: _loading
                    ? const Center(
                        child: CircularProgressIndicator(),
                      )
                    : _error != null
                        ? Center(child: Text(_error!))
                        : _filtered.isEmpty
                            ? const Center(
                                child: Text(
                                  'Nenhum pesquisador encontrado.',
                                ),
                              )
                            : ListView(
                                children: [
                                  if (_search.text
                                      .trim()
                                      .isNotEmpty)
                                    ListTile(
                                      leading: const Icon(
                                        Icons.person_add_alt_outlined,
                                      ),
                                      title: Text(
                                        'Usar "${_search.text.trim()}"',
                                      ),
                                      subtitle: const Text(
                                        'Autor externo — sem cadastro',
                                      ),
                                      onTap: () => Navigator.pop(
                                        context,
                                        _search.text.trim(),
                                      ),
                                    ),
                                  for (final o in _filtered)
                                    ListTile(
                                      leading: const Icon(
                                        Icons.person_outline,
                                      ),
                                      title: Text(o.label),
                                      onTap: () =>
                                          Navigator.pop(
                                              context, o.label),
                                    ),
                                ],
                              ),
              ),
              if (widget.canCreate)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text(
                        'Cadastrar novo pesquisador',
                      ),
                      onPressed: () async {
                        final created =
                            await widget.onCreateNew();
                        if (!context.mounted) return;
                        if (created == true) {
                          // Recarrega: o novo perfil vem primeiro
                          // na lista por -changed.
                          setState(() => _loading = true);
                          await _load();
                        }
                      },
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
