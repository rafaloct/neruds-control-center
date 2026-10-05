# Security Policy

## Escopo

O NERUDS Control Center administra fluxos editoriais e serviços internos. Vulnerabilidades que possam causar publicação indevida, exposição de credenciais, acesso entre papéis ou perda de dados são tratadas como prioridade máxima.

## Regras

- Não registre senha, token, cookie de sessão ou chave privada em logs, Issues ou commits.
- Não publique o bridge diretamente na internet.
- Não conceda `administer nodes` a Extensionista para contornar limitações de API.
- Não enfraqueça validação TLS.
- Não crie novo keystore Android sem decisão explícita sobre identidade de distribuição.
- Não inclua dados reais de usuários em fixtures/testes.

## Incidente

Se um segredo entrar no Git:

1. revogue/rotacione o segredo imediatamente;
2. remova-o do histórico antes de tornar o repositório acessível a terceiros;
3. documente o incidente sem reproduzir o segredo;
4. valide que a credencial antiga não funciona mais.
