# Plano — Financeiro: Contas Bancárias e Conciliação OFX

> Projeto: MestreVirtual / Loja Maçônica
> Status: **Fase 1 em execução** · demais fases documentadas, **não implementadas**.
> Última atualização: 2026-06-27

Este documento registra as decisões já fechadas, o escopo de cada fase, e as
regras invariantes que devem ser respeitadas em qualquer evolução do módulo
financeiro. **Consulte este documento antes de tocar qualquer coisa em
`financas`, `contas_bancarias`, `categorias_financeiras` ou `extratos_bancarios`.**

---

## 1. Decisões já fechadas

### Banco
- Banco principal da loja: **Sicoob**.
- Contas iniciais a cadastrar:
  1. **Sicoob — Conta Corrente** (movimento normal)
  2. **Sicoob — Poupança** (guarda dinheiro do Tronco/Beneficência)
- Sicoob disponibiliza extrato em **PDF e OFX**. **A conciliação futura usa OFX**;
  PDF fica apenas como conferência humana.

### Perfis / permissões
- Importação e conciliação (fases 3+) **apenas para Tesoureiro e Administrador**.
- CRUD de contas bancárias e categorias financeiras (Fase 1):
  - **Editar**: Admin e Tesoureiro.
  - **Visualizar**: Venerável (pode ver para fins de relatório).
  - **Demais perfis** (Secretário, Chanceler, Irmão): sem acesso aos dados bancários.
- Toda tabela nova nasce com **RLS habilitada** e policies explícitas.

### Domínio
- `contas_bancarias` representam **onde o dinheiro está fisicamente** (conta na
  instituição, ou caixa físico se um dia precisar).
- `categorias_financeiras` representam **origem/finalidade** do lançamento
  (mensalidade, joia, ágape, tronco, transferência interna, rendimento etc.).
- `financas` continua sendo o **extrato de lançamentos da loja**
  (= o que aconteceu segundo o Tesoureiro), com `status ∈ {pago, agendado, vencido/aberto}`.
- `extratos_bancarios` (Fase 3) representará **linhas brutas importadas do OFX**
  (= o que o banco diz que aconteceu).
- Conciliação (Fase 4) liga **uma linha de extrato a um lançamento de `financas`**,
  agregando prova bancária ao lançamento existente. **Não substitui** o lançamento.

### Premissas operacionais
- **1 PIX corresponde a 1 pagamento** na prática da loja. Não há (por agora)
  necessidade de modelo "1 extrato → vários lançamentos".
- Conciliação começa **para frente** — sem importar histórico retroativo.
- Cadastro dos irmãos contém **nome civil e nome maçônico**. Regras futuras
  (Fase 5) usarão preferencialmente **nome civil** para casar com a descrição
  do PIX no OFX.
- **Tronco/Beneficência** é uma **categoria/finalidade**, não banco separado.
- **Transferência interna** (corrente ↔ poupança): tratada como `categoria='transferencia_interna'`.
  Por convenção, esses lançamentos **não entram no total de receitas/despesas**
  do período — só movem dinheiro entre contas.
- **Rendimento da poupança**: tratado como **receita financeira realizada**
  na categoria `rendimento`.
- O extrato de lançamentos atual **não é substituído** pela conciliação.
  A conciliação apenas **anexa prova bancária** ao lançamento já existente.

---

## 2. Modelo conceitual

```
       ┌─────────────────────────┐         ┌───────────────────────┐
       │   contas_bancarias      │         │ categorias_financeiras│
       │  (onde está o dinheiro) │         │  (origem/finalidade)  │
       └────────────┬────────────┘         └───────────┬───────────┘
                    │                                  │
                    │ (Fase 2) conta_bancaria_id NULL  │ categoria_slug
                    ▼                                  ▼
       ┌────────────────────────────────────────────────────────┐
       │                       financas                         │
       │   (lançamentos da loja — verdade do Tesoureiro)        │
       │   status: pago | agendado | aberto/vencido             │
       └────────────────────────┬───────────────────────────────┘
                                │
                                │ (Fase 4) financa_id NULL
                                │
       ┌────────────────────────┴───────────────────────────────┐
       │                  extratos_bancarios                    │  (Fase 3)
       │   (linhas brutas vindas do OFX — verdade do banco)     │
       │   status_conciliacao: pendente | conciliado | ignorado │
       └────────────────────────────────────────────────────────┘
```

