-- ===========================================================================
-- MIGRATION - FASE 4C do plano "Financeiro: Contas e Conciliacao"
-- Data:   2026-06-30
-- Plano:  docs/plano-financeiro-contas-conciliacao.md  (Fase 4)
-- Depende de: Fase 4A aplicada (tabelas importacoes_ofx + extratos_bancarios).
-- Status: AGUARDANDO REVISAO - NAO APLICAR SEM:
--   1) Snapshot/backup do banco (Supabase Dashboard > Database > Backups);
--   2) Confirmacao de que a Fase 4A ja foi aplicada (as 2 tabelas existem);
--   3) Confirmacao de que public.is_financeiro_editor() existe (Fase 1).
--
-- O que entra:
--   * Funcao RPC public.importar_ofx_extrato(uuid, jsonb, jsonb) RETURNS jsonb
--     - SECURITY INVOKER (roda com a permissao do usuario; RLS continua valendo)
--     - Insere 1 cabecalho em importacoes_ofx + N linhas em extratos_bancarios
--     - Dedup via ON CONFLICT DO NOTHING nos 2 indices UNIQUE parciais da 4A
--       (por fitid quando presente; por hash_linha quando fitid IS NULL)
--     - Tudo numa unica transacao (a funcao e atomica): ou grava o lote
--       inteiro, ou nada.
--   * REVOKE EXECUTE FROM PUBLIC + GRANT EXECUTE TO authenticated.
--
-- O que NAO entra:
--   * Conciliacao (Fase 5), regras (Fase 6), cancelamento de importacao.
--   * Validacao rigida de ACCTID x conta: formatos variam entre origem do OFX
--     e o cadastro; o cliente exibe aviso. A RPC apenas exige que a conta
--     exista. acctid_ofx fica gravado para conferencia humana.
--
-- Contrato esperado do payload (montado pelo cliente em index.html):
--   p_conta_bancaria_id : uuid da conta destino
--   p_arquivo_meta jsonb: { arquivo_nome, arquivo_hash, arquivo_tamanho_bytes,
--                           ofx_versao?, bankid_ofx?, acctid_ofx?,
--                           periodo_inicio (YYYY-MM-DD), periodo_fim,
--                           saldo_final?, saldo_final_data?, observacao? }
--   p_linhas jsonb      : array de { data, dtposted_raw, descricao_bruta,
--                           descricao_normalizada, valor, tipo_operacao,
--                           fitid?, hash_linha, name_normalizado,
--                           memo_normalizado, checknum?, refnum?,
--                           ordem_no_arquivo? }
-- Retorno jsonb: { importacao_id, total_linhas, total_inseridas,
--                  total_duplicadas }
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- PRE-CHECK (rodar separadamente antes de aplicar; comentado)
-- ---------------------------------------------------------------------------
-- -- As 2 tabelas da Fase 4A existem? (esperado: 2)
-- SELECT table_name FROM information_schema.tables
--  WHERE table_schema='public'
--    AND table_name IN ('importacoes_ofx','extratos_bancarios');
-- -- A funcao helper de RLS existe? (esperado: 1)
-- SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
--  WHERE n.nspname='public' AND p.proname='is_financeiro_editor';

BEGIN;

