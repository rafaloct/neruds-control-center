# Arquitetura

## Princípio

O NERUDS Control Center é uma camada de experiência sobre o Drupal, não um novo CMS.

## Camadas

### 1. Flutter

Uma base para Windows, Android e Web. A interface é orientada a tarefas e não a entidades técnicas do Drupal.

Perfis previstos:

- Bolsista: criar e corrigir rascunhos, anexar mídia e cumprir checklists.
- Revisor: revisar conteúdo, solicitar correção e aprovar.
- Coordenação: publicar, programar publicação, gerenciar taxonomias e usuários editoriais.
- TI: saúde, backup, restauração, logs, cache, cron, módulos e atualizações.

### 2. Bridge no host de operação

FastAPI restrito à Tailscale. Centraliza capacidades que não devem existir no cliente.

Responsabilidades:

- proxy opcional para JSON:API e CORS;
- diagnóstico do portal;
- diagnóstico da Tailscale e do VPS;
- trilha de auditoria;
- tarefas Drush permitidas por allowlist;
- backups e teste de restauração;
- inventário de módulos, conteúdo e taxonomias;
- fila de tarefas administrativas.

Nenhuma senha root deve ser embutida no Flutter.

### 3. Drupal no VPS

Continua sendo a fonte de verdade.

Tipos detectados no portal:

- acao_extensionista
- boletim
- boletim_periodico
- evento_cientifico
- grupo_estudos
- noticia
- perfil_pesquisador
- projeto_pesquisa_extensao
- publicacao
- publicacao_cientifica
- relatorio
- relatorio_fno
- reuniao

Taxonomias detectadas incluem ODS, linhas de pesquisa, áreas de conhecimento, biomas, municípios, microrregiões, financiadores, palavras-chave e setores produtivos.

## Fluxo editorial desejado

Rascunho -> Em revisão -> Ajustes solicitados -> Aprovado -> Publicado -> Arquivado.

Bolsista cria rascunho. Revisor aprova conteúdo. Coordenação publica. O histórico de revisões fica no Drupal.

## Continuidade

Cada tela deve responder três perguntas:

1. O que preciso preencher?
2. Quem revisa depois de mim?
3. O que acontece quando eu salvar?

A interface deve mostrar exemplos, campos obrigatórios, ajuda contextual e validações em português simples.

## IA

IA é assistente, não publicadora. Pode sugerir título, resumo, texto alternativo, palavras-chave, ODS e vínculos prováveis. Publicação depende de revisão humana.

## Integração futura com Drupal

Preferência:

1. JSON:API para entidades e relacionamentos.
2. Media/File API para anexos.
3. Content Moderation para workflow.
4. Endpoint customizado mínimo apenas quando JSON:API/REST não atender.
5. Drush somente no bridge e com comandos permitidos explicitamente.
