-- ════════════════════════════════════════════════════════════════════════════
-- MIGRATION — FASE 1 do plano "Financeiro: Contas e Conciliação"
-- Data:   2026-06-27
-- Plano:  docs/plano-financeiro-contas-conciliacao.md
-- Status: AGUARDANDO REVISÃO — NÃO APLICAR SEM:
--   1) Snapshot/backup do banco (Supabase Dashboard → Database → Backups
--      → Create on-demand backup);
--   2) Revisão por outra pessoa;
--   3) Execução em ambiente de dev/staging primeiro, se houver.
--
-- Aplicação em produção: copiar e colar no SQL Editor do Supabase Dashboard
-- e executar bloco a bloco, lendo o resultado de cada NOTICE.
--
-- O que entra:
--   • Tabela contas_bancarias  (onde o dinheiro está)
--   • Tabela categorias_financeiras (origem/finalidade do lançamento)
--   • RLS habilitada + policies por perfil
--   • Função utilitária is_financeiro_editor() / is_financeiro_reader()
--
-- O que NÃO entra (próximas fases):
--   • Alteração em "financas"
--   • Tabelas de extrato bancário / importação OFX / conciliação
--   • Backfill de dados antigos
--   • Seeds automáticos (Tesoureiro insere via UI após revisar)
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- 1. FUNÇÕES UTILITÁRIAS DE PERMISSÃO
-- Padronizam a checagem usada em todas as policies, evitando duplicar lógica.
-- ────────────────────────────────────────────────────────────────────────────

-- Editor: pode INSERT/UPDATE/DELETE em dados bancários.
-- = Admin do sistema (tabela usuarios) OU Tesoureiro ativo (tabela membros).
CREATE OR REPLACE FUNCTION public.is_financeiro_editor()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.usuarios u
     WHERE u.auth_user_id = auth.uid()
       AND u.ativo = true
       AND (u.role = 'admin' OR u.perfil = 'admin')
  )
  OR EXISTS (
    SELECT 1 FROM public.membros m
     WHERE m.auth_user_id = auth.uid()
       AND m.status = 'ativo'
       AND m.cargo = 'Tesoureiro'
  );
$$;

-- Reader: pode SELECT em dados bancários.
-- = Editor + Venerável Mestre ativo (para fins de relatório).
CREATE OR REPLACE FUNCTION public.is_financeiro_reader()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
  SELECT public.is_financeiro_editor()
    OR EXISTS (
      SELECT 1 FROM public.membros m
       WHERE m.auth_user_id = auth.uid()
         AND m.status = 'ativo'
         AND m.cargo = 'Venerável Mestre'
    );
$$;

COMMENT ON FUNCTION public.is_financeiro_editor IS
  'Fase 1 — financeiro: TRUE se o usuário pode editar contas/categorias bancárias (Admin ou Tesoureiro ativo).';
COMMENT ON FUNCTION public.is_financeiro_reader IS
  'Fase 1 — financeiro: TRUE se o usuário pode visualizar contas/categorias bancárias (Admin, Tesoureiro ou Venerável ativos).';

-- Hardening: revogar EXECUTE de PUBLIC e conceder apenas a `authenticated`.
-- Funções SECURITY DEFINER ficam disponíveis por padrão a qualquer role; com
-- isso restringimos a chamada às sessões autenticadas (anon não chama).
REVOKE EXECUTE ON FUNCTION public.is_financeiro_editor() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.is_financeiro_reader() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.is_financeiro_editor() TO authenticated;
GRANT  EXECUTE ON FUNCTION public.is_financeiro_reader() TO authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. TABELA contas_bancarias
-- Representa ONDE o dinheiro está fisicamente (conta bancária ou caixa físico).
-- ────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.contas_bancarias (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nome            text NOT NULL,                              -- "Sicoob - Conta Corrente"
  banco           text NULL,                                  -- "Sicoob"
  agencia         text NULL,
  conta           text NULL,
  tipo            text NOT NULL DEFAULT 'corrente'
                  CHECK (tipo IN ('corrente','poupanca','caixa_fisico','outra')),
  saldo_inicial   numeric(14,2) NOT NULL DEFAULT 0,
  observacao      text NULL,
  ativo           boolean NOT NULL DEFAULT true,
  criado_em       timestamptz NOT NULL DEFAULT now(),
  alterado_em     timestamptz NULL,
  CONSTRAINT contas_bancarias_nome_uk UNIQUE (nome)
);

COMMENT ON TABLE public.contas_bancarias IS
  'Fase 1 — Onde o dinheiro da loja está fisicamente. Não confundir com categoria do lançamento.';
COMMENT ON COLUMN public.contas_bancarias.tipo IS
  'corrente | poupanca | caixa_fisico | outra';
COMMENT ON COLUMN public.contas_bancarias.saldo_inicial IS
  'Saldo informado pelo Tesoureiro no momento do cadastro. Não é atualizado por triggers.';

