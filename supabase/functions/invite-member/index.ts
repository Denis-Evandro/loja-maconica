// ══════════════════════════════════════════════════════════════════════════════
// Edge Function: invite-member
// Versão: 1.0 — 2026-05-11
// Propósito: Criar convite de acesso para membro da loja de forma segura.
//            Usa service_role no servidor — nunca expõe a chave nem cria
//            sessão no browser de quem convida.
//
// Deploy: Supabase Dashboard → Edge Functions → invite-member
// Variáveis: SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY são auto-injetadas.
// ══════════════════════════════════════════════════════════════════════════════

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';

// ── CORS ──────────────────────────────────────────────────────────────────────
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

// ── Helper de resposta ────────────────────────────────────────────────────────
function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}

// ── Cargos com permissão de convidar (decisão fechada em 2026-05-11) ─────────
// Para alterar esta lista, editar aqui E atualizar ROLES no index.html (Fase C).
const CARGOS_PERMITIDOS = new Set([
  'Venerável Mestre',
  'Secretário',
  'Chanceler',
]);

// ── Handler principal ─────────────────────────────────────────────────────────
serve(async (req: Request) => {
  const L = '[invite-member]';

  // Preflight CORS
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST')   return json({ error: 'Método não permitido' }, 405);

  console.log(`${L} ── início da requisição ──`);

  try {
    // ── 1. Cliente admin com service_role ─────────────────────────────────────
    //    Variáveis auto-injetadas pelo runtime do Supabase — sem config manual.
    const admin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
      { auth: { persistSession: false, autoRefreshToken: false } }
    );

    // ── 2. Verificar JWT do solicitante ───────────────────────────────────────
    const authHeader = req.headers.get('Authorization');
    if (!authHeader?.startsWith('Bearer ')) {
      console.warn(`${L} Token ausente no header`);
      return json({ error: 'Não autorizado: token ausente' }, 401);
    }

    const { data: { user: caller }, error: jwtErr } =
      await admin.auth.getUser(authHeader.replace('Bearer ', ''));

    if (jwtErr || !caller) {
      console.warn(`${L} Token inválido:`, jwtErr?.message);
      return json({ error: 'Não autorizado: token inválido' }, 401);
    }
    console.log(`${L} Solicitante: ${caller.email} | id: ${caller.id}`);

    // ── 3. Verificar permissão — Caminho A: tabela usuarios ──────────────────
    const { data: usuarioRow, error: errUsuario } = await admin
      .from('usuarios')
      .select('role, perfil, ativo')
      .eq('auth_user_id', caller.id)
      .maybeSingle();

    if (errUsuario) {
      // Logar mas não abortar — tentará o caminho B
      console.warn(`${L} Aviso ao consultar usuarios:`, errUsuario.message);
    }

    const isAdmin =
      !!usuarioRow &&
      usuarioRow.ativo === true &&
      (usuarioRow.role === 'admin' || usuarioRow.perfil === 'admin');

    console.log(`${L} isAdmin: ${isAdmin} | role=${usuarioRow?.role} perfil=${usuarioRow?.perfil} ativo=${usuarioRow?.ativo}`);

    // ── 4. Verificar permissão — Caminho B: cargo na tabela membros ───────────
    let isGestor = false;
    if (!isAdmin) {
      const { data: membroCaller, error: errMembroCaller } = await admin
        .from('membros')
        .select('cargo, status')
        .eq('auth_user_id', caller.id)
        .maybeSingle();

      if (errMembroCaller) {
        console.warn(`${L} Aviso ao consultar membros (caller):`, errMembroCaller.message);
      }

      isGestor =
        !!membroCaller &&
        membroCaller.status === 'ativo' &&
        CARGOS_PERMITIDOS.has(membroCaller.cargo);

      console.log(`${L} isGestor: ${isGestor} | cargo="${membroCaller?.cargo}" status="${membroCaller?.status}"`);
    }

    if (!isAdmin && !isGestor) {
      console.warn(`${L} Acesso negado para ${caller.email}`);
      return json({ error: 'Sem permissão para convidar membros' }, 403);
    }

    // ── 5. Ler e validar body ─────────────────────────────────────────────────
    let body: { membroId?: string; email?: string; redirectTo?: string };
    try {
      body = await req.json();
    } catch {
      return json({ error: 'Body inválido — JSON esperado' }, 400);
    }

    const { membroId, email, redirectTo } = body;
    if (!membroId || !email) {
      return json({ error: 'Campos obrigatórios ausentes: membroId, email' }, 400);
    }

    const emailNorm   = email.toLowerCase().trim();
    const redirectUrl = redirectTo ?? '';
    console.log(`${L} Alvo: membroId=${membroId} email=${emailNorm}`);

    // ── 6. Verificar membro no banco ──────────────────────────────────────────
    const { data: membro, error: membroErr } = await admin
      .from('membros')
      .select('id, email, auth_user_id, nome_maconico, status')
      .eq('id', membroId)
      .single();

    if (membroErr || !membro) {
      console.warn(`${L} Membro não encontrado: ${membroId} | erro: ${membroErr?.message}`);
      return json({ error: 'Membro não encontrado' }, 404);
    }

    if ((membro.email ?? '').toLowerCase().trim() !== emailNorm) {
      console.warn(`${L} Email divergente: banco="${membro.email}" request="${emailNorm}"`);
      return json({ error: 'E-mail não corresponde ao membro cadastrado' }, 400);
    }

    console.log(`${L} Membro válido: "${membro.nome_maconico}" | auth_user_id atual: ${membro.auth_user_id ?? 'nenhum'}`);

    // ── 7a. Já tem conta → reenviar link de recuperação ───────────────────────
    //        generateLink não cria sessão no browser de ninguém.
    if (membro.auth_user_id) {
      console.log(`${L} Caminho: REENVIO (auth_user_id já existe)`);

      const { error: linkErr } = await admin.auth.admin.generateLink({
        type: 'recovery',
        email: emailNorm,
        options: { redirectTo: redirectUrl },
      });

      if (linkErr) {
        console.error(`${L} Erro ao gerar link de recuperação:`, linkErr.message);
        return json({ error: 'Erro ao reenviar convite: ' + linkErr.message }, 500);
      }

      const { error: updErr } = await admin
        .from('membros')
        .update({
          login_status:       'convite_enviado',
          login_vinculado_em: new Date().toISOString(),
        })
        .eq('id', membroId);

      if (updErr) console.warn(`${L} Aviso ao atualizar timestamp de reenvio:`, updErr.message);

      console.log(`${L} ── fim (reenvio OK) ──`);
      return json({ success: true, reenvio: true, membro: membro.nome_maconico });
    }

    // ── 7b. Sem conta → inviteUserByEmail (server-side) ───────────────────────
    //        Não cria sessão no browser do admin. Envia email de convite Supabase.
    console.log(`${L} Caminho: NOVO CONVITE (inviteUserByEmail)`);

    const { data: inviteData, error: inviteErr } =
      await admin.auth.admin.inviteUserByEmail(emailNorm, {
        data:       { membroId, nome_maconico: membro.nome_maconico },
        redirectTo: redirectUrl,
      });

    if (inviteErr) {
      console.error(`${L} Erro ao criar convite:`, inviteErr.message);

      // Caso especial: email já existe no Auth mas auth_user_id não estava salvo.
      // Acontece se a Fase A não foi executada para este usuário.
      if (inviteErr.message.toLowerCase().includes('already been registered')) {
        console.warn(`${L} Email já existe no Auth — execute a Fase A (limpeza) para este usuário`);
        return json({
          error: 'Este e-mail já possui conta no sistema. Execute a limpeza (Fase A) para este usuário e tente novamente.',
        }, 409);
      }

      return json({ error: 'Erro ao criar convite: ' + inviteErr.message }, 500);
    }

    const authUserId = inviteData.user.id;
    console.log(`${L} Auth user criado com sucesso: ${authUserId}`);

    // ── 8. Vincular auth_user_id ao membro (com rollback em falha) ────────────
    const { error: updateErr } = await admin
      .from('membros')
      .update({
        auth_user_id:       authUserId,
        login_status:       'convite_enviado',
        login_vinculado_em: new Date().toISOString(),
      })
      .eq('id', membroId);

    if (updateErr) {
      console.error(`${L} ERRO ao vincular auth_user_id. Iniciando rollback...`, updateErr.message);

      const { error: deleteErr } = await admin.auth.admin.deleteUser(authUserId);
      if (deleteErr) {
        console.error(`${L} !! ROLLBACK FALHOU — auth user ${authUserId} ficou órfão:`, deleteErr.message);
      } else {
        console.log(`${L} Rollback OK — auth user ${authUserId} removido`);
      }

      return json({ error: 'Erro ao vincular membro. Operação revertida.' }, 500);
    }

    console.log(`${L} Vínculo salvo: membros.auth_user_id = ${authUserId}`);
    console.log(`${L} ── fim (novo convite OK) ──`);

    return json({
      success:   true,
      reenvio:   false,
      authUserId,
      membro:    membro.nome_maconico,
    });

  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    console.error(`[invite-member] EXCEÇÃO NÃO TRATADA:`, msg);
    return json({ error: 'Erro interno do servidor: ' + msg }, 500);
  }
});
