# Roadmap — NERUDS Control Center

Este documento define a evolução do Control Center a partir da baseline versionada. O objetivo é ampliar autonomia operacional sem transformar o aplicativo em um segundo CMS ou expor infraestrutura a usuários finais.

## Estratégia de versões

O projeto usa **Semantic Versioning**:

- **PATCH** `1.0.x`: correções, hardening e melhorias sem mudança de contrato.
- **MINOR** `1.x.0`: novas capacidades compatíveis.
- **MAJOR** `x.0.0`: mudanças incompatíveis em API, modelo de dados ou fluxo operacional.

A baseline atual será marcada como:

`v1.0.0-internal.1`

Uma versão passa a `v1.0.0` quando a distribuição formal, recuperação operacional e revisão/coordenação estiverem fechadas.

## Fluxo de desenvolvimento

`main` representa o estado integrável.

Mudanças funcionais devem seguir:

```text
Issue
  -> branch curta
  -> implementação + testes
  -> Pull Request
  -> revisão
  -> merge
  -> tag/release quando aplicável
```

Convenção de branches:

- `feat/<issue>-descricao`
- `fix/<issue>-descricao`
- `docs/<issue>-descricao`
- `ops/<issue>-descricao`

Commits devem ser pequenos, descritivos e sem credenciais, bancos, builds ou arquivos institucionais brutos.

## Princípios arquiteturais

1. Drupal continua sendo fonte de verdade para conteúdo, identidade e autorização.
2. O Control Center orquestra tarefas, evidências e experiência do usuário.
3. Extensionista nunca recebe SSH/root.
4. IA auxilia pesquisa, classificação e redação; nunca publica automaticamente.
5. Tailscale é a fronteira privada para bridge e serviços internos.
6. Toda automação deve ser auditável e reversível.
7. A interface deve priorizar usuários rotativos com baixo domínio de TI.
8. Dados institucionais e credenciais ficam fora do Git.

---

# Onda 0 — Fundação do versionamento

**Meta:** tornar cada mudança rastreável e reproduzível.

### Entregas

- repositório privado `rafaloct/neruds-control-center`;
- branch padrão `main`;
- baseline `v1.0.0-internal.1`;
- CI para Python + Flutter;
- template de PR;
- templates de Issue;
- política de segurança e contribuição;
- CHANGELOG;
- proteção de `main` após o primeiro push;
- inventário explícito do que não entra no Git.

### Gate

Nenhum segredo ou artefato runtime no histórico Git.

---

# Onda 1 — Revisão editorial dentro do aplicativo

**Versão alvo:** `1.1.0`

Hoje o Extensionista cria rascunhos seguros, mas a revisão ainda depende demais do Drupal.

### Recursos

- fila “Aguardando revisão”;
- perfil Revisor/Coordenação no app;
- aprovar, devolver para ajuste e registrar justificativa;
- comentários de revisão;
- histórico imutável de decisão;
- vínculo entre rascunho Drupal e item de missão/oportunidade;
- publicar somente por perfil explicitamente autorizado;
- tela “Minhas pendências” por usuário.

### UX

- linguagem não técnica;
- próxima ação evidente;
- validação inline;
- estados vazios explicativos;
- confirmação em ações irreversíveis;
- acessibilidade por teclado/leitor de tela.

### Gate

Extensionista não ganha nenhuma permissão de publicação.

---

# Onda 2 — Missão operacional inteligente

**Versão alvo:** `1.2.0`

### Recursos

- progresso por pessoa, etapa, prioridade e prazo;
- SLA e itens atrasados;
- filtros salvos;
- atribuição/reatribuição controlada;
- evidência por URL, arquivo e comentário;
- revisão cruzada obrigatória quando aplicável;
- exportação XLSX compatível com a planilha original;
- importação de nova revisão da planilha com diff;
- relatório semanal de progresso;
- checklist adaptativo por tipo de conteúdo.

### Automação

- sugerir próxima tarefa P0/P1;
- detectar item sem evidência;
- detectar URL pública quebrada;
- sinalizar possível duplicidade no Drupal;
- nunca concluir tarefa automaticamente.

---

# Onda 3 — Radar de oportunidades e curadoria

**Versão alvo:** `1.3.0`

### Recursos