CREATE OR REPLACE FUNCTION public.importar_ofx_extrato(
  p_conta_bancaria_id uuid,
  p_arquivo_meta      jsonb,
  p_linhas            jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, auth
AS $$
DECLARE
  v_importacao_id uuid;
  v_total         int := 0;
  v_inseridas     int := 0;
  v_duplicadas    int := 0;
  v_linha         jsonb;
  v_novo_id       uuid;
BEGIN
  -- Defesa extra alem da RLS: bloqueia quem nao e editor financeiro.
  IF NOT public.is_financeiro_editor() THEN
    RAISE EXCEPTION 'Sem permissao para importar extrato financeiro.'
      USING ERRCODE = '42501';
  END IF;

  -- A conta destino precisa existir.
  IF NOT EXISTS (
    SELECT 1 FROM public.contas_bancarias WHERE id = p_conta_bancaria_id
  ) THEN
    RAISE EXCEPTION 'Conta bancaria inexistente: %', p_conta_bancaria_id
      USING ERRCODE = '23503';
  END IF;

  IF p_linhas IS NULL OR jsonb_typeof(p_linhas) <> 'array' THEN
    RAISE EXCEPTION 'p_linhas deve ser um array JSON.' USING ERRCODE = '22023';
  END IF;
  v_total := jsonb_array_length(p_linhas);
  IF v_total = 0 THEN
    RAISE EXCEPTION 'Nenhuma linha para importar.' USING ERRCODE = '22023';
  END IF;

  -- Cabecalho. total_linhas fica 0 aqui (default) para nao violar o CHECK
  -- de totais; o valor real e gravado no UPDATE final, ja consistente.
  INSERT INTO public.importacoes_ofx (
    conta_bancaria_id, arquivo_nome, arquivo_hash, arquivo_tamanho_bytes,
    ofx_versao, bankid_ofx, acctid_ofx, periodo_inicio, periodo_fim,
    saldo_final, saldo_final_data, observacao
  ) VALUES (
    p_conta_bancaria_id,
    p_arquivo_meta->>'arquivo_nome',
    p_arquivo_meta->>'arquivo_hash',
    (p_arquivo_meta->>'arquivo_tamanho_bytes')::int,
    NULLIF(p_arquivo_meta->>'ofx_versao',''),
    NULLIF(p_arquivo_meta->>'bankid_ofx',''),
    NULLIF(p_arquivo_meta->>'acctid_ofx',''),
    (p_arquivo_meta->>'periodo_inicio')::date,
    (p_arquivo_meta->>'periodo_fim')::date,
    NULLIF(p_arquivo_meta->>'saldo_final','')::numeric,
    NULLIF(p_arquivo_meta->>'saldo_final_data','')::date,
    NULLIF(p_arquivo_meta->>'observacao','')
  ) RETURNING id INTO v_importacao_id;

  -- Linhas: dedup escolhe o indice parcial conforme haja FITID ou nao.
  FOR v_linha IN SELECT jsonb_array_elements(p_linhas)
  LOOP
    v_novo_id := NULL;

    IF COALESCE(v_linha->>'fitid','') <> '' THEN
      INSERT INTO public.extratos_bancarios (
        conta_bancaria_id, importacao_id, data, dtposted_raw, descricao_bruta,
        descricao_normalizada, valor, tipo_operacao, fitid, hash_linha,
        name_normalizado, memo_normalizado, checknum, refnum, ordem_no_arquivo
      ) VALUES (
        p_conta_bancaria_id, v_importacao_id,
        (v_linha->>'data')::date, v_linha->>'dtposted_raw',
        COALESCE(v_linha->>'descricao_bruta',''),
        COALESCE(v_linha->>'descricao_normalizada',''),
        (v_linha->>'valor')::numeric, v_linha->>'tipo_operacao',
        v_linha->>'fitid', v_linha->>'hash_linha',
        COALESCE(v_linha->>'name_normalizado',''),
        COALESCE(v_linha->>'memo_normalizado',''),
        NULLIF(v_linha->>'checknum',''), NULLIF(v_linha->>'refnum',''),
        NULLIF(v_linha->>'ordem_no_arquivo','')::int
      )
      ON CONFLICT (conta_bancaria_id, fitid) WHERE fitid IS NOT NULL
      DO NOTHING
      RETURNING id INTO v_novo_id;
    ELSE
      INSERT INTO public.extratos_bancarios (
        conta_bancaria_id, importacao_id, data, dtposted_raw, descricao_bruta,
        descricao_normalizada, valor, tipo_operacao, fitid, hash_linha,
        name_normalizado, memo_normalizado, checknum, refnum, ordem_no_arquivo
      ) VALUES (
        p_conta_bancaria_id, v_importacao_id,
        (v_linha->>'data')::date, v_linha->>'dtposted_raw',
        COALESCE(v_linha->>'descricao_bruta',''),
        COALESCE(v_linha->>'descricao_normalizada',''),
        (v_linha->>'valor')::numeric, v_linha->>'tipo_operacao',
        NULL, v_linha->>'hash_linha',
        COALESCE(v_linha->>'name_normalizado',''),
        COALESCE(v_linha->>'memo_normalizado',''),
        NULLIF(v_linha->>'checknum',''), NULLIF(v_linha->>'refnum',''),
        NULLIF(v_linha->>'ordem_no_arquivo','')::int
      )
      ON CONFLICT (conta_bancaria_id, hash_linha) WHERE fitid IS NULL
      DO NOTHING
      RETURNING id INTO v_novo_id;
    END IF;

    IF v_novo_id IS NULL THEN
      v_duplicadas := v_duplicadas + 1;
    ELSE
      v_inseridas := v_inseridas + 1;
    END IF;
  END LOOP;

  -- Totais finais (consistentes: inseridas + duplicadas + 0 = total_linhas).
  UPDATE public.importacoes_ofx
     SET total_linhas     = v_total,
         total_inseridas  = v_inseridas,
         total_duplicadas = v_duplicadas,
         total_erros      = 0
   WHERE id = v_importacao_id;

  RETURN jsonb_build_object(
    'importacao_id',    v_importacao_id,
    'total_linhas',     v_total,
    'total_inseridas',  v_inseridas,
    'total_duplicadas', v_duplicadas
  );
END;
$$;

COMMENT ON FUNCTION public.importar_ofx_extrato(uuid, jsonb, jsonb) IS
  'Fase 4C - importa um lote OFX (1 cabecalho + N linhas) de forma atomica, '
  'com dedup por fitid/hash_linha. SECURITY INVOKER; RLS continua valendo.';

REVOKE EXECUTE ON FUNCTION public.importar_ofx_extrato(uuid, jsonb, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.importar_ofx_extrato(uuid, jsonb, jsonb) TO authenticated;

-- Privilegios de tabela para o papel authenticated (a RPC roda como o usuario,
-- SECURITY INVOKER). Sem DELETE, coerente com as policies da 4A. Idempotente:
-- nao faz mal se o Supabase ja concedeu por privilegios padrao.
GRANT SELECT, INSERT, UPDATE ON public.importacoes_ofx    TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.extratos_bancarios TO authenticated;

COMMIT;

-- ===========================================================================
-- POS-CHECK (rodar separadamente apos o COMMIT)
-- ===========================================================================
-- -- 1. Funcao criada com a assinatura certa
-- SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args,
--        p.prosecdef AS security_definer
--   FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
--  WHERE n.nspname='public' AND p.proname='importar_ofx_extrato';
-- -- Esperado: 1 linha; args = "uuid, jsonb, jsonb"; security_definer = false
--
-- -- 2. Permissoes (PUBLIC nao executa; authenticated executa)
-- SELECT grantee, privilege_type FROM information_schema.routine_privileges
--  WHERE routine_schema='public' AND routine_name='importar_ofx_extrato'
--  ORDER BY grantee;
--
-- -- 3. Smoke test (rodar com ROLLBACK no final, trocando o uuid por uma
-- --    conta real de contas_bancarias):
-- -- BEGIN;
-- --   SELECT public.importar_ofx_extrato(
-- --     '<conta_bancaria_id>'::uuid,
-- --     '{"arquivo_nome":"t.ofx","arquivo_hash":"'||repeat('a',64)||'",
-- --       "arquivo_tamanho_bytes":10,"periodo_inicio":"2026-05-01",
-- --       "periodo_fim":"2026-05-31"}'::jsonb,
-- --     '[{"data":"2026-05-10","dtposted_raw":"20260510","valor":17.0,
-- --        "tipo_operacao":"CREDIT","fitid":"X1","hash_linha":"'||repeat('b',64)||'",
-- --        "name_normalizado":"TESTE","memo_normalizado":"","ordem_no_arquivo":1}]'::jsonb
-- --   );
-- --   -- repetir a MESMA chamada -> total_inseridas=0, total_duplicadas=1
-- -- ROLLBACK;
--
-- ===========================================================================
-- ROLLBACK (se necessario):
--   BEGIN;
--   DROP FUNCTION IF EXISTS public.importar_ofx_extrato(uuid, jsonb, jsonb);
--   COMMIT;
-- ===========================================================================
