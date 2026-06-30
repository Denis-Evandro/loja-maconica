-- ===========================================================================
-- MIGRATION - FASE 7 (fatia: DESCONCILIAR) do plano "Financeiro: Conciliacao"
-- Data:   2026-06-30
-- Plano:  docs/plano-financeiro-contas-conciliacao.md  (Fase 7)
-- Depende de: Fase 4A + 5A aplicadas.
-- Status: AGUARDANDO REVISAO - NAO APLICAR SEM:
--   1) Snapshot/backup do banco;
--   2) extratos_bancarios existe (4A); is_financeiro_editor existe (F1).
--
-- O que entra:
--   * 3 colunas de auditoria de desconciliacao em extratos_bancarios:
--       desconciliado_por uuid, desconciliado_em timestamptz,
--       motivo_desconciliacao text   (ADD COLUMN IF NOT EXISTS; aditivo)
--   * desconciliar_extrato(p_extrato_id uuid, p_motivo text):
--       conciliado -> pendente; limpa financa_id/conciliado_*; grava auditoria
--       de desconciliacao (motivo obrigatorio). Reverte o lancamento para
--       'aberto' e remove o identificador_externo SE for o fitid desta linha.
--   * reabrir_extrato(p_extrato_id uuid):
--       ignorado -> pendente; limpa ignorado_*/motivo.
--   Ambas SECURITY INVOKER; REVOKE PUBLIC + GRANT authenticated.
--
-- Observacao: nao revertemos a DATA do lancamento (a original nao e guardada);
-- so o status volta a 'aberto'. O usuario ajusta manualmente se necessario.
-- ===========================================================================

-- PRE-CHECK (comentado):
-- SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
--  WHERE n.nspname='public' AND p.proname='conciliar_extrato'; -- esperado 1 (5A)

BEGIN;

-- 1. Colunas de auditoria (aditivo, idempotente)
ALTER TABLE public.extratos_bancarios
  ADD COLUMN IF NOT EXISTS desconciliado_por     uuid,
  ADD COLUMN IF NOT EXISTS desconciliado_em      timestamptz,
  ADD COLUMN IF NOT EXISTS motivo_desconciliacao text;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'extratos_desconciliado_por_fk'
  ) THEN
    ALTER TABLE public.extratos_bancarios
      ADD CONSTRAINT extratos_desconciliado_por_fk
      FOREIGN KEY (desconciliado_por) REFERENCES auth.users(id) ON DELETE SET NULL;
  END IF;
END $$;

-- 2. desconciliar_extrato
CREATE OR REPLACE FUNCTION public.desconciliar_extrato(
  p_extrato_id uuid,
  p_motivo     text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, auth
AS $$
DECLARE
  v_status  text;
  v_financa uuid;
  v_fitid   text;
BEGIN
  IF NOT public.is_financeiro_editor() THEN
    RAISE EXCEPTION 'Sem permissao para desconciliar.' USING ERRCODE = '42501';
  END IF;
  IF COALESCE(NULLIF(p_motivo, ''), '') = '' THEN
    RAISE EXCEPTION 'Motivo obrigatorio para desconciliar.' USING ERRCODE = '22023';
  END IF;

  SELECT status_conciliacao, financa_id, fitid
    INTO v_status, v_financa, v_fitid
    FROM public.extratos_bancarios
   WHERE id = p_extrato_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Linha de extrato inexistente: %', p_extrato_id USING ERRCODE = '23503';
  END IF;
  IF v_status <> 'conciliado' THEN
    RAISE EXCEPTION 'Esta linha nao esta conciliada (status atual: %).', v_status
      USING ERRCODE = '22023';
  END IF;

  UPDATE public.extratos_bancarios
     SET status_conciliacao    = 'pendente',
         financa_id            = NULL,
         conciliado_por        = NULL,
         conciliado_em         = NULL,
         desconciliado_por     = auth.uid(),
         desconciliado_em      = now(),
         motivo_desconciliacao = p_motivo
   WHERE id = p_extrato_id;

  IF v_financa IS NOT NULL THEN
    UPDATE public.financas
       SET status = 'aberto',
           identificador_externo = CASE
             WHEN identificador_externo = v_fitid THEN NULL
             ELSE identificador_externo END
     WHERE id = v_financa;
  END IF;

  RETURN jsonb_build_object('extrato_id', p_extrato_id, 'status', 'pendente');
END;
$$;

COMMENT ON FUNCTION public.desconciliar_extrato(uuid, text) IS
  'Fase 7 - desfaz a conciliacao de uma linha (volta a pendente), grava '
  'auditoria com motivo e reverte o lancamento para aberto.';

REVOKE EXECUTE ON FUNCTION public.desconciliar_extrato(uuid, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.desconciliar_extrato(uuid, text) TO authenticated;

-- 3. reabrir_extrato (desfaz "ignorar")
CREATE OR REPLACE FUNCTION public.reabrir_extrato(
  p_extrato_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, auth
AS $$
DECLARE
  v_status text;
BEGIN
  IF NOT public.is_financeiro_editor() THEN
    RAISE EXCEPTION 'Sem permissao para reabrir.' USING ERRCODE = '42501';
  END IF;

  SELECT status_conciliacao INTO v_status
    FROM public.extratos_bancarios
   WHERE id = p_extrato_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Linha de extrato inexistente: %', p_extrato_id USING ERRCODE = '23503';
  END IF;
  IF v_status <> 'ignorado' THEN
    RAISE EXCEPTION 'Esta linha nao esta ignorada (status atual: %).', v_status
      USING ERRCODE = '22023';
  END IF;

  UPDATE public.extratos_bancarios
     SET status_conciliacao = 'pendente',
         ignorado_por       = NULL,
         ignorado_em        = NULL,
         motivo_ignorado    = NULL
   WHERE id = p_extrato_id;

  RETURN jsonb_build_object('extrato_id', p_extrato_id, 'status', 'pendente');
END;
$$;

COMMENT ON FUNCTION public.reabrir_extrato(uuid) IS
  'Fase 7 - desfaz o "ignorar" de uma linha, voltando-a a pendente.';

REVOKE EXECUTE ON FUNCTION public.reabrir_extrato(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.reabrir_extrato(uuid) TO authenticated;

COMMIT;

-- ===========================================================================
-- POS-CHECK (comentado)
-- ===========================================================================
-- SELECT column_name FROM information_schema.columns
--  WHERE table_schema='public' AND table_name='extratos_bancarios'
--    AND column_name IN ('desconciliado_por','desconciliado_em','motivo_desconciliacao');
-- -- Esperado: 3 linhas
-- SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
--  WHERE n.nspname='public' AND p.proname IN ('desconciliar_extrato','reabrir_extrato');
-- -- Esperado: 2 linhas
--
-- ROLLBACK:
--   BEGIN;
--   DROP FUNCTION IF EXISTS public.desconciliar_extrato(uuid, text);
--   DROP FUNCTION IF EXISTS public.reabrir_extrato(uuid);
--   ALTER TABLE public.extratos_bancarios
--     DROP COLUMN IF EXISTS desconciliado_por,
--     DROP COLUMN IF EXISTS desconciliado_em,
--     DROP COLUMN IF EXISTS motivo_desconciliacao;
--   COMMIT;
-- ===========================================================================
