-- ══════════════════════════════════════════════════════════════════════
--  VendaJá — schema.sql
--  Configuração de segurança da base de dados (Supabase / PostgreSQL)
--
--  Exportado em: 2026-07-24
--  Fonte: exportado directamente da base de dados de produção.
--
--  PARA QUE SERVE
--  Este ficheiro é a cópia de segurança das políticas RLS, funções e
--  triggers. Se algo for apagado por engano na consola do Supabase,
--  repõe-se a partir daqui.
--
--  MANTER ACTUALIZADO
--  Sempre que criares ou alterares políticas/funções/triggers, volta a
--  correr o `exportar-seguranca.sql` e actualiza este ficheiro.
--
--  ATENÇÃO: não corras este ficheiro inteiro numa base de dados que já
--  esteja a funcionar sem antes perceberes o que vai mudar.
-- ══════════════════════════════════════════════════════════════════════


-- ┌────────────────────────────────────────────────────────────────────┐
-- │ ÍNDICE                                                             │
-- ├────────────────────────────────────────────────────────────────────┤
-- │ 1. Row Level Security     — 10 tabelas                             │
-- │ 2. Políticas RLS          — 17 políticas                           │
-- │ 3. Funções                — 14 funções                             │
-- │ 4. Triggers               —  4 triggers                            │
-- │ 5. Estrutura das tabelas  — referência (comentada)                 │
-- └────────────────────────────────────────────────────────────────────┘


-- ══════════════════════════════════════════════════════════════════════
--  1. ROW LEVEL SECURITY
--  Sem isto activo, as políticas abaixo não têm efeito nenhum.
-- ══════════════════════════════════════════════════════════════════════

ALTER TABLE public.collections ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payment_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stores ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.subscription_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.subscription_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;


-- ══════════════════════════════════════════════════════════════════════
--  2. POLÍTICAS RLS
--  Definem quem pode ler e escrever cada linha. São a base do
--  isolamento entre vendedores: sem elas, qualquer vendedor
--  autenticado conseguiria ver os dados dos outros.
-- ══════════════════════════════════════════════════════════════════════

CREATE POLICY "Leitura publica de coleções" ON public.collections FOR SELECT TO public USING ((store_id IN ( SELECT stores.id
   FROM stores
  WHERE (stores.is_published = true))));

CREATE POLICY "Vendedores gerem coleções" ON public.collections FOR ALL TO public USING ((store_id IN ( SELECT stores.id
   FROM stores
  WHERE (stores.user_id = auth.uid())))) WITH CHECK ((store_id IN ( SELECT stores.id
   FROM stores
  WHERE (stores.user_id = auth.uid()))));

CREATE POLICY "Criar pedido publico" ON public.orders FOR INSERT TO public WITH CHECK ((store_id IN ( SELECT stores.id
   FROM stores
  WHERE (stores.is_published = true))));

CREATE POLICY "Utilizadores gerem os seus pedidos" ON public.orders FOR ALL TO public USING ((store_id IN ( SELECT stores.id
   FROM stores
  WHERE (stores.user_id = auth.uid())))) WITH CHECK ((store_id IN ( SELECT stores.id
   FROM stores
  WHERE (stores.user_id = auth.uid()))));

CREATE POLICY "admin_ve_tudo" ON public.payment_events FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM profiles
  WHERE ((profiles.id = auth.uid()) AND (profiles.is_admin = true)))));

CREATE POLICY "vendedor_ve_os_seus" ON public.payment_events FOR SELECT TO authenticated USING ((matched_user = auth.uid()));

CREATE POLICY "Leitura publica de produtos" ON public.products FOR SELECT TO public USING ((store_id IN ( SELECT stores.id
   FROM stores
  WHERE (stores.is_published = true))));

