# Incidente de Segurança — Session Takeover via signUp Client-Side

**Data:** 2026-05-11  
**Severidade:** Alta  
**Status:** Parcialmente resolvido (Fases A e B concluídas; Fase C pendente)  
**Sistema afetado:** Mestre Virtual — mestrevirtual.com.br  
**Projeto Supabase:** trwhvecssvbxklqsbzsc  

---

## O que aconteceu

1. O administrador enviou um convite de acesso para um irmão (Rodrigo) pelo sistema.
2. O email de convite **não chegou** ao destinatário.
3. Ao recarregar a página, o administrador foi **logado automaticamente como Rodrigo** — sem passar pela tela de login.
4. Verificado em aba anônima: o login do admin funcionava normalmente (localStorage separado).
5. Confirmado: a sessão de Rodrigo ficou presa no localStorage do navegador do admin.

---

## Causa raiz

A função `enviarConviteMembro()` (index.html, linha 6331) chamava `sb.auth.signUp()` **no browser do admin**, usando a **anon key** com `persistSession: true`:

```js
// CÓDIGO VULNERÁVEL — removido na Fase C
const resp = await sb.auth.signUp({
  email,                            // email do membro convidado
  password: _gerarSenhaAleatoria(),
  options: { emailRedirectTo: redirectTo }
});
```

**Sequência do session takeover:**

```
Admin clica "Convidar"
  → sb.auth.signUp({ email: rodrigo@... })   ← client-side, anon key
  → Supabase cria usuário E retorna sessão   ← "Confirm email" estava desligado
  → SDK salva sessão de Rodrigo no localStorage do admin  ← persistSession: true
  → Sessão do admin é sobrescrita
  → Admin recarrega página
  → verificarSessaoAtiva() lê sessão do localStorage
  → Encontra sessão de Rodrigo
  → Admin é logado como Rodrigo
```

**Agravantes identificados:**

- `persistSession: true` no client Supabase (necessário para login persistente, mas amplifica o impacto do signUp indevido).
- "Confirm email" estava **desligado** no projeto Supabase — sem confirmação, o signUp retorna sessão ativa imediatamente.
- `auth_user_id` **nunca era salvo** em `membros` após o signUp, criando usuários órfãos em `auth.users` a cada tentativa de convite.
- Erros de `resetPasswordForEmail` eram tratados como "não críticos", permitindo que o fluxo continuasse mesmo sem enviar o email.
- Ausência de `onAuthStateChange` — a troca de sessão só era percebida no próximo reload, não em tempo real.

**Usuários órfãos criados em auth.users:**
- ribeiro.verde@hotmail.com
- drlaerciofjr@adv.oabsp.org.br
- denis_evandro@hotmail.com
- contato@petlegau.com.br

---

## Como foi resolvido

### Cinto de segurança imediato (mesmo dia)

**"Confirm email" ativado** no painel Supabase:
> Authentication → Providers → Email → "Confirm email" → ON

Com esta configuração, `signUp()` passa a retornar `session: null` — o localStorage do admin não é mais sobrescrito enquanto a Fase C não é concluída.

---

### Fase A — Limpeza do banco (2026-05-11)

Executado no SQL Editor do Supabase com permissões de service_role.

**SELECT de verificação (antes):**
```sql
SELECT id, email, created_at, last_sign_in_at
FROM auth.users
WHERE email IN (
  'ribeiro.verde@hotmail.com',
  'drlaerciofjr@adv.oabsp.org.br',
  'denis_evandro@hotmail.com',
  'contato@petlegau.com.br'
);
-- Resultado: 4 linhas encontradas
```

**DELETE dos usuários órfãos:**
```sql
DELETE FROM auth.users
WHERE email IN (
  'ribeiro.verde@hotmail.com',
  'drlaerciofjr@adv.oabsp.org.br',
  'denis_evandro@hotmail.com',
  'contato@petlegau.com.br'
);
-- Resultado: 4 linhas deletadas
```

**Reset dos membros correspondentes:**
```sql
UPDATE membros
SET
  login_status       = 'sem_login',
  login_vinculado_em = NULL,
  auth_user_id       = NULL
WHERE email IN (
  'ribeiro.verde@hotmail.com',
  'drlaerciofjr@adv.oabsp.org.br',
  'denis_evandro@hotmail.com',
  'contato@petlegau.com.br'
);
-- Resultado: 4 linhas atualizadas
```

