# Validação da continuidade dos fluxos

Consulta de contexto: 06/10/2026. Revalidação após revisão: 07/10/2026 (UTC).
Base de trabalho: main em 93e16e6. Esta entrega adapta contratos e telas
existentes, sem alteração de conteúdo ou permissões no portal de produção.

## Resultados

| Verificação | Resultado | O que comprova |
| --- | --- | --- |
| Bridge, suíte completa pytest | 108 passed, exit 0 | Contratos HTTP simulados, stores temporários e regressões |
| Python py_compile | PASS, 6 módulos | Validação sintática dos módulos do bridge |
| Flutter analyze | Nenhuma ocorrência | Análise estática do aplicativo |
| Flutter test, suíte completa | 50 passed | Interações, sessão, permissões, formulários e larguras estreitas |
| Windows release | Compilado antes dos ajustes de revisão | Integração de Flutter, plugins e runner Windows |
| Android debug de QA | Compilado antes dos ajustes de revisão | Compatibilidade de compilação dos plugins Android |
| Web release, comando do CI | PASS, exit 0 | Compilação sem serviço configurado; sem execução ou publicação |
| git diff --check | Limpo | Ausência de erros de whitespace no diff |
| PHP | Não se aplica | Nenhum arquivo PHP foi alterado |

A execução de pytest desativou carregamento de .env e notificações SMTP antes
da importação da aplicação. Usou o executável uv disponível, lock congelado e
as fixtures existentes de isolamento. Nenhum teste foi filtrado ou suprimido.

O gate web final executou `flutter build web --no-pub --no-wasm-dry-run`,
o mesmo comando do CI. A saída em `app/build/web` não tem endereço de serviço
configurado e não foi executada no navegador nem publicada.

## Regressões cobertas

- Expiração limpa privilégios e permite retomar a redação com a mesma identidade.
- Os dois diálogos de missão permitem renovar a sessão dentro da própria janela;
  a mesma conta retoma os campos, outra conta limpa e bloqueia a ficha anterior.
  Respostas antigas e seleções de arquivo pendentes não restauram dados nem
  enviam arquivos em nome da nova sessão.
- Bridge remoto exige HTTPS antes de enviar login, bearer ou consultar snapshot.
  HTTP fica restrito aos hosts locais exatos; nomes semelhantes não são aceitos.
- Um 401 atrasado de token antigo não invalida uma sessão nova; login rejeitado
  sem bearer não derruba outra sessão.
- Trocar de aba ou de largura preserva o formulário. Trocar de conta limpa seu
  contexto anterior.
- Saída cancelada não envia logout; saída não confirmada preserva sessão e texto.
  Enquanto a saída aguarda resposta, edição e foco ficam suspensos.
- Missão carregada por identificador retornado, com filtros de responsável/tipo
  e erros de consulta que podem ser retomados.
- Checklist e upload não apagam a proposta aberta; PATCH da tarefa envia apenas
  campos alterados; fechamento pede confirmação quando há trabalho não salvo.
- Redação preservada em 401/503, confirmação de sucesso antes de limpar campos e
  fila com corpo, resumo, autoria, instruções de ajuste e estado publicado real.
- Respostas 502 de criação ambígua e conflitos 409 reconhecidos preservam a
  orientação de conferir o registro existente antes de repetir. Só mensagens
  constantes conhecidas, com o status esperado, são apresentadas; HTML e detalhes
  arbitrários do servidor permanecem ocultos.
- Revisão/publicação dependem das capacidades da conta; item publicado não recebe
  ações editoriais regressivas.
- Prazo explicitamente vazio é removido; omitido ou null permanece compatível.
- Oportunidade vinculada conserva seu rascunho e bloqueia criação repetida, mesmo
  após estado legado inconsistente. Concorrência local foi exercitada.
- Arquivar uma oportunidade vinculada preserva nota, prazo, categoria, tags e
  link do portal, sem liberar nova criação ou estados regressivos. Falha ao
  arquivar mantém a ficha disponível; essa ação não exige poder de revisão.
- Texto simples é preservado literalmente; HTML recebe escape; formato vem do
  formulário permitido, data obrigatória preenchida e status de rascunho explícito.
- Identificação nova exige NID real. Formulário que retorna validação com HTTP200
  não é declarado como criação bem-sucedida.
- Cadastro/encerramento de vínculo preservam campos em erro. Diálogos só descartam
  controladores após concluir sua transição. Senha temporária e link de recuperação
  deixam de ser exibidos quando a sessão que os originou termina.
