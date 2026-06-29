-- ===========================================================================
-- MIGRATION - FASE 4A do plano "Financeiro: Contas e Conciliacao"
-- Data:   2026-06-29
-- Plano:  docs/plano-financeiro-contas-conciliacao.md  (Fase 4)
-- Status: AGUARDANDO REVISAO - NAO APLICAR SEM:
--   1) Snapshot/backup do banco (Supabase Dashboard > Database > Backups
--      > Create on-demand backup);
--   2) Confirmacao de que as migrations da Fase 1 e Fase 2 ja foram aplicadas
--      e que as tabelas contas_bancarias, categorias_financeiras e financas
--      existem com as colunas esperadas;
--   3) Confirmacao de que a funcao public.is_financeiro_editor() existe
--      (criada na Fase 1) - as policies RLS dependem dela.
--
-- O que entra:
--   * Tabela importacoes_ofx     (cabecalho da importacao)
--   * Tabela extratos_bancarios  (linhas brutas vindas do OFX)
--   * RLS habilitada + policies SELECT/INSERT/UPDATE (sem DELETE) para
--     Admin/Tesoureiro via public.is_financeiro_editor()
--   * Indices UNIQUE parciais para dedup (fitid ou hash_linha)
--   * Indices operacionais (data, pendentes, importacao, financa)
--
-- O que NAO entra:
--   * Alteracao em financas (nenhuma)
--   * RPC importar_ofx_extrato     -> Fase 4C (sera nova migration)
--   * RPC cancelar_importacao_ofx  -> Fase 5+ (se necessario)
--   * Backfill de dados            -> nao se aplica (tabelas novas)
--   * CHECKs semanticos amarrando status_conciliacao a financa_id/ignorado_em
--     -> intencionalmente fora desta fase (decisao do plano)
--   * Coluna identificador_externo em extratos_bancarios
--     -> nao criada; usar fitid
--
-- Sobre auth.uid() como DEFAULT em criado_por:
--   * Funciona quando a insercao vem de sessao autenticada (caso operacional
--     via PostgREST/RPC).
--   * Quando rodar INSERT manual no SQL Editor com service_role, auth.uid()
--     retorna NULL e o NOT NULL bloqueia. Nesse caso, providencie criado_por
--     manualmente (uuid de um auth.user real).
-- ===========================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- PRE-CHECK (rode separadamente antes do BEGIN; comentado para nao executar
-- dentro da transacao)
-- ---------------------------------------------------------------------------
-- -- Tabelas das fases anteriores existem?
-- SELECT table_name FROM information_schema.tables
--  WHERE table_schema='public'
--    AND table_name IN ('contas_bancarias','categorias_financeiras','financas');
-- -- Esperado: 3 linhas
--
-- -- Funcao helper de RLS existe?
-- SELECT proname FROM pg_proc p
--   JOIN pg_namespace n ON n.oid = p.pronamespace
--  WHERE n.nspname='public' AND p.proname='is_financeiro_editor';
-- -- Esperado: 1 linha
--
-- -- Tabelas desta migration NAO existem ainda?
-- SELECT table_name FROM information_schema.tables
--  WHERE table_schema='public'
--    AND table_name IN ('importacoes_ofx','extratos_bancarios');
-- -- Esperado: 0 linhas
--
-- -- Baseline de financas (deve continuar igual apos a migration)
-- SELECT count(*) AS total_financas FROM public.financas;

-- ---------------------------------------------------------------------------
-- 1. TABELA importacoes_ofx
-- Cabecalho/metadados de cada arquivo OFX importado. Uma linha por importacao.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.importacoes_ofx (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conta_bancaria_id      uuid NOT NULL,
  arquivo_nome           text NOT NULL,
  arquivo_hash           text NOT NULL,
  arquivo_tamanho_bytes  int  NOT NULL,
  ofx_versao             text NULL,
  bankid_ofx             text NULL,
  acctid_ofx             text NULL,
  periodo_inicio         date NOT NULL,
  periodo_fim            date NOT NULL,
  saldo_final            numeric(14,2) NULL,
  saldo_final_data       date NULL,
  total_linhas           int  NOT NULL DEFAULT 0,
  total_inseridas        int  NOT NULL DEFAULT 0,
  total_duplicadas       int  NOT NULL DEFAULT 0,
  total_erros            int  NOT NULL DEFAULT 0,
  observacao             text NULL,
  criado_por             uuid NOT NULL DEFAULT auth.uid(),
  criado_em              timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT importacoes_ofx_tamanho_ck  CHECK (arquivo_tamanho_bytes > 0),
  CONSTRAINT importacoes_ofx_periodo_ck  CHECK (periodo_fim >= periodo_inicio),
  CONSTRAINT importacoes_ofx_linhas_ck   CHECK (total_linhas     >= 0),
  CONSTRAINT importacoes_ofx_inserid_ck  CHECK (total_inseridas  >= 0),
  CONSTRAINT importacoes_ofx_duplic_ck   CHECK (total_duplicadas >= 0),
  CONSTRAINT importacoes_ofx_erros_ck    CHECK (total_erros      >= 0),
  CONSTRAINT importacoes_ofx_totais_ck   CHECK (
    total_inseridas + total_duplicadas + total_erros = total_linhas
  ),
  CONSTRAINT importacoes_ofx_hash_len_ck CHECK (length(arquivo_hash) = 64)
);

