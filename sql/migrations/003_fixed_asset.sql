-- =====================================================================
-- SmartFin BIMA — Migration 003: Register Aset Tetap & Penyusutan
-- Status : DRAFT — direview dulu, BELUM dijalankan
--
-- Alur:
--   1. Tools/Heavy Equipment yang DIBELI (Duration kosong di Request) dan masuk
--      Aset Tetap (>= batas kapitalisasi) -> begitu diterima di SMMS, SmartFin
--      otomatis membuat 1 kartu aset PER UNIT, status PERLU_DILENGKAPI.
--      Data ditarik dari SMMS: item, kode item, PO, vendor, tanggal terima,
--      harga perolehan, proyek, site tujuan.
--   2. Finance melengkapi di SmartFin: kategori (umur default), umur manfaat,
--      nilai sisa, metode -> status otomatis jadi AKTIF.
--   3. Akhir bulan: finance.run_depreciation('2026-11-01') membuat jurnal DRAFT
--      Dr 6-1300 Beban Penyusutan / Cr 1-2900 Akumulasi Penyusutan
--      (per proyek, supaya bisa masuk Budget vs Actual).
--
-- Umur kategori di bawah = acuan kelompok harta fiskal (UU PPh Pasal 11).
-- Penggolongan tiap jenis alat & umur komersial: WAJIB dicek akuntan/konsultan pajak.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Sumber jurnal baru: ASSET
-- ---------------------------------------------------------------------
alter table finance.journal drop constraint journal_source_system_check;
alter table finance.journal add constraint journal_source_system_check
  check (source_system in ('SMMS','FUSION4','PETTY_CASH','AP','MANUAL','ASSET'));

-- ---------------------------------------------------------------------
-- 2. Kategori aset
-- ---------------------------------------------------------------------
create table finance.asset_category (
  category_code       text primary key,
  category_name       text not null,
  useful_life_months  integer not null check (useful_life_months > 0),
  default_method      text not null default 'STRAIGHT_LINE'
                        check (default_method in ('STRAIGHT_LINE','DECLINING_BALANCE')),
  notes               text
);
alter table finance.asset_category enable row level security;

insert into finance.asset_category (category_code, category_name, useful_life_months, notes) values
  ('KEL1', 'Kelompok 1 (umur 4 tahun)',   48, 'Contoh: alat kerja/perkakas kecil, alat ringan'),
  ('KEL2', 'Kelompok 2 (umur 8 tahun)',   96, 'Contoh: mesin & peralatan menengah'),
  ('KEL3', 'Kelompok 3 (umur 16 tahun)', 192, 'Contoh: mesin & alat berat tertentu'),
  ('KEL4', 'Kelompok 4 (umur 20 tahun)', 240, 'Contoh: mesin & alat berat tertentu');

-- ---------------------------------------------------------------------
-- 3. Kartu aset (1 baris = 1 unit)
-- ---------------------------------------------------------------------
create table finance.fixed_asset (
  asset_id             bigint generated always as identity primary key,
  asset_code           text unique,
  -- asal dari SMMS
  source_receiving_id  bigint not null,          -- public."vendorReceiving"."ReceivingID"
  unit_no              integer not null,          -- unit ke-1..n dari satu penerimaan
  po_id                bigint,
  po_detail_id         bigint,
  vendor_id            bigint,
  item_group           text,
  item_id              bigint,
  item_description     text,
  project_id           uuid references operational.projects(id),
  location             text,                      -- site tujuan dari delivery (bisa diubah Finance)
  acquisition_date     date not null,
  acquisition_cost     numeric(18,2) not null,    -- harga per unit dari PO
  -- dilengkapi Finance
  category_code        text references finance.asset_category(category_code),
  useful_life_months   integer check (useful_life_months > 0),
  residual_value       numeric(18,2) not null default 0 check (residual_value >= 0),
  method               text check (method in ('STRAIGHT_LINE','DECLINING_BALANCE')),
  depreciation_start   date,                      -- bulan pertama disusutkan
  status               text not null default 'PERLU_DILENGKAPI'
                         check (status in ('PERLU_DILENGKAPI','AKTIF','HABIS_DISUSUTKAN',
                                           'PERLU_DICEK','DIJUAL','DIHAPUS')),
  condition            text,
  notes                text,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  updated_by           text,
  unique (source_receiving_id, unit_no)
);
alter table finance.fixed_asset enable row level security;
create index on finance.fixed_asset (status);
create index on finance.fixed_asset (project_id);

