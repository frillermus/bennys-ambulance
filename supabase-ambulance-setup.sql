-- Ambulancetjenestens prisliste og sagsdatabase.
-- Kør hele filen i SQL Editor i det samme Supabase-projekt som Benny's Original Motor Works.
-- Idempotent opsætning: kan køres igen uden at nulstille registrerede sager.

-- Medarbejderroller følger den eksisterende app's user_roles/is_admin-struktur.
create table if not exists public.user_roles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role text not null check (role in ('admin', 'employee')) default 'employee'
);
alter table public.user_roles enable row level security;
grant select on public.user_roles to authenticated;
drop policy if exists "Users can read own role" on public.user_roles;
create policy "Users can read own role" on public.user_roles
  for select to authenticated using (user_id = (select auth.uid()));

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.user_roles r
    where r.user_id = (select auth.uid()) and r.role = 'admin'
  )
$$;
revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to authenticated;

-- Priskatalog: eksplicitte vare-id'er gør, at klienten ikke selv kan bestemme priser.
create table if not exists public.ambulance_price_items (
  item_id text primary key,
  category text not null,
  name text not null,
  price numeric(12,2) not null check (price >= 0),
  sort_order integer not null default 0,
  is_active boolean not null default true
);
alter table public.ambulance_price_items enable row level security;
grant select on public.ambulance_price_items to authenticated;
drop policy if exists "Signed-in users can read ambulance prices" on public.ambulance_price_items;
create policy "Signed-in users can read ambulance prices" on public.ambulance_price_items
  for select to authenticated using (is_active);
drop policy if exists "Admins can manage ambulance prices" on public.ambulance_price_items;
create policy "Admins can manage ambulance prices" on public.ambulance_price_items
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

insert into public.ambulance_price_items (item_id, category, name, price, sort_order) values
  ('core-alternator','Kernedele','Alternator',6000,10),
  ('core-brakes','Kernedele','Brakes',800,20),
  ('core-fuel-injector','Kernedele','Fuel Injector',7500,30),
  ('core-power-steering-pump','Kernedele','Power Steering Pump',9000,40),
  ('core-radiator','Kernedele','Radiator',5000,50),
  ('core-transmission','Kernedele','Transmission',16000,60),
  ('ev-battery','Kernedele EV','EV Battery',18000,10),
  ('ev-electric-motor','Kernedele EV','Electric Motor',12000,20),
  ('ev-brakes','Kernedele EV','Brakes',800,30),
  ('service-air-filter','Servicedele','Air Filter',500,10),
  ('service-brake-pads','Servicedele','Brake Pads',1100,20),
  ('service-drive-belt','Servicedele','Drive Belt',650,30),
  ('service-fuel-filter','Servicedele','Fuel Filter',800,40),
  ('service-high-voltage-wiring','Servicedele','High Voltage Wiring',1400,50),
  ('service-oil-filter','Servicedele','Oil Filter',650,60),
  ('service-spark-plugs','Servicedele','Spark Plugs',1200,70),
  ('service-tire','Servicedele','Tire',520,80),
  ('fluid-battery-coolant','Væsker','Battery Coolant',250,10),
  ('fluid-brake-fluid','Væsker','Brake Fluid',250,20),
  ('fluid-coolant','Væsker','Coolant',130,30),
  ('fluid-steering-fluid','Væsker','Steering Fluid',260,40),
  ('fluid-transmission-fluid','Væsker','Transmission Fluid',200,50),
  ('vehicle-door','Bildele','Vehicle Door',650,10),
  ('vehicle-hood','Bildele','Vehicle Hood',1650,20),
  ('vehicle-trunk','Bildele','Vehicle Trunk',1300,30),
  ('vehicle-wheel','Bildele','Vehicle Wheel',260,40),
  ('vehicle-window','Bildele','Vehicle Window',325,50)
on conflict (item_id) do update set
  category = excluded.category,
  name = excluded.name,
  price = excluded.price,
  sort_order = excluded.sort_order,
  is_active = true;

-- Hver indlevering gemmes som én sag med dokumentation og serverberegnede beløb.
create table if not exists public.ambulance_cases (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  received_at timestamptz not null,
  created_by uuid references auth.users(id) on delete set null,
  created_by_name text not null default '',
  vehicle text not null,
  registration text not null,
  delivered_by text not null,
  visit_type text not null check (visit_type in ('regular', 'planned')),
  repairs_done boolean not null default false,
  work_description text not null default '',
  items jsonb not null default '[]'::jsonb check (jsonb_typeof(items) = 'array'),
  service_fee numeric(12,2) not null check (service_fee >= 0),
  repair_fee numeric(12,2) not null check (repair_fee >= 0),
  parts_total numeric(12,2) not null check (parts_total >= 0),
  total numeric(12,2) not null check (total >= 0)
);
create index if not exists ambulance_cases_received_at_idx on public.ambulance_cases (received_at desc);
create index if not exists ambulance_cases_month_idx on public.ambulance_cases (date_trunc('month', received_at));
alter table public.ambulance_cases enable row level security;
grant select on public.ambulance_cases to authenticated;
drop policy if exists "Signed-in users can read ambulance cases" on public.ambulance_cases;
create policy "Signed-in users can read ambulance cases" on public.ambulance_cases
  for select to authenticated using (true);
