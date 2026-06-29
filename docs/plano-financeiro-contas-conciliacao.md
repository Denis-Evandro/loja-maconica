# Plano — Financeiro: Contas Bancárias e Conciliação OFX

> Projeto: MestreVirtual / Loja Maçônica
> Status: **Fases 1, 2 e 3 concluídas e em produção**. Próxima: Fase 4 (importação OFX do Sicoob).
> Última atualização: 2026-06-29

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
- Importação OFX e conciliação (Fase 4+) **apenas para Tesoureiro e Administrador**.
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
- `extratos_bancarios` (Fase 4) representará **linhas brutas importadas do OFX**
  (= o que o banco diz que aconteceu).
- Conciliação (Fase 5) liga **uma linha de extrato a um lançamento de `financas`**,
  agregando prova bancária ao lançamento existente. **Não substitui** o lançamento.

### Premissas operacionais
- **1 PIX corresponde a 1 pagamento** na prática da loja. Não há (por agora)
  necessidade de modelo "1 extrato → vários lançamentos".
- Conciliação começa **para frente** — sem importar histórico retroativo.
- Cadastro dos irmãos contém **nome civil e nome maçônico**. Regras futuras
  (Fase 6) usarão preferencialmente **nome civil** para casar com a descrição
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
                                │ (Fase 5) financa_id NULL
                                │
       ┌────────────────────────┴───────────────────────────────┐
       │                  extratos_bancarios                    │  (Fase 4)
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
**aplicada no Supabase em 2026-06-28**. PR #1 mergeado em `master`. Fase 1
em produção.

### Fase 2 — Vínculo de categoria/conta no lançamento *(CONCLUÍDA em 2026-06-28)*

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
     - `identificador_externo text` (reservado para FITID/end-to-end-id do PIX — usado a partir da Fase 4)
     - `data_vencimento date` (separa "quando era devido" de `data` que vira "quando aconteceu" — só para lançamentos NOVOS; antigos ficam NULL)
   - **Backfill conservador**: `UPDATE financas SET categoria_id = c.id FROM categorias_financeiras c WHERE c.slug = financas.categoria AND financas.categoria_id IS NULL`.
     Não toca `financas.categoria` (texto) — mantém compatibilidade com cálculos atuais.
   - Índices em `financas(categoria_id)` e `financas(conta_bancaria_id)`.

2. **Cliente (`index.html`)**:
   - Modal "Novo Lançamento" passa a montar o select de categoria a partir de
     `DATA.categorias_financeiras` (apenas ativas, ordenadas por `ordem`).
     **Fallback raro**: se a tabela estiver vazia (cenário só possível antes
     da Fase 1, que já está aplicada em produção), continua usando
     `CATEGORIAS_FIN` do localStorage. É *dead-code defensivo*, não caminho
     operacional.
   - Botão "+" e tags de "remover categoria" do localStorage ficam **escondidos**
     quando a lista vem do banco. No lugar, mensagem orientando ir em
     **Finanças → Bancos & Categorias** para cadastrar/editar.
   - Novo select opcional **"Conta Bancária"** — lista contas ativas
     (`DATA.contas_bancarias.filter(c => c.ativo)`). Vazio por padrão.
   - `salvarLancamento`: inclui `categoria_id` (resolvido pelo slug) e
     `conta_bancaria_id` (do select) no payload. Mantém `categoria` (texto)
     redundante para compatibilidade com código antigo.
   - `salvarEdicaoLancamento`: recalcula `categoria_id` pelo slug atual quando
     o Tesoureiro muda a categoria, garantindo que `categoria` (texto) e
     `categoria_id` (FK) **nunca divirjam**.
   - Filtros, relatórios e cálculos atuais **não mudam** — continuam usando
     `categoria` (string).

3. **Invariante de deploy** (CRÍTICO):
   - A migration `2026-06-28-fase2-vinculo-financas.sql` **DEVE** ser aplicada
     no Supabase **ANTES** do merge do PR / publicação do `index.html` desta fase.
   - Motivo: o cliente novo envia `categoria_id` e `conta_bancaria_id` no
     INSERT/UPDATE de `financas`. Sem as colunas, o PostgREST devolve
     `Could not find the 'categoria_id' column of 'financas' in the schema
     cache` e o lançamento falha para o usuário final.
   - Ordem segura: (1) snapshot/backup → (2) aplicar SQL via SQL Editor →
     (3) rodar queries do bloco de verificação → (4) merge do PR →
     (5) GitHub Pages republica o cliente.

**Fora de escopo desta fase:**
- Forçar `categoria_id NOT NULL` (futuro, após backfill total e migração de UI).
- Remover `financas.categoria` (texto) — fica como fallback até auditoria.
- Usar `forma_pagamento` e `data_vencimento` no fluxo manual (entram na
  Fase 3); `identificador_externo` fica reservado para a Fase 4 (OFX).
- Mexer em relatórios ou cálculos de saldo.

