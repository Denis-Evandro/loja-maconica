# Fase C — Plano de Implementação: Edge Function invite-member

**Preparado em:** 2026-05-10  
**Contexto:** Remover `sb.auth.signUp()` e `sb.auth.resetPasswordForEmail()` do browser e substituir por `sb.functions.invoke('invite-member')` — elimina o session takeover definitivamente.  
**Pré-requisito:** Fase B (Edge Function `invite-member`) já deployada e ativa.

---

## 1. Pré-requisitos — verificação antes de começar

### 1.1 Edge Function "invite-member" está ativa?

**Via Dashboard Supabase:**
1. Abrir `https://supabase.com/dashboard/project/trwhvecssvbxklqsbzsc/functions`
2. Verificar que `invite-member` aparece na lista com status **Active** (verde)
3. Clicar na função → aba "Logs" — deve mostrar invocações recentes (se houver)

**Via CLI (se tiver Supabase CLI instalado):**
```bash
supabase functions list --project-ref trwhvecssvbxklqsbzsc
```
Deve retornar `invite-member` na lista.

**Via curl de health-check (sem body válido — esperado erro 400/401, mas não 404):**
```bash
curl -s -o /dev/null -w "%{http_code}" \
  -X POST \
  https://trwhvecssvbxklqsbzsc.supabase.co/functions/v1/invite-member \
  -H "Authorization: Bearer ANON_KEY_AQUI"
```
- `401` ou `400` = função existe, rejeitou a requisição sem token válido ✅
- `404` = função não deployada ❌

### 1.2 `sb.functions.invoke()` disponível no SDK?

A anon key carregada é `@supabase/supabase-js@2` (CDN, latest v2.x). A API `sb.functions` foi introduzida na v2.0.0 e está disponível em **todas as versões v2.x**.

Confirmar no console do navegador (com o app aberto):
```js
typeof sb.functions.invoke  // deve retornar "function"
```

Se retornar `"function"` → pré-requisito OK.

---

## 2. Código atual vs. proposto — `enviarConviteMembro()`

**Localização:** `index.html`, linha 6331  
**Função atual (linhas 6331–6400) — REMOVER:**

```js
async function enviarConviteMembro(membroId, email, nomeMemb) {
  const canEdit = ROLES[currentRole]?.access['membros'] === 'full';
  if (!canEdit) { toast('⛔ Sem permissão'); return; }
  email = (email||'').toLowerCase().trim();
  if (!email)   { toast('⚠️ Este membro não tem e-mail cadastrado. Adicione um e-mail primeiro.'); return; }

  const confirmar = confirm(
    `Enviar convite de acesso para:\n\n` +
    `👤 ${nomeMemb}\n` +
    `📧 ${email}\n\n` +
    `O irmão receberá um link para criar sua senha.`
  );
  if (!confirmar) return;

  toast('⏳ Enviando convite...');

  try {
    const membro = DATA.membros.find(m => m.id === membroId);
    const temConta = !!membro?.auth_user_id;
    const redirectTo = window.location.origin + window.location.pathname;

    // [... muitos console.log + lógica signUp/resetPassword ...]

    if (temConta) {
      const resp = await sb.auth.resetPasswordForEmail(email, { redirectTo });
      if (resp.error) { toast('❌ Erro ao enviar: ' + resp.error.message); return; }
    } else {
      const resp = await sb.auth.signUp({    // ← VULNERABILIDADE
        email,
        password: _gerarSenhaAleatoria(),
        options: { emailRedirectTo: redirectTo }
      });
      if (resp.error) { toast('❌ Erro ao criar acesso: ' + resp.error.message); return; }
      const respReset = await sb.auth.resetPasswordForEmail(email, { redirectTo });
      if (respReset.error) console.warn(...);
    }

    const { error: errStatus } = await sb.from('membros').update({
      login_status: 'convite_enviado',
      login_vinculado_em: new Date().toISOString()
    }).eq('id', membroId);
    // ...
    toast(`✅ Convite enviado para ${email}!`);
    await _reloadMembros();
    renderMembros(ROLES[currentRole].access['membros']);
  } catch(e) {
    toast('❌ Erro: ' + e.message);
  }
}
```

