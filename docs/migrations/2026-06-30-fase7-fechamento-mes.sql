-- ===========================================================================
-- MIGRATION - FASE 7 (fatia: FECHAMENTO DE MES no servidor)
-- Data:   2026-06-30
-- Plano:  docs/plano-financeiro-contas-conciliacao.md  (Fase 7)
-- Depende de: Fase 1 (is_financeiro_editor, usuarios/membros), 4A (extratos).
-- Status: AGUARDANDO REVISAO - NAO APLICAR SEM BACKUP. Esta migration cria
--   GATILHOS que BLOQUEIAM escrita em meses fechados (financas e import OFX).
--   Estado inicial seguro: tabela vazia => nenhum mes fechado => nada bloqueado.
--
-- O que entra:
--   * is_financeiro_admin()  -> true se admin (usuarios.role/perfil='admin')
--   * Tabela fechamentos_mensais (ano, mes, saldos, fechado_por/_em), RLS.
--   * Trigger trg_bloqueia_mes_fechado() (SECURITY DEFINER) em:
--       - financas         BEFORE INSERT OR UPDATE
--       - extratos_bancarios BEFORE INSERT
--     Recusa se a data cair num (ano,mes) presente em fechamentos_mensais.
--   * RPC fechar_mes(...)   (editor) e reabrir_mes(ano,mes) (ADMIN, definer).
-- ===========================================================================

BEGIN;

-- 1. Helper: admin financeiro (espelha o trecho admin de is_financeiro_editor)
CREATE OR REPLACE FUNCTION public.is_financeiro_admin()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, auth AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.usuarios u
     WHERE u.auth_user_id = auth.uid()
       AND u.ativo = true
       AND (u.role = 'admin' OR u.perfil = 'admin')
  );
$$;
REVOKE EXECUTE ON FUNCTION public.is_financeiro_admin() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.is_financeiro_admin() TO authenticated;

-- 2. Tabela de fechamentos
CREATE TABLE IF NOT EXISTS public.fechamentos_mensais (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ano           int  NOT NULL,
  mes           int  NOT NULL,
  observacao    text NULL,
  saldo_inicial numeric(14,2) NULL,
  receitas      numeric(14,2) NULL,
  despesas      numeric(14,2) NULL,
  saldo_final   numeric(14,2) NULL,
  fechado_por   uuid NOT NULL DEFAULT auth.uid(),
  fechado_em    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fechamentos_mes_ck     CHECK (mes BETWEEN 1 AND 12),
  CONSTRAINT fechamentos_ano_ck     CHECK (ano BETWEEN 2000 AND 2100),
  CONSTRAINT fechamentos_ano_mes_uk UNIQUE (ano, mes)
);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fechamentos_fechado_por_fk') THEN
    ALTER TABLE public.fechamentos_mensais
      ADD CONSTRAINT fechamentos_fechado_por_fk
      FOREIGN KEY (fechado_por) REFERENCES auth.users(id) ON DELETE RESTRICT;
  END IF;
END $$;

ALTER TABLE public.fechamentos_mensais ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS fechamentos_select ON public.fechamentos_mensais;
DROP POLICY IF EXISTS fechamentos_insert ON public.fechamentos_mensais;
CREATE POLICY fechamentos_select ON public.fechamentos_mensais FOR SELECT
  USING (public.is_financeiro_editor());
CREATE POLICY fechamentos_insert ON public.fechamentos_mensais FOR INSERT
  WITH CHECK (public.is_financeiro_editor());
-- UPDATE/DELETE: sem policy. DELETE acontece so via reabrir_mes (SECURITY DEFINER).

-- 3. Gatilho que bloqueia escrita em mes fechado
CREATE OR REPLACE FUNCTION public.trg_bloqueia_mes_fechado()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth AS $$
DECLARE
  v_ano int;
  v_mes int;
BEGIN
  -- Bloqueia se a NOVA data cair em mes fechado (insert ou update)
  IF NEW.data IS NOT NULL THEN
    v_ano := EXTRACT(YEAR FROM NEW.data);
    v_mes := EXTRACT(MONTH FROM NEW.data);
    IF EXISTS (SELECT 1 FROM public.fechamentos_mensais WHERE ano = v_ano AND mes = v_mes) THEN
      RAISE EXCEPTION 'O mes %/% esta fechado. Reabra o mes (Admin) para alterar.',
        lpad(v_mes::text, 2, '0'), v_ano USING ERRCODE = '23514';
    END IF;
  END IF;
  -- Em UPDATE, tambem bloqueia mexer num registro que JA esta num mes fechado
  IF TG_OP = 'UPDATE' AND OLD.data IS NOT NULL THEN
    v_ano := EXTRACT(YEAR FROM OLD.data);
    v_mes := EXTRACT(MONTH FROM OLD.data);
    IF EXISTS (SELECT 1 FROM public.fechamentos_mensais WHERE ano = v_ano AND mes = v_mes) THEN
      RAISE EXCEPTION 'O mes %/% esta fechado. Reabra o mes (Admin) para alterar.',
        lpad(v_mes::text, 2, '0'), v_ano USING ERRCODE = '23514';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS bloqueia_mes_fechado_financas ON public.financas;
