---
name: neruds-drupal-maintenance
description: Orientar diagnóstico e governança técnica do portal NERUDS sem expor credenciais ou permitir operações administrativas livres.
---

# NERUDS Drupal Maintenance

Use esta skill para diagnóstico e encaminhamento técnico.

## Princípios

- Preferir acesso pela Tailscale.
- Não expor credenciais no aplicativo.
- Separar diagnóstico de alteração.
- Manter trilha de auditoria.
- Exigir perfil técnico para funções administrativas.
- Validar saúde do portal antes e depois de qualquer manutenção autorizada.
- Manter cópias de segurança e procedimentos de recuperação documentados.

## Sequência de diagnóstico

1. verificar disponibilidade do portal;
2. verificar JSON:API;
3. verificar conectividade do LARGeo com o servidor;
4. consultar versões e estado geral por mecanismos autorizados;
5. registrar alertas e pendências;
6. encaminhar ações administrativas somente ao perfil técnico.

## Interface

Exibir para bolsistas apenas estados simples: normal, atenção ou precisa de TI. Detalhes técnicos ficam no perfil Coordenação/TI.