**Função nova (SUBSTITUIR pela versão abaixo):**

```js
async function enviarConviteMembro(membroId, email, nomeMemb) {
  const canEdit = ROLES[currentRole]?.access['membros'] === 'full';
  if (!canEdit) { toast('⛔ Sem permissão'); return; }
  email = (email||'').toLowerCase().trim();
  if (!email) { toast('⚠️ Este membro não tem e-mail cadastrado. Adicione um e-mail primeiro.'); return; }

  const confirmar = confirm(
    `Enviar convite de acesso para:\n\n` +
    `👤 ${nomeMemb}\n` +
    `📧 ${email}\n\n` +
    `O irmão receberá um link para criar sua senha.`
  );
  if (!confirmar) return;

  toast('⏳ Enviando convite...');

  try {
    const redirectTo = window.location.origin + window.location.pathname;
    const { data, error } = await sb.functions.invoke('invite-member', {
      body: { membroId, email, redirectTo }
    });
    if (error) { toast('❌ Erro ao enviar convite: ' + error.message); return; }
    if (data?.error) { toast('❌ ' + data.error); return; }

    toast(`✅ Convite enviado para ${email}!`);
    await _reloadMembros();
    renderMembros(ROLES[currentRole].access['membros']);
  } catch(e) {
    console.error('[enviarConviteMembro] EXCEÇÃO:', e);
    toast('❌ Erro: ' + e.message);
  }
}
```

**Diff visual:**

```diff
- const membro = DATA.membros.find(m => m.id === membroId);
- const temConta = !!membro?.auth_user_id;
  const redirectTo = window.location.origin + window.location.pathname;
- if (temConta) {
-   const resp = await sb.auth.resetPasswordForEmail(email, { redirectTo });
-   if (resp.error) { toast('❌ Erro ao enviar: ' + resp.error.message); return; }
- } else {
-   const resp = await sb.auth.signUp({ email, password: _gerarSenhaAleatoria(), ... });
-   if (resp.error) { toast('❌ Erro ao criar acesso: ' + resp.error.message); return; }
-   const respReset = await sb.auth.resetPasswordForEmail(email, { redirectTo });
-   if (respReset.error) console.warn(...);
- }
- const { error: errStatus } = await sb.from('membros').update({
-   login_status: 'convite_enviado', login_vinculado_em: new Date().toISOString()
- }).eq('id', membroId);
+ const { data, error } = await sb.functions.invoke('invite-member', {
+   body: { membroId, email, redirectTo }
+ });
+ if (error) { toast('❌ Erro ao enviar convite: ' + error.message); return; }
+ if (data?.error) { toast('❌ ' + data.error); return; }
```

> A Edge Function já é responsável por atualizar `login_status` e salvar `auth_user_id` — não duplicar no client.

---

## 3. Código atual vs. proposto — `enviarConvitesTodos()`

**Localização:** `index.html`, linha 6403  
**Função atual (linhas 6403–6461) — corpo do loop, REMOVER:**

```js
// Dentro do for (const m of semLogin):
const temConta = !!m.auth_user_id;
let erro = null;

if (temConta) {
  const { error } = await sb.auth.resetPasswordForEmail(m.email, { redirectTo });
  erro = error;
} else {
  const { error: errSignUp } = await sb.auth.signUp({   // ← VULNERABILIDADE
    email: m.email,
    password: _gerarSenhaAleatoria(),
    options: { emailRedirectTo: redirectTo }
  });
  if (!errSignUp) {
    const { error: errReset } = await sb.auth.resetPasswordForEmail(m.email, { redirectTo });
    if (errReset) console.warn(...);
  }
  erro = errSignUp;
}

if (erro) {
  console.warn('[enviarConvitesTodos]', m.email, erro.message);
} else {
  await sb.from('membros').update({ login_status: 'convite_enviado' }).eq('id', m.id);
  enviados++;
}
```

