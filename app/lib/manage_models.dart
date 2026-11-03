/// Modelos do gateway de gestão (`/manage`) — dirigidos pelos schemas
/// servidos pelo bridge; nenhum campo fica hardcoded por setor.
class ManageField {
  const ManageField({
    required this.name,
    required this.label,
    required this.kind,
    required this.required,
    this.target,
    this.multiple = false,
    this.hint,
    this.group = 'basics',
  });

  final String name;
  final String label;
  final String kind;
  final bool required;
  final String? target;
  final bool multiple;
  final String? hint;
  final String group;

  factory ManageField.fromJson(Map<String, dynamic> json) => ManageField(
        name: json['name']?.toString() ?? '',
        label: json['label']?.toString() ?? '',
        kind: json['kind']?.toString() ?? 'text',
        required: json['required'] == true,
        target: json['target']?.toString(),
        multiple: json['multiple'] == true,
        hint: json['hint']?.toString(),
        group: json['group']?.toString() ?? 'basics',
      );
}

/// Um passo do wizard (grupo de campos) declarado pelo schema.
class ManageStep {
  const ManageStep({required this.id, required this.label});

  final String id;
  final String label;

  factory ManageStep.fromJson(Map<String, dynamic> json) => ManageStep(
        id: json['id']?.toString() ?? '',
        label: json['label']?.toString() ?? '',
      );
}

class ManageBundle {
  const ManageBundle({
    required this.name,
    required this.label,
    required this.labelSingular,
    required this.icon,
    required this.fields,
    required this.canCreate,
    this.steps = const [],
  });

  final String name;
  final String label;
  final String labelSingular;
  final String icon;
  final List<ManageField> fields;
  final bool canCreate;
  final List<ManageStep> steps;

  factory ManageBundle.fromJson(
    String name,
    Map<String, dynamic> json, {
    required bool canCreate,
  }) =>
      ManageBundle(
        name: name,
        label: json['label']?.toString() ?? name,
        labelSingular: json['label_singular']?.toString() ?? name,
        icon: json['icon']?.toString() ?? 'folder',
        fields: ((json['fields'] as List?) ?? const [])
            .map((f) => ManageField.fromJson(
                Map<String, dynamic>.from(f as Map)))
            .toList(),
        canCreate: canCreate,
        steps: ((json['steps'] as List?) ?? const [])
            .map((s) => ManageStep.fromJson(
                Map<String, dynamic>.from(s as Map)))
            .toList(),
      );
}

class ManageItem {
  const ManageItem({
    required this.nid,
    required this.uuid,
    required this.title,
    required this.status,
    this.changed,
  });

  final int nid;
  final String uuid;
  final String title;
  final bool status;
  final String? changed;

  factory ManageItem.fromJson(Map<String, dynamic> json) => ManageItem(
        nid: () {
          // Termos de taxonomia chegam com "tid" em vez de "nid".
          final raw = json['nid'] ?? json['tid'];
          return raw is int ? raw : int.tryParse('$raw') ?? 0;
        }(),
        uuid: json['uuid']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        status: json['status'] == true,
        changed: json['changed']?.toString(),
      );
}

class ManageOption {
  const ManageOption({required this.id, required this.uuid, required this.label});

  final int id;
  final String uuid;
  final String label;

  factory ManageOption.fromJson(Map<String, dynamic> json) => ManageOption(
        id: json['id'] is int ? json['id'] : int.tryParse('${json['id']}') ?? 0,
        uuid: json['uuid']?.toString() ?? '',
        label: json['label']?.toString() ?? '',
      );
}
