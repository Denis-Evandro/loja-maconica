// ══════════════════════════════════════════════════════════════════════════════
// Edge Function: invite-member
// Versão: 1.2 — 2026-06-27 — must_set_password no metadata + logs verbose
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

const L = '[invite-member]';

serve(async (req: Request) => {
  console.log(L, '▶ request', req.method, new URL(req.url).pathname);

  if (req.method === 'OPTIONS') {
    console.log(L, '↩ CORS preflight OK');
    return new Response('ok', { headers: CORS });
  }
  if (req.method !== 'POST') {
    console.log(L, '✖ método não permitido:', req.method);
    return json({ error: 'Método não permitido' }, 405);
  }

  try {
    // 1. Cliente admin com service_role
    const supaUrl = Deno.env.get('SUPABASE_URL');
    const supaKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    if (!supaUrl || !supaKey) {
      console.error(L, '✖ env ausente — SUPABASE_URL=', !!supaUrl, 'SERVICE_ROLE=', !!supaKey);
      return json({ error: 'Configuração do servidor incompleta' }, 500);
    }
    const admin = createClient(supaUrl, supaKey,
      { auth: { persistSession: false, autoRefreshToken: false } }
    );

    // 1b. Buscar dados da loja para o email de convite
    const { data: configRow, error: configErr } = await admin
      .from('configuracoes')
      .select('dados')
      .eq('id', 'loja_principal')
      .maybeSingle();
    if (configErr) console.warn(L, '⚠ leitura configuracoes:', configErr.message);

    const dadosLoja = configRow?.dados ?? {};
    const nomeLoja  = dadosLoja.nome_loja   ?? 'Loja Maçônica';
    const numLoja   = dadosLoja.numero_loja ?? '';
    const oriente   = dadosLoja.oriente     ?? '';

    // 2. Verificar JWT do solicitante
    const authHeader = req.headers.get('Authorization');
    if (!authHeader?.startsWith('Bearer ')) {
      console.warn(L, '✖ Authorization ausente ou malformado');
      return json({ error: 'Não autorizado: token ausente' }, 401);
    }

    const { data: { user: caller }, error: jwtErr } =
      await admin.auth.getUser(authHeader.replace('Bearer ', ''));
    if (jwtErr || !caller) {
      console.warn(L, '✖ JWT inválido:', jwtErr?.message);
      return json({ error: 'Não autorizado: token inválido' }, 401);
    }
    console.log(L, '✓ caller', { id: caller.id, email: caller.email });

    // 3. Permissão — Caminho A: tabela usuarios (admin)
    const { data: usuarioRow, error: usuarioErr } = await admin
      .from('usuarios')
      .select('role, perfil, ativo')
      .eq('auth_user_id', caller.id)
      .maybeSingle();
    if (usuarioErr) console.warn(L, '⚠ leitura usuarios:', usuarioErr.message);

    const isAdmin =
      !!usuarioRow && usuarioRow.ativo === true &&
      (usuarioRow.role === 'admin' || usuarioRow.perfil === 'admin');

    // 4. Permissão — Caminho B: cargo na tabela membros
    let isGestor = false;
    let cargoCaller: string | null = null;
    if (!isAdmin) {
      const { data: membroCaller, error: membroCallerErr } = await admin
        .from('membros')
        .select('cargo, status')
        .eq('auth_user_id', caller.id)
        .maybeSingle();
      if (membroCallerErr) console.warn(L, '⚠ leitura membros (caller):', membroCallerErr.message);
      cargoCaller = membroCaller?.cargo ?? null;

      isGestor =
        !!membroCaller &&
        membroCaller.status === 'ativo' &&
        CARGOS_PERMITIDOS.has(membroCaller.cargo);
    }
    console.log(L, '✓ permissão', { isAdmin, isGestor, cargoCaller });

    if (!isAdmin && !isGestor) {
      console.warn(L, '✖ sem permissão para convidar');
      return json({ error: 'Sem permissão para convidar membros' }, 403);
    }

    // 5. Ler e validar body
    let body: { membroId?: string; email?: string; redirectTo?: string };
    try { body = await req.json(); }
    catch (e) {
      console.warn(L, '✖ body inválido (não-JSON):', (e as Error).message);
      return json({ error: 'Body inválido — JSON esperado' }, 400);
    }
    console.log(L, '✓ body recebido', {
      hasMembroId: !!body.membroId,
      email: body.email,
      redirectTo: body.redirectTo
    });

    const { membroId, email, redirectTo } = body;
    if (!membroId || !email) {
      console.warn(L, '✖ campos obrigatórios ausentes');
      return json({ error: 'Campos obrigatórios ausentes: membroId, email' }, 400);
    }

    const emailNorm   = email.toLowerCase().trim();
    const redirectUrl = redirectTo ?? '';

    // 6. Verificar membro no banco
    const { data: membro, error: membroErr } = await admin
      .from('membros')
      .select('id, email, auth_user_id, nome_maconico, status')
      .eq('id', membroId)
      .single();

    if (membroErr || !membro) {
      console.warn(L, '✖ membro não encontrado:', membroErr?.message);
      return json({ error: 'Membro não encontrado' }, 404);
    }
    console.log(L, '✓ membro alvo', {
      id: membro.id,
      nome: membro.nome_maconico,
      status: membro.status,
      jaTemAuth: !!membro.auth_user_id
    });

    if ((membro.email ?? '').toLowerCase().trim() !== emailNorm) {
      console.warn(L, '✖ email não bate com cadastro', { recebido: emailNorm, cadastrado: membro.email });
      return json({ error: 'E-mail não corresponde ao membro cadastrado' }, 400);
    }

    // ── Helper: reenvio para usuário que JÁ EXISTE no auth ──────────
    // - garante vínculo com o membro
    // - força must_set_password=true se a senha ainda não foi definida
    // - envia e-mail de recovery (mesmo link usado pelo cliente para
    //   "esqueci a senha" / "primeiro acesso")
    const reenviarParaUsuarioExistente = async (authUserId: string) => {
      console.log(L, '→ reenvio para auth.user existente', { authUserId });

      // 1. Vincular membro se ainda não estiver vinculado
      if (!membro.auth_user_id) {
        const { error: vincErr } = await admin.from('membros').update({
          auth_user_id:       authUserId,
          login_status:       'convite_enviado',
          login_vinculado_em: new Date().toISOString(),
        }).eq('id', membroId);
        if (vincErr) {
          console.error(L, '✖ vínculo do membro falhou:', vincErr.message);
          return json({ error: 'Erro ao vincular membro existente: ' + vincErr.message }, 500);
        }
      } else {
        await admin.from('membros').update({
          login_status:       'convite_enviado',
          login_vinculado_em: new Date().toISOString(),
        }).eq('id', membroId);
      }

      // 2. Atualizar metadata: se ainda não definiu senha, manter must_set_password
      const { data: existing, error: getErr } = await admin.auth.admin.getUserById(authUserId);
      if (getErr) console.warn(L, '⚠ getUserById:', getErr.message);
      const meta = existing?.user?.user_metadata ?? {};
      if (meta.password_set !== true) {
        const { error: metaErr } = await admin.auth.admin.updateUserById(authUserId, {
          user_metadata: { ...meta, membroId, must_set_password: true },
        });
        if (metaErr) console.warn(L, '⚠ updateUserById metadata:', metaErr.message);
      }

      // 3. Disparar e-mail de recovery (essa chamada ENVIA o e-mail, ao contrário
      //    de generateLink que só gera o link)
      const { error: resetErr } = await admin.auth.resetPasswordForEmail(emailNorm, {
        redirectTo: redirectUrl,
      });
      if (resetErr) {
        console.error(L, '✖ resetPasswordForEmail falhou:', resetErr.message);
        return json({ error: 'Erro ao reenviar convite: ' + resetErr.message }, 500);
      }

      const semSenha = meta.password_set !== true;
      console.log(L, '✓ reenvio emitido', { semSenha, authUserId });
      return json({
        success: true,
        reenvio: true,
        semSenha,
        membro: membro.nome_maconico,
      });
    };

    // 7a. Já tem conta vinculada → reenviar link
    if (membro.auth_user_id) {
      console.log(L, '→ caminho REENVIO (membro já vinculado)');
      return await reenviarParaUsuarioExistente(membro.auth_user_id);
    }

    // 7b. Sem vínculo → tentar inviteUserByEmail (cria user novo)
    // must_set_password: flag de UX usado pelo cliente para forçar a tela de
    // primeiro acesso mesmo se o usuário recarregar a página antes de definir
    // a senha. Não é controle de segurança — é a senha em si que valida.
    console.log(L, '→ caminho INVITE (membro sem vínculo)');
    const { data: inviteData, error: inviteErr } =
      await admin.auth.admin.inviteUserByEmail(emailNorm, {
        data: {
          membroId,
          nome_maconico:      membro.nome_maconico,
          nome_loja:          nomeLoja,
          numero_loja:        numLoja,
          oriente:            oriente,
          must_set_password:  true,
        },
        redirectTo: redirectUrl,
      });

    if (inviteErr) {
      console.error(L, '✖ inviteUserByEmail falhou:', inviteErr.message, 'status=', (inviteErr as any).status);
      // Se o usuário JÁ existe no auth (caso comum: convite anterior, vínculo
      // perdido, ou conta criada por outro fluxo), buscamos o ID e tratamos
      // como reenvio — não devolver 409 cego.
      if (inviteErr.message.toLowerCase().includes('already')) {
        console.log(L, '→ usuário já existe no auth, recuperando ID via listUsers');
        try {
          // listUsers só aceita paginação; iteramos até encontrar
          let achado: any = null;
          for (let page = 1; page <= 20 && !achado; page++) {
            const { data: listData, error: listErr } = await admin.auth.admin.listUsers({ page, perPage: 200 });
            if (listErr) { console.error(L, '✖ listUsers page', page, listErr.message); break; }
            if (!listData?.users?.length) break;
            achado = listData.users.find((u: any) => (u.email || '').toLowerCase() === emailNorm);
            if (achado || listData.users.length < 200) break;
          }
          if (!achado) {
            console.error(L, '✖ usuário "already exists" mas não foi encontrado via listUsers');
            return json({ error: 'E-mail já registrado no servidor de auth, mas não foi possível localizar a conta. Contate o administrador.' }, 500);
          }
          return await reenviarParaUsuarioExistente(achado.id);
        } catch (e) {
          console.error(L, '✖ erro buscando user existente:', e);
          return json({ error: 'Erro ao tratar e-mail já registrado: ' + (e instanceof Error ? e.message : String(e)) }, 500);
        }
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
      console.error(L, '✖ update membros falhou, rollback do auth user:', updateErr.message);
      await admin.auth.admin.deleteUser(authUserId); // rollback
      return json({ error: 'Erro ao vincular membro. Operação revertida.' }, 500);
    }

    console.log(L, '✓ convite enviado e membro vinculado', { authUserId });
    return json({ success: true, reenvio: false, authUserId, membro: membro.nome_maconico });

  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    const stk = e instanceof Error ? e.stack : '';
    console.error(L, '💥 EXCEÇÃO não tratada:', msg, '\n', stk);
    return json({ error: 'Erro interno do servidor: ' + msg }, 500);
  }
});
