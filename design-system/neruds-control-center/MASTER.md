# NERUDS — sistema visual do trabalho editorial

## Fundamento

Aplicativo operacional para cuidar do portal e do inventário de pesquisa.
A experiência atende pesquisa, evidência, proposta, revisão e conferência
pública, preservando o contexto entre pessoas e computadores.

Fontes: manual da marca NERUDS disponibilizado em 24/05/2026 e os guias de
inventário e responsabilidade de conteúdo de setembro de 2026.
O briefing de decisões está em docs/NERUDS_WORKFLOW_BRIEFING.md.

## Identidade

| Elemento | Valor | Aplicação |
| --- | --- | --- |
| Laranja institucional | #F58535 | Destaque e orientação, sem texto branco pequeno |
| Cinza institucional | #606062 | Texto secundário e contornos |
| Cinza claro institucional | #DCDDDF | Divisórias e agrupamento |
| Texto principal | #29292B | Leitura prolongada |
| Ação principal | #434345 sobre branco, branco sobre #434345 | Botão de ação inequívoca |
| Fundo de trabalho | #F6F6F7 | Separar a área de trabalho dos cartões |
| Destaque suave | #FFDEC7 | Próxima ação e navegação selecionada |

Usar a marca oficial somente com o arquivo aprovado, suas proporções e área de
proteção. O texto NERUDS no cabeçalho identifica o aplicativo sem simular um novo
logotipo. Não importar fontes decorativas da marca para formulários.

## Estrutura

- Cabeçalho estável com identidade do núcleo e conta individual.
- Navegação lateral em largura de trabalho; navegação inferior em tela estreita.
- Páginas visitadas preservadas durante a sessão. Mudar de aba não reinicia
  formulário, filtro ou posição.
- Início com uma ação principal de inventário e entradas secundárias de conteúdo
  e oportunidades. Notícias públicas complementam, sem competir com o trabalho.
- Largura de leitura controlada, espaçamento de 8/12/16/24/32 e cartões simples.
- Botões com área mínima de 48, texto explícito, ícone como apoio.
- Formulários e mensagens acessíveis a teclado e ampliação de texto.

## Linguagem e estados

Descrever o efeito: Abrir ficha, Registrar fonte, Salvar proposta, Criar
rascunho, Solicitar ajuste, Conferir página, Encerrar vínculo.
Evitar exposição de endpoints, nomes de permissões e infraestrutura em fluxos
comuns.

Cada consulta distingue carregamento, vazio válido, resultado e falha. Falha de
consulta não vira zero registros nem sucesso silencioso. Mensagens orientam
recuperação sem revelar endereço privado ou token.

Uma proposta salva na tarefa não significa conteúdo alterado no portal.
Rascunho criado não significa notícia publicada. Etapa registrada não equivale
a permissão ou aprovação institucional.

## Formulários e wizards

1. Apresentar primeiro a ficha/objetivo e o contexto que a pessoa precisa.
2. Agrupar campos pela decisão de trabalho, sem pedir identificadores técnicos
   antes do texto.
3. Mostrar revisão legível antes do envio e um resultado com destino depois dele.
4. Manter campos em falha de rede e expiração de sessão da mesma conta.
5. Ao trocar de pessoa ou sair, limpar contexto da conta anterior, com aviso
   de alterações não salvas.
6. Atualizações de anexos e checklist não devem substituir texto que a pessoa
   ainda está editando.
7. Abertura no navegador usa apenas o link da ficha. Credenciais do aplicativo
   não são colocadas em URLs.

## Critérios de revisão

- Primeira tarefa acessível a partir do Início sem consultar documentação técnica.
- Conteúdo compreensível em desktop e largura de celular, inclusive com texto
  ampliado.
- Área/responsável, fonte, próxima ação e limite da operação perceptíveis.
- Ausência de cartões sem ação apresentados como funcionalidades prontas.
- Ações privilegiadas dependentes das capacidades reais da sessão.
- Nenhum indicador institucional fixo, fictício ou derivado de campos errados.
- Nenhuma dependência visual de nomes de pessoas, bolsistas ou datas de campanha.
- Separar prova automatizada de layout da prova de execução em dispositivo.
