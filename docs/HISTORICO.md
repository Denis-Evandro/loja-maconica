# Histórico de Sessões — Projeto Mestre Virtual

Registro cronológico das sessões de desenvolvimento do sistema.

---

## Sessão 1 — Abr/2026 · Planejamento SaaS
**Chat:** "Começando um projeto no Claude Code"

- Decisão de transformar o sistema em SaaS multi-tenant
- Definida arquitetura: novo repositório `loja-maconica-saas` + novo projeto Supabase
- Planejadas features: multi-tenancy via `loja_id`, autenticação por roles, onboarding, pagamentos (Stripe/Mercado Pago)
- Definida estratégia: manter sistema atual em produção enquanto SaaS é construído em paralelo

---

## Sessão 2 — Abr/2026 · Configuração do Cursor IDE
**Chat:** "Configuração inicial do Cursor"

- Instalação e configuração do Cursor IDE no Windows
- Definido uso de Privacy Mode (código não usado para treinamento)
- Configurada pasta de projeto correta (não root do usuário)
- Definidas permissões de firewall (apenas redes privadas)

---

## Sessão 3 — Abr/2026 · Identidade Visual
**Chat:** "Correções do projeto loja maçônica"

- Criada página de boas-vindas antes da tela de login
- Layout: fundo navy + símbolo ✦ dourado + botão "Entrar na Loja"
- Grid com 6 cards dos módulos do sistema
- Criados slides de apresentação do Mestre Virtual (PowerPoint)
- Criado roteiro de apresentação para sessão da loja

---

## Sessão 4 — Mai/2026 · Crise de Egress + Upgrade Supabase
**Chat:** "Problema de autenticação no Mestre Virtual"

- Sistema bloqueado por exceder cota de egress do plano Free (10 GB/mês)
- Diagnóstico: TD-1 (loop de requisições em /trabalhos) como causa provável
- Decisão: upgrade para plano Pro (US$ 25/mês) para destravar imediatamente
- Sistema restaurado em produção

---

## Sessão 5 — 15/Mai/2026 · Bug Crítico de Autenticação + Customização Email
**Chat:** "Bug nos aniversariantes do mês" → handoff para chat atual

### Problemas resolvidos:
- **Bug session takeover** — `sb.auth.signUp()` client-side criava sessão no navegador do admin
  - Solução: Edge Function `invite-member` com `inviteUserByEmail()` server-side
  - Fases A, B e C executadas e testadas em produção
- **Branch divergence** — GitHub Pages publicava da branch `main` (desatualizada)
  - Solução: CNAME adicionado ao master, Pages reconfigurado para master

### Commits relevantes:
- `8c4f548` — fix(pages): adiciona CNAME
- `5d58963` — fix(auth): Fase C - substitui signUp client-side
- `8b40eac` — fix(auth): Edge Function inviteUserByEmail

---

## Sessão 6 — 15/Mai/2026 · Manutenção e Tech Debt
**Chat:** atual (handoff-mestrevirtual.txt)

### Resolvido:
- ✅ Email de convite customizado em português com identidade visual do Mestre Virtual
- ✅ Tabela `configuracoes` populada com dados da loja (JSONB)
- ✅ Edge Function v1.1 — passa dados da loja no template de email
- ✅ Bug Aniversariantes — dado corrompido corrigido no banco (`_familiares` do Ir∴ Jose Brito)
- ✅ TD-3 — erro 400 em comissões corrigido (`data_criacao` → `criado_em`, colunas faltantes adicionadas)
- ✅ Fix `_carregarConfiguracoes` — JSON.parse em campo JSONB já parseado
- ✅ TD-1 — monitorado, loop não se manifestou (estável)
- ✅ TD-2 — planejamento documentado em `docs/TD2-planejamento.md`

### Commits:
- `b264658` — feat(invite): v1.1 - busca dados da loja na configuracoes
- `95f135b` — fix(comissoes): corrige campo data_criacao → criado_em
- `8017ca6` — fix(configuracoes): corrige JSON.parse em campo JSONB
- `9456a4d` — debug(trabalhos): remove console.trace após diagnóstico
- `1abe9ac` — docs(td2): planejamento RLS multi-tenant

### Pendente:
- 🔴 TD-2 — RLS multi-tenant com `loja_id` (2-3h de sessão)

---

## Tech Debt Ativo

| ID | Descrição | Status |
|----|-----------|--------|
| TD-1 | Loop infinito de requisições /trabalhos (tabela vazia) | Monitorado — estável |
| TD-2 | RLS aberto demais — crítico antes do SaaS | Planejado — pendente execução |
| TD-3 | Erro 400 em /comissoes | ✅ Resolvido (15/05/2026) |
| TD-4 | Outros usos de auth client-side (linhas 2493, 2394, 3359) | Pendente |