**Função nova (SUBSTITUIR):**

```js
async function enviarConvitesTodos() {
  const canEdit = ROLES[currentRole]?.access['membros'] === 'full';
  if (!canEdit) { toast('⛔ Sem permissão'); return; }

  const semLogin = DATA.membros.filter(m =>
    m.email &&
    (!m.login_status || m.login_status === 'sem_login') &&
    (m.status === 'ativo' || m.status === 'iniciado')
  );

  if (!semLogin.length) { toast('✅ Todos os membros com e-mail já receberam convite.'); return; }

  const confirmar = confirm(
    `Enviar convites para ${semLogin.length} irmão(s) sem acesso?\n\n` +
    semLogin.map(m => `• ${m.nome_maconico} (${m.email})`).join('\n')
  );
  if (!confirmar) return;

  toast(`⏳ Enviando ${semLogin.length} convites...`);
  const redirectTo = window.location.origin + window.location.pathname;
  let enviados = 0;

  for (const m of semLogin) {
    try {
      const { data, error } = await sb.functions.invoke('invite-member', {
        body: { membroId: m.id, email: m.email, redirectTo }
      });
      if (error || data?.error) {
        console.warn('[enviarConvitesTodos]', m.email, error?.message || data?.error);
      } else {
        enviados++;
      }
    } catch(e) { console.warn('Erro convite', m.email, e); }
    await new Promise(r => setTimeout(r, 300));
  }

  toast(`✅ ${enviados} convite(s) enviados!`);
  await _reloadMembros();
  renderMembros(ROLES[currentRole].access['membros']);
}
```

**Diff visual (corpo do loop):**

```diff
- const temConta = !!m.auth_user_id;
- let erro = null;
- if (temConta) {
-   const { error } = await sb.auth.resetPasswordForEmail(m.email, { redirectTo });
-   erro = error;
- } else {
-   const { error: errSignUp } = await sb.auth.signUp({ email: m.email, ... });
-   if (!errSignUp) { await sb.auth.resetPasswordForEmail(m.email, { redirectTo }); }
-   erro = errSignUp;
- }
- if (erro) { console.warn(...); }
- else { await sb.from('membros').update({ login_status: 'convite_enviado' }).eq('id', m.id); enviados++; }
+ const { data, error } = await sb.functions.invoke('invite-member', {
+   body: { membroId: m.id, email: m.email, redirectTo }
+ });
+ if (error || data?.error) { console.warn(...); }
+ else { enviados++; }
```

---

## 4. Snippet onAuthStateChange — defesa de sessão

**Inserir em `index.html` imediatamente após a linha 1944** (após o `});` que fecha o `createClient`):

```js
// Detectar troca inesperada de sessão — proteção contra session takeover residual
sb.auth.onAuthStateChange((event, session) => {
  if (event === 'SIGNED_IN' && session) {
    const currentUserId = DATA?.currentUser?.id;
    if (currentUserId && session.user.id !== currentUserId) {
      console.error('[onAuthStateChange] Sessão trocada inesperadamente!',
        { era: currentUserId, virou: session.user.id, email: session.user.email });
      sb.auth.signOut().then(() => window.location.reload());
    }
  }
});
```

**Contexto de inserção (linhas 1944–1946 atuais):**

```js
// linha 1944:  });   ← fecha createClient
//                    ← INSERIR AQUI
// linha 1946: const ROLES = {
```

