# NERUDS: briefing operacional para o app

## Objetivo e limite

A adaptação organiza o trabalho que já existe: inventariar fichas, pesquisar
lacunas, registrar evidências, preparar notícias, revisar e conferir o resultado
público. A mesma base de trabalho deve ser acessada por pessoas diferentes, em
computadores diferentes, com contas individuais.

Drupal continua sendo a fonte de identidade, permissões e conteúdo publicado.
Tarefas, propostas, evidências e decisões de curadoria continuam nos contratos
existentes do bridge. Uma área de responsabilidade não concede permissões de
edição ou publicação.

Não foram criados tipos de conteúdo, novos papéis, um calendário paralelo,
cadastro de projetos paralelo, integração com outro repositório de dados ou
automação de publicação.

## Evidências consultadas em 06/10/2026

1. UFT, **Sobre o NERUDS**: núcleo interdisciplinar dedicado às dinâmicas rurais,
   desigualdades e sistemas socioecológicos; criação formal pela Resolução
   36/2021 do Consepe. Fonte institucional:
   https://www.uft.edu.br/nucleos-de-pesquisa-e-extensao/nucleo-de-estudos-rurais-desigualdades-e-sistemas-socioecologicos/sobre-o-neruds-1
2. UFT, **Projetos**: a apresentação institucional cita quatro iniciativas.
   Essa lista não é uma autorização para criar quatro fichas nem comprova seu
   estado atual:
   https://www.uft.edu.br/nucleos-de-pesquisa-e-extensao/nucleo-de-estudos-rurais-desigualdades-e-sistemas-socioecologicos/projetos
3. Portal, páginas existentes **Sobre** e **Inventário de Pesquisa**, tipos,
   campos, rotas públicas, formulários, taxonomias e permissões, consultados por
   Drush/HTTP sem alterar conteúdo ou configuração.
4. **GUIA_PESQUISA_COMPLEMENTACAO.md**, 11/09/2026: o levantamento anterior
   identificou lacunas importantes em ano, resumo, veículo e acesso à produção.
   Parte da informação pode já estar no corpo da ficha; é necessário conferir.
5. **GUIA_RESPONSAVEIS_CONTEUDO.md**, 11/09/2026: áreas de conteúdo, responsáveis,
   uso dos tipos e campos ativos e preservação das fichas existentes.
6. **Guia_Complementar_NERUDS.html**, 13/09/2026, revisto em 14/09:
   fonte recebida, aprovação editorial e conferência pública são evidências
   diferentes. Exemplos de treinamento não são decisões institucionais.
7. **Narracao_Planilha_NERUDS.txt**, 14/09/2026: controle mestre, atividades
   complementares, revisão cruzada, diário e continuidade entre equipes.
8. **neruds - manual da marca (1).docx**, versão disponibilizada em 24/05/2026:
   laranja #F58535, cinza #606062 e cinza claro #DCDDDF; respeitar proporções e
   área de proteção da marca.

Os documentos originais de governança, roteiro de entrevistas e planilha citados
no guia complementar não foram todos recuperados diretamente. Esta adaptação
usa os materiais efetivamente consultados; não atribui aos originais conclusões
que não foram verificadas. O briefing de Palmas Sustentável é específico de um
projeto e não foi usado como missão geral do núcleo.

As evidências técnicas detalhadas ficam em data/qa/, fora do Git. Não devem
conter senhas, tokens, links de recuperação ou exportações de pessoas.

## O que o portal realmente contém

Fotografia de 06/10/2026, obtida por Drush. Os números são diagnóstico, não
constantes para exibição permanente no aplicativo.