---

## 3. Fases

### Fase 1 — Cadastros básicos *(em execução agora)*

**Entrega:**
- Tabela `contas_bancarias` (com RLS).
- Tabela `categorias_financeiras` (com RLS).
- CRUD simples acessado pelo painel **Finanças** (botão "🏦 Bancos & Categorias"
  no topo do extrato — Admin/Tesoureiro editam; Venerável lê).
  - **Nota técnica**: inicialmente a aba foi colocada em Configurações, mas o
    Tesoureiro tem `configuracoes:'none'` no ROLES, o que bloqueava o acesso.
    A funcionalidade foi movida para Finanças, onde Tesoureiro e Venerável
    têm `financas:'full'`.
- Seeds iniciais documentados (não inseridos automaticamente — Tesoureiro
  insere via UI após revisar):
  - Contas: *Sicoob — Conta Corrente*, *Sicoob — Poupança*
  - Categorias adicionais sugeridas: *Tronco/Beneficência* (já existe como
    `tronco`), *Transferência interna* (novo, slug `transferencia_interna`),
    *Rendimento financeiro* (novo, slug `rendimento`).

**Fora de escopo desta fase:**
- Vincular conta bancária ao lançamento de `financas` (vai na Fase 2).
- Importar OFX (Fase 3).
- Painel de conciliação (Fase 4).
- Regras de matching (Fase 5).
- Backfill de lançamentos antigos (qualquer fase futura, sempre opt-in).
- Migrar o `localStorage.cats_fin` automaticamente (Tesoureiro decide o que
  promover para a tabela; categorias antigas em localStorage seguem funcionando
  como fallback).

**Migration:** `docs/migrations/2026-06-27-fase1-contas-categorias.sql`
(arquivo separado, **não rodado** — fica para revisão antes da aplicação manual
no SQL Editor do Supabase **com backup feito previamente**).

### Fase 2 — Vínculo opcional de conta no lançamento *(planejada)*

**Entrega:**
- `ALTER TABLE financas ADD COLUMN conta_bancaria_id uuid NULLABLE REFERENCES contas_bancarias(id)`.
- `ALTER TABLE financas ADD COLUMN forma_pagamento text NULLABLE`
  (`pix` / `ted` / `dinheiro` / `boleto` / `cartao` / `outro`).
- `ALTER TABLE financas ADD COLUMN identificador_externo text NULLABLE`
  (campo para guardar FITID/end-to-end-id do PIX quando conciliado).
- `ALTER TABLE financas ADD COLUMN data_vencimento date NULLABLE` —
  separa `data` (efetiva, quando aconteceu) de `data_vencimento`
  (quando era devido). Lançamentos antigos: `data_vencimento = NULL`,
  código antigo continua usando `data` como hoje.
- Modal "Novo Lançamento" ganha selects opcionais.

**Cuidados:**
- **Tudo nullable**. Não inventar histórico falso: lançamentos antigos
  ficam com `conta_bancaria_id = NULL` indefinidamente, salvo backfill
  manual conduzido pelo Tesoureiro **caso a caso**, jamais em massa.
- Cálculos atuais de saldo continuam funcionando sem mudança.

### Fase 3 — Importação OFX do Sicoob *(planejada)*

**Entrega:**
- `CREATE TABLE extratos_bancarios` (id, conta_bancaria_id, data, descricao_bruta,
  valor, sinal, tipo_operacao, fitid, hash_linha, identificador_externo,
  status_conciliacao, financa_id NULL, importacao_id, criado_em).
