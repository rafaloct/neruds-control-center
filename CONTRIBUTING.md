# Contributing

## Fluxo

1. Abra ou escolha uma Issue.
2. Crie uma branch curta a partir de `main`.
3. Faça mudanças focadas no escopo da Issue.
4. Rode os testes relevantes.
5. Abra um Pull Request referenciando a Issue.
6. Só faça merge depois dos checks e revisão.

## Convenções

Branches:

- `feat/<issue>-descricao`
- `fix/<issue>-descricao`
- `docs/<issue>-descricao`
- `ops/<issue>-descricao`

Commits sugeridos:

- `feat: ...`
- `fix: ...`
- `docs: ...`
- `test: ...`
- `ops: ...`
- `refactor: ...`

## Antes do commit

```powershell
cd app
dart analyze lib test
flutter test --no-pub

cd ..\bridge
uv run python -m py_compile main.py mission_store.py rss_store.py review_store.py

cd ..
git diff --check
```

Nunca adicione ao Git:

- `.env`;
- `secrets/`;
- bancos SQLite/runtime;
- builds e releases;
- planilhas institucionais brutas;
- keystores;
- tokens, senhas, cookies ou certificados privados.
