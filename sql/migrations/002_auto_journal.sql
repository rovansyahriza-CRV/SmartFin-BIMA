-- =====================================================================
-- SmartFin BIMA — Migration 002: Jurnal Otomatis (Fase 1)
-- Status : DRAFT — direview dulu, BELUM dijalankan
--
-- Event yang menghasilkan jurnal DRAFT otomatis:
--   A. vendorReceiving   (barang/jasa diterima dari vendor)
--   B. endUserReceiving  (material diserahkan ke end user)
--   C. materialReturn    (end user mengembalikan material)
--   D. vendor_invoice -> APPROVED  (hutang usaha diakui, PPN, PPh 23)
--   E. payment_schedule -> PAID    (pembayaran vendor / DP)
--
-- Prinsip penting:
--   1. Trigger TIDAK PERNAH menggagalkan transaksi SMMS. Kalau pembuatan
--      jurnal error, transaksi SMMS tetap tersimpan dan errornya dicatat
--      di finance.auto_journal_error untuk dicek Finance.
--   2. Semua jurnal otomatis berstatus DRAFT, baru POSTED lewat approve Finance.
--   3. Kalau data sumber diedit/dihapus:
--        - jurnal masih DRAFT  -> isinya diperbarui / di-VOID
--        - jurnal sudah POSTED -> dibuat jurnal penyesuaian (selisihnya saja)
--
-- Klasifikasi item (dikonfirmasi user 26 Nov 2026):
--   - Material, Consumables, Coating, dll  -> Persediaan (1-1600), jadi beban
--     proyek (5-1100) saat diserahkan ke end user
--   - Service Order                         -> jasa, langsung beban (5-1200)
--   - Tools / Heavy Equipment:
--       Duration di Request terisi = SEWA   -> langsung beban (5-1200)
--       Duration kosong            = BELI   -> harga/unit >= batas kapitalisasi:
--                                              Aset Tetap (1-2100)
--                                              di bawah batas: Beban Peralatan Kecil (5-1250)
--     Batas kapitalisasi disimpan di finance.setting (diisi Finance/akuntan).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Log error jurnal otomatis
-- ---------------------------------------------------------------------
create table finance.auto_journal_error (
  error_id      bigint generated always as identity primary key,
  source_table  text,
  source_id     text,
  source_event  text,
  error_message text,
  created_at    timestamptz not null default now(),
  resolved      boolean not null default false
);
alter table finance.auto_journal_error enable row level security;

-- ---------------------------------------------------------------------
-- 1. Akun tambahan, pengaturan, dan klasifikasi item
-- ---------------------------------------------------------------------
insert into finance.coa (account_code, account_name, account_type) values
  ('1-2100','Aset Tetap - Peralatan & Alat Berat','ASSET'),
  ('1-2900','Akumulasi Penyusutan Aset Tetap','ASSET'),
  ('5-1250','Beban Peralatan Kecil Proyek','EXPENSE'),
  ('6-1300','Beban Penyusutan','EXPENSE');

create table finance.setting (
  key        text primary key,
  value      text not null,
  notes      text,
  updated_by text,
  updated_at timestamptz not null default now()
);
alter table finance.setting enable row level security;

insert into finance.setting (key, value, notes) values
  ('capitalization_threshold', '0',
   'Batas kapitalisasi per unit (Rp) untuk pembelian Tools/Heavy Equipment. WAJIB ditetapkan Finance/akuntan. 0 = semua pembelian dicatat sebagai Aset Tetap.');

-- Tambah Duration (penanda sewa) ke view PO detail
create or replace view finance.v_po_detail_project with (security_invoker = true) as
select pod."PODetailID"  as po_detail_id,
       pod."POID"        as po_id,
       po."VendorID"     as vendor_id,
       po."DocType"      as doc_type,
       pod."ItemGroup"   as item_group,
       pod."ItemDescription" as item_description,
       pod."Qty"         as po_qty,
       pod."UnitPrice"   as po_unit_price,
       pod."Subtotal"    as po_subtotal,
       r."PROJECTID"     as smms_project_id,
       pm.project_id,
       r."WoID"          as wo_id,
       r."CostType"      as cost_type,
       r."Duration"      as rent_duration