**Cuidados / invariantes:**
- Toda coluna nova é **nullable**. Lançamentos antigos preservados.
- Backfill é idempotente e não destrutivo (`WHERE categoria_id IS NULL`).
- Soft delete preservado: FKs usam `ON DELETE SET NULL` (não bloqueiam delete
  futuro de conta/categoria, embora a Fase 1 já proíba delete por policy).
- `salvarEdicaoLancamento` só envia `categoria_id` se `_categoriasVemDoBanco()`
  (defesa parcial). `salvarLancamento` envia sempre — a invariante de deploy
  acima é o que garante a integridade.

**Status:** migration `docs/migrations/2026-06-28-fase2-vinculo-financas.sql`
**aplicada no Supabase em 2026-06-28**. PR #2 mergeado em `master`. Fase 2
em produção.

### Fase 3 — UX operacional do extrato *(CONCLUÍDA em 2026-06-29)*

**Objetivo:** tornar o extrato de lançamentos operacional para o Tesoureiro
no dia a dia — preenchimento e leitura mais rica, sem mexer em modelo de
dados nem em cálculos.

**Entregue:**

Sub-fase **3A** — *forma de pagamento + data de vencimento*
(`docs/migrations/`: nenhuma; sem alterações de schema; PR #3):
- Modal "Novo Lançamento" passa a gravar `forma_pagamento` (select fechado:
  pix / ted / dinheiro / boleto / cartao / outro) e `data_vencimento`.
- `data_vencimento` espelha `data` por padrão, com auto-sync enquanto o
  Tesoureiro não edita manualmente o campo de vencimento.
- Modal de **edição** ganhou os 3 campos: `conta_bancaria_id`,
  `forma_pagamento`, `data_vencimento` (completou a Fase 2, que tinha
  adicionado o vínculo apenas na criação).
- Lançamentos parcelados: cada parcela grava `data_vencimento` igual à sua
  própria `data` (item 5 do escopo aprovado).
- Sublinha cinza compacta abaixo da descrição do lançamento mostrando
  `conta · forma · vencimento` (helper `_detalhesFinanceirosLinha`).
- Correção pré-merge: auto-sync respeita reescritas programáticas de `data`
  no bloco de Tronco; `oninput` + `onchange` em `f-data-fin` para
  robustez (commit `64faf14`).

Sub-fase **3B** — *filtros operacionais do extrato* (PR #4):
- Helper único `_buildRowExtrato(lanc)` consumido pelo render inicial
  (`buildRows` em `renderFinancas`) e pelo re-render após filtro
  (`filtrarExtrato`). Corrige inconsistência herdada da 3A em que o filtro
  perdia a sublinha conta · forma · vencimento.
- Helper `_calcularStatusVencimento(lanc)` puro, com comparação como string
  `'YYYY-MM-DD'` (sem `Date`). Regra invariante: `status === 'pago'` nunca
  retorna "vencido".
- 3 filtros novos no extrato: **conta bancária**, **forma de pagamento**,
  **situação de vencimento** (`vencido` / `vence_hoje` / `a_vencer` /
  `sem_vencimento`).
- Botão **"Limpar filtros"** zera todos os 9 filtros e reaplica o default
  (mês corrente + pendências de meses anteriores em `agendado`/`aberto`).
- `imprimirExtrato` passa a usar `_aplicarFiltrosExtrato` e inclui a
  sublinha conta · forma · venc. **Não toca em relatórios formais**
  (`RelFinancas`, `RelDebitos`, `RelTronco`).
- `exportarFinancasCsv` adiciona 5 colunas **no final** (sem reordenar
  ou renomear as existentes — preserva planilhas externas que referenciam
  colunas por posição): `conta_bancaria`, `conta_bancaria_id`,
  `forma_pagamento`, `data_vencimento`, `status_vencimento_calculado`.

**Sem migration / sem backfill / sem Supabase**: a Fase 3 inteira opera
sobre as colunas que a Fase 2 já criou (`forma_pagamento`,
`data_vencimento`, `conta_bancaria_id`). Lançamentos antigos preservados:
quem tem os 3 campos nulos continua aparecendo no extrato sem a sublinha
cinza e como `sem_vencimento` no filtro de situação — comportamento
esperado e documentado.

**Fora de escopo (e respeitado):**
- Nenhuma mudança em `executarPagamentoAgendado`, Ágape, Tronco,
  inadimplência, saldos, previsão, gráficos, "Lançar Mensalidades do Mês"
  ou fechamento mensal.
- Nenhuma mudança em "Meu Financeiro" do irmão nem nos relatórios formais.
- Sem backfill automático de lançamentos antigos.

**Status:** PRs #3 e #4 mergeados em `master`; Fase 3 validada
funcionalmente em produção.

### Fase 4 — Importação OFX do Sicoob *(planejada)*

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

### Fase 5 — Painel manual de conciliação *(planejada)*

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

### Fase 6 — Regras determinísticas *(planejada)*

**Entrega:**
- `CREATE TABLE regras_conciliacao` (id, ativa, descricao_regex, valor_min,
  valor_max, dia_min, dia_max, categoria_destino, membro_id_destino,
  conta_bancaria_id, status_destino, prioridade).
- Tela CRUD de regras.
- Ao importar OFX, regras são aplicadas e geram **sugestões** mostradas no
  painel da Fase 5 — **nunca conciliam sozinhas**.
- Regras usam preferencialmente **nome civil** do irmão para casar com a
  descrição do PIX (ex: `PIX RECEBIDO JOSE DA SILVA` → membro José da Silva).

### Fase 7 — Trava real, auditoria e relatório do Conselho Fiscal *(planejada)*

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
10. **Ordem de deploy:** quando uma fase adiciona colunas em `financas` que
    o cliente novo passa a enviar (Fase 2 em diante), a **migration entra
    ANTES** do merge/deploy do `index.html` correspondente. Não há
    compatibilidade "cliente novo + DB antigo" no caminho de criação de
    lançamento — o PostgREST rejeita colunas inexistentes.

---

## 5. Como o financeiro funciona hoje (referência rápida)

Detalhado em `docs/HISTORICO.md` e na auditoria feita em 2026-06-27.
Resumo atualizado após Fases 1–3:
- Tabela `financas` (id, descricao, valor, tipo, data, categoria, status,
  membro_id) **+ vínculos opcionais nullable** adicionados na Fase 2:
  `categoria_id`, `conta_bancaria_id`, `forma_pagamento`,
  `identificador_externo`, `data_vencimento`.
- Categorias agora vêm de `categorias_financeiras` (Fase 1); o
  `localStorage.cats_fin` permanece como fallback defensivo, dead-code
  no caminho operacional.
- "Saldo Bancário" no painel é cálculo virtual `receitas pagas - despesas pagas`
  excluindo `categoria='tronco'` (inalterado pelas Fases 1–3).
- O modal "Novo Lançamento" e a edição já gravam `forma_pagamento`,
  `data_vencimento` e `conta_bancaria_id` (Fase 3). O extrato tem filtros
  por conta, forma e situação de vencimento e mostra sublinha cinza
  `conta · forma · vencimento`.
- **Ainda não existe** importação OFX, tabela de extrato bancário, painel
  de conciliação ou uso operacional de FITID (Fase 4+).
- `fechamentos_mensais` em localStorage (Fase 7 migrará para tabela com
  trava server-side).

---

## 6. Riscos conhecidos e mitigações

| Risco | Mitigação |
|---|---|
| Importação OFX duplicada | UNIQUE(conta, fitid) + UNIQUE(conta, hash_linha) na Fase 4. |
| Saldos inconsistentes após conciliação errada | Painel Fase 5 sempre exige clique; Fase 7 introduz desconciliação com motivo. |
| Categorias divergentes entre máquinas (localStorage) | Migrar para tabela na Fase 1. localStorage continua como fallback até confirmação. |
| `financas.data` ambígua (vencimento ou efetiva) | Fase 2 separa `data` e `data_vencimento`; código antigo segue. |
| `fechamentos_mensais` client-side | Fase 7 migra para tabela e adiciona trava server-side. |
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
| 2026-06-28 | 2 | Revisão pré-merge: botão "+" de categoria escondido quando vier do banco; `salvarEdicaoLancamento` recalcula `categoria_id`; invariante #10 de ordem de deploy registrada | Denis + Claude |
| 2026-06-28 | 2 | Migration aplicada em produção; PR #2 mergeado em `master` | Denis |
| 2026-06-28 | 3A | Iniciada — branch `fase3a-forma-pagamento-vencimento`. Modal "Novo Lançamento" passa a gravar `forma_pagamento` e `data_vencimento`; edição ganha `conta_bancaria_id`/`forma_pagamento`/`data_vencimento`; sublinha cinza `conta · forma · venc` no extrato | Denis + Claude |
| 2026-06-28 | 3A | Fix pré-merge: auto-sync respeita reescritas programáticas de `data` (commit `64faf14`); `oninput` + `onchange` em `f-data-fin` | Denis + Claude |
| 2026-06-29 | 3A | PR #3 mergeado em `master` (commit `edb5ad6`) | Denis |
| 2026-06-29 | 3B | Iniciada — branch `fase3b-filtros-extrato-financeiro`. Helper único `_buildRowExtrato` corrige inconsistência da 3A (filtro perdia sublinha); helper `_calcularStatusVencimento`; filtros novos conta/forma/vencimento; "Limpar filtros" zera tudo; CSV +5 colunas no final; impressão do extrato com sublinha | Denis + Claude |
| 2026-06-29 | 3B | Revisão pré-merge: `_buildFormaPagamentoOptions` ganha `incluirVazio` (sem regex em HTML) | Denis + Claude |
| 2026-06-29 | 3B | PR #4 mergeado em `master` (commit `c79da56`) | Denis |
| 2026-06-29 | 3 | Documentação consolidada: Fase 3 marcada como concluída; renumeração Fase 4 (OFX) / Fase 5 (conciliação) / Fase 6 (regras) / Fase 7 (auditoria) — branch `docs/fase3-concluida-financeiro` | Denis + Claude |
