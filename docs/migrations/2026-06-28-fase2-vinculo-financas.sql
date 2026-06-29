-- ===========================================================================
-- MIGRATION - FASE 2 do plano "Financeiro: Contas e Conciliacao"
-- Data:   2026-06-28
-- Plano:  docs/plano-financeiro-contas-conciliacao.md
-- Status: AGUARDANDO REVISAO - NAO APLICAR SEM:
--   1) Snapshot/backup do banco (Supabase Dashboard > Database > Backups
--      > Create on-demand backup);
--   2) Confirmacao de que a migration da Fase 1 (2026-06-27-fase1-...)
--      ja foi aplicada e que as tabelas contas_bancarias e
--      categorias_financeiras existem;
--   3) Execucao em ambiente de dev/staging primeiro, se houver.
--
-- O que entra:
--   * Seeds das 10 categorias legadas (mensalidade, joia, manutencao,
--     aluguel, mutua, agape, material, evento, outros + tronco ja
--     existente desde a Fase 1). Idempotente via ON CONFLICT.
--   * ALTER TABLE financas: 5 colunas novas, todas NULLABLE
--     - categoria_id        uuid FK -> categorias_financeiras(id)
--     - conta_bancaria_id   uuid FK -> contas_bancarias(id)
--     - forma_pagamento     text   (uso futuro: pix/ted/dinheiro/etc)
--     - identificador_externo text (uso futuro: FITID/PIX end-to-end-id)
--     - data_vencimento     date   (uso futuro: separar vencimento de pagamento)
--   * Backfill conservador: preenche categoria_id apenas onde o slug
--     em financas.categoria casa com algum categorias_financeiras.slug,
--     e somente onde categoria_id ainda esta NULL.
--   * Indices em financas(categoria_id) e financas(conta_bancaria_id).
--
-- O que NAO entra:
--   * Mudanca em policies RLS de financas (escopo do TD-2).
--   * Forcar categoria_id NOT NULL (caso haja categoria nao mapeada).
--   * Remocao do campo financas.categoria (texto) - permanece como
--     fallback ate auditoria completa.
--   * Uso efetivo de forma_pagamento / identificador_externo / data_vencimento
--     no fluxo manual (entra na Fase 3+ junto com OFX).
-- ===========================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. SEEDS DAS CATEGORIAS LEGADAS
-- Mapeia o que hoje vive em localStorage.cats_fin para a nova tabela.
-- Acentuacao preservada nos nomes (exibidos na UI).
-- ---------------------------------------------------------------------------

INSERT INTO public.categorias_financeiras
       (slug,          nome,                  natureza,      tipo,      impacta_resultado, sistema, ordem)
VALUES ('mensalidade', 'Mensalidade',         'operacional', 'receita', true,              true,    100),  -- usada pelo "Lancar Mensalidades do Mes"
       ('joia',        'Joia de Iniciação',   'operacional', 'receita', true,              false,   110),
       ('manutencao',  'Manutenção',          'operacional', 'despesa', true,              false,   120),
       ('aluguel',     'Aluguel',             'operacional', 'despesa', true,              false,   130),
       ('mutua',       'Mútua',               'operacional', 'ambos',   true,              false,   140),
       ('agape',       'Ágape',               'operacional', 'ambos',   true,              false,   150),
       ('material',    'Material',            'operacional', 'despesa', true,              false,   160),
       ('evento',      'Evento',              'operacional', 'ambos',   true,              false,   170),
       ('outros',      'Outros',              'operacional', 'ambos',   true,              true,    900)   -- fallback generico
ON CONFLICT (slug) DO UPDATE
SET nome               = EXCLUDED.nome,
    natureza           = EXCLUDED.natureza,
    tipo               = EXCLUDED.tipo,
    impacta_resultado  = EXCLUDED.impacta_resultado,
    -- sistema: preserva se ja foi promovido; nunca desce de true para false
    sistema            = (public.categorias_financeiras.sistema OR EXCLUDED.sistema)
WHERE public.categorias_financeiras.slug = EXCLUDED.slug;

-- Observacao: o ON CONFLICT acima nao re-define ordem/ativo, preservando
-- escolhas do Tesoureiro. Sistema soh sobe (false -> true), nunca desce.

-- ---------------------------------------------------------------------------
-- 2. ADD COLUMNs em financas (todas NULLABLE, sem default destrutivo)
-- ---------------------------------------------------------------------------

ALTER TABLE public.financas
  ADD COLUMN IF NOT EXISTS categoria_id          uuid NULL,
  ADD COLUMN IF NOT EXISTS conta_bancaria_id     uuid NULL,
  ADD COLUMN IF NOT EXISTS forma_pagamento       text NULL,
  ADD COLUMN IF NOT EXISTS identificador_externo text NULL,
  ADD COLUMN IF NOT EXISTS data_vencimento       date NULL;

-- FKs em separado para poder usar IF NOT EXISTS no ADD COLUMN.
-- ON DELETE SET NULL: nao bloqueia delete da conta/categoria (na pratica,
-- a Fase 1 ja proibe DELETE por policy, mas isso protege contra hard delete
-- via SQL direto / service role).

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'financas_categoria_id_fk'
  ) THEN
    ALTER TABLE public.financas
      ADD CONSTRAINT financas_categoria_id_fk
      FOREIGN KEY (categoria_id) REFERENCES public.categorias_financeiras(id)
      ON DELETE SET NULL;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'financas_conta_bancaria_id_fk'
  ) THEN
    ALTER TABLE public.financas
      ADD CONSTRAINT financas_conta_bancaria_id_fk
      FOREIGN KEY (conta_bancaria_id) REFERENCES public.contas_bancarias(id)
      ON DELETE SET NULL;
  END IF;
