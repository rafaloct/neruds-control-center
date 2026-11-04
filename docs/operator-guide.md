# Guia do Operador — NERUDS Control Center

Versão atemporal: qualquer pessoa com uma conta autorizada (e-mail
registrado no portal) pode seguir este guia para entrar no app e
realizar as atividades editoriais e administrativas do site
`neruds.org`. O aplicativo é sempre o ponto de partida — o portal
continua sendo a fonte dos dados.

---

## 1. Acessando

1. Abra o navegador em **https://app.neruds.org**.
2. Toque no ícone de perfil (canto superior direito).
3. Digite o **e-mail** cadastrado como usuário e a **senha** do portal.
4. Toque em **Entrar** — a barra lateral libera as áreas.

Não é preciso credencial extra nem configuração local — a sessão é a
mesma do portal.

## 2. Mapa das áreas (barra lateral)

| Área | Para que serve |
|---|---|
| **Início** | Painel de atenção — o que precisa de ação hoje |
| **Conteúdo** | Preparar uma notícia (assistente em 3 etapas) |
| **Inventário** | Suas frentes de trabalho (tarefas/missões). Chip **"Só as minhas"** filtra as suas |
| **Monitoramento** | Qualidade do portal — fichas com campos faltantes |
| **Oportunidades** | Editais e fontes monitoradas, com triagem |
| **Gestão** | Todos os setores do portal: notícias, projetos, pesquisadores, publicações, grupos, ações, relatórios, reuniões, eventos, páginas, boletins, taxonomias, menus e usuários |

## 3. Tarefas do dia (Inventário)

- O painel "Trabalho do núcleo" lista verificações pendentes.
- **"Só as minhas"** mostra só o que está sob sua responsabilidade.
- Filtros de responsável, tipo e etapa organizam o trabalho; **"Limpar filtros"** volta ao padrão.
- Tocar numa tarefa abre o detalhe — registrar evidência, vincular ficha, concluir etapa.

## 4. Qualidade do portal (Monitoramento)

Cada ficha mostra:

- **% de completude** (verde ≥80, âmbar ≥50, vermelho abaixo) —
  calculada pelo peso de cada campo faltante
- **Faltam: top-3** (+ N mais) — prioriza os campos críticos
- Badge 🌐/📝 — se está publicada ou é rascunho

Ações por ficha:

| Botão | O que faz |
|---|---|
| **Ver** | Abre a ficha interna do registro |
| **Editar** | Abre o formulário completo |
| **✨ Sugerir** | IA gera rascunhos das top-3 lacunas de texto — você revisa e aplica com 1 clique |
| **Criar tarefa** | Transforma a lacuna em tarefa do Inventário |

Os chips no topo (**Prontos p/ publicar · Precisam de atenção · Críticos**)
filtram a lista por faixa de completude. A busca por título e o botão
**Limpar filtros** ficam acima da lista.

## 5. Editando conteúdo (Gestão)

### 5.1 Encontrar e abrir

1. **Gestão** → toque no setor (ex.: **Pesquisadores**).
2. Use a **busca** ou o funil de filtros (status, etc.).
3. Toque no item → **ficha interna** (dados agrupados por etapa).

### 5.2 Edição rápida

Na ficha, **toque em qualquer campo** — abre um painel só daquele
campo: edite e salve — PATCH parcial, sem reescrever o resto.
Campos de texto podem usar **✨ Sugerir** (IA esboça, você revisa).

### 5.3 Formulário completo

O botão **Editar** abre o wizard em etapas:

- Dados gerais, equipe, conteúdo, vínculos, revisão — varia por tipo.
- **Campos de pessoa** (autor, coordenador, equipe, participantes):
  ícone de lupa abre a busca de pesquisadores; **"Cadastrar novo(a)"**
  cria um perfil sem sair do fluxo.
- Editor rico com toolbar real (negrito, itálico, listas, link).
- A etapa final revisa tudo antes de salvar.

### 5.4 Criar novo item

O botão **+ Nova {tipo}** aparece apenas nos setores que sua conta
pode criar. Tipos reservados a administradores (projetos, publicações,
eventos etc.) só permitem ver e editar.

## 6. Menus e páginas

- **Gestão → Menus do portal**: selecione o menu, liste itens, edite
  título/endereço/peso, ative/desative links.
- **Gestão → Páginas institucionais**: título, descrição e imagem das
  páginas fixas (Sobre, Missão, Links Úteis…). A composição interna da
  home é feita pelo tema do Drupal — a **"Prévia da página inicial"**
  na Gestão mostra como as seções estão sendo montadas com os
  conteúdos publicados.

## 7. Taxonomias, equipe e mídia

- **Categorias e Tags**: escolha o vocabulário, crie/renomeie termos.
- **Equipe**: contas de usuário, papel e e-mail.
- **Biblioteca de mídia**: no formulário, campos de imagem/arquivo
  abrem o seletor da biblioteca.

## 8. Dicas atemporais

- "Ficha" = um registro do portal (notícia, projeto, pesquisador…).
- Tudo que o app salva vai direto ao portal — não existe cópia local.
- Sugestões da IA são rascunhos: **sempre revise antes de aplicar**.
- Se uma mudança não aparecer no site, verifique se a ficha está
  publicada (badge) e aguarde a página pública ser reconstruída.
- Em caso de dúvida sobre permissões, o app já esconde o que a conta
  não pode fazer — o que aparece, pode ser feito.


---

## 9. Resolvendo erros na hora da demonstração

Erros comuns durante uma apresentação ou uso ao vivo, e o que fazer:

| Sintoma | Causa | Correção |
|---|---|---|
| Botão "+ Novo" não aparece | A conta não pode criar aquele tipo | Abra um item existente e edite — o portal só libera criação nos tipos permitidos (notícia, relatório, pesquisador) |
| "Qual é o setor desta ficha?" | O app ainda não conhece o tipo daquele registro | Escolha o setor uma vez — a partir daí ele resolve sozinho |
| Lista de pesquisadores vazia no seletor | Sessão expirada ou sem permissão | Saia e entre de novo; se persistir, o papel no portal precisa de "access content" |
| "✨ Sugerir" não responde | Limite de chamadas de IA ou campo não é texto | Aguarde ~1 min e tente de novo; só campos de texto/rico aceitam sugestão |
| Campo de referência mostra só opções antigas | Item criado por outra conta depois do carregamento | Toque fora do campo e reabra — a lista recarrega |
| Mudança salva não aparece no site | A ficha continua rascunho ou o portal está reconstruindo a página | Confira o badge Publicado/Rascunho; se rascunho, publique; se publicado, aguarde ~1 min |
| "O portal recusou o salvamento" | Permissão ou validação do Drupal | Tente pelo formulário completo — a mensagem do Drupal explica o motivo |
| Validação não deixa avançar | Campo obrigatório vazio ou inválido | Os campos com borda vermelha mostram o que falta — preencha e avance |
| Datepicker não confirma | Clique fora fechou sem OK | Reabra e confirme com o botão "OK" do calendário |
| Tela cinza ou travada | Falha temporária de rede no portal | Atualize a página (F5) — o trabalho salvo não se perde |