-- FKs em bloco DO para permitir reexecucao sem erro
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'importacoes_ofx_conta_fk'
  ) THEN
    ALTER TABLE public.importacoes_ofx
      ADD CONSTRAINT importacoes_ofx_conta_fk
      FOREIGN KEY (conta_bancaria_id) REFERENCES public.contas_bancarias(id)
      ON DELETE RESTRICT;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'importacoes_ofx_criado_por_fk'
  ) THEN
    ALTER TABLE public.importacoes_ofx
      ADD CONSTRAINT importacoes_ofx_criado_por_fk
      FOREIGN KEY (criado_por) REFERENCES auth.users(id)
      ON DELETE RESTRICT;
  END IF;
END $$;

COMMENT ON TABLE  public.importacoes_ofx IS
  'Fase 4A - cabecalho de cada importacao de arquivo OFX. Uma linha por arquivo.';
COMMENT ON COLUMN public.importacoes_ofx.arquivo_hash IS
  'SHA-256 hex (64 chars) do arquivo .ofx inteiro. Usado para detectar re-importacao byte-a-byte.';
COMMENT ON COLUMN public.importacoes_ofx.acctid_ofx IS
  'ACCTID extraido do arquivo. Cliente deve validar contra contas_bancarias.conta antes de chamar a RPC; RPC re-valida.';
COMMENT ON COLUMN public.importacoes_ofx.saldo_final IS
  'LEDGERBAL.BALAMT - saldo informado pelo banco na data DTASOF. Util para conferencia humana.';
COMMENT ON COLUMN public.importacoes_ofx.total_inseridas IS
  'Linhas que efetivamente entraram em extratos_bancarios (escaparam dos ON CONFLICT da dedup).';
COMMENT ON COLUMN public.importacoes_ofx.total_duplicadas IS
  'Linhas rejeitadas pela dedup (UNIQUE parcial em fitid ou hash_linha).';
COMMENT ON COLUMN public.importacoes_ofx.total_erros IS
  'Linhas que o parser nao conseguiu interpretar - logadas mas nao inseridas.';

-- RLS
ALTER TABLE public.importacoes_ofx ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS importacoes_ofx_select ON public.importacoes_ofx;
DROP POLICY IF EXISTS importacoes_ofx_insert ON public.importacoes_ofx;
DROP POLICY IF EXISTS importacoes_ofx_update ON public.importacoes_ofx;

CREATE POLICY importacoes_ofx_select ON public.importacoes_ofx FOR SELECT
  USING (public.is_financeiro_editor());

CREATE POLICY importacoes_ofx_insert ON public.importacoes_ofx FOR INSERT
  WITH CHECK (public.is_financeiro_editor());

CREATE POLICY importacoes_ofx_update ON public.importacoes_ofx FOR UPDATE
  USING (public.is_financeiro_editor())
  WITH CHECK (public.is_financeiro_editor());

-- DELETE intencionalmente NAO permitido. Padrao do projeto (Fase 1).

-- Indice operacional
CREATE INDEX IF NOT EXISTS importacoes_conta_data_idx
  ON public.importacoes_ofx (conta_bancaria_id, criado_em DESC);

