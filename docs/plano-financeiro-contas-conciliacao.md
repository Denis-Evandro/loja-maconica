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

### Fase 1 — Cadastros básicos *(CONCLUÍDA em 2026-06-28)*

**Entregue:**
- Tabela `contas_bancarias` (com RLS).
- Tabela `categorias_financeiras` (com RLS).
- CRUD simples acessado pelo painel **Finanças** (botão "🏦 Bancos & Categorias"
  no topo do extrato — Admin/Tesoureiro editam; Venerável lê).
  - **Nota técnica**: inicialmente a aba foi colocada em Configurações, mas o
    Tesoureiro tem `configuracoes:'none'` no ROLES, o que bloqueava o acesso.
    A funcionalidade foi movida para Finanças, onde Tesoureiro e Venerável
    têm `financas:'full'`.
- 3 categorias-sistema inseridas via seed: `tronco`, `transferencia_interna`,
  `rendimento`.
- Funções helper RLS `is_financeiro_editor()` / `is_financeiro_reader()` com
  SECURITY DEFINER, search_path fixo, REVOKE FROM PUBLIC + GRANT TO authenticated.
- Soft delete (sem policy `FOR DELETE`).

**Status:** migration `docs/migrations/2026-06-27-fase1-contas-categorias.sql`
**aplicada no Supabase em 2026-06-28**. PR #1 (branch
`fase1-contas-bancarias-categorias`) pendente de merge em `master` no momento
em que a Fase 2 começa — ambas as fases serão mergeadas em ordem.

### Fase 2 — Vínculo de categoria/conta no lançamento *(em execução agora)*

**Objetivo:** fazer `financas` referenciar as tabelas da Fase 1 sem quebrar
nenhum lançamento existente nem o fluxo atual de criação.

**Entrega:**

1. **Migration aditiva** (`docs/migrations/2026-06-28-fase2-vinculo-financas.sql`)
   - Seeds das **10 categorias legadas** que hoje vivem em
     `localStorage.cats_fin`, mapeando cada slug para um nome amigável e
     `natureza='operacional'`:
     | slug          | nome                | tipo    | sistema |
     |---------------|---------------------|---------|---------|
     | `mensalidade` | Mensalidade         | receita | **true** (usada por "Lançar Mensalidades do Mês") |
     | `joia`        | Joia de Iniciação   | receita | false |
     | `manutencao`  | Manutenção          | despesa | false |
     | `aluguel`     | Aluguel             | despesa | false |
     | `mutua`       | Mútua               | ambos   | false |
     | `agape`       | Ágape               | ambos   | false |
     | `material`    | Material            | despesa | false |
     | `evento`      | Evento              | ambos   | false |
     | `outros`      | Outros              | ambos   | **true** (fallback genérico) |
     | `tronco`      | (já existe da Fase 1) | — | true |
     - Seed **idempotente** (`ON CONFLICT (slug) DO UPDATE`).
   - **ADD COLUMN** em `financas` (todas **nullable**, não invalidam linhas existentes):
     - `categoria_id uuid REFERENCES categorias_financeiras(id) ON DELETE SET NULL`
     - `conta_bancaria_id uuid REFERENCES contas_bancarias(id) ON DELETE SET NULL`
     - `forma_pagamento text` (`pix` / `ted` / `dinheiro` / `boleto` / `cartao` / `outro`)
     - `identificador_externo text` (reservado para FITID/end-to-end-id do PIX — usado a partir da Fase 3)
     - `data_vencimento date` (separa "quando era devido" de `data` que vira "quando aconteceu" — só para lançamentos NOVOS; antigos ficam NULL)
   - **Backfill conservador**: `UPDATE financas SET categoria_id = c.id FROM categorias_financeiras c WHERE c.slug = financas.categoria AND financas.categoria_id IS NULL`.
     Não toca `financas.categoria` (texto) — mantém compatibilidade com cálculos atuais.
   - Índices em `financas(categoria_id)` e `financas(conta_bancaria_id)`.

2. **Cliente (`index.html`)**:
   - Modal "Novo Lançamento" passa a montar o select de categoria a partir de
     `DATA.categorias_financeiras` (apenas ativas, ordenadas por `ordem`).
     **Fallback**: se a tabela estiver vazia (migration não aplicada), continua
     usando `CATEGORIAS_FIN` do localStorage como hoje.
   - Novo select opcional **"Conta Bancária"** — lista contas ativas
     (`DATA.contas_bancarias.filter(c => c.ativo)`). Vazio por padrão.
   - `salvarLancamento`: inclui `categoria_id` (resolvido pelo slug) e
     `conta_bancaria_id` (do select) no payload. Mantém `categoria` (texto)
     redundante para compatibilidade com código antigo.
   - Filtros, relatórios e cálculos atuais **não mudam** — continuam usando
     `categoria` (string).

**Fora de escopo desta fase:**
- Forçar `categoria_id NOT NULL` (futuro, após backfill total e migração de UI).
- Remover `financas.categoria` (texto) — fica como fallback até auditoria.
- Usar `forma_pagamento`/`identificador_externo`/`data_vencimento` no fluxo
  manual (entram na Fase 3+ junto com OFX).
- Mexer em relatórios ou cálculos de saldo.

**Cuidados / invariantes:**
- Toda coluna nova é **nullable**. Lançamentos antigos preservados.
- Backfill é idempotente e não destrutivo (`WHERE categoria_id IS NULL`).
- Soft delete preservado: FKs usam `ON DELETE SET NULL` (não bloqueiam delete
  futuro de conta/categoria, embora a Fase 1 já proíba delete por policy).
- Cliente tolera ausência de `DATA.categorias_financeiras`/`DATA.contas_bancarias`
  (fallback ao comportamento legado).

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
| 2026-06-27 | 1 | Migration revisada: `neutra` → `impacta_resultado`, coluna `natureza` adicionada, policies de DELETE removidas (soft-delete), hardening REVOKE/GRANT | Denis + Claude |
| 2026-06-28 | 1 | C1 corrigido: UI movida de Configurações para Finanças (Tesoureiro bloqueado por `configuracoes:'none'`) — commit `e7a7d36` | Denis + Claude |
| 2026-06-28 | 1 | Migration aplicada em produção (Supabase) | Denis |
| 2026-06-28 | 2 | Iniciada — branch `fase2-vinculo-financas-bancos-categorias` | Denis + Claude |
