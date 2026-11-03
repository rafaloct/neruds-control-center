import 'package:flutter/material.dart';

import 'manage_service.dart';

/// Gestão de equipe — contas do portal com badges de papel e edição
/// (nome, e-mail, ativo/bloqueado, papéis).
class ManageUsersPage extends StatefulWidget {
  const ManageUsersPage({super.key});

  @override
  State<ManageUsersPage> createState() => _ManageUsersPageState();
}

class _ManageUsersPageState extends State<ManageUsersPage> {
  List<Map<String, dynamic>> _users = const [];
  List<Map<String, String>> _roles = const [];
  bool _loading = true;
  String? _error;
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
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final users =
          await ManageService.users(search: _search.text.trim());
      final roles = await ManageService.userRoles();
      if (!mounted) return;
      setState(() {
        _users = users;
        _roles = roles;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'O portal recusou a consulta de usuários.';
        _loading = false;
      });
    }
  }

  String _roleLabel(String id) => _roles
          .firstWhere((r) => r['id'] == id,
              orElse: () => {'label': id})['label'] ??
      id;

  Future<void> _editUser(Map<String, dynamic> user) async {
    final name = TextEditingController(text: user['name']?.toString() ?? '');
    final mail = TextEditingController(text: user['mail']?.toString() ?? '');
    final selected = Set<String>.from(
        (user['roles'] as List? ?? const []).map((r) => r.toString()));
    var status = user['status'] == true;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: Text('Editar ${user['name']}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Nome de usuário'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: mail,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'E-mail'),
                ),
                SwitchListTile(
                  value: status,
                  onChanged: (v) => setDialog(() => status = v),
                  title: const Text('Conta ativa'),
                  subtitle: const Text('Bloqueado não consegue entrar.'),
                  dense: true,
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Papéis',
                      style: Theme.of(context).textTheme.labelLarge),
                ),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final role in _roles)
                      FilterChip(
                        label: Text(role['label'] ?? role['id'] ?? ''),
                        selected: selected.contains(role['id']),
                        onSelected: (v) => setDialog(() {
                          v
                              ? selected.add(role['id'] ?? '')
                              : selected.remove(role['id']);
                        }),
                      ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Salvar'),
            ),
          ],
        ),
      ),
    );
    if (saved != true) return;
    try {
      await ManageService.updateUser(user['uid'] as int, {
        if (name.text.trim().isNotEmpty) 'name': name.text.trim(),
        if (mail.text.trim().isNotEmpty) 'mail': mail.text.trim(),
        'status': status,
        'roles': selected.toList(),
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Conta atualizada.')),
      );
      _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('O portal recusou a atualização da conta.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Equipe')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              controller: _search,
              decoration: const InputDecoration(
                hintText: 'Buscar por nome de usuário',
                prefixIcon: Icon(Icons.search),
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _load(),
            ),
          ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: const Text('Tentar novamente'),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        itemCount: _users.length,
        itemBuilder: (context, index) {
          final user = _users[index];
          final roles =
              (user['roles'] as List? ?? const []).map((r) => r.toString());
          return ListTile(
            leading: Icon(
              user['status'] == true
                  ? Icons.person_outline
                  : Icons.person_off_outlined,
            ),
            title: Text(user['name']?.toString() ?? ''),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (user['mail'] != null)
                  Text(user['mail'].toString(),
                      style: Theme.of(context).textTheme.bodySmall),
                Wrap(
                  spacing: 4,
                  children: [
                    for (final role in roles)
                      Chip(
                        label: Text(_roleLabel(role),
                            style: const TextStyle(fontSize: 11)),
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                      ),
                  ],
                ),
              ],
            ),
            isThreeLine: roles.isNotEmpty,
            trailing: IconButton(
              tooltip: 'Editar conta',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => _editUser(user),
            ),
          );
        },
      ),
    );
  }
}