-- ---------------------------------------------------------------------------
-- 2. TABELA extratos_bancarios
-- Linhas brutas (transacoes) do OFX. Uma linha por <STMTTRN>.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.extratos_bancarios (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conta_bancaria_id      uuid NOT NULL,
  importacao_id          uuid NOT NULL,
  data                   date NOT NULL,
  dtposted_raw           text NOT NULL,
  descricao_bruta        text NOT NULL DEFAULT '',
  descricao_normalizada  text NOT NULL DEFAULT '',
  valor                  numeric(14,2) NOT NULL,
  tipo_operacao          text NOT NULL,
  fitid                  text NULL,
  hash_linha             text NOT NULL,
  name_normalizado       text NOT NULL DEFAULT '',
  memo_normalizado       text NOT NULL DEFAULT '',
  checknum               text NULL,
  refnum                 text NULL,
  ordem_no_arquivo       int  NULL,
  status_conciliacao     text NOT NULL DEFAULT 'pendente',
  financa_id             uuid NULL,
  conciliado_em          timestamptz NULL,
  conciliado_por         uuid NULL,
  ignorado_em            timestamptz NULL,
  ignorado_por           uuid NULL,
  motivo_ignorado        text NULL,
  criado_por             uuid NOT NULL DEFAULT auth.uid(),
  criado_em              timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT extratos_status_ck    CHECK (status_conciliacao IN ('pendente','conciliado','ignorado')),
  CONSTRAINT extratos_hash_len_ck  CHECK (length(hash_linha) = 64)
);

-- FKs
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'extratos_conta_fk'
  ) THEN
    ALTER TABLE public.extratos_bancarios
      ADD CONSTRAINT extratos_conta_fk
      FOREIGN KEY (conta_bancaria_id) REFERENCES public.contas_bancarias(id)
      ON DELETE RESTRICT;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'extratos_importacao_fk'
  ) THEN
    ALTER TABLE public.extratos_bancarios
      ADD CONSTRAINT extratos_importacao_fk
      FOREIGN KEY (importacao_id) REFERENCES public.importacoes_ofx(id)
      ON DELETE RESTRICT;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'extratos_financa_fk'
  ) THEN
    ALTER TABLE public.extratos_bancarios
      ADD CONSTRAINT extratos_financa_fk
      FOREIGN KEY (financa_id) REFERENCES public.financas(id)
      ON DELETE SET NULL;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'extratos_criado_por_fk'
  ) THEN
    ALTER TABLE public.extratos_bancarios
      ADD CONSTRAINT extratos_criado_por_fk
      FOREIGN KEY (criado_por) REFERENCES auth.users(id)
      ON DELETE RESTRICT;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'extratos_conciliado_por_fk'
  ) THEN
    ALTER TABLE public.extratos_bancarios
      ADD CONSTRAINT extratos_conciliado_por_fk
      FOREIGN KEY (conciliado_por) REFERENCES auth.users(id)
      ON DELETE SET NULL;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'extratos_ignorado_por_fk'
  ) THEN
    ALTER TABLE public.extratos_bancarios
      ADD CONSTRAINT extratos_ignorado_por_fk
      FOREIGN KEY (ignorado_por) REFERENCES auth.users(id)
      ON DELETE SET NULL;
  END IF;
END $$;

COMMENT ON TABLE  public.extratos_bancarios IS
  'Fase 4A - linhas brutas importadas do OFX. Uma linha por STMTTRN. Verdade do banco; nunca substitui financas.';
COMMENT ON COLUMN public.extratos_bancarios.dtposted_raw IS
  'Valor cru de <DTPOSTED> (ex: 20260628120000[-03:BRT]). Faz parte do hash_linha.';
COMMENT ON COLUMN public.extratos_bancarios.valor IS
  'TRNAMT signed (negativo = saida). Sem coluna sinal separada.';
COMMENT ON COLUMN public.extratos_bancarios.tipo_operacao IS
  'TRNTYPE em uppercase (CREDIT/DEBIT/FEE/INT/XFER/PAYMENT/OTHER/...). Sem CHECK - aceita o que vier.';
COMMENT ON COLUMN public.extratos_bancarios.hash_linha IS
  'SHA-256 hex (64 chars) de: dtposted_raw|trntype|valor_centavos|name_normalizado|memo_normalizado|checknum|refnum. Usado no UNIQUE parcial quando fitid IS NULL.';
COMMENT ON COLUMN public.extratos_bancarios.fitid IS
  'FITID do OFX. Quando presente, dedup pelo UNIQUE parcial (conta, fitid). Quando NULL, dedup pelo UNIQUE parcial (conta, hash_linha).';
COMMENT ON COLUMN public.extratos_bancarios.ordem_no_arquivo IS
  'Posicao 1-based dentro do <BANKTRANLIST>. Auditoria apenas; NAO entra no hash.';
COMMENT ON COLUMN public.extratos_bancarios.status_conciliacao IS
  'pendente | conciliado | ignorado. Transicoes operacionais sao da Fase 5 (sem CHECK semantico amarrado a financa_id/ignorado_em nesta fase).';
