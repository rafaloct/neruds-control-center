import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'app_session.dart';

class EditorialPage extends StatefulWidget {
  const EditorialPage({super.key});

  @override
  State<EditorialPage> createState() => _EditorialPageState();
}

class _EditorialPageState extends State<EditorialPage> {
  static const _bridgeUrl = String.fromEnvironment(
    'NERUDS_BRIDGE_URL',
    defaultValue: 'https://largeo.tail2faed0.ts.net:8443',
  );

  final _loginFormKey = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _title = TextEditingController();
  final _summary = TextEditingController();
  final _body = TextEditingController();

  String? _token;
  String? _loggedUser;
  bool _busy = false;
  bool _showPassword = false;
  bool _loadingDrafts = false;
  List<Map<String, dynamic>> _drafts = const [];

  Map<String, String> get _authHeaders => {
        'Authorization': 'Bearer $_token',
        'Content-Type': 'application/json',
      };

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _title.dispose();
    _summary.dispose();
    _body.dispose();
    super.dispose();
  }

  String _endpoint(String path) {
    final base = _bridgeUrl.endsWith('/')
        ? _bridgeUrl.substring(0, _bridgeUrl.length - 1)
        : _bridgeUrl;
    return '$base$path';
  }

  String _errorMessage(http.Response response) {
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      final detail = decoded['detail'];
      if (detail is String) return detail;
      if (detail is Map && detail['message'] != null) {
        return detail['message'].toString();
      }
      return detail?.toString() ?? 'Erro HTTP ${response.statusCode}';
    } catch (_) {
      return 'Erro HTTP ${response.statusCode}';
    }
  }

  void _message(String value) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(value)));
  }

  Future<void> _login() async {
    if (!(_loginFormKey.currentState?.validate() ?? false)) {
      return;
    }

    setState(() => _busy = true);
    try {
      final response = await http
          .post(
            Uri.parse(_endpoint('/auth/login')),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'username': _username.text.trim(),
              'password': _password.text,
            }),
          )
          .timeout(const Duration(seconds: 20));

      if (response.statusCode != 200) {
        _message(_errorMessage(response));
        return;
      }

      final data = jsonDecode(utf8.decode(response.bodyBytes));
      final token = data['token']?.toString() ?? '';
      final username = data['username']?.toString() ?? _username.text.trim();
      final roles = (data['roles'] as List<dynamic>? ?? const [])
          .map((role) => role.toString())
          .toList();
      AppSession.instance.setSession(
        tokenValue: token,
        usernameValue: username,
        rolesValue: roles,
        canReviewValue: data['can_review'] == true,
        canPublishValue: data['can_publish'] == true,
      );
      setState(() {
        _token = token;
        _loggedUser = username;
        _password.clear();
      });
      _message('Sessão iniciada com as permissões do Drupal.');
      await _loadDrafts();
    } catch (error) {
      _message('Não foi possível acessar o bridge: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _logout() async {
    final token = _token;
    if (token != null) {
      try {
        await http
            .post(
              Uri.parse(_endpoint('/auth/logout')),
              headers: _authHeaders,
            )
            .timeout(const Duration(seconds: 10));
      } catch (_) {}
    }
    AppSession.instance.clear();
    if (!mounted) return;
    setState(() {
      _token = null;
      _loggedUser = null;
      _drafts = const [];
    });
  }

  Future<void> _loadDrafts() async {
    if (_token == null) return;
    setState(() => _loadingDrafts = true);
    try {
      final response = await http
          .get(
            Uri.parse(_endpoint('/content/news/drafts')),
            headers: _authHeaders,
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 401) {
        await _logout();
        _message('Sua sessão expirou. Entre novamente.');
        return;
      }
      if (response.statusCode != 200) {
        _message(_errorMessage(response));
        return;
      }
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      final items = (data['items'] as List<dynamic>? ?? const [])
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();
      if (mounted) setState(() => _drafts = items);
    } catch (error) {
      _message('Não foi possível carregar os rascunhos: $error');
    } finally {
      if (mounted) setState(() => _loadingDrafts = false);
    }
  }

  Future<void> _createDraft() async {
    if (_title.text.trim().length < 3 || _body.text.trim().isEmpty) {
      _message('Preencha pelo menos título e texto.');
      return;
    }

    setState(() => _busy = true);
    try {
      final response = await http
          .post(
            Uri.parse(_endpoint('/content/news/draft')),
            headers: _authHeaders,
            body: jsonEncode({
              'title': _title.text.trim(),
              'summary': _summary.text.trim(),
              'body': _body.text.trim(),
            }),
          )
          .timeout(const Duration(seconds: 25));

      if (response.statusCode == 401) {
        await _logout();
        _message('Sua sessão expirou. Entre novamente.');
        return;
      }
      if (response.statusCode != 200 && response.statusCode != 201) {
        _message(_errorMessage(response));
        return;
      }

      final data = jsonDecode(utf8.decode(response.bodyBytes));
      final notification = data['notification'] as Map<String, dynamic>?;
      final emailSent = notification?['sent'] == true;
      _title.clear();
      _summary.clear();
      _body.clear();
      _message(emailSent
          ? 'Rascunho criado e revisão avisada por e-mail.'
          : 'Rascunho criado no Drupal. A notificação por e-mail ainda não está configurada.');
      await _loadDrafts();
    } catch (error) {
      _message('Não foi possível criar o rascunho: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_token == null) return _loginView(context);

    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          Material(
            color: Theme.of(context).colorScheme.surface,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 14, 16, 0),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Icon(Icons.verified_user_outlined),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Conectado como ${_loggedUser ?? ''}',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _logout,
                        icon: const Icon(Icons.logout),
                        label: const Text('Sair'),
                      ),
                    ],
                  ),
                  const TabBar(
                    tabs: [
                      Tab(
                          icon: Icon(Icons.edit_note_outlined),
                          text: 'Nova notícia'),
                      Tab(
                          icon: Icon(Icons.rate_review_outlined),
                          text: 'Rascunhos'),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: TabBarView(
              children: [
                _draftForm(context),
                _draftQueue(context),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _loginView(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Conteúdo do portal',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 6),
        const Text(
          'Entre com sua conta do neruds.org. O aplicativo usa as mesmas permissões definidas no Drupal e não guarda sua senha.',
        ),
        const SizedBox(height: 24),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: AutofillGroup(
                child: Form(
                  key: _loginFormKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextFormField(
                        controller: _username,
                        enabled: !_busy,
                        autofillHints: const [
                          AutofillHints.username,
                          AutofillHints.email,
                        ],
                        textInputAction: TextInputAction.next,
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Informe seu usuário do portal.';
                          }
                          return null;
                        },
                        decoration: const InputDecoration(
                          labelText: 'Usuário do portal *',
                          helperText: 'Ex.: extensionista.1 ou seu usuário institucional',
                          prefixIcon: Icon(Icons.person_outline),
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _password,
                        enabled: !_busy,
                        obscureText: !_showPassword,
                        autofillHints: const [AutofillHints.password],
                        textInputAction: TextInputAction.done,
                        validator: (value) {
                          if (value == null || value.isEmpty) {
                            return 'Informe sua senha.';
                          }
                          return null;
                        },
                        onFieldSubmitted: (_) => _login(),
                        decoration: InputDecoration(
                          labelText: 'Senha *',
                          helperText: 'Sua senha é validada pelo Drupal e não fica salva no app.',
                          prefixIcon: const Icon(Icons.lock_outline),
                          border: const OutlineInputBorder(),
                          suffixIcon: IconButton(
                            tooltip: _showPassword
                                ? 'Ocultar senha'
                                : 'Mostrar senha',
                            onPressed: _busy
                                ? null
                                : () => setState(
                                      () => _showPassword = !_showPassword,
                                    ),
                            icon: Icon(
                              _showPassword
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Semantics(
                        button: true,
                        label: _busy
                            ? 'Entrando no Portal NERUDS'
                            : 'Entrar no Portal NERUDS',
                        child: FilledButton.icon(
                          onPressed: _busy ? null : _login,
                          icon: _busy
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.login),
                          label: Text(_busy ? 'Entrando...' : 'Entrar'),
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Bolsistas não precisam de acesso à VPS, SSH ou painel técnico.',
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _draftForm(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Criar notícia',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 6),
        const Text(
          'O conteúdo é salvo como rascunho. A publicação continua dependendo das permissões e da revisão editorial.',
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _title,
          enabled: !_busy,
          maxLength: 255,
          decoration: const InputDecoration(
            labelText: 'Título',
            hintText: 'Ex.: NERUDS participa de atividade no Jalapão',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _summary,
          enabled: !_busy,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: 'Resumo curto',
            hintText: 'Explique em poucas linhas o que aconteceu e por que é relevante.',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _body,
          enabled: !_busy,
          minLines: 8,
          maxLines: 18,
          decoration: const InputDecoration(
            labelText: 'Texto',
            hintText:
                'Escreva normalmente. Separe parágrafos com uma linha em branco; o sistema formata para o Drupal.',
            alignLabelWithHint: true,
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 18),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: _busy ? null : _createDraft,
            icon: const Icon(Icons.save_outlined),
            label: const Text('Salvar como rascunho'),
          ),
        ),
      ],
    );
  }

  Widget _draftQueue(BuildContext context) {
    if (_loadingDrafts) {
      return const Center(child: CircularProgressIndicator());
    }

    return RefreshIndicator(
      onRefresh: _loadDrafts,
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Aguardando revisão',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              IconButton(
                tooltip: 'Atualizar',
                onPressed: _loadDrafts,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'A lista respeita o que sua conta Drupal tem permissão para visualizar.',
          ),
          const SizedBox(height: 16),
          if (_drafts.isEmpty)
            const Card(
              child: ListTile(
                leading: Icon(Icons.check_circle_outline),
                title: Text('Nenhum rascunho visível para esta conta.'),
              ),
            )
          else
            ..._drafts.map(
              (item) => Card(
                child: ListTile(
                  leading: const Icon(Icons.article_outlined),
                  title: Text(item['title']?.toString() ?? 'Sem título'),
                  subtitle: Text(
                    item['moderation_state']?.toString().isNotEmpty == true
                        ? 'Estado: ${item['moderation_state']}'
                        : 'Rascunho não publicado',
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