END $$;

COMMENT ON COLUMN public.financas.categoria_id IS
  'FK opcional para categorias_financeiras. Conviva com financas.categoria (texto) durante a transicao.';
COMMENT ON COLUMN public.financas.conta_bancaria_id IS
  'FK opcional para contas_bancarias. NULL = lancamento sem conta vinculada (caso comum em lancamentos antigos).';
COMMENT ON COLUMN public.financas.forma_pagamento IS
  'pix | ted | dinheiro | boleto | cartao | outro - uso futuro (Fase 3+).';
COMMENT ON COLUMN public.financas.identificador_externo IS
  'FITID ou end-to-end-id do PIX quando conciliado com extrato OFX. Uso futuro (Fase 3+).';
COMMENT ON COLUMN public.financas.data_vencimento IS
  'Quando o lancamento era devido. financas.data continua sendo a data efetiva. NULL em lancamentos antigos.';

-- ---------------------------------------------------------------------------
-- 3. BACKFILL CONSERVADOR
-- Preenche categoria_id apenas onde o slug bate exatamente.
-- Categorias antigas sem correspondencia ficam com categoria_id NULL
-- e mantem o texto em financas.categoria (sem prejuizo de calculos).
-- ---------------------------------------------------------------------------

UPDATE public.financas f
   SET categoria_id = c.id
  FROM public.categorias_financeiras c
 WHERE c.slug = f.categoria
   AND f.categoria_id IS NULL;

-- Sem backfill de conta_bancaria_id - lancamentos antigos nao tem como
-- adivinhar a conta. Fica NULL ate o Tesoureiro editar individualmente
-- (ou ate a Fase 4 de conciliacao preencher quando casar com um extrato).

-- ---------------------------------------------------------------------------
-- 4. INDICES
-- ---------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS financas_categoria_id_idx
  ON public.financas(categoria_id);

CREATE INDEX IF NOT EXISTS financas_conta_bancaria_id_idx
  ON public.financas(conta_bancaria_id);

-- ---------------------------------------------------------------------------
-- 5. VERIFICACAO (read-only) - rode separadamente apos o COMMIT
-- ---------------------------------------------------------------------------
-- -- Total de categorias hoje cadastradas:
-- SELECT slug, nome, tipo, sistema, ativo, ordem
--   FROM public.categorias_financeiras
--  ORDER BY ordem, slug;
--
-- -- Quantos lancamentos foram vinculados ao backfill:
-- SELECT count(*) AS total_financas,
--        count(categoria_id) AS com_categoria_id,
--        count(*) - count(categoria_id) AS sem_categoria_id
--   FROM public.financas;
--
-- -- Lancamentos com categoria nao mapeada (que vao ficar com categoria_id NULL):
-- SELECT DISTINCT categoria, count(*) AS n
--   FROM public.financas f
--  WHERE f.categoria_id IS NULL
--    AND f.categoria IS NOT NULL
--  GROUP BY categoria
--  ORDER BY n DESC;
--
-- -- Confirmar as colunas novas:
-- SELECT column_name, data_type, is_nullable
--   FROM information_schema.columns
--  WHERE table_schema = 'public' AND table_name = 'financas'
--    AND column_name IN ('categoria_id','conta_bancaria_id','forma_pagamento','identificador_externo','data_vencimento')
--  ORDER BY column_name;
--
-- -- Confirmar FKs:
-- SELECT conname, pg_get_constraintdef(oid)
--   FROM pg_constraint
--  WHERE conrelid = 'public.financas'::regclass
--    AND contype = 'f'
--    AND conname LIKE 'financas_%';

COMMIT;

-- ===========================================================================
-- ROLLBACK (se necessario, dentro da mesma janela do SQL Editor):
--   BEGIN;
--   -- 1. Remover FKs primeiro (caso CASCADE nao remova)
--   ALTER TABLE public.financas DROP CONSTRAINT IF EXISTS financas_categoria_id_fk;
--   ALTER TABLE public.financas DROP CONSTRAINT IF EXISTS financas_conta_bancaria_id_fk;
--   -- 2. Remover colunas (CUIDADO: destroi categoria_id/conta_bancaria_id ja preenchidos)
--   ALTER TABLE public.financas
--     DROP COLUMN IF EXISTS categoria_id,
--     DROP COLUMN IF EXISTS conta_bancaria_id,
--     DROP COLUMN IF EXISTS forma_pagamento,
--     DROP COLUMN IF EXISTS identificador_externo,
--     DROP COLUMN IF EXISTS data_vencimento;
--   -- 3. Indices caem junto com as colunas (CASCADE implicito)
--   -- 4. Seeds das categorias legadas NAO sao removidos - se quiser limpar,
--   --    rode DELETE manualmente apenas para slugs especificos. Lancamentos
--   --    em financas.categoria (texto) ja conviviam com esses slugs.
--   COMMIT;
-- ===========================================================================