CREATE TRIGGER bloqueia_mes_fechado_financas
  BEFORE INSERT OR UPDATE ON public.financas
  FOR EACH ROW EXECUTE FUNCTION public.trg_bloqueia_mes_fechado();

DROP TRIGGER IF EXISTS bloqueia_mes_fechado_extratos ON public.extratos_bancarios;
CREATE TRIGGER bloqueia_mes_fechado_extratos
  BEFORE INSERT ON public.extratos_bancarios
  FOR EACH ROW EXECUTE FUNCTION public.trg_bloqueia_mes_fechado();

-- 4. RPC fechar_mes (editor)
CREATE OR REPLACE FUNCTION public.fechar_mes(
  p_ano int, p_mes int, p_observacao text,
  p_saldo_inicial numeric, p_receitas numeric, p_despesas numeric, p_saldo_final numeric
) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public, auth AS $$
DECLARE v_id uuid;
BEGIN
  IF NOT public.is_financeiro_editor() THEN
    RAISE EXCEPTION 'Sem permissao para fechar mes.' USING ERRCODE = '42501';
  END IF;
  IF p_mes < 1 OR p_mes > 12 THEN
    RAISE EXCEPTION 'Mes invalido: %', p_mes USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM public.fechamentos_mensais WHERE ano = p_ano AND mes = p_mes) THEN
    RAISE EXCEPTION 'O mes %/% ja esta fechado.', lpad(p_mes::text, 2, '0'), p_ano
      USING ERRCODE = '23505';
  END IF;
  INSERT INTO public.fechamentos_mensais
    (ano, mes, observacao, saldo_inicial, receitas, despesas, saldo_final)
  VALUES
    (p_ano, p_mes, NULLIF(p_observacao, ''), p_saldo_inicial, p_receitas, p_despesas, p_saldo_final)
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('id', v_id, 'ano', p_ano, 'mes', p_mes, 'status', 'fechado');
END;
$$;
REVOKE EXECUTE ON FUNCTION public.fechar_mes(int,int,text,numeric,numeric,numeric,numeric) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fechar_mes(int,int,text,numeric,numeric,numeric,numeric) TO authenticated;

-- 5. RPC reabrir_mes (ADMIN; SECURITY DEFINER para apagar bypassando RLS)
CREATE OR REPLACE FUNCTION public.reabrir_mes(p_ano int, p_mes int)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth AS $$
BEGIN
  IF NOT public.is_financeiro_admin() THEN
    RAISE EXCEPTION 'Apenas o Administrador pode reabrir um mes.' USING ERRCODE = '42501';
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

-- ===========================================================================
-- POS-CHECK (comentado)
-- ===========================================================================
-- SELECT table_name FROM information_schema.tables
--  WHERE table_schema='public' AND table_name='fechamentos_mensais';            -- 1
-- SELECT tgname FROM pg_trigger WHERE tgname LIKE 'bloqueia_mes_fechado%';      -- 2
-- SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
--  WHERE n.nspname='public' AND p.proname IN ('fechar_mes','reabrir_mes','is_financeiro_admin'); -- 3
--
-- Smoke test (com ROLLBACK):
-- BEGIN;
--   SELECT public.fechar_mes(2099, 1, 'teste', 0,0,0,0);
--   -- tentar inserir financa em 2099-01-15 -> deve falhar (23514)
--   SELECT public.reabrir_mes(2099, 1);
-- ROLLBACK;
--
-- ===========================================================================
-- ROLLBACK:
--   BEGIN;
--   DROP TRIGGER IF EXISTS bloqueia_mes_fechado_financas ON public.financas;
--   DROP TRIGGER IF EXISTS bloqueia_mes_fechado_extratos ON public.extratos_bancarios;
--   DROP FUNCTION IF EXISTS public.trg_bloqueia_mes_fechado();
--   DROP FUNCTION IF EXISTS public.fechar_mes(int,int,text,numeric,numeric,numeric,numeric);
--   DROP FUNCTION IF EXISTS public.reabrir_mes(int,int);
--   DROP TABLE IF EXISTS public.fechamentos_mensais;
--   DROP FUNCTION IF EXISTS public.is_financeiro_admin();
--   COMMIT;
-- ===========================================================================