- Falhas de roster/histórico não são mostradas como ausência de contas ou eventos.

Os testes de widgets exercitaram 390/400 px, desktop e ampliação de texto a 1,6.
Usaram nomes e respostas sintéticos, sem chamadas ao portal de produção.

## Compilação Android no ambiente de QA

O primeiro build encontrou um problema do cache incremental Kotlin com fontes e
projeto em volumes diferentes. A compilação foi concluída com propriedades
limitadas ao processo, sem mudança de dependências, arquivos Android versionados
ou configuração global:

```text
GRADLE_OPTS += -Dorg.gradle.project.kotlin.incremental=false
GRADLE_OPTS += -Dorg.gradle.project.kotlin.compiler.execution.strategy=in-process
```

Referências oficiais: [compilação incremental Kotlin](https://kotlinlang.org/docs/gradle-compilation-and-caches.html),
[estratégia de execução Kotlin](https://kotlinlang.org/docs/compiler-execution-strategy.html)
e [ambiente e propriedades Gradle](https://docs.gradle.org/current/userguide/build_environment.html).

O APK é debug e aponta para um endereço fictício. A prova é de compilação:
nenhum dispositivo Android foi usado nesta etapa. Os logs e o hash do APK ficam
na evidência privada de QA. Esse APK antecede o ajuste final dos rótulos da barra
compacta e as correções de revisão descritas acima. A revisão posterior repetiu
análise, suíte Flutter completa e build web. Não distribuir esse APK como versão
de produção.

## Escopo da inspeção visual Windows

A inspeção usa um servidor HTTP sintético na própria máquina, com todas as
alterações em memória. As fichas, pessoas e oportunidades são exemplos marcados
QA. O processo não contém cliente de rede externa e não publica no portal.

As capturas e o roteiro ficam em data/qa/workflow-context-20261006, fora do Git.
Foram conferidos início, entrada, filtros/lista do inventário, os três passos
da ficha, redação/prévia, fila de revisão e uma oportunidade com rascunho já
vinculado. A prévia manteve o texto após visitar outra área e retornar. A fila
também foi inspecionada em janela estreita, assim como Administração e a página
de equipe/acessos. Uma correção visual tornou a trilha da
barra de progresso neutra para não representar 0% como uma barra concluída.
A última captura confirmou os rótulos compactos Pautas e Contas sem quebra
de palavras. Os nomes completos continuam nas dicas e na navegação lateral.

O build Windows e essas capturas antecedem os quatro ajustes de revisão. A
recuperação de sessão dentro das fichas, os avisos de criação incerta e a ação de
arquivar foram validados posteriormente por testes de widgets; não se atribui
às capturas anteriores a comprovação dessas novas interações.

## Limites da evidência

- O teste de identidade em produção da entrega anterior não é um E2E de notícias
  desta alteração. Não foi realizada submissão editorial real nesta etapa.
- Contas operacionais continuam sem edição geral de projetos/publicações/reuniões.
  O app abre a ficha existente e o Drupal aplica sua autorização.
- Um vínculo legado que contém apenas UUID não recebe uma URL de edição inventada.
  Ele continua impedindo nova criação; sua referência requer conferência no portal.
- A serialização de criação de oportunidade cobre um processo do bridge. Não é
  uma garantia de idempotência entre múltiplos workers nem de resultado remoto
  após resposta de rede ambígua. Nessa situação, conferir a ficha antes de repetir.
- Texto não salvo é mantido em memória, sem promessa de persistência após fechar
  o processo ou de sincronização offline.
- Os resultados da tabela são locais. Após a regularização do faturamento, a
  segunda tentativa do [run 37547833653](https://github.com/rafaloct/neruds-control-center/actions/runs/37547833653)
  concluiu Bridge checks e Flutter checks no commit c4d802c. O bridge do CI
  executa compile/import; os 108 testes pytest são evidência local separada.
  O estado do CI para os commits posteriores desta revisão é reportado no PR.

## Revisão e implantação

A implantação corresponde ao cliente e ao bridge deste PR. O módulo Drupal e o
repositório do portal não foram alterados. PRs operacionais já abertos mantêm
seu próprio ciclo de decisão. Existem arquivos compartilhados com as propostas
de sanitização e operações; coordenar a ordem de aterrissagem sem reescrever suas
branches nem incorporá-las silenciosamente.