COMMENT ON COLUMN public.extratos_bancarios.financa_id IS
  'FK opcional para financas. Preenchido na Fase 5 (conciliacao manual). ON DELETE SET NULL para nao quebrar historico se a financa for excluida.';

-- RLS
ALTER TABLE public.extratos_bancarios ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS extratos_bancarios_select ON public.extratos_bancarios;
DROP POLICY IF EXISTS extratos_bancarios_insert ON public.extratos_bancarios;
DROP POLICY IF EXISTS extratos_bancarios_update ON public.extratos_bancarios;

CREATE POLICY extratos_bancarios_select ON public.extratos_bancarios FOR SELECT
  USING (public.is_financeiro_editor());

CREATE POLICY extratos_bancarios_insert ON public.extratos_bancarios FOR INSERT
  WITH CHECK (public.is_financeiro_editor());

CREATE POLICY extratos_bancarios_update ON public.extratos_bancarios FOR UPDATE
  USING (public.is_financeiro_editor())
  WITH CHECK (public.is_financeiro_editor());

-- DELETE intencionalmente NAO permitido. Padrao do projeto (Fase 1).
-- Cancelamento de importacao inteira fica para Fase 5+ via flag/RPC dedicada.

-- ---------------------------------------------------------------------------
-- 3. INDICES UNIQUE PARCIAIS (dedup)
-- ---------------------------------------------------------------------------

-- Quando FITID existe: garante unicidade por (conta, fitid)
CREATE UNIQUE INDEX IF NOT EXISTS extratos_conta_fitid_uk
  ON public.extratos_bancarios (conta_bancaria_id, fitid)
  WHERE fitid IS NOT NULL;

-- Quando FITID nao existe: dedup por hash_linha
-- (sem sobreposicao com o indice acima - os dois sao disjuntos)
CREATE UNIQUE INDEX IF NOT EXISTS extratos_conta_hash_uk
  ON public.extratos_bancarios (conta_bancaria_id, hash_linha)
  WHERE fitid IS NULL;

-- ---------------------------------------------------------------------------
-- 4. INDICES OPERACIONAIS
-- ---------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS extratos_conta_data_idx
  ON public.extratos_bancarios (conta_bancaria_id, data DESC);

CREATE INDEX IF NOT EXISTS extratos_pendentes_idx
  ON public.extratos_bancarios (conta_bancaria_id, data DESC)
  WHERE status_conciliacao = 'pendente';

CREATE INDEX IF NOT EXISTS extratos_importacao_idx
  ON public.extratos_bancarios (importacao_id);

CREATE INDEX IF NOT EXISTS extratos_financa_idx
  ON public.extratos_bancarios (financa_id)
  WHERE financa_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 5. NOTA - Fase 4C (NAO entra nesta migration)
-- ---------------------------------------------------------------------------
-- A funcao publica importar_ofx_extrato(p_conta_bancaria_id uuid,
--                                       p_arquivo_meta jsonb,
--                                       p_linhas jsonb) RETURNS jsonb
-- sera criada em migration separada da Fase 4C, com:
--   * LANGUAGE plpgsql
--   * SECURITY INVOKER
--   * SET search_path = public, auth
--   * REVOKE EXECUTE FROM PUBLIC + GRANT EXECUTE TO authenticated
--   * INSERT em importacoes_ofx + bulk INSERT em extratos_bancarios com
--     ON CONFLICT DO NOTHING nos dois UNIQUE parciais, tudo em transacao.
-- Esta migration 4A apenas cria a base de schema; a RPC vem depois.

COMMIT;