from public."purchaseOrderDetail" pod
join public."purchaseOrder" po on po."POID" = pod."POID"
left join public."rfqDetail" rd on rd."RFQDetailID" = pod."RFQDetailID"
left join public.request r      on r."ID" = rd."RequestID"
left join finance.v_project_map pm on pm.smms_project_id = r."PROJECTID";

-- INVENTORY | SERVICE | RENTAL | PURCHASE (Tools/HE dibeli)
create or replace function finance.acquisition_kind(p_item_group text, p_doc_type text, p_duration numeric)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when coalesce(upper(p_doc_type),'') = 'SO'
      or regexp_replace(lower(coalesce(p_item_group,'')), '[^a-z]', '', 'g') in ('serviceorder','service')
      then 'SERVICE'
    when regexp_replace(lower(coalesce(p_item_group,'')), '[^a-z]', '', 'g') in ('tools','tool','heavyequipment')
      then case when coalesce(p_duration,0) > 0 then 'RENTAL' else 'PURCHASE' end
    else 'INVENTORY'
  end;
$$;

-- ---------------------------------------------------------------------
-- 2. Helper utama: buat / perbarui / sesuaikan jurnal dari satu event sumber
--    p_lines = jsonb array: [{"account":"1-1600","debit":100,"credit":0,
--                              "project_id":"uuid","vendor_id":1,"memo":"..."}]
--    Array kosong = sumber dihapus.
-- ---------------------------------------------------------------------
create or replace function finance.sync_auto_journal(
  p_source_system text,
  p_source_table  text,
  p_source_id     text,
  p_event         text,
  p_date          date,
  p_project_id    uuid,
  p_description   text,
  p_lines         jsonb
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_j        finance.journal%rowtype;
  v_new_id   bigint;
  v_has_diff boolean;
begin
  p_lines := coalesce(p_lines, '[]'::jsonb);

  select * into v_j from finance.journal
   where source_table = p_source_table and source_id = p_source_id and source_event = p_event;

  -- 2a. Belum ada jurnal
  if v_j.journal_id is null then
    if jsonb_array_length(p_lines) = 0 then return; end if;
    insert into finance.journal (journal_date, source_system, source_table, source_id, source_event,
                                 project_id, description, created_by)
    values (p_date, p_source_system, p_source_table, p_source_id, p_event,
            p_project_id, p_description, 'auto')
    returning journal_id into v_new_id;

    insert into finance.journal_line (journal_id, account_code, debit, credit, project_id, vendor_id, memo)
    select v_new_id, l->>'account', coalesce((l->>'debit')::numeric,0), coalesce((l->>'credit')::numeric,0),
           nullif(l->>'project_id','')::uuid, nullif(l->>'vendor_id','')::bigint, l->>'memo'
      from jsonb_array_elements(p_lines) l
     where coalesce((l->>'debit')::numeric,0) > 0 or coalesce((l->>'credit')::numeric,0) > 0;
    return;
  end if;

  -- 2b. Jurnal masih DRAFT / VOID: ganti isinya
  if v_j.status in ('DRAFT','VOID') then
    delete from finance.journal_line where journal_id = v_j.journal_id;
    if jsonb_array_length(p_lines) = 0 then
      update finance.journal set status = 'VOID', void_reason = 'Data sumber dihapus'
       where journal_id = v_j.journal_id;
      return;
    end if;
    update finance.journal
       set status = 'DRAFT', void_reason = null, journal_date = p_date,
           project_id = p_project_id, description = p_description
     where journal_id = v_j.journal_id;
    insert into finance.journal_line (journal_id, account_code, debit, credit, project_id, vendor_id, memo)
    select v_j.journal_id, l->>'account', coalesce((l->>'debit')::numeric,0), coalesce((l->>'credit')::numeric,0),
           nullif(l->>'project_id','')::uuid, nullif(l->>'vendor_id','')::bigint, l->>'memo'
      from jsonb_array_elements(p_lines) l
     where coalesce((l->>'debit')::numeric,0) > 0 or coalesce((l->>'credit')::numeric,0) > 0;
    return;
  end if;

  -- 2c. Jurnal sudah POSTED: buat jurnal penyesuaian sebesar selisihnya
  delete from finance.journal
   where source_table = p_source_table and source_id = p_source_id
     and source_event like p_event || '-ADJ-%' and status = 'DRAFT';

  create temporary table if not exists pg_temp._sfm_diff (
    account_code text, project_id uuid, vendor_id bigint, net numeric
  ) on commit drop;
  truncate pg_temp._sfm_diff;

  insert into pg_temp._sfm_diff
  with target as (
    select l->>'account' as account_code,
           nullif(l->>'project_id','')::uuid as project_id,
           nullif(l->>'vendor_id','')::bigint as vendor_id,
           sum(coalesce((l->>'debit')::numeric,0) - coalesce((l->>'credit')::numeric,0)) as net
      from jsonb_array_elements(p_lines) l
     group by 1,2,3
  ),
  posted as (
    select jl.account_code, jl.project_id, jl.vendor_id, sum(jl.debit - jl.credit) as net
      from finance.journal_line jl
      join finance.journal j on j.journal_id = jl.journal_id
     where j.source_table = p_source_table and j.source_id = p_source_id
       and (j.source_event = p_event or j.source_event like p_event || '-ADJ-%')
       and j.status = 'POSTED'
     group by 1,2,3
  )
  select coalesce(t.account_code, p.account_code),
         coalesce(t.project_id, p.project_id),
         coalesce(t.vendor_id, p.vendor_id),
         coalesce(t.net,0) - coalesce(p.net,0)
    from target t
    full join posted p
      on p.account_code = t.account_code
     and p.project_id is not distinct from t.project_id
     and p.vendor_id  is not distinct from t.vendor_id;

  select exists (select 1 from pg_temp._sfm_diff where round(net,2) <> 0) into v_has_diff;
  if not v_has_diff then return; end if;

  insert into finance.journal (journal_date, source_system, source_table, source_id, source_event,
                               project_id, description, created_by)
  values (current_date, p_source_system, p_source_table, p_source_id,
          p_event || '-ADJ-' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS'),
          p_project_id, 'Penyesuaian: ' || p_description, 'auto')
  returning journal_id into v_new_id;

  insert into finance.journal_line (journal_id, account_code, debit, credit, project_id, vendor_id, memo)
  select v_new_id, account_code,
         case when net > 0 then round(net,2) else 0 end,
         case when net < 0 then round(-net,2) else 0 end,
         project_id, vendor_id, 'Penyesuaian otomatis'
    from pg_temp._sfm_diff where round(net,2) <> 0;
end;
$$;

-- ---------------------------------------------------------------------
-- 3A. vendorReceiving: barang/jasa diterima dari vendor
--     Barang : Dr 1-1600 Persediaan        / Cr 2-1150 Hutang Belum Ditagih
--     Jasa   : Dr 5-1200 Beban Jasa/Sewa   / Cr 2-1150 Hutang Belum Ditagih
-- ---------------------------------------------------------------------
create or replace function finance.journal_vendor_receiving(p_receiving_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  r       record;
  v_amt   numeric;
  v_acct  text;
  v_kind  text;
  v_cap   numeric;
  v_lines jsonb := '[]'::jsonb;
begin
  select vr."ReceivingID", vr."QtyReceived", vr."ReceivedDate", vr."VendorDocNumber",
         d.po_detail_id, d.po_id, d.vendor_id, d.project_id, d.item_description,
         d.po_unit_price, d.item_group, d.doc_type, d.rent_duration, po."DocNumber"
    into r
    from public."vendorReceiving" vr
    join finance.v_po_detail_project d on d.po_detail_id = vr."PODetailID"
    join public."purchaseOrder" po on po."POID" = d.po_id
   where vr."ReceivingID" = p_receiving_id;

  if found then
    v_amt  := round(coalesce(r."QtyReceived",0) * coalesce(r.po_unit_price,0), 2);
    v_kind := finance.acquisition_kind(r.item_group, r.doc_type, r.rent_duration);
    select coalesce(nullif(value,'')::numeric, 0) into v_cap
      from finance.setting where key = 'capitalization_threshold';
    v_acct := case v_kind
                when 'INVENTORY' then '1-1600'
                when 'PURCHASE'  then case when coalesce(r.po_unit_price,0) >= coalesce(v_cap,0)
                                           then '1-2100' else '5-1250' end
                else '5-1200'
              end;
    if v_amt > 0 then
      v_lines := jsonb_build_array(
        jsonb_build_object('account', v_acct,   'debit', v_amt, 'credit', 0,
                           'project_id', r.project_id, 'vendor_id', r.vendor_id, 'memo', r.item_description),
        jsonb_build_object('account', '2-1150', 'debit', 0, 'credit', v_amt,
                           'project_id', r.project_id, 'vendor_id', r.vendor_id, 'memo', r."DocNumber"));
    end if;
  end if;

  perform finance.sync_auto_journal('SMMS', 'vendorReceiving', p_receiving_id::text, 'RECEIVED',
          coalesce(r."ReceivedDate"::date, current_date), r.project_id,
          'Penerimaan ' || coalesce(r."DocNumber",'PO') || ' - ' || coalesce(r.item_description,''),
          v_lines);
end;
$$;

-- ---------------------------------------------------------------------
-- 3B. endUserReceiving: material diserahkan ke end user (hanya barang persediaan)
--     Dr 5-1100 Beban Material Proyek / Cr 1-1600 Persediaan
-- ---------------------------------------------------------------------
create or replace function finance.journal_end_user_receiving(p_confirmation_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  r       record;
  v_amt   numeric;
  v_lines jsonb := '[]'::jsonb;
begin
  select eu."ConfirmationID", eu."QtyConfirmed", eu."ConfirmedDate", eu."NoTransaksi",
         d.project_id, d.vendor_id, d.item_description, d.po_unit_price, d.item_group, d.doc_type, d.rent_duration
    into r
    from public."endUserReceiving" eu
    join public."siteReceiving" sr on sr."ReceivingID" = eu."ReceivingID"
    join public.delivery dl        on dl."DeliveryID"  = sr."DeliveryID"
    join finance.v_po_detail_project d on d.po_detail_id = dl."PODetailID"
   where eu."ConfirmationID" = p_confirmation_id;

  if found and finance.acquisition_kind(r.item_group, r.doc_type, r.rent_duration) = 'INVENTORY' then
    v_amt := round(coalesce(r."QtyConfirmed",0) * coalesce(r.po_unit_price,0), 2);
    if v_amt > 0 then
      v_lines := jsonb_build_array(
        jsonb_build_object('account', '5-1100', 'debit', v_amt, 'credit', 0,
                           'project_id', r.project_id, 'memo', r.item_description),
        jsonb_build_object('account', '1-1600', 'debit', 0, 'credit', v_amt,
                           'project_id', r.project_id, 'memo', r."NoTransaksi"));
    end if;
  end if;

  perform finance.sync_auto_journal('SMMS', 'endUserReceiving', p_confirmation_id::text, 'ISSUED',
          coalesce(r."ConfirmedDate"::date, current_date), r.project_id,
          'Serah terima end user ' || coalesce(r."NoTransaksi",'') || ' - ' || coalesce(r.item_description,''),
          v_lines);
end;
$$;

-- ---------------------------------------------------------------------
-- 3C. materialReturn: end user mengembalikan material
--     Dr 1-1600 Persediaan / Cr 5-1100 Beban Material Proyek
-- ---------------------------------------------------------------------
create or replace function finance.journal_material_return(p_return_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  r       record;
  v_amt   numeric;
  v_lines jsonb := '[]'::jsonb;
begin
  select mr."ReturnID", mr."QtyReturned", mr."ReturnDate",
         d.project_id, d.item_description, d.po_unit_price, d.item_group, d.doc_type, d.rent_duration
    into r
    from public."materialReturn" mr
    join public."endUserReceiving" eu on eu."ConfirmationID" = mr."ConfirmationID"
    join public."siteReceiving" sr    on sr."ReceivingID"    = eu."ReceivingID"
    join public.delivery dl           on dl."DeliveryID"     = sr."DeliveryID"
    join finance.v_po_detail_project d on d.po_detail_id = dl."PODetailID"
   where mr."ReturnID" = p_return_id;

  if found and finance.acquisition_kind(r.item_group, r.doc_type, r.rent_duration) = 'INVENTORY' then
    v_amt := round(coalesce(r."QtyReturned",0) * coalesce(r.po_unit_price,0), 2);
    if v_amt > 0 then
      v_lines := jsonb_build_array(
        jsonb_build_object('account', '1-1600', 'debit', v_amt, 'credit', 0,
                           'project_id', r.project_id, 'memo', r.item_description),
        jsonb_build_object('account', '5-1100', 'debit', 0, 'credit', v_amt,
                           'project_id', r.project_id, 'memo', 'Retur material'));
    end if;
  end if;

  perform finance.sync_auto_journal('SMMS', 'materialReturn', p_return_id::text, 'RETURNED',
          coalesce(r."ReturnDate"::date, current_date), r.project_id,
          'Retur material - ' || coalesce(r.item_description,''), v_lines);
end;
$$;

-- ---------------------------------------------------------------------
-- 3D. vendor_invoice APPROVED: hutang usaha diakui
--     Dr 2-1150 Hutang Belum Ditagih (subtotal)
--     Dr 1-1400 PPN Masukan          (ppn)
--     Cr 2-1100 Hutang Usaha         (total)
--     Cr 2-1410 Hutang PPh 23        (pph23)
--     Syarat approve: semua baris invoice berstatus COCOK di 3-way match.
-- ---------------------------------------------------------------------
create or replace function finance.journal_vendor_invoice(p_invoice_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  i        record;
  v_proj   uuid;
  v_lines  jsonb := '[]'::jsonb;
begin
  select vi.*, po."DocNumber" as po_no, v."VendorName" as vendor_name
    into i
    from finance.vendor_invoice vi
    join public."purchaseOrder" po on po."POID" = vi.po_id
    join public.vendor v on v."VendorID" = vi.vendor_id
   where vi.invoice_id = p_invoice_id;

  select d.project_id into v_proj
    from finance.vendor_invoice_line l
    join finance.v_po_detail_project d on d.po_detail_id = l.po_detail_id
   where l.invoice_id = p_invoice_id
   limit 1;

  if i.invoice_id is not null and i.status in ('APPROVED','PARTIAL_PAID','PAID') then
    v_lines := jsonb_build_array(
      jsonb_build_object('account','2-1150','debit', i.subtotal,     'credit',0, 'project_id',v_proj,'vendor_id',i.vendor_id,'memo',i.invoice_no),
      jsonb_build_object('account','1-1400','debit', i.ppn_amount,   'credit',0, 'project_id',v_proj,'vendor_id',i.vendor_id,'memo',coalesce(i.faktur_pajak_no,i.invoice_no)),
      jsonb_build_object('account','2-1100','debit', 0, 'credit', i.total_amount, 'project_id',v_proj,'vendor_id',i.vendor_id,'memo',i.invoice_no),
      jsonb_build_object('account','2-1410','debit', 0, 'credit', i.pph23_amount, 'project_id',v_proj,'vendor_id',i.vendor_id,'memo','PPh 23 ' || i.invoice_no));
  end if;

  perform finance.sync_auto_journal('AP', 'vendor_invoice', p_invoice_id::text, 'APPROVED',
          coalesce(i.invoice_date, current_date), v_proj,
          'Invoice ' || coalesce(i.invoice_no,'') || ' - ' || coalesce(i.vendor_name,'') || ' (' || coalesce(i.po_no,'') || ')',
          v_lines);
end;
$$;

-- Validasi sebelum invoice boleh APPROVED
create or replace function finance.trg_vendor_invoice_validate()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'APPROVED'
     and (tg_op = 'INSERT' or (to_jsonb(old)->>'status') is distinct from 'APPROVED') then
    if not exists (select 1 from finance.vendor_invoice_line where invoice_id = new.invoice_id) then
      raise exception 'Invoice % belum punya baris item', new.invoice_no;
    end if;
    if exists (
      select 1
        from finance.vendor_invoice_line l
        join finance.v_three_way_match m on m.po_detail_id = l.po_detail_id
       where l.invoice_id = new.invoice_id and m.match_status <> 'COCOK'
    ) then
      raise exception 'Invoice % belum lolos 3-way match (cek qty/harga vs PO & penerimaan)', new.invoice_no;
    end if;
    new.approved_at := coalesce(new.approved_at, now());
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- 3E. payment_schedule PAID: pembayaran vendor
--     Sudah ada invoice : Dr 2-1100 Hutang Usaha      / Cr Bank
--     Belum ada invoice : Dr 1-1500 Uang Muka Vendor  / Cr Bank  (DP)
-- ---------------------------------------------------------------------
create or replace function finance.journal_payment(p_schedule_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  s       record;
  v_amt   numeric;
  v_proj  uuid;
  v_lines jsonb := '[]'::jsonb;
begin
  select ps.*, po."DocNumber" as po_no, po."VendorID" as vendor_id
    into s
    from finance.payment_schedule ps
    join public."purchaseOrder" po on po."POID" = ps.po_id
   where ps.schedule_id = p_schedule_id;

  select project_id into v_proj from finance.v_po_detail_project where po_id = s.po_id limit 1;

  if s.schedule_id is not null and s.status = 'PAID' then
    v_amt := coalesce(s.paid_amount, s.amount);
    if v_amt > 0 then
      v_lines := jsonb_build_array(
        jsonb_build_object('account', case when s.invoice_id is null then '1-1500' else '2-1100' end,
                           'debit', v_amt, 'credit', 0, 'project_id', v_proj, 'vendor_id', s.vendor_id,
                           'memo', coalesce(s.description, s.term_type)),
        jsonb_build_object('account', coalesce(s.paid_from_account, '1-1200'),
                           'debit', 0, 'credit', v_amt, 'project_id', v_proj, 'vendor_id', s.vendor_id,
                           'memo', s.payment_ref));
    end if;
  end if;

  perform finance.sync_auto_journal('AP', 'payment_schedule', p_schedule_id::text, 'PAID',
          coalesce(s.paid_at::date, current_date), v_proj,
          'Pembayaran ' || coalesce(s.po_no,'') || ' - ' || coalesce(s.description, s.term_type, ''),
          v_lines);
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Trigger: pemanggil yang aman (error tidak menggagalkan transaksi sumber)
-- ---------------------------------------------------------------------
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
    -- NEW kosong saat DELETE; ambil baris yang ada sebagai jsonb supaya aman lintas tabel
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
  return null;
end;
$$;

-- AFTER trigger: baris sumber sudah tersimpan saat jurnal dibuat.
-- (Untuk DELETE, fungsi journal_* tidak menemukan baris -> lines kosong -> VOID / jurnal pembalik.)
create trigger trg_sfm_vendor_receiving
  after insert or update or delete on public."vendorReceiving"
  for each row execute function finance.trg_auto_journal();

create trigger trg_sfm_end_user_receiving
  after insert or update or delete on public."endUserReceiving"
  for each row execute function finance.trg_auto_journal();

create trigger trg_sfm_material_return
  after insert or update or delete on public."materialReturn"
  for each row execute function finance.trg_auto_journal();

create trigger trg_sfm_vendor_invoice_validate
  before insert or update on finance.vendor_invoice
  for each row execute function finance.trg_vendor_invoice_validate();

create trigger trg_sfm_vendor_invoice
  after insert or update on finance.vendor_invoice
  for each row execute function finance.trg_auto_journal();

create trigger trg_sfm_payment
  after insert or update on finance.payment_schedule
  for each row execute function finance.trg_auto_journal();

-- Fungsi-fungsi ini hanya dipanggil trigger, bukan dari web
revoke execute on function finance.sync_auto_journal(text,text,text,text,date,uuid,text,jsonb) from public, anon, authenticated;
revoke execute on function finance.journal_vendor_receiving(bigint)   from public, anon, authenticated;
revoke execute on function finance.journal_end_user_receiving(bigint) from public, anon, authenticated;
revoke execute on function finance.journal_material_return(bigint)    from public, anon, authenticated;
revoke execute on function finance.journal_vendor_invoice(bigint)     from public, anon, authenticated;
revoke execute on function finance.journal_payment(bigint)            from public, anon, authenticated;
revoke execute on function finance.trg_auto_journal()                 from public, anon, authenticated;
revoke execute on function finance.trg_vendor_invoice_validate()      from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 5. Backfill: buat jurnal DRAFT untuk transaksi SMMS yang sudah ada
--    (6 penerimaan vendor, 5 serah terima end user, 2 retur per 26 Nov 2026)
-- ---------------------------------------------------------------------
select finance.journal_vendor_receiving("ReceivingID")      from public."vendorReceiving";
select finance.journal_end_user_receiving("ConfirmationID") from public."endUserReceiving";
select finance.journal_material_return("ReturnID")          from public."materialReturn";