| Tipo existente | Publicado | Não publicado | Uso na experiência |
| --- | ---: | ---: | --- |
| publicacao_cientifica | 169 | 2 | Pesquisa de lacunas e conferência da ficha |
| perfil_pesquisador | 14 | 1 | Conferência de autoria e vínculos |
| noticia | 7 | 0 | Atualizações, chamadas, vagas e relatos editoriais |
| page | 5 | 5 | Páginas institucionais existentes |
| projeto_pesquisa_extensao | 2 | 0 | Acompanhamento das fichas dos projetos |
| boletim_periodico | 1 | 0 | Conteúdo existente, sem novo fluxo paralelo |
| grupo_estudos | 1 | 0 | Conteúdo existente |
| reuniao | 1 | 0 | Registro existente, sem criar uma nova agenda |
| acao_extensionista | 1 | 0 | Ação e seus vínculos existentes |
| relatorio | 1 | 0 | Registro existente |
| relatorio_fno | 2 | 0 | Registro existente |
| evento_cientifico | 0 | 1 | Ficha em preparação |
| publicacao | 0 | 0 | Tipo legado vazio; não orientar novo uso |
| boletim | 0 | 0 | Tipo legado vazio; não orientar novo uso |
| **Total** | **204** | **9** | **213 fichas em 14 tipos** |

Há 171 registros de publicação científica. Na consulta atual, 125 não tinham ano,
137 não tinham resumo, 152 não tinham veículo e 113 não tinham link no respectivo
campo. Campos preenchidos também precisam de conferência: quantidade preenchida
não mede qualidade, e nem todos os metadados se aplicam a toda produção.

Dois registros publicados compartilham o mesmo DOI. A busca de possíveis
duplicados deve ajudar a verificar a ficha antes de criar outra, sem exclusão ou
fusão automática.

As duas fichas de projeto usam campos de resumo, justificativa, objetivos,
metodologia, linhas de pesquisa, equipe e ODS. O campo genérico de descrição não
representa seu conteúdo real. A UI encaminha à ficha existente e não inventa um
formulário genérico de projeto.

Foram identificadas páginas públicas vazias, uma página não publicada vinculada
no menu e referências de campos para tipos inexistentes. Essas constatações
orientam tarefas de conferência; não autorizam alterações automáticas no portal.

## Responsabilidade e autorização

| Conta/papel observado | Trabalho disponível | Limite observado |
| --- | --- | --- |
| extensionista | Notícias/relatórios próprios, pesquisa, tarefas e evidências | Sem publicação, revisão editorial privilegiada ou administração de contas |
| pesquisador | Criação de notícia/relatório, conforme Drupal | Não supor edição de todos os tipos |
| revisor | Revisão de notícias | Não concede criação de conteúdo ou administração de contas |
| content_editor | Revisão/publicação de notícia, páginas e notícias/relatórios nos limites de autoria; contas extensionistas | Não concede edição geral de projetos, publicações ou reuniões |
| administrator | Administração implícita do Drupal | Usar apenas para ações efetivamente autorizadas |

O workflow basic_editorial está aplicado a páginas. A configuração
editorial_boletins não está vinculada a tipos. JSON:API com escrita habilitada
não concede a ninguém autorização para editar conteúdo.

Os guias sugerem áreas como comunicação, produção científica, projetos,
secretaria, extensão e páginas institucionais. Nenhuma pessoa foi nomeada
automaticamente. A missão continua exibindo os responsáveis e áreas já
registrados. A coordenação decide atribuições, e o Drupal decide acesso.

As etapas da missão registram o andamento do trabalho. O backend atual permite
sua atualização por contas autenticadas; mover uma tarefa para uma etapa de
validação não é prova de aprovação institucional nem concede publicação.

## Percurso que orienta a interface

| Momento | O que a pessoa precisa resolver | Evidência de continuidade |
| --- | --- | --- |
| Localizar | Qual ficha e qual lacuna devo cuidar? | Missão, tipo, responsável, área sugerida, identificador e links existentes |
| Pesquisar | O que a fonte realmente sustenta? | Origem, link, texto de trabalho e anexo já suportados |
| Propor | O que deve mudar na ficha? | Texto proposto e observações, separados do conteúdo público |
| Revisar | Outra pessoa conferiu fonte e proposta? | Registro da revisão e do que falta ajustar |
| Conferir | A página pública mostra o resultado correto? | Link conferido, evidência e próximo passo |