**Por que isso funciona:**
- `onAuthStateChange` é disparado **imediatamente** quando o SDK troca a sessão, antes do próximo reload.
- Se `enviarConviteMembro()` ainda estivesse chamando `signUp()` com "Confirm email" desligado, essa guarda faria o logout em <100ms, antes do usuário perceber.
- Com a Fase C concluída (signUp removido), funciona como rede de segurança residual para cenários futuros.

**Limitação:**
- `DATA?.currentUser?.id` só está preenchido após `verificarSessaoAtiva()`. Na janela entre `createClient` e o primeiro login, `currentUserId` é `undefined` e a guarda não dispara — comportamento correto (sem usuário logado, qualquer sessão nova é legítima).

---

## 5. Plano de teste — Fase C

### 5.1 Verificar deploy no Vercel/produção

1. Fazer push para o branch de produção (ou upload direto do `index.html` para Vercel).
2. Acessar `https://mestrevirtual.com.br` e abrir DevTools → Console.
3. Verificar ausência de erros de sintaxe JS no load.
4. Verificar no Console: `typeof sb.functions.invoke` → deve ser `"function"`.

### 5.2 Teste de convite individual — Fernando Blanco

**Conta de teste:** Fernando Blanco, email `denis_evandro@hotmail.com`  
**Pré-condição:** `login_status = 'sem_login'` e `auth_user_id = NULL` para este membro.

**Confirmar estado inicial:**
```sql
SELECT id, nome_maconico, email, login_status, auth_user_id
FROM membros
WHERE email = 'denis_evandro@hotmail.com';
-- Esperado: login_status = 'sem_login', auth_user_id = NULL
```

**Passos:**
1. Fazer login como admin (Venerável ou Secretário).
2. Acessar aba "Membros".
3. Localizar Fernando Blanco → clicar "Convidar".
4. Confirmar o modal de confirmação.
5. Aguardar toast `✅ Convite enviado para denis_evandro@hotmail.com!`

**Verificações após o convite:**
```sql
-- Login status deve ter mudado
SELECT id, nome_maconico, email, login_status, auth_user_id, login_vinculado_em
FROM membros
WHERE email = 'denis_evandro@hotmail.com';
-- Esperado: login_status = 'convite_enviado', auth_user_id preenchido

-- Usuário deve existir em auth.users
SELECT id, email, created_at, last_sign_in_at, raw_user_meta_data
FROM auth.users
WHERE email = 'denis_evandro@hotmail.com';
-- Esperado: 1 linha, last_sign_in_at = NULL (nunca logou ainda)
```

**Verificar email recebido:**
- Abrir `denis_evandro@hotmail.com` → verificar email de convite com link de ativação.
- Clicar no link → deve redirecionar para `https://mestrevirtual.com.br` com parâmetro `type=invite` ou `type=recovery` na URL.
- Definir uma senha → confirmar login bem-sucedido como Fernando Blanco.

**Verificar que a sessão do admin NÃO foi trocada:**
- No navegador do admin (onde o convite foi enviado), confirmar que ainda está logado como admin.
- `localStorage` não deve conter sessão de Fernando Blanco.
- DevTools → Console → sem mensagem de `[onAuthStateChange] Sessão trocada`.

### 5.3 Teste de convite em lote

1. Garantir pelo menos 2 membros com `login_status = 'sem_login'` e email válido.
2. Como admin, clicar "Enviar convites para todos".
3. Confirmar modal (lista os membros afetados).
4. Aguardar toast de conclusão.
5. Validar:
```sql
SELECT nome_maconico, email, login_status, auth_user_id
FROM membros
WHERE status IN ('ativo','iniciado')
  AND email IS NOT NULL
  AND login_status = 'sem_login';
-- Deve retornar 0 linhas após o envio em lote
```

### 5.4 Rollback

Se algo der errado após o deploy:

**Rollback do código (Vercel):**
- Acessar Vercel Dashboard → projeto → Deployments → selecionar o deploy anterior → "Promote to Production".