-- ===========================================================================
-- POS-CHECK (rodar separadamente apos o COMMIT, sao todos read-only)
-- ===========================================================================
-- -- 1. Tabelas criadas
-- SELECT table_name FROM information_schema.tables
--  WHERE table_schema='public'
--    AND table_name IN ('importacoes_ofx','extratos_bancarios');
-- -- Esperado: 2 linhas
--
-- -- 2. RLS habilitada nas duas
-- SELECT relname, relrowsecurity FROM pg_class
--  WHERE relname IN ('importacoes_ofx','extratos_bancarios')
--  ORDER BY relname;
-- -- Esperado: relrowsecurity = true em ambas
--
-- -- 3. Policies criadas (3 por tabela, sem DELETE)
-- SELECT tablename, policyname, cmd
--   FROM pg_policies
--  WHERE schemaname='public'
--    AND tablename IN ('importacoes_ofx','extratos_bancarios')
--  ORDER BY tablename, cmd;
-- -- Esperado: 6 linhas, cmd em (SELECT, INSERT, UPDATE), nenhum DELETE
--
-- -- 4. FKs com ON DELETE corretos
-- SELECT conname, pg_get_constraintdef(oid)
--   FROM pg_constraint
--  WHERE conrelid IN ('public.importacoes_ofx'::regclass,
--                     'public.extratos_bancarios'::regclass)
--    AND contype = 'f'
--  ORDER BY conname;
-- -- Esperado: 8 FKs (2 em importacoes_ofx + 6 em extratos_bancarios)
-- --   importacoes_ofx_conta_fk        ON DELETE RESTRICT
-- --   importacoes_ofx_criado_por_fk   ON DELETE RESTRICT
-- --   extratos_conta_fk               ON DELETE RESTRICT
-- --   extratos_importacao_fk          ON DELETE RESTRICT
-- --   extratos_financa_fk             ON DELETE SET NULL
-- --   extratos_criado_por_fk          ON DELETE RESTRICT
-- --   extratos_conciliado_por_fk      ON DELETE SET NULL
-- --   extratos_ignorado_por_fk        ON DELETE SET NULL
--
-- -- 5. CHECKs
-- SELECT conname, pg_get_constraintdef(oid)
--   FROM pg_constraint
--  WHERE conrelid IN ('public.importacoes_ofx'::regclass,
--                     'public.extratos_bancarios'::regclass)
--    AND contype = 'c'
--  ORDER BY conname;
--
-- -- 6. Indices (incluindo UNIQUE parciais com clausula WHERE)
-- SELECT indexname, indexdef FROM pg_indexes
--  WHERE schemaname='public'
--    AND tablename IN ('importacoes_ofx','extratos_bancarios')
--  ORDER BY tablename, indexname;
-- -- Esperado:
-- --   importacoes_conta_data_idx
-- --   importacoes_ofx_pkey
-- --   extratos_bancarios_pkey
-- --   extratos_conta_fitid_uk        (UNIQUE, WHERE fitid IS NOT NULL)
-- --   extratos_conta_hash_uk         (UNIQUE, WHERE fitid IS NULL)
-- --   extratos_conta_data_idx
-- --   extratos_pendentes_idx         (WHERE status_conciliacao = 'pendente')
-- --   extratos_importacao_idx
-- --   extratos_financa_idx           (WHERE financa_id IS NOT NULL)
--
-- -- 7. Sanity: financas nao foi alterada
-- SELECT count(*) AS total_financas FROM public.financas;
-- -- Esperado: mesmo valor da baseline do pre-check
--
-- -- 8. Smoke test (rodar em janela separada, com ROLLBACK no final)
-- BEGIN;
--   -- a) inserir 1 importacao mock (precisa de conta_bancaria_id valido)
--   --    INSERT INTO importacoes_ofx(...) VALUES (...) RETURNING id;
--   -- b) inserir 2 extratos com fitid distintos -> ambos OK
--   -- c) inserir 3o extrato com mesmo (conta, fitid) do anterior -> falha UNIQUE
--   -- d) inserir extrato sem fitid com hash X -> OK
--   -- e) inserir outro extrato sem fitid com mesmo hash X -> falha UNIQUE
--   -- f) inserir extrato com status_conciliacao='foo' -> falha CHECK
--   -- g) tentar DELETE de linha -> falha (sem policy DELETE)
-- ROLLBACK;

-- ===========================================================================
-- ROLLBACK (se necessario, dentro da mesma janela do SQL Editor):
--   BEGIN;
--   -- 1. Indices (caem junto com as tabelas, mas explicito para clareza)
--   DROP INDEX IF EXISTS public.extratos_conta_fitid_uk;
--   DROP INDEX IF EXISTS public.extratos_conta_hash_uk;
--   DROP INDEX IF EXISTS public.extratos_conta_data_idx;
--   DROP INDEX IF EXISTS public.extratos_pendentes_idx;
--   DROP INDEX IF EXISTS public.extratos_importacao_idx;
--   DROP INDEX IF EXISTS public.extratos_financa_idx;
--   DROP INDEX IF EXISTS public.importacoes_conta_data_idx;
--   -- 2. Tabelas (CASCADE remove policies e constraints automaticamente)
--   DROP TABLE IF EXISTS public.extratos_bancarios CASCADE;
--   DROP TABLE IF EXISTS public.importacoes_ofx   CASCADE;
--   COMMIT;
-- ===========================================================================
