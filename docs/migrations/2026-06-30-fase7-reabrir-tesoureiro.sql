-- ===========================================================================
-- MIGRATION - FASE 7 (ajuste): reabrir_mes passa a permitir TESOUREIRO
-- Data:   2026-06-30
-- Depende de: 2026-06-30-fase7-fechamento-mes.sql (ja aplicada).
-- Motivo: decisao do usuario — em loja pequena o Tesoureiro e a autoridade
--   financeira; reabrir mes fica disponivel a Admin OU Tesoureiro
--   (is_financeiro_editor), mantendo a confirmacao no cliente.
-- Aplicar: editor vazio -> colar -> Run. Nao toca em dados.
-- ===========================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.reabrir_mes(p_ano int, p_mes int)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth AS $$
BEGIN
  IF NOT public.is_financeiro_editor() THEN
    RAISE EXCEPTION 'Sem permissao para reabrir mes.' USING ERRCODE = '42501';
  END IF;
  DELETE FROM public.fechamentos_mensais WHERE ano = p_ano AND mes = p_mes;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O mes %/% nao estava fechado.', lpad(p_mes::text, 2, '0'), p_ano
      USING ERRCODE = '22023';
  END IF;
  RETURN jsonb_build_object('ano', p_ano, 'mes', p_mes, 'status', 'reaberto');
END;
$$;

REVOKE EXECUTE ON FUNCTION public.reabrir_mes(int,int) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.reabrir_mes(int,int) TO authenticated;

COMMIT;

-- ROLLBACK (volta a exigir Admin): reaplicar a versao com is_financeiro_admin
-- da migration 2026-06-30-fase7-fechamento-mes.sql.
