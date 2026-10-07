# Instalação do cliente nos computadores do NERUDS

## Uma base de trabalho, várias contas individuais

Cada computador executa o cliente Flutter e consulta o mesmo bridge. O bridge
mantém o acompanhamento compartilhado e usa o Drupal como fonte de identidade,
permissões e conteúdo. Não instalar uma cópia independente do banco do bridge em
cada computador: isso separaria tarefas, evidências e decisões.

A pessoa entra com sua própria conta. A área/responsável de uma tarefa organiza
o trabalho, mas não concede permissões de publicação ou edição no portal.

## Configuração de uma versão

O endereço é fornecido pela equipe técnica no ambiente de compilação:

| Configuração | Uso |
| --- | --- |
| NERUDS_BRIDGE_URL | Endereço HTTPS do serviço central acessível pela rede autorizada |
| NERUDS_PORTAL_URL | Opcional; endereço público do portal para consulta direta ou fixação da origem |

O cliente exige HTTPS para o bridge remoto. HTTP é aceito somente em localhost,
127.0.0.1 ou [::1], para desenvolvimento/QA na própria máquina; nomes semelhantes
e outros endereços de rede não recebem essa exceção.

O cliente aprende o endereço público do portal na resposta do bridge quando o
segundo parâmetro não é fornecido. Não há endereço de infraestrutura embutido no
código do cliente. Uma versão sem configuração mostra uma orientação de
instalação, em vez de tentar um servidor desconhecido.

Não colocar senhas, tokens ou chaves em --dart-define, código, logs ou arquivos
versionados. Os parâmetros de compilação são inspecionáveis no aplicativo.

## Compilar e distribuir no Windows

No diretório app, usando uma versão de Flutter compatível com pubspec.yaml e o
toolchain de desktop já configurado:

```powershell
if ([string]::IsNullOrWhiteSpace($env:NERUDS_BRIDGE_URL)) {
  throw 'Defina NERUDS_BRIDGE_URL com o endereço aprovado do serviço central.'
}
flutter pub get
flutter analyze
flutter test
flutter build windows --release "--dart-define=NERUDS_BRIDGE_URL=$env:NERUDS_BRIDGE_URL"
```

O parâmetro opcional segue a mesma forma:

```powershell
flutter build windows --release "--dart-define=NERUDS_BRIDGE_URL=$env:NERUDS_BRIDGE_URL" "--dart-define=NERUDS_PORTAL_URL=$env:NERUDS_PORTAL_URL"
```

Distribuir a pasta completa de saída Release, incluindo executável, DLLs e data.
Copiar apenas o executável deixa de fora recursos e plugins necessários.
Confirmar também o runtime Visual C++ no computador de destino ou incluí-lo pelo
procedimento de distribuição aprovado. O guia oficial de empacotamento enumera
as DLLs necessárias: https://docs.flutter.dev/platform-integration/windows/building

A pessoa
usuária não precisa de Flutter, Git, Drush ou acesso administrativo ao servidor.

O endereço faz parte dessa versão compilada. Mudar de servidor requer nova
compilação configurada. Não há descoberta automática de serviços nem tela de
credenciais administrativas no cliente.

Guia oficial de distribuição Windows:
https://docs.flutter.dev/deployment/windows

## Android

O mesmo contrato de configuração é usado na compilação Android:

```sh
flutter build apk --release --dart-define=NERUDS_BRIDGE_URL="$NERUDS_BRIDGE_URL"
```

Usar HTTPS. A assinatura de distribuição permanece no mecanismo de keystore já
existente no projeto. Não copiar keystore ou senhas para o repositório.

O sucesso de testes de widgets em largura de celular não comprova uma execução
em dispositivo Android. Registrar separadamente o que foi compilado, o que foi
testado em simulação de layout e o que foi executado em um dispositivo real.

## Primeiro uso

1. Abrir a versão configurada e conferir se a consulta ao portal responde.
2. Entrar com a conta individual. Se ela não existe, solicitar à pessoa que já
   administra contas; não compartilhar a conta de outra pessoa.
3. Abrir Inventário e escolher a missão disponível. Filtrar responsável e tipo
   de conteúdo para localizar uma tarefa.
4. Conferir contexto, ficha existente e fonte. Salvar o trabalho antes de fechar
   o aplicativo.
5. Ao editar no navegador, usar a conta do portal. Retornar à tarefa para
   registrar a revisão e a conferência pública.
6. Ao terminar em computador compartilhado, usar Sair da conta. Se o serviço
   não confirmar a saída, o aplicativo informa o problema e permite tentar
   novamente.

O aplicativo não salva a senha para entrar automaticamente. A sessão do
navegador é independente: sair do aplicativo não afirma que todas as sessões
abertas no navegador foram encerradas.

## Atualizar uma instalação

Fechar o aplicativo após salvar o trabalho. Substituir a pasta do cliente por
uma versão revisada e identificada por commit/build. Conferir conexão, entrada,
abertura da tarefa e navegação para a ficha. O conteúdo continua no serviço
central; não copiar pastas data de desenvolvimento entre computadores.

O bridge e o módulo Drupal têm seus próprios procedimentos de implantação.
Distribuir um cliente novo não substitui a atualização do backend quando o PR
altera seu contrato. Esta adaptação usa respostas compatíveis, mas a fila
editorial completa e as proteções de vínculo dependem da versão correspondente
do bridge.

## Evidência de uma validação

Registrar commit do cliente/backend, plataforma, resultado dos testes, telas
exercitadas e eventual uso de dados sintéticos. Guardar evidência operacional em
data/qa/ ou no destino privado de QA, fora do Git. Não incluir senha, token,
e-mail privado ou link de recuperação em capturas.

A aprovação de uma versão não autoriza uma mudança de papel, publicação de
conteúdo ou instalação em todas as máquinas sem o procedimento operacional
combinado pela equipe.
