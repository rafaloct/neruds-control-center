import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'manage_models.dart';
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
  final Map<String, bool> _bools = {};
  final Map<String, DateTime?> _dates = {};
  final Map<String, List<ManageOption>> _refSelections = {};
  final Map<String, List<String>> _fileUuids = {};
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
              _controllers[f.name]?.text =
                  raw is Map ? (raw['value']?.toString() ?? '') : '${raw ?? ''}';
            case 'link':
              _controllers[f.name]?.text =
                  raw is Map ? (raw['uri']?.toString() ?? '') : '${raw ?? ''}';
            case 'number':
              _controllers[f.name]?.text = '${raw ?? ''}';
            case 'reference':
              _prefillRefs(f, rels[f.name]);
            case 'image' || 'file':
              _fileUuids[f.name] = _relUuids(rels[f.name]);
            default:
              _controllers[f.name]?.text = '${raw ?? ''}';
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

  DateTime? _parseDate(dynamic raw) {
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
        default:
          final text = _controllers[f.name]?.text.trim() ?? '';
          if (text.isNotEmpty) values[f.name] = text;
      }
    }
    return values;
  }

  Future<void> _save() async {
    if (_saving || !(_formKey.currentState?.validate() ?? false)) return;
    // Validação manual dos campos que o Form não alcança (datas, refs).
    for (final f in widget.bundle.fields) {
      if (!f.required) continue;
      final missing = switch (f.kind) {
        'date' => _dates[f.name] == null,
        'reference' => (_refSelections[f.name] ?? const []).isEmpty,
        'image' || 'file' => (_fileUuids[f.name] ?? const []).isEmpty,
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
          : Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  if (_error != null) ...[
                    Card(
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(_error!),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  for (final f in widget.bundle.fields) ...[
                    _buildField(f),
                    const SizedBox(height: 14),
                  ],
                  SwitchListTile(
                    value: _published,
                    onChanged: (v) => setState(() => _published = v),
                    title: const Text('Publicado no site'),
                    subtitle: const Text(
                      'Desligado mantém como rascunho — só quem pode revisar publica.',
                    ),
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: const Icon(Icons.save_outlined),
                    label: Text(_saving ? 'Salvando…' : 'Salvar'),
                  ),
                ],
              ),
            ),
    );
  }

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
      'longtext' => TextFormField(
          controller: _controllers[f.name],
          minLines: 4,
          maxLines: 12,
          validator: (v) => f.required && (v?.trim().isEmpty ?? true)
              ? 'Informe ${f.label}.'
              : null,
          decoration: _decoration(f),
        ),
      'reference' => _referenceField(f),
      'image' || 'file' => _fileField(f),
      _ => TextFormField(
          controller: _controllers[f.name],
          validator: (v) => f.required && (v?.trim().isEmpty ?? true)
              ? 'Informe ${f.label}.'
              : null,
          decoration: _decoration(f),
        ),
    };
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
            ],
          );
        }
        return DropdownButtonFormField<int>(
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
                orElse: () => const ManageOption(id: 0, uuid: '', label: ''));
            setState(() =>
                _refSelections[f.name] = opt.id == 0 ? [] : [opt]);
          },
        );
      },
    );
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