-- Trigger leve para manter alterado_em
CREATE OR REPLACE FUNCTION public._tg_contas_bancarias_touch()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.alterado_em := now();
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS contas_bancarias_touch ON public.contas_bancarias;
CREATE TRIGGER contas_bancarias_touch
  BEFORE UPDATE ON public.contas_bancarias
  FOR EACH ROW EXECUTE FUNCTION public._tg_contas_bancarias_touch();

-- RLS
ALTER TABLE public.contas_bancarias ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "contas_bancarias_select"  ON public.contas_bancarias;
DROP POLICY IF EXISTS "contas_bancarias_insert"  ON public.contas_bancarias;
DROP POLICY IF EXISTS "contas_bancarias_update"  ON public.contas_bancarias;
DROP POLICY IF EXISTS "contas_bancarias_delete"  ON public.contas_bancarias;

CREATE POLICY "contas_bancarias_select"
  ON public.contas_bancarias FOR SELECT
  USING (public.is_financeiro_reader());

CREATE POLICY "contas_bancarias_insert"
  ON public.contas_bancarias FOR INSERT
  WITH CHECK (public.is_financeiro_editor());

CREATE POLICY "contas_bancarias_update"
  ON public.contas_bancarias FOR UPDATE
  USING (public.is_financeiro_editor())
  WITH CHECK (public.is_financeiro_editor());

-- DELETE intencionalmente NÃO permitido. Use UPDATE ativo=false (soft delete).
-- Justificativa: na Fase 2, financas terá conta_bancaria_id apontando para esta
-- tabela. Apagar conta usada quebraria histórico. Manter sempre como soft-delete.
-- Cliente reflete essa decisão escondendo o botão "Excluir".

-- ────────────────────────────────────────────────────────────────────────────
-- 3. TABELA categorias_financeiras
-- Representa ORIGEM/FINALIDADE do lançamento (mensalidade, ágape, tronco, etc.)
-- Migra (não destrutivamente) o que hoje vive em localStorage.cats_fin.
-- ────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.categorias_financeiras (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug               text NOT NULL,                              -- 'mensalidade', 'tronco', etc.
  nome               text NOT NULL,                              -- "Mensalidade"
  -- natureza: classifica o lançamento estruturalmente
  --   'operacional'   → mensalidade, joia, ágape, despesas normais (caso comum)
  --   'transferencia' → transferência entre contas próprias da loja
  --   'rendimento'    → juros/rendimento de aplicação
  --   'outros'        → reserva
  natureza           text NOT NULL DEFAULT 'operacional'
                     CHECK (natureza IN ('operacional','transferencia','rendimento','outros')),
  -- tipo: 'receita' / 'despesa' / 'ambos' — para filtro no formulário
  tipo               text NOT NULL DEFAULT 'ambos'
                     CHECK (tipo IN ('receita','despesa','ambos')),
  -- Quando FALSE, lançamentos desta categoria NÃO entram no total de
  -- receita/despesa do período (ex: transferência interna corrente↔poupança).
  -- Default TRUE (caso comum). Combina com natureza para o cálculo correto.
  impacta_resultado  boolean NOT NULL DEFAULT true,
  -- Sistema = entregue pela aplicação, não pode ser excluída/desativada de forma
  -- a quebrar invariantes (controlado no cliente; backend impede DELETE).
  sistema            boolean NOT NULL DEFAULT false,
  ordem              int NOT NULL DEFAULT 100,
  ativo              boolean NOT NULL DEFAULT true,
  criado_em          timestamptz NOT NULL DEFAULT now(),
  alterado_em        timestamptz NULL,
  CONSTRAINT categorias_financeiras_slug_uk UNIQUE (slug)
);

COMMENT ON TABLE public.categorias_financeiras IS
  'Fase 1 — Origem/finalidade dos lançamentos financeiros. impacta_resultado=false (ex: transferência interna) NÃO entra nos totais.';
COMMENT ON COLUMN public.categorias_financeiras.natureza IS
  'operacional | transferencia | rendimento | outros — usado por relatórios e DRE para classificação estrutural.';
COMMENT ON COLUMN public.categorias_financeiras.impacta_resultado IS
  'Quando FALSE, lançamentos desta categoria NÃO entram nos totais de receita/despesa do período. Combine com natureza para regras de relatório.';
COMMENT ON COLUMN public.categorias_financeiras.sistema IS
  'Quando TRUE, é categoria criada pela aplicação (DELETE bloqueado por policy; UI esconde botões destrutivos).';

CREATE OR REPLACE FUNCTION public._tg_categorias_financeiras_touch()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.alterado_em := now();
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS categorias_financeiras_touch ON public.categorias_financeiras;
CREATE TRIGGER categorias_financeiras_touch
  BEFORE UPDATE ON public.categorias_financeiras
  FOR EACH ROW EXECUTE FUNCTION public._tg_categorias_financeiras_touch();

-- RLS
ALTER TABLE public.categorias_financeiras ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "categorias_financeiras_select"  ON public.categorias_financeiras;
DROP POLICY IF EXISTS "categorias_financeiras_insert"  ON public.categorias_financeiras;
DROP POLICY IF EXISTS "categorias_financeiras_update"  ON public.categorias_financeiras;
DROP POLICY IF EXISTS "categorias_financeiras_delete"  ON public.categorias_financeiras;

