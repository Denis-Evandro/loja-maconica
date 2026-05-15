// ══════════════════════════════════════════════════════════════════════════════
// Edge Function: invite-member
// Versão: 1.1 — 2026-05-15 — passa dados da loja pro template de convite
// ══════════════════════════════════════════════════════════════════════════════

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}

const CARGOS_PERMITIDOS = new Set([
  'Venerável Mestre',
  'Secretário',
  'Chanceler',
]);

serve(async (req: Request) => {
  const L = '[invite-member]';

  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST')   return json({ error: 'Método não permitido' }, 405);

  try {
    // 1. Cliente admin com service_role
    const admin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
      { auth: { persistSession: false, autoRefreshToken: false } }
    );

    // 1b. Buscar dados da loja para o email de convite
    const { data: configRow } = await admin
      .from('configuracoes')
      .select('dados')
      .eq('id', 'loja_principal')
      .maybeSingle();

    const dadosLoja = configRow?.dados ?? {};
    const nomeLoja  = dadosLoja.nome_loja   ?? 'Loja Maçônica';
    const numLoja   = dadosLoja.numero_loja ?? '';
    const oriente   = dadosLoja.oriente     ?? '';

    // 2. Verificar JWT do solicitante
    const authHeader = req.headers.get('Authorization');
    if (!authHeader?.startsWith('Bearer ')) {
      return json({ error: 'Não autorizado: token ausente' }, 401);
    }

    const { data: { user: caller }, error: jwtErr } =
      await admin.auth.getUser(authHeader.replace('Bearer ', ''));
    if (jwtErr || !caller) return json({ error: 'Não autorizado: token inválido' }, 401);

    // 3. Permissão — Caminho A: tabela usuarios (admin)
    const { data: usuarioRow } = await admin
      .from('usuarios')
      .select('role, perfil, ativo')
      .eq('auth_user_id', caller.id)
      .maybeSingle();

    const isAdmin =
      !!usuarioRow && usuarioRow.ativo === true &&
      (usuarioRow.role === 'admin' || usuarioRow.perfil === 'admin');

    // 4. Permissão — Caminho B: cargo na tabela membros
    let isGestor = false;
    if (!isAdmin) {
      const { data: membroCaller } = await admin
        .from('membros')
        .select('cargo, status')
        .eq('auth_user_id', caller.id)
        .maybeSingle();

      isGestor =
        !!membroCaller &&
        membroCaller.status === 'ativo' &&
        CARGOS_PERMITIDOS.has(membroCaller.cargo);
    }

    if (!isAdmin && !isGestor) return json({ error: 'Sem permissão para convidar membros' }, 403);

    // 5. Ler e validar body
    let body: { membroId?: string; email?: string; redirectTo?: string };
    try { body = await req.json(); }
    catch { return json({ error: 'Body inválido — JSON esperado' }, 400); }

    const { membroId, email, redirectTo } = body;
    if (!membroId || !email) return json({ error: 'Campos obrigatórios ausentes: membroId, email' }, 400);

    const emailNorm   = email.toLowerCase().trim();
    const redirectUrl = redirectTo ?? '';

    // 6. Verificar membro no banco
    const { data: membro, error: membroErr } = await admin
      .from('membros')
      .select('id, email, auth_user_id, nome_maconico, status')
      .eq('id', membroId)
      .single();

    if (membroErr || !membro) return json({ error: 'Membro não encontrado' }, 404);

    if ((membro.email ?? '').toLowerCase().trim() !== emailNorm)
      return json({ error: 'E-mail não corresponde ao membro cadastrado' }, 400);

    // 7a. Já tem conta → reenviar link de recuperação
    if (membro.auth_user_id) {
      const { error: linkErr } = await admin.auth.admin.generateLink({
        type: 'recovery',
        email: emailNorm,
        options: { redirectTo: redirectUrl },
      });
      if (linkErr) return json({ error: 'Erro ao reenviar convite: ' + linkErr.message }, 500);

      await admin.from('membros').update({
        login_status:       'convite_enviado',
        login_vinculado_em: new Date().toISOString(),
      }).eq('id', membroId);

      return json({ success: true, reenvio: true, membro: membro.nome_maconico });
    }

    // 7b. Sem conta → inviteUserByEmail (server-side)
    const { data: inviteData, error: inviteErr } =
      await admin.auth.admin.inviteUserByEmail(emailNorm, {
        data: {
          membroId,
          nome_maconico: membro.nome_maconico,
          nome_loja:     nomeLoja,
          numero_loja:   numLoja,
          oriente:       oriente,
        },
        redirectTo: redirectUrl,
      });

    if (inviteErr) {
      if (inviteErr.message.toLowerCase().includes('already been registered')) {
        return json({ error: 'Este e-mail já possui conta no sistema. Execute a limpeza (Fase A) para este usuário e tente novamente.' }, 409);
      }
      return json({ error: 'Erro ao criar convite: ' + inviteErr.message }, 500);
    }

    // 8. Vincular auth_user_id ao membro (com rollback em falha)
    const authUserId = inviteData.user.id;
    const { error: updateErr } = await admin
      .from('membros')
      .update({
        auth_user_id:       authUserId,
        login_status:       'convite_enviado',
        login_vinculado_em: new Date().toISOString(),
      })
      .eq('id', membroId);

    if (updateErr) {
      await admin.auth.admin.deleteUser(authUserId); // rollback
      return json({ error: 'Erro ao vincular membro. Operação revertida.' }, 500);
    }

    return json({ success: true, reenvio: false, authUserId, membro: membro.nome_maconico });

  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    return json({ error: 'Erro interno do servidor: ' + msg }, 500);
  }
});
