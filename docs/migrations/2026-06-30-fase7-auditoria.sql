-- ===========================================================================
-- MIGRATION - FASE 7 (fatia: AUDITORIA AMPLIADA)
-- Data:   2026-06-30
-- Plano:  docs/plano-financeiro-contas-conciliacao.md  (Fase 7)
-- Depende de: Fase 1 (contas_bancarias/categorias_financeiras + touch triggers),
--   financas (base).
-- Status: AGUARDANDO REVISAO - NAO APLICAR SEM BACKUP. Aditivo: adiciona
--   colunas de auditoria e ajusta triggers. NAO altera dados existentes
--   (linhas antigas ficam com criado_por/em = NULL = "desconhecido").
--
-- O que entra (quem criou / quem alterou):
--   * financas: +criado_por, +criado_em, +alterado_por, +alterado_em
--       - defaults: criado_por=auth.uid(), criado_em=now()
--       - trigger BEFORE UPDATE seta alterado_por/alterado_em
--   * contas_bancarias / categorias_financeiras: ja tinham criado_em/alterado_em;
--       +criado_por (default auth.uid()) e +alterado_por; os touch triggers da
--       Fase 1 passam a setar alterado_por tambem.
-- ===========================================================================

BEGIN;

-- Funcao FK helper reutilizada em bloco DO (auth.users, ON DELETE SET NULL)
-- (feita inline por tabela abaixo)

-- ---------------------------------------------------------------------------
-- 1. financas
-- ---------------------------------------------------------------------------
ALTER TABLE public.financas
  ADD COLUMN IF NOT EXISTS criado_por   uuid,
  ADD COLUMN IF NOT EXISTS criado_em    timestamptz,
  ADD COLUMN IF NOT EXISTS alterado_por uuid,
  ADD COLUMN IF NOT EXISTS alterado_em  timestamptz;

ALTER TABLE public.financas ALTER COLUMN criado_em  SET DEFAULT now();
ALTER TABLE public.financas ALTER COLUMN criado_por SET DEFAULT auth.uid();

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'financas_criado_por_fk') THEN
    ALTER TABLE public.financas ADD CONSTRAINT financas_criado_por_fk
      FOREIGN KEY (criado_por) REFERENCES auth.users(id) ON DELETE SET NULL;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'financas_alterado_por_fk') THEN
    ALTER TABLE public.financas ADD CONSTRAINT financas_alterado_por_fk
      FOREIGN KEY (alterado_por) REFERENCES auth.users(id) ON DELETE SET NULL;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public._tg_financas_audit()
RETURNS trigger LANGUAGE plpgsql SET search_path = public, auth AS $$
BEGIN
  NEW.alterado_por := auth.uid();
  NEW.alterado_em  := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS financas_audit_touch ON public.financas;
CREATE TRIGGER financas_audit_touch
  BEFORE UPDATE ON public.financas
  FOR EACH ROW EXECUTE FUNCTION public._tg_financas_audit();

-- ---------------------------------------------------------------------------
-- 2. contas_bancarias (ja tem criado_em/alterado_em)
-- ---------------------------------------------------------------------------
ALTER TABLE public.contas_bancarias
  ADD COLUMN IF NOT EXISTS criado_por   uuid,
  ADD COLUMN IF NOT EXISTS alterado_por uuid;
ALTER TABLE public.contas_bancarias ALTER COLUMN criado_por SET DEFAULT auth.uid();

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'contas_criado_por_fk') THEN
    ALTER TABLE public.contas_bancarias ADD CONSTRAINT contas_criado_por_fk
      FOREIGN KEY (criado_por) REFERENCES auth.users(id) ON DELETE SET NULL;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'contas_alterado_por_fk') THEN
    ALTER TABLE public.contas_bancarias ADD CONSTRAINT contas_alterado_por_fk
      FOREIGN KEY (alterado_por) REFERENCES auth.users(id) ON DELETE SET NULL;
  END IF;
END $$;

-- Estende o touch da Fase 1 para tambem gravar alterado_por
CREATE OR REPLACE FUNCTION public._tg_contas_bancarias_touch()
RETURNS trigger LANGUAGE plpgsql SET search_path = public, auth AS $$
BEGIN
  NEW.alterado_em  := now();
  NEW.alterado_por := auth.uid();
  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- 3. categorias_financeiras (ja tem criado_em/alterado_em)
-- ---------------------------------------------------------------------------
ALTER TABLE public.categorias_financeiras
  ADD COLUMN IF NOT EXISTS criado_por   uuid,
  ADD COLUMN IF NOT EXISTS alterado_por uuid;
ALTER TABLE public.categorias_financeiras ALTER COLUMN criado_por SET DEFAULT auth.uid();

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'categorias_criado_por_fk') THEN
    ALTER TABLE public.categorias_financeiras ADD CONSTRAINT categorias_criado_por_fk
      FOREIGN KEY (criado_por) REFERENCES auth.users(id) ON DELETE SET NULL;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'categorias_alterado_por_fk') THEN
    ALTER TABLE public.categorias_financeiras ADD CONSTRAINT categorias_alterado_por_fk
      FOREIGN KEY (alterado_por) REFERENCES auth.users(id) ON DELETE SET NULL;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public._tg_categorias_financeiras_touch()
RETURNS trigger LANGUAGE plpgsql SET search_path = public, auth AS $$
BEGIN
  NEW.alterado_em  := now();
  NEW.alterado_por := auth.uid();
  RETURN NEW;
END;
$$;

COMMIT;

-- ===========================================================================
-- POS-CHECK (comentado)
-- ===========================================================================
-- SELECT table_name, column_name FROM information_schema.columns
--  WHERE table_schema='public'
--    AND table_name IN ('financas','contas_bancarias','categorias_financeiras')
--    AND column_name IN ('criado_por','criado_em','alterado_por','alterado_em')
--  ORDER BY table_name, column_name;
-- -- Esperado: financas 4; contas 4; categorias 4 (criado_em/alterado_em ja existiam)
--
-- Smoke: inserir 1 financa nova -> criado_por/criado_em preenchidos;
--        editar -> alterado_por/alterado_em preenchidos.
--
-- ===========================================================================
-- ROLLBACK:
--   BEGIN;
--   DROP TRIGGER IF EXISTS financas_audit_touch ON public.financas;
--   DROP FUNCTION IF EXISTS public._tg_financas_audit();
--   ALTER TABLE public.financas
--     DROP COLUMN IF EXISTS criado_por, DROP COLUMN IF EXISTS criado_em,
--     DROP COLUMN IF EXISTS alterado_por, DROP COLUMN IF EXISTS alterado_em;
--   ALTER TABLE public.contas_bancarias
--     DROP COLUMN IF EXISTS criado_por, DROP COLUMN IF EXISTS alterado_por;
--   ALTER TABLE public.categorias_financeiras
--     DROP COLUMN IF EXISTS criado_por, DROP COLUMN IF EXISTS alterado_por;
--   -- (as funcoes touch continuam setando alterado_por; sem a coluna daria erro,
--   --  entao reaplicar a versao Fase 1 dos touch se fizer rollback das colunas.)
--   COMMIT;
-- ===========================================================================