create table finance.asset_depreciation (
  depreciation_id  bigint generated always as identity primary key,
  asset_id         bigint not null references finance.fixed_asset(asset_id),
  period           date not null check (period = date_trunc('month', period)::date),
  amount           numeric(18,2) not null check (amount >= 0),
  accumulated      numeric(18,2) not null,
  book_value       numeric(18,2) not null,
  created_at       timestamptz not null default now(),
  unique (asset_id, period)
);
alter table finance.asset_depreciation enable row level security;

-- ---------------------------------------------------------------------
-- 4. Kelengkapan otomatis: kode aset, umur default, status AKTIF
-- ---------------------------------------------------------------------
create or replace function finance.trg_fixed_asset_defaults()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  c finance.asset_category%rowtype;
begin
  if new.asset_code is null then
    new.asset_code := 'AST-' || to_char(new.acquisition_date, 'YYYY') || '-' || lpad(new.asset_id::text, 5, '0');
  end if;

  if new.category_code is not null then
    select * into c from finance.asset_category where category_code = new.category_code;
    new.useful_life_months := coalesce(new.useful_life_months, c.useful_life_months);
    new.method             := coalesce(new.method, c.default_method);
  end if;

  new.depreciation_start := coalesce(new.depreciation_start,
                                     (date_trunc('month', new.acquisition_date) + interval '1 month')::date);

  if new.status = 'PERLU_DILENGKAPI'
     and new.category_code is not null and new.useful_life_months is not null and new.method is not null then
    new.status := 'AKTIF';
  end if;

  new.updated_at := now();
  return new;
end;
$$;

create trigger trg_sfm_fixed_asset_defaults
  before insert or update on finance.fixed_asset
  for each row execute function finance.trg_fixed_asset_defaults();