---

### Fase B — Edge Function invite-member (2026-05-11)

Criada e deployada via Supabase Dashboard.

**Arquivo:** `supabase/functions/invite-member/index.ts`

**O que a função faz:**
1. Extrai o JWT do header `Authorization` da requisição.
2. Verifica identidade do solicitante via `admin.auth.getUser(token)`.
3. Verifica permissão via tabela `usuarios` (role/perfil = 'admin', ativo = true) ou via tabela `membros` (cargo em lista permitida).
4. Valida que o membro existe e o email corresponde.
5. Se membro já tem `auth_user_id`: chama `generateLink({ type: 'recovery' })` — reenvio seguro.
6. Se membro sem `auth_user_id`: chama `admin.auth.admin.inviteUserByEmail()` — **nunca cria sessão no browser do admin**.
7. Salva `auth_user_id` no registro do membro.
8. Em caso de falha no passo 7: faz rollback com `admin.auth.admin.deleteUser()`.

**Cargos com permissão de convidar:**
- `Venerável Mestre`
- `Secretário`
- `Chanceler`
- Qualquer usuário com `role = 'admin'` ou `perfil = 'admin'` na tabela `usuarios`

**Variáveis de ambiente:** `SUPABASE_URL` e `SUPABASE_SERVICE_ROLE_KEY` — auto-injetadas pelo runtime do Supabase, sem configuração manual.

---

### Fase C — Substituição no client-side (PENDENTE)

Pendente de implementação em `index.html`:

1. Remover `sb.auth.signUp()` e `sb.auth.resetPasswordForEmail()` de `enviarConviteMembro()` (linha 6331) e `enviarConvitesTodos()` (linha 6403).
2. Substituir por `sb.functions.invoke('invite-member', { body: { membroId, email, redirectTo } })`.
3. Adicionar `sb.auth.onAuthStateChange()` como detector de trocas de sessão indevidas.

---

## Lições aprendidas

| # | Lição |
|---|---|
| 1 | **Nunca usar `auth.signUp()` no client para criar contas de terceiros.** O SDK salva a sessão do usuário criado no localStorage do chamador. |
| 2 | **"Confirm email" deve estar sempre ligado em produção.** Sem confirmação, qualquer `signUp` cria sessão ativa imediatamente. |
| 3 | **Operações que requerem service_role pertencem a Edge Functions**, nunca ao browser. A anon key não deve ser usada para criar usuários. |
| 4 | **Sempre salvar `auth_user_id` imediatamente após criar o usuário Auth**, antes de qualquer outra operação. Sem isso, usuários órfãos se acumulam e re-convites ficam impossíveis de detectar. |
| 5 | **Tratar todos os erros de fluxo de convite como críticos.** Um email que não chega e um `login_status = 'convite_enviado'` cria estado inconsistente invisível. |
| 6 | **`onAuthStateChange` deve ser registrado no início da aplicação** para detectar trocas de sessão em tempo real. |

---

## Recomendações para o futuro SaaS multi-tenant

1. **`loja_id` em todas as tabelas sensíveis** (`membros`, `financas`, `sessoes`, `presencas`, `atas`) com RLS `USING (loja_id = auth.jwt()->>'loja_id')`. O `loja_id` deve ser injetado no JWT via `raw_app_meta_data` no momento do convite (`inviteUserByEmail`).

2. **Auditar RLS em todas as tabelas públicas** — verificar se está ativo e se as policies cobrem todos os roles (anon, authenticated, service_role).

3. **Centralizar toda criação de usuários em Edge Functions** com service_role. Nenhuma operação de `auth.admin.*` deve existir no client.

4. **Monitoramento de usuários órfãos** — criar job periódico (cron ou pg_cron) que alerta quando `auth.users` tem emails sem correspondência em `membros.auth_user_id`.

5. **Rate limiting na Edge Function** — limitar chamadas por minuto por admin para prevenir abuso em ambiente SaaS.

---

*Documentado por: Claude Code — assistência técnica de diagnóstico e remediação*  
*Revisado por: Denis Mangili (mangiliimports@gmail.com)*