Salvar a tarefa registra o acompanhamento no bridge. Alterar uma ficha ocorre
no formulário existente do Drupal, de acordo com a conta da pessoa. O app não
afirma que um PATCH na tarefa já atualizou o portal.

Notícias usam o fluxo já existente: preparar texto, conferir, criar rascunho,
revisar e publicar quando a conta possui autorização. Oportunidades continuam
sendo referências curadas; quando já existe uma notícia vinculada, a experiência
encaminha a essa notícia.

## Decisões implementadas

- Início orientado à próxima ação, com acesso a inventário, conteúdo e
  oportunidades. Situação e notícias vêm de consulta real; não há números
  institucionais fixos nem métricas simuladas.
- Navegação mantém as páginas visitadas. Troca de largura, aba ou renovação da
  sessão pela mesma pessoa preserva o texto aberto.
- Saída explícita avisa sobre alterações não salvas, solicita encerramento ao
  serviço e limpa a identidade local apenas com confirmação. Troca de pessoa
  limpa o estado associado à conta anterior.
- Endereço do serviço central configurado na compilação. Credenciais ficam na
  sessão; o navegador recebe somente o endereço da ficha.
- Missão carregada por GET /missions, filtros por responsável/tipo, paginação,
  número real de resultados e área/próxima ação visíveis.
- Ficha da missão com contexto, evidências/proposta e conferência. Checklist e
  upload não reescrevem o texto ainda não salvo. PATCH envia somente campos
  alterados.
- Redação em passos com resultado explícito. A fila mostra texto, autoria,
  estado e links existentes para uma revisão informada.
- Listagem editorial consulta o estado real de publicação. Conteúdo publicado
  no Drupal prevalece sobre um estado local antigo.
- Autoria legada é reconciliada pelo UID observado; uma ficha não é atribuída
  arbitrariamente à pessoa que a consultou.
- Oportunidade já vinculada não cria uma segunda notícia por regressão de
  estado/reenvio. Remover prazo funciona sem confundir omissão e limpeza.
- Criação de notícia preenche o campo de data obrigatório observado e solicita
  rascunho explicitamente, preservando a revisão humana. Também usa o formato
  de texto efetivamente oferecido pelo formulário: a inspeção confirmou que
  basic_html não estava disponível às contas operacionais. Texto simples é
  preservado literalmente; formatos HTML recebem texto escapado, sem grants.
- Administração apresenta o fluxo de contas implementado. Cartões sem ação não
  são apresentados como operações disponíveis.

## Indicadores que não devem orientar decisões

A inspeção do PortalDataService identificou contagem de projetos baseada em
bundles inexistentes, quantidade fixa de territórios, curvas fixas, contagem de
termos ODS tratada como indicador e data de reunião derivada da criação da ficha.
O app não reutiliza esses valores como retrato do núcleo.

A reunião cadastrada tinha data própria diferente de sua criação. A existência
de configuração de busca/IA não comprova indexação ativa. A adaptação não
reimplementa esses módulos nem altera o repositório do portal.

## Operação duradoura

A replicação é do cliente, com uma base central. Todas as pessoas acessam o mesmo
serviço e a mesma origem Drupal. Senhas e dados de trabalho não são copiados para
cada instalação. Ver [instalação dos computadores](WORKSTATION_SETUP.md).

O registro só passa a ser compartilhado depois de salvo. Texto aberto é
preservado em memória durante a sessão, mas não é um rascunho offline persistido:
fechar o aplicativo ou o processo pode descartá-lo. A interface não promete
sincronização offline.

Chamadas, vagas e avisos podem usar a notícia existente quando houver fonte,
responsável e revisão. Acompanhamento de projeto e reunião usa as fichas e
tarefas existentes. Nenhuma expansão de tipos ou mudança de permissões está
embutida nesta entrega.