-- ---------------------------------------------------------------------
-- 5. Tarik aset dari penerimaan SMMS (dipanggil trigger vendorReceiving)
-- ---------------------------------------------------------------------
create or replace function finance.sync_assets_from_receiving(p_receiving_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  r       record;
  v_cap   numeric;
  v_units integer := 0;
  i       integer;
begin
  select vr."ReceivingID", vr."QtyReceived", vr."ReceivedDate",
         d.po_id, d.po_detail_id, d.vendor_id, d.item_group, d.item_description, d.project_id,
         d.po_unit_price, d.doc_type, d.rent_duration, pod."ItemID" as item_id,
         (select dl."DestinationSite" from public.delivery dl
           where dl."PODetailID" = d.po_detail_id order by dl."DeliveryDate" desc nulls last limit 1) as site
    into r
    from public."vendorReceiving" vr
    join finance.v_po_detail_project d on d.po_detail_id = vr."PODetailID"
    join public."purchaseOrderDetail" pod on pod."PODetailID" = d.po_detail_id
   where vr."ReceivingID" = p_receiving_id;

  select coalesce(nullif(value,'')::numeric, 0) into v_cap
    from finance.setting where key = 'capitalization_threshold';

  if r."ReceivingID" is not null
     and finance.acquisition_kind(r.item_group, r.doc_type, r.rent_duration) = 'PURCHASE'
     and coalesce(r.po_unit_price,0) >= coalesce(v_cap,0) then
    v_units := greatest(floor(coalesce(r."QtyReceived",0))::integer, 0);
  end if;

  -- tambah unit yang belum ada
  for i in 1..v_units loop
    insert into finance.fixed_asset (source_receiving_id, unit_no, po_id, po_detail_id, vendor_id,
                                     item_group, item_id, item_description, project_id, location,
                                     acquisition_date, acquisition_cost)
    values (p_receiving_id, i, r.po_id, r.po_detail_id, r.vendor_id,
            r.item_group, r.item_id, r.item_description, r.project_id, r.site,
            coalesce(r."ReceivedDate"::date, current_date), coalesce(r.po_unit_price,0))
    on conflict (source_receiving_id, unit_no) do nothing;
  end loop;

  -- unit berlebih (qty dikurangi / penerimaan dihapus):
  -- belum pernah disusutkan -> hapus; sudah disusutkan -> tandai PERLU_DICEK
  delete from finance.fixed_asset fa
   where fa.source_receiving_id = p_receiving_id and fa.unit_no > v_units
     and not exists (select 1 from finance.asset_depreciation ad where ad.asset_id = fa.asset_id);
  update finance.fixed_asset
     set status = 'PERLU_DICEK', notes = coalesce(notes || ' | ', '') || 'Qty penerimaan SMMS berubah/dihapus'
   where source_receiving_id = p_receiving_id and unit_no > v_units and status <> 'PERLU_DICEK';
end;
$$;

-- Trigger jurnal otomatis vendorReceiving ikut menarik aset (blok terpisah:
-- kalau sinkron aset error, jurnal tetap jalan dan sebaliknya)
create or replace function finance.trg_auto_journal()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row jsonb;
  v_id  text;
begin
  begin
    if tg_op = 'DELETE' then v_row := to_jsonb(old); else v_row := to_jsonb(new); end if;
    if    tg_table_name = 'vendorReceiving'  then v_id := v_row->>'ReceivingID';
      perform finance.journal_vendor_receiving(v_id::bigint);
    elsif tg_table_name = 'endUserReceiving' then v_id := v_row->>'ConfirmationID';
      perform finance.journal_end_user_receiving(v_id::bigint);
    elsif tg_table_name = 'materialReturn'   then v_id := v_row->>'ReturnID';
      perform finance.journal_material_return(v_id::bigint);
    elsif tg_table_name = 'vendor_invoice'   then v_id := v_row->>'invoice_id';
      perform finance.journal_vendor_invoice(v_id::bigint);
    elsif tg_table_name = 'payment_schedule' then v_id := v_row->>'schedule_id';
      perform finance.journal_payment(v_id::bigint);
    end if;
  exception when others then
    insert into finance.auto_journal_error (source_table, source_id, source_event, error_message)
    values (tg_table_name, v_id, tg_op, sqlerrm);
  end;

  if tg_table_name = 'vendorReceiving' then
    begin
      perform finance.sync_assets_from_receiving(v_id::bigint);
    exception when others then
      insert into finance.auto_journal_error (source_table, source_id, source_event, error_message)
      values (tg_table_name, v_id, 'ASSET_' || tg_op, sqlerrm);
    end;
  end if;
  return null;
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Penyusutan bulanan
--    Garis lurus : (harga perolehan - nilai sisa) / umur bulan
--    Saldo menurun: nilai buku x (2 / umur bulan); bulan terakhir = sisa nilai buku
--    Aman dijalankan ulang untuk periode yang sama (aset baru ikut, yang sudah tidak dobel).
-- ---------------------------------------------------------------------
create or replace function finance.run_depreciation(p_period date, p_run_by text default null)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_period date := date_trunc('month', p_period)::date;
  a        record;
  v_acc    numeric;
  v_months integer;
  v_base   numeric;
  v_amt    numeric;
  v_count  integer := 0;
  v_lines  jsonb;
begin
  for a in
    select fa.* from finance.fixed_asset fa
     where fa.status = 'AKTIF'
       and fa.depreciation_start <= v_period
       and not exists (select 1 from finance.asset_depreciation ad
                        where ad.asset_id = fa.asset_id and ad.period = v_period)
  loop
    select coalesce(sum(amount),0), count(*) into v_acc, v_months
      from finance.asset_depreciation where asset_id = a.asset_id and period < v_period;

    v_base := a.acquisition_cost - a.residual_value;
    if v_base - v_acc <= 0 then
      update finance.fixed_asset set status = 'HABIS_DISUSUTKAN' where asset_id = a.asset_id;
      continue;
    end if;

    if a.method = 'DECLINING_BALANCE' then
      v_amt := round((a.acquisition_cost - v_acc) * 2.0 / a.useful_life_months, 2);
    else
      v_amt := round(v_base / a.useful_life_months, 2);
    end if;
    if v_months + 1 >= a.useful_life_months or v_amt > v_base - v_acc then
      v_amt := v_base - v_acc;   -- bulan terakhir / jangan melebihi nilai yang bisa disusutkan
    end if;

    insert into finance.asset_depreciation (asset_id, period, amount, accumulated, book_value)
    values (a.asset_id, v_period, v_amt, v_acc + v_amt, a.acquisition_cost - (v_acc + v_amt));
    v_count := v_count + 1;

    if v_base - (v_acc + v_amt) <= 0 then
      update finance.fixed_asset set status = 'HABIS_DISUSUTKAN' where asset_id = a.asset_id;
    end if;
  end loop;

  -- satu jurnal per periode, baris dikelompokkan per proyek
  select coalesce(jsonb_agg(l), '[]'::jsonb) into v_lines
    from (
      select jsonb_build_object('account','6-1300','debit', sum(ad.amount),'credit',0,
                                'project_id', fa.project_id, 'memo','Penyusutan ' || to_char(v_period,'MM/YYYY')) as l
        from finance.asset_depreciation ad join finance.fixed_asset fa using (asset_id)
       where ad.period = v_period group by fa.project_id
      union all
      select jsonb_build_object('account','1-2900','debit',0,'credit', sum(ad.amount),
                                'project_id', fa.project_id, 'memo','Akumulasi penyusutan ' || to_char(v_period,'MM/YYYY'))
        from finance.asset_depreciation ad join finance.fixed_asset fa using (asset_id)
       where ad.period = v_period group by fa.project_id
    ) x;

  perform finance.sync_auto_journal('ASSET', 'asset_depreciation', to_char(v_period,'YYYY-MM'), 'DEPRECIATION',
          (v_period + interval '1 month' - interval '1 day')::date, null,
          'Penyusutan aset tetap ' || to_char(v_period,'MM/YYYY'), v_lines);
  return v_count;
end;
$$;

-- ---------------------------------------------------------------------
-- 7. View register aset
-- ---------------------------------------------------------------------
create or replace view finance.v_asset_register with (security_invoker = true) as
select fa.asset_id, fa.asset_code, fa.status, fa.item_group, fa.item_id, fa.item_description,
       fa.unit_no, p.code as project_code, p.name as project_name, fa.location,
       v."VendorName" as vendor_name, po."DocNumber" as po_number,
       fa.acquisition_date, fa.acquisition_cost, fa.category_code, fa.useful_life_months,
       fa.residual_value, fa.method, fa.depreciation_start,
       coalesce(d.accumulated, 0)                        as accumulated_depreciation,
       fa.acquisition_cost - coalesce(d.accumulated, 0)  as book_value,
       d.last_period
from finance.fixed_asset fa
left join operational.projects p on p.id = fa.project_id
left join public.vendor v        on v."VendorID" = fa.vendor_id
left join public."purchaseOrder" po on po."POID" = fa.po_id
left join lateral (
  select sum(amount) as accumulated, max(period) as last_period
    from finance.asset_depreciation ad where ad.asset_id = fa.asset_id
) d on true;

-- ---------------------------------------------------------------------
-- 8. Hak akses & backfill
-- ---------------------------------------------------------------------
revoke execute on function finance.trg_fixed_asset_defaults()          from public, anon, authenticated;
revoke execute on function finance.sync_assets_from_receiving(bigint)  from public, anon, authenticated;
revoke execute on function finance.run_depreciation(date, text)        from public, anon, authenticated;
revoke execute on function finance.trg_auto_journal()                  from public, anon, authenticated;

select finance.sync_assets_from_receiving("ReceivingID") from public."vendorReceiving";