CREATE POLICY "Utilizadores gerem os seus produtos" ON public.products FOR ALL TO public USING ((store_id IN ( SELECT stores.id
   FROM stores
  WHERE (stores.user_id = auth.uid())))) WITH CHECK ((store_id IN ( SELECT stores.id
   FROM stores
  WHERE (stores.user_id = auth.uid()))));

CREATE POLICY "admin_update_profiles" ON public.profiles FOR UPDATE TO authenticated USING ((EXISTS ( SELECT 1
   FROM profiles profiles_1
  WHERE ((profiles_1.id = auth.uid()) AND (profiles_1.is_admin = true)))));

CREATE POLICY "perfil: dono le" ON public.profiles FOR SELECT TO authenticated USING ((id = auth.uid()));

CREATE POLICY "eventos: dono le" ON public.store_events FOR SELECT TO authenticated USING ((store_id IN ( SELECT stores.id
   FROM stores
  WHERE (stores.user_id = auth.uid()))));

CREATE POLICY "eventos: registo publico" ON public.store_events FOR INSERT TO anon, authenticated WITH CHECK ((store_id IN ( SELECT stores.id
   FROM stores
  WHERE ((stores.is_published = true) AND (COALESCE(stores.is_suspended, false) = false)))));

CREATE POLICY "Leitura publica de lojas publicadas" ON public.stores FOR SELECT TO public USING ((is_published = true));

CREATE POLICY "Utilizadores gerem as suas lojas" ON public.stores FOR ALL TO public USING ((auth.uid() = user_id)) WITH CHECK ((auth.uid() = user_id));

CREATE POLICY "config: leitura autenticada" ON public.subscription_config FOR SELECT TO authenticated USING (true);

CREATE POLICY "eventos sub: dono le" ON public.subscription_events FOR SELECT TO authenticated USING ((user_id = auth.uid()));

CREATE POLICY "eventos sub: registo proprio" ON public.subscription_events FOR INSERT TO authenticated WITH CHECK (((user_id = auth.uid()) AND (event = 'blocked_attempt'::text)));


-- ══════════════════════════════════════════════════════════════════════
--  3. FUNÇÕES
--  Inclui as RPC chamadas pelo frontend (subscription_permissions,
--  store_public_state, store_analytics) e a de reconciliação de
--  pagamentos, que valida internamente se quem chama é administrador.
-- ══════════════════════════════════════════════════════════════════════

-- ── admin_reconcile_payment ──
CREATE OR REPLACE FUNCTION public.admin_reconcile_payment(p_payment_id bigint, p_target_email text, p_plan_key text, p_dias integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_id   uuid;
  v_is_admin    boolean;
  v_target_id   uuid;
  v_payment     record;
  v_expires_at  timestamptz;
BEGIN
  -- Quem está a chamar?
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'erro', 'Não autenticado.');
  END IF;

  -- É administrador?
  SELECT is_admin INTO v_is_admin
  FROM public.profiles WHERE id = v_caller_id;
  IF NOT COALESCE(v_is_admin, false) THEN
    RETURN jsonb_build_object('ok', false, 'erro', 'Sem permissão.');
  END IF;

  -- Valida o plano
  IF p_plan_key NOT IN ('basico', 'pro', 'premium') THEN
    RETURN jsonb_build_object('ok', false, 'erro', 'Plano inválido: ' || p_plan_key);
  END IF;

  -- Valida os dias
  IF p_dias < 1 OR p_dias > 400 THEN
    RETURN jsonb_build_object('ok', false, 'erro', 'Número de dias inválido.');
  END IF;

  -- Encontra o pagamento
  SELECT * INTO v_payment
  FROM public.payment_events WHERE id = p_payment_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erro', 'Pagamento não encontrado.');
  END IF;

  -- Encontra o utilizador de destino
  SELECT p.id INTO v_target_id
  FROM public.profiles p
  JOIN auth.users u ON u.id = p.id
  WHERE u.email = p_target_email;
  IF v_target_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'erro',
      'Nenhuma conta com o email: ' || p_target_email);
  END IF;

  -- Calcula a nova data de expiração
  v_expires_at := NOW() + (p_dias || ' days')::interval;

  -- Associa o pagamento ao utilizador correcto
  UPDATE public.payment_events
  SET matched_user = v_target_id
  WHERE id = p_payment_id;

  -- Activa o plano
  UPDATE public.profiles
  SET plan             = p_plan_key,
      plan_status      = 'active',
      plan_expires_at  = v_expires_at,
      subscription_status = 'active',
      updated_at       = NOW()
  WHERE id = v_target_id;

  -- Regista para auditoria
  INSERT INTO public.subscription_events
    (user_id, event, detail, created_at)
  VALUES
    (v_target_id, 'admin_reconcile',
     jsonb_build_object(
       'payment_id',    p_payment_id,
       'plan',          p_plan_key,
       'source_email',  v_payment.customer_email,
       'target_email',  p_target_email,
       'days',          p_dias,
       'expires_at',    v_expires_at,
       'admin_id',      v_caller_id
     ),
     NOW()
    )
  ON CONFLICT DO NOTHING;

  RETURN jsonb_build_object(
    'ok',          true,
    'target_id',   v_target_id,
    'plan',        p_plan_key,
    'expires_at',  v_expires_at
  );