CREATE POLICY "categorias_financeiras_select"
  ON public.categorias_financeiras FOR SELECT
  USING (public.is_financeiro_reader());

CREATE POLICY "categorias_financeiras_insert"
  ON public.categorias_financeiras FOR INSERT
  WITH CHECK (public.is_financeiro_editor());

CREATE POLICY "categorias_financeiras_update"
  ON public.categorias_financeiras FOR UPDATE
  USING (public.is_financeiro_editor())
  WITH CHECK (public.is_financeiro_editor());

-- DELETE intencionalmente NÃO permitido. Use UPDATE ativo=false (soft delete).
-- Justificativa: linhas em "financas" guardam o slug da categoria como texto.
-- Apagar categoria não corromperia esses lançamentos, mas perderia histórico de
-- nome/natureza para relatórios. Manter como soft-delete.
-- Categorias "sistema" também não podem ser desativadas pela UI (proteção
-- client-side; backend permite UPDATE mas o cliente esconde o botão).

-- ────────────────────────────────────────────────────────────────────────────
-- 4. SEEDS DE CATEGORIAS "SISTEMA" — exigidas pelo plano da Fase 1
-- Estas três categorias são essenciais para a lógica de saldo e conciliação
-- (mesmo nas próximas fases). Por isso entram aqui como categorias sistema.
-- As categorias antigas em localStorage.cats_fin continuam funcionando como
-- fallback no cliente — Tesoureiro pode promover via UI quando quiser.
-- ────────────────────────────────────────────────────────────────────────────

INSERT INTO public.categorias_financeiras
       (slug,                    nome,                    natureza,        tipo,      impacta_resultado, sistema, ordem)
VALUES ('tronco',                'Tronco / Beneficência', 'operacional',   'ambos',   true,              true,    10),
       ('transferencia_interna', 'Transferência interna', 'transferencia', 'ambos',   false,             true,    20),
       ('rendimento',            'Rendimento financeiro', 'rendimento',    'receita', true,              true,    30)
ON CONFLICT (slug) DO UPDATE
SET nome               = EXCLUDED.nome,
    natureza           = EXCLUDED.natureza,
    tipo               = EXCLUDED.tipo,
    impacta_resultado  = EXCLUDED.impacta_resultado,
    sistema            = true;

-- NOTA: as duas contas iniciais (Sicoob - Conta Corrente / Poupança)
-- NÃO são inseridas aqui. O Tesoureiro vai cadastrá-las pela UI da Fase 1,
-- conferindo banco/agência/conta e saldo inicial antes de salvar.

-- ────────────────────────────────────────────────────────────────────────────
-- 5. ÍNDICES auxiliares
-- ────────────────────────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS contas_bancarias_ativo_idx
  ON public.contas_bancarias(ativo);

CREATE INDEX IF NOT EXISTS categorias_financeiras_ativo_idx
  ON public.categorias_financeiras(ativo);

CREATE INDEX IF NOT EXISTS categorias_financeiras_ordem_idx
  ON public.categorias_financeiras(ordem);

-- ────────────────────────────────────────────────────────────────────────────
-- 6. VERIFICAÇÃO (read-only) — rode separadamente após o COMMIT
-- ────────────────────────────────────────────────────────────────────────────
-- SELECT 'contas_bancarias' as tabela, count(*) as linhas FROM public.contas_bancarias
-- UNION ALL
-- SELECT 'categorias_financeiras', count(*) FROM public.categorias_financeiras;
--
-- SELECT slug, nome, natureza, tipo, impacta_resultado, sistema, ativo, ordem
--   FROM public.categorias_financeiras
--  ORDER BY ordem;
--
-- -- Confirmar RLS habilitada:
-- SELECT relname, relrowsecurity, relforcerowsecurity
--   FROM pg_class
--  WHERE relname IN ('contas_bancarias','categorias_financeiras');
--
-- -- Confirmar policies:
-- SELECT tablename, policyname, cmd, qual, with_check
--   FROM pg_policies
--  WHERE schemaname = 'public'
--    AND tablename IN ('contas_bancarias','categorias_financeiras')
--  ORDER BY tablename, policyname;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
-- ROLLBACK (se necessário, dentro da mesma janela do SQL Editor):
--   BEGIN;
--   DROP TABLE IF EXISTS public.contas_bancarias       CASCADE;
--   DROP TABLE IF EXISTS public.categorias_financeiras CASCADE;
--   DROP FUNCTION IF EXISTS public.is_financeiro_editor() CASCADE;
--   DROP FUNCTION IF EXISTS public.is_financeiro_reader() CASCADE;
--   DROP FUNCTION IF EXISTS public._tg_contas_bancarias_touch()       CASCADE;
--   DROP FUNCTION IF EXISTS public._tg_categorias_financeiras_touch() CASCADE;
--   COMMIT;
-- ════════════════════════════════════════════════════════════════════════════