- `CREATE TABLE importacoes_ofx` (id, conta_bancaria_id, arquivo_nome,
  periodo_inicio, periodo_fim, total_linhas, total_duplicadas, criado_por, criado_em).
- **Dedup forte**: `UNIQUE(conta_bancaria_id, fitid)` quando FITID não nulo;
  `UNIQUE(conta_bancaria_id, hash_linha)` como fallback (hash determinístico
  sobre data + valor + descricao normalizada).
- Parser OFX client-side, começando pelo formato do Sicoob.
- Tela "Importar Extrato" em Financeiro: escolhe conta → upload `.ofx` →
  preview → confirma. Linhas entram com `status_conciliacao = 'pendente'`.
- Auditoria mínima: `criado_por`, `criado_em` em ambas as tabelas.

**Cuidados:**
- Não criar `financas` automaticamente a partir do extrato.
- Não conciliar nada automaticamente.
- Erros de parsing não devem deixar linhas parciais no banco
  (importação inteira em transação).

### Fase 4 — Painel manual de conciliação *(planejada)*

**Entrega:**
- Tela "Extratos pendentes" lista linhas com `status_conciliacao = 'pendente'`.
- **Painel lateral à direita** ao clicar numa linha:
  - dados do extrato (data, valor, descrição bruta)
  - candidatos automáticos: `financas` com `|valor − extrato.valor| ≤ 0.05`,
    `|data − extrato.data| ≤ 15 dias`, `status ∈ {agendado, aberto}`,
    mesma conta_bancaria_id (se preenchida) ou NULL
  - botões:
    - **Vincular** → atualiza extrato (`status='conciliado'`, `financa_id`,
      `conciliado_por`, `conciliado_em`) **e** financa (`status='pago'`,
      `data` ← data do extrato, `identificador_externo` ← fitid).
    - **Criar novo lançamento** → abre o modal atual já pré-preenchido.
    - **Ignorar** (taxa bancária pequena, transferência interna já lançada
      no outro lado etc.) → marca extrato como `ignorado` com motivo.
- **Toda ação exige clique humano.** Sugestões aparecem destacadas, nunca
  aplicadas automaticamente.

### Fase 5 — Regras determinísticas *(planejada)*

**Entrega:**
- `CREATE TABLE regras_conciliacao` (id, ativa, descricao_regex, valor_min,
  valor_max, dia_min, dia_max, categoria_destino, membro_id_destino,
  conta_bancaria_id, status_destino, prioridade).
- Tela CRUD de regras.
- Ao importar OFX, regras são aplicadas e geram **sugestões** mostradas no
  painel da Fase 4 — **nunca conciliam sozinhas**.
- Regras usam preferencialmente **nome civil** do irmão para casar com a
  descrição do PIX (ex: `PIX RECEBIDO JOSE DA SILVA` → membro José da Silva).

### Fase 6 — Trava real, auditoria e relatório do Conselho Fiscal *(planejada)*

**Entrega:**
- Migrar `fechamentos_mensais` de localStorage para tabela `fechamentos_mensais`
  (ano, mes, fechado_por, fechado_em, observacao).
- Importação e edição **bloqueadas em mês fechado** no servidor (não só client).
- Desconciliação manual permitida **apenas com motivo registrado**
  (`desconciliado_por`, `desconciliado_em`, `motivo_desconciliacao`).
- Auditoria ampliada: `criado_por`, `criado_em`, `alterado_por`, `alterado_em`
  em `financas`, `contas_bancarias`, `categorias_financeiras`.
- Relatório de conciliação (extrato bancário × lançamentos da loja) com
  diferenças destacadas — material para o Conselho Fiscal.

---

## 4. Regras invariantes (valem em **todas** as fases)

