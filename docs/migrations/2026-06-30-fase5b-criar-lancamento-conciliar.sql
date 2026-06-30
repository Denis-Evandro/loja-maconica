-- ===========================================================================
-- MIGRATION - FASE 5B do plano "Financeiro: Contas e Conciliacao"
-- Data:   2026-06-30
-- Plano:  docs/plano-financeiro-contas-conciliacao.md  (Fase 5)
-- Depende de: Fase 4A (extratos_bancarios) + Fase 5A aplicadas; financas (F1/F2).
-- Status: AGUARDANDO REVISAO - NAO APLICAR SEM:
--   1) Snapshot/backup do banco;
--   2) extratos_bancarios existe (4A); financas tem identificador_externo (F2);
--   3) public.is_financeiro_editor() existe (F1).
--
-- O que entra (1 funcao RPC, atomica, SECURITY INVOKER):
--   * criar_lancamento_e_conciliar(p_extrato_id uuid, p_lancamento jsonb)
--       - cria 1 lancamento em financas JA como 'pago', com a data do banco
--         (data do extrato) e identificador_externo = fitid;
--       - vincula a linha do extrato a esse lancamento (conciliado), tudo numa
--         transacao so. Para o caso "nao ha lancamento candidato": cria a partir
--         da linha do banco e concilia de uma vez.
--       - trava: extrato precisa estar 'pendente'.
--
-- Contrato do payload p_lancamento (jsonb):
--   { descricao, valor, tipo ('receita'|'despesa'), categoria?, membro_id?,
--     conta_bancaria_id? }
--   data/data_vencimento/status/identificador_externo sao definidos pela RPC.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- PRE-CHECK (comentado)
-- ---------------------------------------------------------------------------
-- SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
--  WHERE n.nspname='public' AND p.proname='conciliar_extrato';  -- esperado: 1 (5A aplicada)

BEGIN;

CREATE OR REPLACE FUNCTION public.criar_lancamento_e_conciliar(
  p_extrato_id uuid,
  p_lancamento jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, auth
AS $$
DECLARE
  v_status     text;
  v_data       date;
  v_fitid      text;
  v_conta      uuid;
  v_tipo       text;
  v_valor      numeric;
  v_financa_id uuid;
BEGIN
  IF NOT public.is_financeiro_editor() THEN
    RAISE EXCEPTION 'Sem permissao para conciliar extrato.' USING ERRCODE = '42501';
  END IF;

  SELECT status_conciliacao, data, fitid, conta_bancaria_id
    INTO v_status, v_data, v_fitid, v_conta
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

  v_tipo  := p_lancamento->>'tipo';
  v_valor := (p_lancamento->>'valor')::numeric;
  IF v_tipo NOT IN ('receita', 'despesa') THEN
    RAISE EXCEPTION 'tipo deve ser receita ou despesa (recebido: %).', v_tipo
      USING ERRCODE = '22023';
  END IF;
  IF v_valor IS NULL OR v_valor <= 0 THEN
    RAISE EXCEPTION 'valor deve ser positivo.' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.financas (
    descricao, valor, tipo, data, data_vencimento, categoria, status,
    membro_id, conta_bancaria_id, identificador_externo
  ) VALUES (
    COALESCE(NULLIF(p_lancamento->>'descricao', ''), 'Lancamento do extrato'),
    v_valor,
    v_tipo,
    v_data,
    v_data,
    NULLIF(p_lancamento->>'categoria', ''),
    'pago',
    NULLIF(p_lancamento->>'membro_id', '')::uuid,
    COALESCE(NULLIF(p_lancamento->>'conta_bancaria_id', '')::uuid, v_conta),
    v_fitid
  ) RETURNING id INTO v_financa_id;

  UPDATE public.extratos_bancarios
     SET status_conciliacao = 'conciliado',
         financa_id         = v_financa_id,
         conciliado_por     = auth.uid(),
         conciliado_em      = now()
   WHERE id = p_extrato_id;

  RETURN jsonb_build_object(
    'extrato_id', p_extrato_id,
    'financa_id', v_financa_id,
    'status',     'conciliado'
  );
END;
$$;

COMMENT ON FUNCTION public.criar_lancamento_e_conciliar(uuid, jsonb) IS
  'Fase 5B - cria um lancamento (pago, com data do banco e fitid) a partir de '
  'uma linha de extrato e concilia, de forma atomica.';

REVOKE EXECUTE ON FUNCTION public.criar_lancamento_e_conciliar(uuid, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.criar_lancamento_e_conciliar(uuid, jsonb) TO authenticated;

COMMIT;

-- ===========================================================================
-- POS-CHECK (comentado)
-- ===========================================================================
-- SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args, p.prosecdef
--   FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
--  WHERE n.nspname='public' AND p.proname='criar_lancamento_e_conciliar';
-- -- Esperado: 1 linha; args = uuid, jsonb; prosecdef=false.
--
-- ===========================================================================
-- ROLLBACK:
--   BEGIN;
--   DROP FUNCTION IF EXISTS public.criar_lancamento_e_conciliar(uuid, jsonb);
--   COMMIT;
-- ===========================================================================
