import 'dart:convert';

import 'package:flutter/material.dart';

import 'app_config.dart';
import 'app_session.dart';
import 'bridge_http.dart' as http;
import 'unsaved_work.dart';
import 'workflow_widgets.dart';

Future<bool> _confirmDiscard(BuildContext context, String action) async {
  if (!UnsavedWork.instance.hasChanges) return true;
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Há alterações ainda não salvas'),
          content: Text(
            '$action descarta os campos que ainda não foram enviados. '
            'Você pode voltar para salvá-los primeiro.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Continuar trabalhando'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Descartar e continuar'),
            ),
          ],
        ),
      ) ==
      true;
}

Future<bool> showSignInDialog(BuildContext context) async {
  if (AppSession.instance.authenticated) return true;
  return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const _SignInDialog(),
      ) ==
      true;
}

Future<bool> signOut(BuildContext context) async {
  if (!await _confirmDiscard(context, 'Sair da conta')) return false;
  if (!context.mounted) return false;
  final session = AppSession.instance;
  if (!session.authenticated) {
    session.clear();
    return true;
  }
  final token = session.token;
  final identity = session.identityEpoch;
  try {
    final response = await http.post(
      AppConfig.endpoint('/auth/logout'),
      headers: session.authHeaders,
    );
    if (response.statusCode != 200 && response.statusCode != 401) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'O serviço não confirmou a saída. Sua sessão foi mantida '
              'neste computador; tente sair novamente.',
            ),
          ),
        );
      }
      return false;
    }
    // Do not clear a different login that happened while the request was pending.
    if (session.identityEpoch == identity &&
        (session.token == token || !session.authenticated)) {
      session.clear();
    }
    return true;
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Não foi possível confirmar a saída. '
            'A sessão foi mantida neste computador. ${workflowError(error)}',
          ),
        ),
      );
    }
    return false;
  }
}

class SessionPrompt extends StatelessWidget {
  const SessionPrompt({super.key, required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.person_outline, size: 32),
                  const SizedBox(height: 20),
                  Text(title, style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 12),
                  Text(message),
                  if (AppSession.instance.expired) ...[
                    const SizedBox(height: 12),
                    const Text(
                      'Sua sessão expirou. Entre com a mesma conta para retomar '
                      'os campos que ainda estão abertos neste computador.',
                    ),
                  ],
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: () => showSignInDialog(context),
                    icon: const Icon(Icons.login),
                    label: const Text('Entrar com minha conta'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SignInDialog extends StatefulWidget {
  const _SignInDialog();

  @override
  State<_SignInDialog> createState() => _SignInDialogState();
}

class _SignInDialogState extends State<_SignInDialog> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _username;
  final _password = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _username = TextEditingController(
      text: AppSession.instance.reauthenticationUsername ?? '',
    );
  }

  @override
  void dispose() {
    _username.dispose();
    _password.clear();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !_form.currentState!.validate()) return;
    final user = _username.text.trim();
    final previous = AppSession.instance.reauthenticationUsername;
    if (previous != null &&
        user != previous &&
        !await _confirmDiscard(context, 'Entrar com outra conta')) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final response = await http.post(
        AppConfig.endpoint('/auth/login'),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({'username': user, 'password': _password.text}),
      );
      _password.clear();
      if (!mounted) return;
      if (response.statusCode != 200) {
        setState(() {
          _error = switch (response.statusCode) {
            401 =>
              'Usuário ou senha não conferem. Verifique e tente novamente.',
            403 =>
              'Esta conta não tem acesso. Peça à coordenação para verificar.',
            429 =>
              'Houve muitas tentativas. Aguarde um pouco antes de tentar de novo.',
            _ => 'O serviço não conseguiu confirmar o acesso. Tente novamente.',
          };
        });
        return;
      }
      final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
      final token = data['token']?.toString() ?? '';
      if (token.isEmpty) throw const FormatException();
      AppSession.instance.setSession(
        tokenValue: token,
        usernameValue: data['username']?.toString() ?? user,
        rolesValue: (data['roles'] as List? ?? const [])
            .map((value) => value.toString())
            .toList(),
        canReviewValue: data['can_review'] == true,
        canPublishValue: data['can_publish'] == true,
        canAdminUsersValue: data['can_admin_users'] == true,
      );
      Navigator.pop(context, true);
    } catch (error) {
      if (mounted) setState(() => _error = workflowError(error));
    } finally {
      if (mounted) {
        _password.clear();
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: const Text('Entrar no NERUDS'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Form(
              key: _form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Use sua conta individual do portal. '
                    'As permissões acompanham sua conta em cada computador.',
                  ),
                  const SizedBox(height: 24),
                  TextFormField(
                    controller: _username,
                    enabled: !_busy,
                    autofocus: true,
                    autocorrect: false,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(labelText: 'Usuário'),
                    validator: (value) => value == null || value.trim().isEmpty
                        ? 'Informe seu usuário.'
                        : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _password,
                    enabled: !_busy,
                    obscureText: _obscure,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => _submit(),
                    decoration: InputDecoration(
                      labelText: 'Senha',
                      suffixIcon: IconButton(
                        tooltip: _obscure ? 'Mostrar senha' : 'Ocultar senha',
                        onPressed: () => setState(() => _obscure = !_obscure),
                        icon: Icon(
                          _obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                      ),
                    ),
                    validator: (value) => value == null || value.isEmpty
                        ? 'Informe sua senha.'
                        : null,
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                  if (_busy) ...[
                    const SizedBox(height: 16),
                    const LinearProgressIndicator(),
                  ],
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context, false),
            child: const Text('Voltar'),
          ),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: Text(_busy ? 'Confirmando acesso…' : 'Entrar'),
          ),
        ],
      ),
    );
  }
}