- catálogo de fontes institucionais;
- RSS/Atom com saúde da fonte;
- fallback para páginas sem feed;
- deduplicação por URL/título;
- prazo de inscrição/publicação;
- tags por aderência ao NERUDS;
- fila “vence em breve”;
- aprovação de pauta por Revisor;
- criação de rascunho vinculada à oportunidade;
- arquivamento com motivo.

### IA assistiva

- resumo em linguagem editorial;
- classificação sugerida;
- identificação de prazo;
- explicação de por que interessa ao NERUDS;
- sugestão de público interno;
- sempre exigir revisão humana.

---

# Onda 4 — Operação e confiabilidade

**Versão alvo:** `1.4.0`

### Recursos

- bridge como serviço Windows formal, substituindo Startup;
- health/readiness separados;
- logs estruturados sem PII/senhas;
- rotação e retenção de logs;
- backup automático do mission store;
- restore ensaiado;
- monitor de Tailscale Serve;
- monitor de Drupal/Poste.io;
- painel de incidentes;
- auditoria de alterações administrativas;
- política de sessão configurável por papel.

### Gate

Teste documentado de recuperação em máquina limpa.

---

# Onda 5 — Identidade e ciclo de vida de bolsistas

**Versão alvo:** `1.5.0`

### Recursos

- provisionar `extensionista.N` por fluxo administrativo;
- ativação/desativação sem SSH;
- troca segura de senha;
- encerramento de acesso ao fim da bolsa;
- transferência de tarefas/evidências;
- checklist de offboarding;
- histórico de quem ocupou cada conta operacional, sem armazenar dados desnecessários;
- papéis Drupal sincronizados com o app.

### Segurança

- princípio de menor privilégio;
- nenhuma senha em arquivo de projeto;
- credenciais de mailbox separadas de credenciais Drupal;
- registro de eventos administrativos.

---

# Onda 6 — Distribuição e mobilidade

**Versão alvo:** `2.0.0`

### Windows

- instalador assinado;
- atualização controlada;
- autostart do cliente apenas quando necessário.

### Android

- localizar/importar ou criar deliberadamente o keystore definitivo;
- APK/AAB release assinado;
- atualização compatível com a mesma identidade;
- teste em dispositivos reais.

### Web

Antes de qualquer publicação pública:

- decidir se continuará tailnet-only ou ganhará gateway autenticado;
- CORS explícito;
- headers de segurança;
- proteção CSRF/origin quando aplicável;
- threat model documentado.

---

# Backlog transversal

## UX/UI

- auditoria recorrente usando o design system;
- dark mode somente se mantiver contraste e simplicidade;
- responsividade tablet/celular;
- mensagens de erro acionáveis;
- onboarding de 5 minutos para novo bolsista;
- modo “o que faço agora?” orientado à missão.

## Dados

- migrations explícitas para SQLite;
- schema versionado;
- testes de migração;
- export/restore;
- retenção de histórico.

## Segurança

- secret scan no CI;
- dependency review;
- atualização periódica de dependências;
- CSP/CORS revisados;
- headers HTTPS;
- princípio de least privilege;
- teste negativo de publicação por Extensionista.

## Observabilidade

- métricas de disponibilidade do bridge;
- latência Drupal;
- falhas de login;
- falhas de RSS;
- falhas de notificação;
- nenhuma métrica deve registrar senha/token.

## Qualidade

- testes unitários de `mission_store`, `rss_store` e `review_store`;
- integração FastAPI com Drupal fake;
- E2E descartável contra Drupal real;
- smoke tests por release.

---

# Critério de priorização

Cada Issue deve ser classificada por:

- **P0:** segurança, perda de dados, publicação indevida ou indisponibilidade total.
- **P1:** bloqueia trabalho normal de extensionista/revisor.
- **P2:** ganho importante de produtividade/UX.
- **P3:** melhoria desejável sem impacto operacional imediato.

Ordem padrão:

`segurança > integridade dos dados > acesso > fluxo editorial > UX > automação > conveniência`.

## Definition of Done

Uma Issue funcional só é concluída quando:

- critério de aceite atendido;
- teste automatizado ou prova reproduzível;
- sem segredo no diff;
- documentação atualizada quando necessário;
- rollback conhecido;
- `dart analyze` / testes relevantes verdes;
- `git diff --check` verde.
