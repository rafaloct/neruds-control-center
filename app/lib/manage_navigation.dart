import 'package:flutter/material.dart';

import 'manage_form_page.dart';
import 'manage_models.dart';
import 'manage_service.dart';

/// Abre a edição nativa de uma ficha do portal — elimina a necessidade
/// de url_launcher para o Drupal. Quando [bundleName] não resolve a um
/// schema conhecido, pergunta o setor ao usuário.
/// Devolve `true` se o formulário salvou alterações.
Future<bool?> openManageEditor(
  BuildContext context, {
  required int nid,
  String? bundleName,
}) async {
  List<ManageBundle> schemas;
  try {
    schemas = await ManageService.schemas();
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('O portal recusou a consulta aos setores.'),
        ),
      );
    }
    return null;
  }
  if (!context.mounted) return null;
  var bundle =
      schemas.where((s) => s.name == bundleName).firstOrNull;
  bundle ??= await showModalBottomSheet<ManageBundle>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Text(
              'Qual é o setor desta ficha?',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          for (final s in schemas)
            ListTile(
              title: Text(s.label),
              onTap: () => Navigator.pop(context, s),
            ),
        ],
      ),
    ),
  );
  if (!context.mounted || bundle == null) return null;
  return Navigator.of(context).push<bool>(
    MaterialPageRoute(
      builder: (_) => ManageFormPage(bundle: bundle!, nid: nid),
    ),
  );
}
