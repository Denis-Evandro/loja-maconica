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

## Sessão 7 — 26-27/Jun/2026 · Relatório Completo de Membros + Fix Convite/Primeiro Acesso
**Chat:** atual

### Relatório Completo de Membros (modo ficha)
- ✅ Mantido modo tabela (padrão) intacto — sem regressão
- ✅ Novo modo **ficha por irmão** ativado pelo botão "📚 Completo"
  - Cabeçalho com foto, número, nome maçônico/civil, badges de grau/cargo/tipo/situação
  - Seções: Identificação · Dados Pessoais · Contato e Endereço · Dados Maçônicos · Situação Cadastral · **Familiares** (tabela) · **Histórico Maçônico** (tabela)
  - Layout fluido (`grid auto-fit minmax(160px,1fr)`) — não corta horizontalmente
  - Familiares e histórico lidos de `m._familiares` / `m._historico` (JSON-string na tabela `membros`)
- ✅ Filtro de situação: **Apenas Ativos** (padrão) / Apenas Inativos / Todos
  - Ativos = `status === 'ativo'`; Inativos = todos os demais
  - Contagem exibida em destaque antes da impressão
- ✅ Seletor de seções "⚙️ Seções" para customizar quais blocos aparecem
- ✅ Impressão com `page-break-inside:avoid` por ficha e `table-layout:fixed` interno
- ✅ Excel com **3 abas separadas**: Membros · Familiares · Histórico (FK por Nº/nome maçônico)

### Fix Auth — Primeiro Acesso via Convite
- 🔴 **Bug**: clique no link de convite consumia tokens via `detectSessionInUrl:true` e logava o irmão direto **sem nunca pedir senha**. Resultado: ele entrava na primeira vez e nunca mais conseguia.
- ✅ Boot reescrito: detecta `type=invite` / `type=signup` / `type=recovery` no hash e abre modal "🔑 PRIMEIRO ACESSO — CRIE SUA SENHA" (ou "DEFINIR NOVA SENHA" para recovery)
- ✅ Guard em `verificarSessaoAtiva` lê `user_metadata.must_set_password` — bloqueia entrada no app se a senha ainda não foi definida (cobre reload no meio do fluxo)
- ✅ `salvarNovaSenha` grava `user_metadata.password_set=true`, atualiza `membros.login_status='ativo'`, desloga e mostra "✅ Conta criada! Faça login com seu e-mail e a nova senha."
- ✅ Banner persistente vermelho acima do form de login para convite expirado/inválido (lê `error_description` do hash)
- ✅ Edge function `invite-member` v1.2 inclui `must_set_password:true` no `user_metadata` do convite

### Fix Edge Function — 409 Conflict no reenvio de convite
- 🔴 **Bug**: ao reenviar convite para e-mail que já estava em `auth.users` mas sem vínculo em `membros.auth_user_id` (situação clássica de teste interrompido), a function retornava 409 e mandava "executar a limpeza (Fase A)"
- 🔴 **Bug secundário herdado**: caminho 7a (membro já tem `auth_user_id`) usava `generateLink` que **só gera o link e não envia e-mail** — quem já tinha conta nunca recebia o reenvio
- ✅ Novo helper `reenviarParaUsuarioExistente()` que: vincula `auth_user_id` ao membro, atualiza `user_metadata` com `must_set_password=true` se a senha ainda não foi definida, e dispara `resetPasswordForEmail` (que **envia** o e-mail)
- ✅ Quando `inviteUserByEmail` retorna "already registered", a function agora busca o user existente via `listUsers` paginado e cai no helper de reenvio — sem 409
- ✅ Caminho 7a refeito para usar o mesmo helper, eliminando o bug do "convite que não chegava"
- ✅ Logs verbose em 13 pontos da edge function (`▶ ✓ ✖ ⚠ → 💥`) para diagnóstico futuro
- ✅ Cliente: novo helper `_extrairMsgErroFuncao` que lê o body real do `Response` via `error.context.clone().text()` — antes o SDK mostrava só "non-2xx status code" genérico
- ✅ Toast diferencia "convite novo" / "reenvio para conta sem senha" / "reenvio para conta com senha"
- ✅ A "Fase A" (limpeza manual de auth órfão documentada em `INCIDENT-2026-05-11-session-takeover.md`) **fica obsoleta** — a function trata o cenário automaticamente

### Operação realizada
- Bloqueio do delete manual de auth user causado por FK `membros.auth_user_id → auth.users(id)` com `ON DELETE NO ACTION`
- Workaround documentado: `UPDATE membros SET auth_user_id=NULL WHERE auth_user_id = <id>` antes do `DELETE FROM auth.users` — não foi necessário em produção após o fix da function

### Commits:
- `8beb5fe` — feat(relatorios): modo ficha completo de membros com familiares, histórico e filtro de situação
- `9ff8ef6` — fix(auth): força criação de senha no primeiro acesso via convite
- (este commit) — fix(convite): reaproveita user existente, envia e-mail de reenvio e mostra erro real no cliente

### Deploys realizados:
- `git push origin master` → GitHub Pages republicou
- `npx supabase functions deploy invite-member` → Edge Function v1.2 ativa

---

## Tech Debt Ativo

| ID | Descrição | Status |
|----|-----------|--------|
| TD-1 | Loop infinito de requisições /trabalhos (tabela vazia) | Monitorado — estável |
| TD-2 | RLS aberto demais — crítico antes do SaaS | Planejado — pendente execução |
| TD-3 | Erro 400 em /comissoes | ✅ Resolvido (15/05/2026) |
| TD-4 | Outros usos de auth client-side (linhas 2493, 2394, 3359) | Pendente |
| TD-5 | Logs verbose temporários da edge function `invite-member` | Pendente — remover após período de observação estável |