END;
$function$;

-- ── block_orders_on_suspended_store ──
CREATE OR REPLACE FUNCTION public.block_orders_on_suspended_store()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_suspended boolean;
begin
  select is_suspended into v_suspended
  from public.stores where id = new.store_id;

  if coalesce(v_suspended, false) then
    raise exception 'Loja temporariamente indisponível.';
  end if;

  return new;
end;
$function$;

-- ── can_write ──
CREATE OR REPLACE FUNCTION public.can_write(p_user uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select (public.subscription_state(p_user) ->> 'estado') in ('active','expiring');
$function$;

-- ── chk_plan_expires_sane ──
CREATE OR REPLACE FUNCTION public.chk_plan_expires_sane()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.plan_expires_at IS NOT NULL
     AND NEW.plan_expires_at > NOW() + INTERVAL '400 days' THEN
    RAISE EXCEPTION 'plan_expires_at demasiado longe no futuro: %', NEW.plan_expires_at;
  END IF;
  RETURN NEW;
END;
$function$;

-- ── handle_new_user ──
CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  insert into public.profiles (id, nome, tel, email, plan, plan_status)
  values (new.id,
          new.raw_user_meta_data ->> 'nome',
          new.raw_user_meta_data ->> 'tel',
          new.email, 'none', 'blocked')
  on conflict (id) do nothing;
  return new;
end;
$function$;

-- ── limit_store_events ──
CREATE OR REPLACE FUNCTION public.limit_store_events()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_count int;
begin
  select count(*) into v_count
    from public.store_events
   where store_id = new.store_id
     and session_id = new.session_id
     and created_at > now() - interval '1 hour';

  if v_count >= 200 then
    raise exception 'Demasiados eventos nesta sessão.';
  end if;

  return new;
end;
$function$;

-- ── purge_old_store_events ──
CREATE OR REPLACE FUNCTION public.purge_old_store_events()
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  delete from public.store_events where created_at < now() - interval '180 days';
$function$;

-- ── store_accepts_orders ──
CREATE OR REPLACE FUNCTION public.store_accepts_orders(p_store uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(
    (select (public.subscription_state(s.user_id) ->> 'loja') = 'active'
       from public.stores s where s.id = p_store),
    false);
$function$;

-- ── store_analytics ──
CREATE OR REPLACE FUNCTION public.store_analytics(p_days integer DEFAULT 30)
 RETURNS TABLE(visitas bigint, visitantes_unicos bigint, compras bigint, carrinhos bigint, carrinhos_perdidos bigint, taxa_conversao numeric)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with meus as (
    select id from public.stores where user_id = auth.uid()
  ),
  ev as (
    select * from public.store_events
    where store_id in (select id from meus)
      and created_at > now() - (p_days || ' days')::interval
  ),
  sess_cart as (
    select distinct session_id from ev where event_type = 'add_to_cart'
  ),
  sess_buy as (
    select distinct session_id from ev where event_type = 'purchase'
  )
  select
    (select count(*) from ev where event_type = 'view')                        as visitas,
    (select count(distinct session_id) from ev where event_type = 'view')      as visitantes_unicos,
    (select count(*) from ev where event_type = 'purchase')                    as compras,
    (select count(*) from sess_cart)                                            as carrinhos,
    (select count(*) from sess_cart s
      where not exists (select 1 from sess_buy b where b.session_id = s.session_id))
                                                                                as carrinhos_perdidos,
    case
      when (select count(distinct session_id) from ev where event_type = 'view') > 0
      then round(
        (select count(distinct session_id) from sess_buy)::numeric * 100
        / (select count(distinct session_id) from ev where event_type = 'view')::numeric
      , 1)
      else 0
    end                                                                         as taxa_conversao;
$function$;

-- ── store_public_state ──
CREATE OR REPLACE FUNCTION public.store_public_state(p_slug text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(
    (select jsonb_build_object(
        'loja',  public.subscription_state(s.user_id) ->> 'loja',
        'store_id', s.id)
       from public.stores s
      where s.slug = p_slug and s.is_published = true
      limit 1),
    jsonb_build_object('loja','suspended'));
$function$;

-- ── subscription_permissions ──
CREATE OR REPLACE FUNCTION public.subscription_permissions(p_user uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_st   jsonb := public.subscription_state(p_user);
  v_e    text  := v_st ->> 'estado';
  v_livre boolean := v_e in ('active','expiring');
begin
  return v_st || jsonb_build_object('permissoes', jsonb_build_object(
    'criar_produtos',    v_livre,
    'editar_produtos',   v_livre,
    'eliminar_produtos', v_livre,
    'gerir_colecoes',    v_livre,
    'aplicar_temas',     v_livre,
    'publicar_loja',     v_livre,
    'usar_marketing',    v_livre,
    'gerir_pagamentos',  v_livre,
    'receber_pedidos',   v_livre,
    -- Sempre permitido (Doc 1: modo leitura)
    'ver_dashboard',     true,
    'ver_relatorios',    true,
    'ver_pedidos',       true,
    'gerir_estado_pedidos', true,   -- fechar encomendas antigas
    'exportar_dados',    true,
    'gerir_conta',       true,
    'renovar',           true
  ));
end;
$function$;

-- ── subscription_state ──
CREATE OR REPLACE FUNCTION public.subscription_state(p_user uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_user   uuid := coalesce(p_user, auth.uid());
  v_p      record;
  v_cfg    record;
  v_now    timestamptz := now();
  v_dias   int;
  v_estado text;
  v_loja   text;
  v_fim_carencia timestamptz;
begin
  if v_user is null then
    return jsonb_build_object('estado','blocked','loja','suspended','erro','sem sessão');
  end if;

  select * into v_cfg from public.subscription_config where id = 1;

  select plan, plan_status, plan_expires_at, subscription_status, created_at
    into v_p
    from public.profiles
   where id = v_user;

  if not found then
    return jsonb_build_object('estado','blocked','loja','suspended','erro','perfil inexistente');
  end if;

  v_fim_carencia := v_p.plan_expires_at + (v_cfg.grace_days || ' days')::interval;
  v_dias := case when v_p.plan_expires_at is null then null
                 else ceil(extract(epoch from (v_p.plan_expires_at - v_now)) / 86400.0)::int end;

  -- Derivação do estado efectivo
  if v_p.plan_status = 'blocked' or v_p.plan_expires_at is null then
    v_estado := 'blocked';                                   -- nunca pagou / bloqueado por reembolso
  elsif v_p.plan_expires_at > v_now then
    v_estado := case when v_dias <= v_cfg.warning_days then 'expiring' else 'active' end;
  elsif v_now <= v_fim_carencia then
    v_estado := 'expired';                                   -- modo leitura
  else
    v_estado := 'suspended';                                 -- passou a carência
  end if;

  -- Estado da loja pública
  v_loja := case
    when v_estado in ('active','expiring') then 'active'
    when v_estado = 'expired'              then 'maintenance'
    else 'suspended'
  end;

  return jsonb_build_object(
    'user_id',        v_user,
    'plano',          coalesce(v_p.plan, 'none'),
    'estado',         v_estado,
    'loja',           v_loja,
    'inicio',         v_p.created_at,
    'expira_em',      v_p.plan_expires_at,
    'dias_restantes', v_dias,
    'fim_carencia',   v_fim_carencia,
    'dias_carencia',  case when v_estado = 'expired'
                        then ceil(extract(epoch from (v_fim_carencia - v_now)) / 86400.0)::int
                        else null end,
    'assinatura',     coalesce(v_p.subscription_status, 'none'),
    'servidor_agora', v_now
  );
end;
$function$;

-- ── update_my_profile ──
CREATE OR REPLACE FUNCTION public.update_my_profile(p_nome text, p_tel text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  update public.profiles
     set nome = coalesce(p_nome, nome),
         tel  = coalesce(p_tel, tel),
         updated_at = now()
   where id = auth.uid();
end;
$function$;

-- ── validate_new_order ──
CREATE OR REPLACE FUNCTION public.validate_new_order()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_prod         record;
  v_min_amount   numeric;
  v_offer        jsonb;
  v_phone        text;
  v_recent_phone int;
  v_recent_store int;
begin
  -- ── 1. Campos obrigatórios ──
  if new.customer_name is null or length(trim(new.customer_name)) < 3 then
    raise exception 'Nome do cliente inválido.';
  end if;

  if new.city is null or length(trim(new.city)) < 2 then
    raise exception 'Cidade em falta.';
  end if;

  if new.customer_address is null or length(trim(new.customer_address)) < 5 then
    raise exception 'Endereço de entrega inválido.';
  end if;

  -- ── 2. Telefone moçambicano válido ──
  -- Aceita +2588XXXXXXXX ou 8XXXXXXXX (9 dígitos, começa por 82-87)
  v_phone := regexp_replace(coalesce(new.customer_phone, ''), '[^0-9]', '', 'g');
  if v_phone !~ '^(258)?8[234567][0-9]{7}$' then
    raise exception 'Número de telefone inválido.';
  end if;

  -- ── 3. Quantidade sensata ──
  if new.quantity is null or new.quantity < 1 or new.quantity > 50 then
    raise exception 'Quantidade inválida.';
  end if;

  -- ── 4. Valor positivo ──
  if new.amount is null or new.amount <= 0 then
    raise exception 'Valor do pedido inválido.';
  end if;

  -- ── 5. Estado inicial só pode ser 'pend' ──
  -- (impede que alguém insira um pedido já marcado como entregue)
  if coalesce(new.status, 'pend') <> 'pend' then
    raise exception 'Estado inicial do pedido inválido.';
  end if;

  -- ── 6. Produto tem de pertencer à loja + valor plausível ──
  if new.product_id is not null then
    select id, store_id, price, upsell
      into v_prod
      from public.products
     where id = new.product_id;

    if not found then
      raise exception 'Produto não encontrado.';
    end if;

    if v_prod.store_id is distinct from new.store_id then
      raise exception 'Produto não pertence a esta loja.';
    end if;

    -- Valor mínimo plausível: o menor entre o preço base × quantidade
    -- e o preço de qualquer oferta de upsell configurada.
    -- (As ofertas podem ser MAIS BARATAS que o preço base — por isso
    --  entram todas no cálculo do mínimo.)
    v_min_amount := coalesce(v_prod.price, 0) * new.quantity;

    if v_prod.upsell is not null
       and coalesce((v_prod.upsell ->> 'enabled')::boolean, false) then
      for v_offer in
        select * from jsonb_array_elements(coalesce(v_prod.upsell -> 'offers', '[]'::jsonb))
      loop
        if (v_offer ->> 'price') is not null then
          v_min_amount := least(v_min_amount, (v_offer ->> 'price')::numeric);
        end if;
      end loop;
    end if;

    -- Tolerância de 1% para arredondamentos.
    -- Só bloqueia SUBVALORIZAÇÃO (pagar menos do que qualquer preço válido).
    -- Valores acima passam: o vendedor pode ter baixado o preço entretanto.
    if v_min_amount > 0 and new.amount < (v_min_amount * 0.99) then
      raise exception 'Valor do pedido não corresponde ao preço do produto.';
    end if;
  end if;

  -- ── 7. Anti-spam: limite por telefone e por loja ──
  select count(*) into v_recent_phone
    from public.orders
   where store_id = new.store_id
     and customer_phone = new.customer_phone
     and created_at > now() - interval '1 hour';

  if v_recent_phone >= 10 then
    raise exception 'Demasiados pedidos deste número. Tenta novamente mais tarde.';
  end if;

  select count(*) into v_recent_store
    from public.orders
   where store_id = new.store_id
     and created_at > now() - interval '1 minute';

  if v_recent_store >= 20 then
    raise exception 'Demasiados pedidos em curto espaço de tempo. Tenta novamente.';
  end if;

  return new;
end;
$function$;


-- ══════════════════════════════════════════════════════════════════════
--  4. TRIGGERS
-- ══════════════════════════════════════════════════════════════════════

-- orders.trg_block_orders_suspended
DROP TRIGGER IF EXISTS trg_block_orders_suspended ON public.orders;
CREATE TRIGGER trg_block_orders_suspended BEFORE INSERT ON public.orders FOR EACH ROW EXECUTE FUNCTION block_orders_on_suspended_store();

-- orders.trg_validate_order
DROP TRIGGER IF EXISTS trg_validate_order ON public.orders;
CREATE TRIGGER trg_validate_order BEFORE INSERT ON public.orders FOR EACH ROW EXECUTE FUNCTION validate_new_order();

-- profiles.trg_plan_expires_sane
DROP TRIGGER IF EXISTS trg_plan_expires_sane ON public.profiles;
CREATE TRIGGER trg_plan_expires_sane BEFORE INSERT OR UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION chk_plan_expires_sane();

-- store_events.trg_limit_store_events
DROP TRIGGER IF EXISTS trg_limit_store_events ON public.store_events;
CREATE TRIGGER trg_limit_store_events BEFORE INSERT ON public.store_events FOR EACH ROW EXECUTE FUNCTION limit_store_events();


-- ══════════════════════════════════════════════════════════════════════
--  5. ESTRUTURA DAS TABELAS (referência — não executável)
--  Serve para consulta rápida: que colunas existem e de que tipo.
-- ══════════════════════════════════════════════════════════════════════

-- ── admin_orphan_payments ──
--   id                       bigint
--   created_at               timestamp with time zone
--   event                    text
--   customer_email           text
--   amount                   numeric
--   currency                 text
--   is_test                  boolean
--   webhook_id               text
--   raw                      jsonb

-- ── collections ──
--   id                       uuid NOT NULL  default: gen_random_uuid()
--   store_id                 uuid
--   name                     text NOT NULL
--   cover_image              text  default: ''::text
--   product_ids              ARRAY  default: '{}'::uuid[]
--   created_at               timestamp with time zone  default: now()

-- ── orders ──
--   id                       uuid NOT NULL  default: gen_random_uuid()
--   store_id                 uuid
--   customer_name            text NOT NULL
--   customer_phone           text
--   product_id               uuid
--   quantity                 integer  default: 1
--   status                   text  default: 'pendente'::text
--   created_at               timestamp with time zone  default: now()
--   city                     text  default: ''::text
--   amount                   numeric  default: 0
--   product_name             text  default: ''::text
--   customer_address         text  default: ''::text

-- ── payment_events ──
--   id                       bigint NOT NULL
--   webhook_id               text
--   event                    text
--   order_id                 text
--   customer_email           text
--   product_id               text
--   amount                   numeric
--   currency                 text
--   is_test                  boolean  default: false
--   matched_user             uuid
--   raw                      jsonb
--   created_at               timestamp with time zone NOT NULL  default: now()

-- ── products ──
--   id                       uuid NOT NULL  default: gen_random_uuid()
--   store_id                 uuid
--   name                     text NOT NULL
--   description              text
--   price                    numeric NOT NULL
--   image_url                text
--   stock                    integer  default: 0
--   created_at               timestamp with time zone  default: now()
--   category                 text  default: ''::text
--   cost                     numeric  default: 0
--   status                   text  default: 'active'::text
--   emoji                    text  default: '📦'::text
--   images                   ARRAY  default: '{}'::text[]
--   rating                   numeric  default: 0
--   sold_count               integer  default: 0
--   reviews                  jsonb  default: '[]'::jsonb
--   page_blocks              jsonb  default: '[]'::jsonb
--   upsell                   jsonb  default: '{"offers": [], "enabled": false}'::jsonb
--   guarantee_text           text  default: ''::text
--   compare_price            numeric  default: 0

-- ── profiles ──
--   id                       uuid NOT NULL
--   nome                     text
--   tel                      text
--   email                    text
--   plan                     text NOT NULL  default: 'none'::text
--   plan_status              text NOT NULL  default: 'blocked'::text
--   plan_expires_at          timestamp with time zone
--   subscription_id          text
--   subscription_status      text  default: 'none'::text
--   created_at               timestamp with time zone NOT NULL  default: now()
--   updated_at               timestamp with time zone NOT NULL  default: now()
--   is_admin                 boolean NOT NULL  default: false

-- ── store_events ──
--   id                       bigint NOT NULL
--   store_id                 uuid NOT NULL
--   event_type               text NOT NULL
--   product_id               uuid
--   session_id               text NOT NULL
--   created_at               timestamp with time zone NOT NULL  default: now()

-- ── stores ──
--   id                       uuid NOT NULL  default: gen_random_uuid()
--   user_id                  uuid
--   name                     text NOT NULL
--   theme                    jsonb  default: '{}'::jsonb
--   published                boolean  default: false
--   created_at               timestamp with time zone  default: now()
--   slug                     text
--   is_published             boolean  default: false
--   custom_domain            text
--   meta_pixel_id            text
--   is_suspended             boolean NOT NULL  default: false
--   onboarding               jsonb NOT NULL  default: '{}'::jsonb

-- ── subscription_config ──
--   id                       smallint NOT NULL  default: 1
--   grace_days               integer NOT NULL  default: 30
--   warning_days             integer NOT NULL  default: 7
--   sync_grace_hours         integer NOT NULL  default: 6

-- ── subscription_events ──
--   id                       bigint NOT NULL
--   user_id                  uuid
--   event                    text NOT NULL
--   detail                   jsonb
--   created_at               timestamp with time zone NOT NULL  default: now()

-- ── users ──
--   id                       uuid NOT NULL  default: gen_random_uuid()
--   name                     text NOT NULL
--   email                    text NOT NULL
--   password_hash            text NOT NULL
--   created_at               timestamp with time zone  default: now()


-- ══════════════════════════════════════════════════════════════════════
--  FIM
-- ══════════════════════════════════════════════════════════════════════