**Rollback do banco (se auth_user_id ficou sujo):**
```sql
-- Limpar usuários órfãos criados por erro
DELETE FROM auth.users
WHERE email = 'denis_evandro@hotmail.com'
  AND last_sign_in_at IS NULL;

-- Reset do membro correspondente
UPDATE membros
SET login_status = 'sem_login',
    login_vinculado_em = NULL,
    auth_user_id = NULL
WHERE email = 'denis_evandro@hotmail.com';
```

**Rollback de emergência (todos os órfãos):**
```sql
-- Identificar usuários Auth sem correspondência em membros
SELECT u.id, u.email, u.created_at
FROM auth.users u
LEFT JOIN membros m ON m.auth_user_id = u.id
WHERE m.id IS NULL
  AND u.last_sign_in_at IS NULL
ORDER BY u.created_at DESC;

-- Deletar após confirmar que são órfãos
DELETE FROM auth.users
WHERE id IN (
  SELECT u.id FROM auth.users u
  LEFT JOIN membros m ON m.auth_user_id = u.id
  WHERE m.id IS NULL AND u.last_sign_in_at IS NULL
);
```

---

## 6. Tech Debt — pendências descobertas durante investigação

*(Para registro; não bloqueiam a Fase C)*

### 6.1 Loop de 1000+ requests — endpoint `/rest/v1/trabalhos`

**Sintoma observado (2026-05-10):**  
Com o app aberto, 1000+ requisições `GET /rest/v1/trabalhos?select=*%2Cmembros(...)` disparadas em segundos, cada uma retornando `200 OK` com array vazio (tabela `trabalhos` tem 0 linhas). Loop pré-existia às mudanças do dia.

**Investigação estática concluída:**
- Nenhum `setInterval`, `setTimeout` recursivo ou Realtime subscription para `trabalhos` encontrado no código.
- `loadAllData()` (linha 2044): 1 SELECT.
- `_recarregarTrabalhos()` (linha 10846): 1 SELECT.
- `renderTrabalhos()` (linha ~2250, pós-F1.3): SELECT condicional via `forceRefresh`.
- Máximo teórico de 4 SELECTs por carregamento de página — incompatível com 1000+.

**Causa raiz: não determinada por análise estática.**

**Ação necessária:**  
Adicionar `console.trace()` em produção antes de investigar mais:

```js
// Em _recarregarTrabalhos() — linha ~10846, antes do SELECT:
console.trace('[_recarregarTrabalhos] chamada');

// Em loadAllData() — linha ~2057, antes do SELECT de trabalhos:
console.trace('[loadAllData] query trabalhos');
```

O `trace` vai mostrar o call stack completo — identifica se é um listener, um ciclo de renderização ou código externo.  
A diferença no SELECT (`id%2Cnome_maconico` vs `nome_maconico`) já permite identificar qual função está no loop pelo URL da requisição nas DevTools.

### 6.2 RLS muito permissivo — policy `allow_all_trabalhos`

**Observado:** Policy com `qual = true` (sem restrição) em `trabalhos`. Qualquer usuário autenticado lê e escreve qualquer trabalho de qualquer loja.

**Risco para SaaS multi-tenant:** crítico. Ao escalar para múltiplas lojas, um membro da Loja A leria trabalhos da Loja B.

**Ação recomendada (não urgente para loja única):**  
```sql
-- Quando loja_id for adicionado à tabela:
CREATE POLICY trabalhos_por_loja ON trabalhos
  USING (loja_id = (SELECT loja_id FROM membros WHERE auth_user_id = auth.uid() LIMIT 1));
```

### 6.3 Erros 400 em `/rest/v1/comissoes`

**Observado durante debug:** Requests para `/rest/v1/comissoes` retornando 400. Indica query malformada ou tabela/coluna inexistente.

**Ação:** Inspecionar a função que consulta `comissoes` no código e verificar se a estrutura da tabela bate com o SELECT usado.