drop policy if exists "Admins can delete ambulance cases" on public.ambulance_cases;
create policy "Admins can delete ambulance cases" on public.ambulance_cases
  for delete to authenticated using (public.is_admin());

-- Only this RPC can add a case; prices and fees are calculated from the database, not trusted from the browser.
create or replace function public.save_ambulance_case(
  p_received_at timestamptz,
  p_vehicle text,
  p_registration text,
  p_delivered_by text,
  p_visit_type text,
  p_repairs_done boolean,
  p_work_description text,
  p_lines jsonb
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := (select auth.uid());
  v_line jsonb;
  v_item public.ambulance_price_items%rowtype;
  v_qty integer;
  v_items jsonb := '[]'::jsonb;
  v_parts_total numeric(12,2) := 0;
  v_service_fee numeric(12,2);
  v_repair_fee numeric(12,2) := 0;
  v_total numeric(12,2);
  v_id uuid;
  v_name text;
begin
  if v_uid is null then raise exception 'Ikke logget ind'; end if;
  if p_received_at is null then raise exception 'Dato og tidspunkt for modtagelse mangler'; end if;
  if nullif(btrim(p_vehicle), '') is null then raise exception 'Køretøjets mærke og model mangler'; end if;
  if nullif(btrim(p_registration), '') is null then raise exception 'Registreringsnummer mangler'; end if;
  if nullif(btrim(p_delivered_by), '') is null then raise exception 'Afleverende person mangler'; end if;
  if p_visit_type not in ('regular', 'planned') then raise exception 'Ugyldig besøgstype'; end if;
  if p_repairs_done and nullif(btrim(p_work_description), '') is null then
    raise exception 'Beskriv arbejdet eller reparationen';
  end if;
  if p_lines is null or jsonb_typeof(p_lines) is distinct from 'array' then
    raise exception 'Varelisten skal være en liste';
  end if;
  if jsonb_array_length(p_lines) > 100 then raise exception 'For mange varelinjer'; end if;

  for v_line in select value from jsonb_array_elements(p_lines)
  loop
    if jsonb_typeof(v_line) is distinct from 'object'
       or coalesce(v_line->>'id', '') = ''
       or coalesce(v_line->>'qty', '') !~ '^[0-9]+$' then
      raise exception 'Ugyldig varelinje';
    end if;
    v_qty := (v_line->>'qty')::integer;
    if v_qty < 1 or v_qty > 99 then raise exception 'Antal skal være mellem 1 og 99'; end if;
    select * into v_item from public.ambulance_price_items
      where item_id = v_line->>'id' and is_active = true;
    if not found then raise exception 'Varen findes ikke eller er ikke aktiv'; end if;
    v_parts_total := v_parts_total + v_item.price * v_qty;
    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'id', v_item.item_id, 'category', v_item.category, 'name', v_item.name,
      'qty', v_qty, 'unit_price', v_item.price, 'line_total', v_item.price * v_qty
    ));
  end loop;

  v_service_fee := case when p_visit_type = 'planned' then 500 else 1000 end;
  if p_repairs_done then
    v_repair_fee := case when p_visit_type = 'planned' then 2750 else 3000 end;
  end if;
  v_total := v_service_fee + v_repair_fee + v_parts_total;
  select coalesce(nullif(auth.jwt()->'user_metadata'->>'full_name', ''), auth.jwt()->>'email', '') into v_name;

  insert into public.ambulance_cases (
    received_at, created_by, created_by_name, vehicle, registration, delivered_by,
    visit_type, repairs_done, work_description, items, service_fee, repair_fee, parts_total, total
  ) values (
    p_received_at, v_uid, v_name, btrim(p_vehicle), btrim(p_registration), btrim(p_delivered_by),
    p_visit_type, coalesce(p_repairs_done, false), coalesce(btrim(p_work_description), ''),
    v_items, v_service_fee, v_repair_fee, v_parts_total, v_total
  ) returning id into v_id;

  return jsonb_build_object(
    'id', v_id, 'service_fee', v_service_fee, 'repair_fee', v_repair_fee,
    'parts_total', v_parts_total, 'total', v_total
  );
end
$$;
revoke all on function public.save_ambulance_case(timestamptz, text, text, text, text, boolean, text, jsonb) from public;
grant execute on function public.save_ambulance_case(timestamptz, text, text, text, text, boolean, text, jsonb) to authenticated;

-- Én månedlig fakturalinje pr. måned: fakturadato er sidste dag og forfaldsdato 15 dage senere.
create or replace view public.ambulance_monthly_invoice_summary
with (security_invoker = true) as
select
  date_trunc('month', received_at)::date as month_start,
  count(*)::integer as case_count,
  sum(total)::numeric(14,2) as total,
  (date_trunc('month', received_at) + interval '1 month - 1 day')::date as invoice_date,
  ((date_trunc('month', received_at) + interval '1 month - 1 day')::date + 15) as due_date
from public.ambulance_cases
group by date_trunc('month', received_at);
grant select on public.ambulance_monthly_invoice_summary to authenticated;

-- Live-opdateringer for sagslisten.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'ambulance_cases'
  ) then
    execute 'alter publication supabase_realtime add table public.ambulance_cases';
  end if;
end
$$;