1. **Toda tabela nova nasce com RLS habilitada e policies explícitas.**
2. **Categorias estruturalmente classificadas**:
   - Campo `natureza` em `categorias_financeiras`: `operacional` (caso comum),
     `transferencia`, `rendimento`, `outros`.
   - Campo `impacta_resultado boolean`: quando `false`, lançamentos da categoria
     **não entram** nos totais de receita/despesa do período (ex.: transferência
     interna). Mantém-se no extrato de lançamentos.
   - Cálculo do período deve usar **`WHERE impacta_resultado = true`** ao somar
     receitas/despesas. Categoria sem a flag (NULL) é tratada como TRUE por
     compatibilidade com `financas` antigas.
3. **Rendimento da poupança** entra como **receita** financeira (categoria
   `rendimento`).
4. **Extrato de lançamentos atual permanece**. Conciliação **anexa**, não
   substitui.
5. **Nenhuma conciliação automática.** Sugestões sim, ação sempre humana.
6. **Sem backfill silencioso** de `financas` antigas. Se necessário, sempre
   sob comando explícito do Tesoureiro, em escopo definido.
7. **SQL nunca rodado no Supabase em produção sem snapshot/backup prévio.**
   Migrations ficam em `docs/migrations/` para revisão antes da aplicação.
8. **Dados sensíveis (número de conta, nome do titular do PIX) não devem
   aparecer em logs ou no console.**
9. **Sem hard delete em dados bancários.** Tanto `contas_bancarias` quanto
   `categorias_financeiras` usam apenas soft delete (`ativo = false`). As
   policies da Fase 1 omitem `FOR DELETE` propositadamente. UI esconde botões
   destrutivos. Razão: na Fase 2, `financas.conta_bancaria_id` apontará para
   `contas_bancarias`; apagar conta usada destruiria histórico.

---

## 5. Como o financeiro funciona hoje (referência rápida)

Detalhado em `docs/HISTORICO.md` e na auditoria feita em 2026-06-27.
Resumo:
- Tabela única: `financas` (id, descricao, valor, tipo, data, categoria,
  status, membro_id).
- Categorias em `localStorage.cats_fin` (será gradualmente migrado para
  `categorias_financeiras` da Fase 1).
- "Saldo Bancário" no painel é cálculo virtual `receitas pagas - despesas pagas`
  excluindo `categoria='tronco'`.
- Sem conceito de conta bancária, extrato OFX, conciliação ou FITID.
- `fechamentos_mensais` em localStorage (fase 6 migrará).

---

## 6. Riscos conhecidos e mitigações

| Risco | Mitigação |
|---|---|
| Importação OFX duplicada | UNIQUE(conta, fitid) + UNIQUE(conta, hash_linha) na Fase 3. |
| Saldos inconsistentes após conciliação errada | Painel Fase 4 sempre exige clique; Fase 6 introduz desconciliação com motivo. |
| Categorias divergentes entre máquinas (localStorage) | Migrar para tabela na Fase 1. localStorage continua como fallback até confirmação. |
| `financas.data` ambígua (vencimento ou efetiva) | Fase 2 separa `data` e `data_vencimento`; código antigo segue. |
| `fechamentos_mensais` client-side | Fase 6 migra para tabela e adiciona trava server-side. |
| Parser OFX divergente entre versões | Começar com OFX 2.x do Sicoob; expandir conforme necessidade. |
| RLS frouxa em outras tabelas (TD-2) | Tabelas novas nascem com RLS estrita; TD-2 segue separado. |
| Dados sensíveis em logs | Code review obrigatório nas funções de import; nunca `console.log` de descrição bruta em produção. |

---

## 7. Histórico de execução deste plano

| Data | Fase | O que foi feito | Por |
|---|---|---|---|
| 2026-06-27 | — | Plano criado | Denis + Claude |
| 2026-06-27 | 1 | Migration SQL escrita para revisão (`docs/migrations/2026-06-27-fase1-contas-categorias.sql`) | Denis + Claude |
| 2026-06-27 | 1 | CRUD UI de contas bancárias e categorias financeiras em Configurações | Denis + Claude |
