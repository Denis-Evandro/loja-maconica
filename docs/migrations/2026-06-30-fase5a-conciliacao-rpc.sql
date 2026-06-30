-- ===========================================================================
-- MIGRATION - FASE 5A do plano "Financeiro: Contas e Conciliacao"
-- Data:   2026-06-30
-- Plano:  docs/plano-financeiro-contas-conciliacao.md  (Fase 5)
-- Depende de: Fase 4A (extratos_bancarios) + Fase 4C aplicadas; financas (F1/F2).
-- Status: AGUARDANDO REVISAO - NAO APLICAR SEM:
--   1) Snapshot/backup do banco;
--   2) Confirmacao de que extratos_bancarios existe (4A) e que financas tem a
--      coluna identificador_externo (Fase 2);
--   3) Confirmacao de que public.is_financeiro_editor() existe (Fase 1).
--
-- O que entra (2 funcoes RPC, atomicas, SECURITY INVOKER):
--   * conciliar_extrato(p_extrato_id uuid, p_financa_id uuid) -> "Vincular"
--       - extrato: status_conciliacao='conciliado', financa_id, conciliado_por,
--         conciliado_em
--       - financa: status='pago', data <- data do extrato,
--         identificador_externo <- fitid (se houver)
--       - travas: extrato precisa estar 'pendente'; financa nao pode ja estar
--         conciliada a outra linha (1:1).
--   * ignorar_extrato(p_extrato_id uuid, p_motivo text) -> "Ignorar"
--       - extrato: status_conciliacao='ignorado', ignorado_por, ignorado_em,
--         motivo_ignorado. Trava: extrato precisa estar 'pendente'.
--
-- O que NAO entra:
--   * Criar lancamento pre-preenchido (Fase 5B).
--   * Desconciliar (Fase 7).
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- PRE-CHECK (rodar separadamente; comentado)
-- ---------------------------------------------------------------------------
-- SELECT table_name FROM information_schema.tables
--  WHERE table_schema='public' AND table_name IN ('extratos_bancarios','financas');
-- -- Esperado: 2 linhas
-- SELECT column_name FROM information_schema.columns
--  WHERE table_schema='public' AND table_name='financas'
--    AND column_name='identificador_externo';
-- -- Esperado: 1 linha
-- SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
--  WHERE n.nspname='public' AND p.proname='is_financeiro_editor';
-- -- Esperado: 1 linha

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. conciliar_extrato  (Vincular)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.conciliar_extrato(
  p_extrato_id uuid,
  p_financa_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, auth
AS $$
DECLARE
  v_status text;
  v_data   date;
  v_fitid  text;
BEGIN
  IF NOT public.is_financeiro_editor() THEN
    RAISE EXCEPTION 'Sem permissao para conciliar extrato.' USING ERRCODE = '42501';
  END IF;

  SELECT status_conciliacao, data, fitid
    INTO v_status, v_data, v_fitid
    FROM public.extratos_bancarios
   WHERE id = p_extrato_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Linha de extrato inexistente: %', p_extrato_id USING ERRCODE = '23503';
  END IF;
  IF v_status <> 'pendente' THEN
    RAISE EXCEPTION 'Esta linha nao esta pendente (status atual: %).', v_status
      USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.financas WHERE id = p_financa_id) THEN
    RAISE EXCEPTION 'Lancamento inexistente: %', p_financa_id USING ERRCODE = '23503';
  END IF;

  -- Vinculo 1:1: o lancamento nao pode ja estar conciliado a outra linha.
  IF EXISTS (
    SELECT 1 FROM public.extratos_bancarios
     WHERE financa_id = p_financa_id
       AND status_conciliacao = 'conciliado'
       AND id <> p_extrato_id
  ) THEN
    RAISE EXCEPTION 'Esse lancamento ja esta conciliado a outra linha do extrato.'
      USING ERRCODE = '23505';
  END IF;

  UPDATE public.extratos_bancarios
     SET status_conciliacao = 'conciliado',
         financa_id         = p_financa_id,
         conciliado_por     = auth.uid(),
         conciliado_em      = now()
   WHERE id = p_extrato_id;

  UPDATE public.financas
     SET status                = 'pago',
         data                  = v_data,
         identificador_externo = COALESCE(v_fitid, identificador_externo)
   WHERE id = p_financa_id;

  RETURN jsonb_build_object(
    'extrato_id', p_extrato_id,
    'financa_id', p_financa_id,
    'status',     'conciliado'
  );
END;
$$;

COMMENT ON FUNCTION public.conciliar_extrato(uuid, uuid) IS
  'Fase 5A - vincula 1 linha de extrato a 1 lancamento, de forma atomica: '
  'extrato->conciliado, financa->pago com data do extrato e fitid.';

REVOKE EXECUTE ON FUNCTION public.conciliar_extrato(uuid, uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.conciliar_extrato(uuid, uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. ignorar_extrato  (Ignorar)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ignorar_extrato(
  p_extrato_id uuid,
  p_motivo     text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, auth
AS $$
DECLARE
  v_status text;
BEGIN
  IF NOT public.is_financeiro_editor() THEN
    RAISE EXCEPTION 'Sem permissao para ignorar extrato.' USING ERRCODE = '42501';
  END IF;

  SELECT status_conciliacao INTO v_status
    FROM public.extratos_bancarios
   WHERE id = p_extrato_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Linha de extrato inexistente: %', p_extrato_id USING ERRCODE = '23503';
  END IF;
  IF v_status <> 'pendente' THEN
    RAISE EXCEPTION 'Esta linha nao esta pendente (status atual: %).', v_status
      USING ERRCODE = '22023';
  END IF;

  UPDATE public.extratos_bancarios
     SET status_conciliacao = 'ignorado',
         ignorado_por       = auth.uid(),
         ignorado_em        = now(),
         motivo_ignorado    = NULLIF(p_motivo, '')
   WHERE id = p_extrato_id;

  RETURN jsonb_build_object('extrato_id', p_extrato_id, 'status', 'ignorado');
END;
$$;

COMMENT ON FUNCTION public.ignorar_extrato(uuid, text) IS
  'Fase 5A - marca uma linha de extrato como ignorada, com motivo e autor.';

REVOKE EXECUTE ON FUNCTION public.ignorar_extrato(uuid, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.ignorar_extrato(uuid, text) TO authenticated;

COMMIT;

-- ===========================================================================
-- POS-CHECK (rodar separadamente)
-- ===========================================================================
-- SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args, p.prosecdef
--   FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
--  WHERE n.nspname='public' AND p.proname IN ('conciliar_extrato','ignorar_extrato')
--  ORDER BY p.proname;
-- -- Esperado: 2 linhas; prosecdef=false; args corretos.
--
-- -- Smoke test (rodar com ROLLBACK; trocar pelos ids reais):
-- -- BEGIN;
-- --   SELECT public.conciliar_extrato('<extrato_pendente_id>','<financa_id>');
-- --   -- conferir extrato.status_conciliacao='conciliado' e financa.status='pago'
-- -- ROLLBACK;
--
-- ===========================================================================
-- ROLLBACK (se necessario):
--   BEGIN;
--   DROP FUNCTION IF EXISTS public.conciliar_extrato(uuid, uuid);
--   DROP FUNCTION IF EXISTS public.ignorar_extrato(uuid, text);
--   COMMIT;
-- ===========================================================================
