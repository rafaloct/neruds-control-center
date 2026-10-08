import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' show ClientException, Response;
import 'package:url_launcher/url_launcher.dart';

import 'app_config.dart';

// Only these bridge contract messages are safe to display verbatim. Never pass
// arbitrary response bodies, HTML, or exception details through to the UI.
const _safeResponseMessages = <int, Set<String>>{
  502: {
    'Drupal retornou sem confirmar o identificador numérico da notícia. '
        'Confira o registro no portal antes de repetir.',
    'Drupal salvou sem confirmar o identificador. '
        'Confira a notícia no portal antes de repetir.',
  },
  409: {
    'Esta oportunidade já possui um rascunho Drupal. '
        'Abra o registro existente no portal.',
    'Esta oportunidade já possui um rascunho no portal. '
        'Continue no registro existente ou arquive a oportunidade.',
    'Esta oportunidade já está vinculada a outro rascunho Drupal.',
    'A oportunidade precisa ser aprovada como pauta antes de virar rascunho.',
    'Uma oportunidade duplicada não pode virar rascunho. '
        'Use o item de referência para preservar a auditoria.',
  },
};

class _WorkflowResponseException implements Exception {
  const _WorkflowResponseException([this.message]);

  final String? message;
}

/// Raised when a request reaches the service but is refused — carries the
/// status code so callers can distinguish authz failures from outages.
class HttpStatusException implements Exception {
  const HttpStatusException(this.statusCode);

  final int statusCode;
}

/// Retains actionable, known contract messages without exposing server output.
Exception workflowResponseError(Response response) {
  try {
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final detail = decoded is Map ? decoded['detail'] : null;
    final message = detail is Map ? detail['message'] : detail;
    for (final safeMessage
        in _safeResponseMessages[response.statusCode] ?? const <String>{}) {
      if (message == safeMessage) {
        return _WorkflowResponseException(safeMessage);
      }
    }
  } on FormatException {
    // Non-JSON responses are intentionally hidden from the user.
  }
  return const _WorkflowResponseException();
}

String workflowError(Object error) {
  if (error is _WorkflowResponseException && error.message != null) {
    return error.message!;
  }
  if (error is HttpStatusException) {
    if (error.statusCode == 401) {
      return 'Sua sessão expirou ou não é válida. Saia e entre novamente '
          'para continuar.';
    }
    if (error.statusCode == 403) {
      return 'Sua conta não tem permissão para esta consulta no portal. '
          'Se deveria ter, peça a revisão do seu perfil.';
    }
    return 'O serviço não pôde responder a esta consulta agora '
        '(HTTP ${error.statusCode}). Tente novamente e, se continuar, '
        'avise a equipe responsável.';
  }
  if (error is AppConfigurationException) {
    return 'Este computador ainda precisa do endereço do serviço NERUDS. '
        'Peça à equipe técnica a versão configurada do aplicativo.';
  }
  if (error is TimeoutException) {
    return 'A resposta demorou mais que o esperado. Confira a conexão e tente novamente. '
        'Se estava enviando algo, consulte a lista antes de repetir o envio.';
  }
  if (error is FormatException) {
    return 'A resposta recebida não pôde ser lida. Atualize a consulta e, se continuar, '
        'avise a equipe responsável pelo serviço.';
  }
  if (error is ClientException) {
    return 'Não foi possível conectar ao serviço. Confira sua conexão à rede do NERUDS '
        'e tente novamente.';
  }
  return 'Não foi possível concluir esta ação. Seus campos continuam nesta tela. '
      'Confira a conexão e tente novamente.';
}

/// Launches [uri] in the external browser, offering to copy the address
/// when the browser cannot be opened.
Future<void> launchExternalUri(BuildContext context, Uri uri) async {
  var launched = false;
  try {
    launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    launched = false;
  }
  if (launched || !context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: const Text(
        'O navegador não abriu. Você pode copiar o endereço.',
      ),
      action: SnackBarAction(
        label: 'Copiar link',
        onPressed: () => Clipboard.setData(ClipboardData(text: uri.toString())),
      ),
    ),
  );
}

/// Opens existing portal pages in the browser without passing app credentials.
class PortalLinkButton extends StatelessWidget {
  const PortalLinkButton({
    super.key,
    required this.label,
    required this.url,
    this.editing = false,
  });

  final String label;
  final String? url;
  final bool editing;

  Uri? get _uri {
    final target = AppConfig.webUri(url);
    if (target == null) return null;
    final portal = AppConfig.webUri(AppConfig.portalUrl);
    if (editing && portal != null && target.origin != portal.origin) {
      return null;
    }
    return target;
  }

  Future<void> _open(BuildContext context, Uri uri) async {
    if (editing) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Editar a ficha no portal'),
          content: const Text(
            'O formulário existente será aberto no navegador. Entre com sua conta '
            'do portal; ela determina quais campos você pode alterar.\n\n'
            'Mantenha a ficha e seus vínculos. Depois de salvar, volte à tarefa '
            'para registrar a evidência e conferir a página pública.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Voltar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Abrir formulário'),
            ),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) return;
    }
    await launchExternalUri(context, uri);
  }

  @override
  Widget build(BuildContext context) {
    final uri = _uri;
    return TextButton.icon(
      onPressed: uri == null ? null : () => _open(context, uri),
      icon: Icon(editing ? Icons.edit_outlined : Icons.open_in_new, size: 18),
      label: Text(label),
    );
  }
}
