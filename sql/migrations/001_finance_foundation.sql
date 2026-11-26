-- =====================================================================
-- SmartFin BIMA — Migration 001: Fondasi Finance (Fase 1)
-- Project Supabase : rovansyahriza-CRV's Project (nhmpwjriextmbotmvvbu)
-- Status           : DRAFT — direview dulu, BELUM dijalankan
--
-- Isi:
--   1. Schema `finance` (terpisah dari public/SMMS-Fusion4 & operational)
--   2. Chart of Accounts (COA) + seed awal  -> WAJIB direview akuntan
--   3. Budget proyek (RAB biaya) per kategori, refer ke operational.projects
--   4. Jurnal (header + baris), status DRAFT -> POSTED, cek balance saat posting
--   5. AP: vendor_invoice + baris, jadwal bayar
--   6. View: mapping proyek, 3-way match, Budget vs Actual
--
-- Trigger jurnal otomatis (vendorReceiving, endUserReceiving, payroll)
-- sengaja dipisah ke migration 002 supaya fondasi ini bisa direview dulu.
-- =====================================================================

create schema if not exists finance;

-- ---------------------------------------------------------------------
-- 1. Chart of Accounts
-- ---------------------------------------------------------------------
create table finance.coa (
  account_code  text primary key,
  account_name  text not null,
  account_type  text not null check (account_type in ('ASSET','LIABILITY','EQUITY','REVENUE','EXPENSE')),
  parent_code   text references finance.coa(account_code),
  is_postable   boolean not null default true,
  is_active     boolean not null default true,
  notes         text,
  created_at    timestamptz not null default now()
);

-- Seed awal (contoh struktur kontraktor; nomor & nama akun silakan disesuaikan akuntan BIMA)
insert into finance.coa (account_code, account_name, account_type) values
  ('1-1100','Kas Kecil (Petty Cash)','ASSET'),
  ('1-1200','Bank','ASSET'),
  ('1-1300','Piutang Usaha','ASSET'),
  ('1-1400','PPN Masukan','ASSET'),
  ('1-1500','Uang Muka Vendor (DP)','ASSET'),
  ('1-1600','Persediaan Material di Site','ASSET'),
  ('2-1100','Hutang Usaha Vendor','LIABILITY'),
  ('2-1150','Hutang Belum Ditagih (Barang Diterima)','LIABILITY'),
  ('2-1200','Hutang Gaji','LIABILITY'),
  ('2-1300','Hutang BPJS','LIABILITY'),
  ('2-1400','Hutang PPh 21','LIABILITY'),
  ('2-1410','Hutang PPh 23','LIABILITY'),
  ('2-1500','PPN Keluaran','LIABILITY'),
  ('2-2100','Cadangan Pesangon / Uang Kompensasi','LIABILITY'),
  ('3-1000','Modal','EQUITY'),
  ('4-1000','Pendapatan Kontrak','REVENUE'),
  ('5-1100','Beban Material Proyek','EXPENSE'),
  ('5-1200','Beban Jasa / Sewa Alat Proyek','EXPENSE'),
  ('5-1300','Beban Tenaga Kerja Proyek','EXPENSE'),
  ('5-1400','Beban Operasional Site (Petty Cash)','EXPENSE'),
  ('6-1000','Beban Gaji Overhead','EXPENSE'),
  ('6-1100','Beban BPJS Perusahaan','EXPENSE'),
  ('6-1200','Beban Pesangon / Uang Kompensasi','EXPENSE');

-- ---------------------------------------------------------------------
-- 2. Budget proyek (RAB biaya)
--    operational.projects = master proyek yang sudah ada (014, 015, 901-905, ...)
-- ---------------------------------------------------------------------
create table finance.project_budget (
  budget_id      bigint generated always as identity primary key,
  project_id     uuid not null references operational.projects(id),
  cost_category  text not null check (cost_category in
                   ('MATERIAL','CONSUMABLE','TOOLS','HEAVY_EQUIPMENT','SERVICE','MANPOWER','PETTY_CASH','OVERHEAD','OTHER')),
  amount         numeric(18,2) not null check (amount >= 0),
  revision       text not null default 'R0',
  notes          text,
  approved_by    text,
  approved_at    timestamptz,
  created_at     timestamptz not null default now(),
  unique (project_id, cost_category, revision)
);

-- ---------------------------------------------------------------------
-- 3. Jurnal
-- ---------------------------------------------------------------------
create table finance.journal (
  journal_id     bigint generated always as identity primary key,
  journal_no     text unique,
  journal_date   date not null default current_date,
  source_system  text not null check (source_system in ('SMMS','FUSION4','PETTY_CASH','AP','MANUAL')),
  source_table   text,          -- mis. 'vendorReceiving', 'payrollBulananTbl'
  source_id      text,          -- PK baris sumber (text supaya bisa bigint / uuid)
  source_event   text,          -- mis. 'RECEIVED', 'INVOICE_MATCHED', 'PAID'
  project_id     uuid references operational.projects(id),
  description    text not null,
  status         text not null default 'DRAFT' check (status in ('DRAFT','POSTED','VOID')),
  created_by     text,
  created_at     timestamptz not null default now(),
  posted_by      text,
  posted_at      timestamptz,
  void_reason    text,
  -- satu event sumber hanya boleh menghasilkan satu jurnal (anti dobel)
  unique (source_table, source_id, source_event)
);

create table finance.journal_line (
  line_id        bigint generated always as identity primary key,
  journal_id     bigint not null references finance.journal(journal_id) on delete cascade,
  account_code   text not null references finance.coa(account_code),
  debit          numeric(18,2) not null default 0 check (debit >= 0),
  credit         numeric(18,2) not null default 0 check (credit >= 0),
  project_id     uuid references operational.projects(id),
  vendor_id      bigint references public.vendor("VendorID"),
  karyawan_id    bigint,
  memo           text,
  check ((debit > 0 and credit = 0) or (credit > 0 and debit = 0))
);
create index on finance.journal_line (journal_id);
create index on finance.journal_line (account_code);
create index on finance.journal_line (project_id);

-- Posting: hanya jurnal DRAFT yang balance (total debit = total kredit) yang bisa POSTED
create or replace function finance.post_journal(p_journal_id bigint, p_posted_by text)
returns void
language plpgsql
as $$
declare
  v_debit  numeric;
  v_credit numeric;
  v_status text;
begin
  select status into v_status from finance.journal where journal_id = p_journal_id for update;
  if v_status is null then
    raise exception 'Jurnal % tidak ditemukan', p_journal_id;
  end if;
  if v_status <> 'DRAFT' then
    raise exception 'Jurnal % berstatus %, hanya DRAFT yang bisa diposting', p_journal_id, v_status;
  end if;

  select coalesce(sum(debit),0), coalesce(sum(credit),0)
    into v_debit, v_credit
    from finance.journal_line where journal_id = p_journal_id;

  if v_debit = 0 or v_debit <> v_credit then
    raise exception 'Jurnal % tidak balance (debit %, kredit %)', p_journal_id, v_debit, v_credit;
  end if;

  update finance.journal
     set status = 'POSTED', posted_by = p_posted_by, posted_at = now(),
         journal_no = coalesce(journal_no, 'JV-' || to_char(journal_date,'YYYYMM') || '-' || lpad(p_journal_id::text, 5, '0'))
   where journal_id = p_journal_id;
end;
$$;

-- ---------------------------------------------------------------------
-- 4. AP: invoice vendor & jadwal bayar
-- ---------------------------------------------------------------------
create table finance.vendor_invoice (
  invoice_id     bigint generated always as identity primary key,
  invoice_no     text not null,                 -- nomor invoice dari vendor
  vendor_id      bigint not null references public.vendor("VendorID"),
  po_id          bigint not null references public."purchaseOrder"("POID"),
  invoice_date   date not null,
  received_date  date not null default current_date,
  due_date       date,
  subtotal       numeric(18,2) not null default 0,
  ppn_amount     numeric(18,2) not null default 0,
  pph23_amount   numeric(18,2) not null default 0,   -- untuk Service Order
  total_amount   numeric(18,2) generated always as (subtotal + ppn_amount - pph23_amount) stored,
  faktur_pajak_no text,
  status         text not null default 'RECEIVED'
                   check (status in ('RECEIVED','MATCHED','HOLD','APPROVED','PARTIAL_PAID','PAID','CANCELLED')),
  hold_reason    text,
  file_url       text,
  notes          text,
  created_by     text,
  created_at     timestamptz not null default now(),
  approved_by    text,
  approved_at    timestamptz,
  unique (vendor_id, invoice_no)
);

create table finance.vendor_invoice_line (
  invoice_line_id bigint generated always as identity primary key,
  invoice_id      bigint not null references finance.vendor_invoice(invoice_id) on delete cascade,
  po_detail_id    bigint not null references public."purchaseOrderDetail"("PODetailID"),
  qty             numeric(18,4) not null check (qty > 0),
  unit_price      numeric(18,2) not null check (unit_price >= 0),
  subtotal        numeric(18,2) generated always as (round(qty * unit_price, 2)) stored
);
create index on finance.vendor_invoice_line (po_detail_id);

-- Jadwal bayar: dibentuk dari termin rfqVendorTerm (DP / 30 hari / back to back / dst)
create table finance.payment_schedule (
  schedule_id    bigint generated always as identity primary key,
  po_id          bigint not null references public."purchaseOrder"("POID"),
  invoice_id     bigint references finance.vendor_invoice(invoice_id),
  term_type      text,                -- disalin dari rfqVendorTerm.PaymentTermType
  description    text,                -- mis. 'DP 30%', 'Pelunasan 70%'
  due_date       date,
  amount         numeric(18,2) not null check (amount >= 0),
  status         text not null default 'PLANNED' check (status in ('PLANNED','DUE','PAID','CANCELLED')),
  paid_amount    numeric(18,2),
  paid_at        timestamptz,
  paid_from_account text references finance.coa(account_code),
  payment_ref    text,                -- nomor bukti transfer
  created_at     timestamptz not null default now()
);
create index on finance.payment_schedule (due_date);

-- ---------------------------------------------------------------------
-- 5. Views
-- ---------------------------------------------------------------------

-- Mapping proyek: request.PROJECTID (14, 15, 901 ...) = operational.projects.code ('014','015','901')
-- (Asumsi dari data yang ada; smms_project_id masih kosong. Kalau mapping dibetulkan, cukup ubah view ini.)
create or replace view finance.v_project_map with (security_invoker = true) as
select p.id as project_id,
       p.code,
       p.name,
       coalesce(p.smms_project_id, nullif(regexp_replace(p.code,'\D','','g'),'')::bigint) as smms_project_id
from operational.projects p;

-- Proyek per baris PO detail (PO detail -> rfqDetail -> request -> proyek)
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
       r."CostType"      as cost_type
from public."purchaseOrderDetail" pod
join public."purchaseOrder" po on po."POID" = pod."POID"
left join public."rfqDetail" rd on rd."RFQDetailID" = pod."RFQDetailID"
left join public.request r      on r."ID" = rd."RequestID"
left join finance.v_project_map pm on pm.smms_project_id = r."PROJECTID";

-- 3-way match per baris PO: dipesan vs diterima vs ditagih
create or replace view finance.v_three_way_match with (security_invoker = true) as
with rcv as (
  select "PODetailID" as po_detail_id, sum("QtyReceived") as qty_received
  from public."vendorReceiving" group by 1
),
inv as (
  select l.po_detail_id,
         sum(l.qty) as qty_invoiced,
         max(l.unit_price) as max_invoice_price,
         min(l.unit_price) as min_invoice_price
  from finance.vendor_invoice_line l
  join finance.vendor_invoice i on i.invoice_id = l.invoice_id
  where i.status <> 'CANCELLED'
  group by 1
)
select d.po_detail_id, d.po_id, d.vendor_id, d.project_id, d.item_description,
       d.po_qty, d.po_unit_price,
       coalesce(rcv.qty_received,0) as qty_received,
       coalesce(inv.qty_invoiced,0) as qty_invoiced,
       case
         when inv.po_detail_id is null                         then 'BELUM_DITAGIH'
         when inv.max_invoice_price > d.po_unit_price
           or inv.min_invoice_price < d.po_unit_price          then 'SELISIH_HARGA'
         when inv.qty_invoiced > coalesce(rcv.qty_received,0)  then 'SELISIH_QTY'
         when inv.qty_invoiced > d.po_qty                      then 'MELEBIHI_PO'
         else 'COCOK'
       end as match_status
from finance.v_po_detail_project d
left join rcv on rcv.po_detail_id = d.po_detail_id
left join inv on inv.po_detail_id = d.po_detail_id;

-- Budget vs Actual per proyek
--   budget     = RAB (revisi terbaru per kategori)
--   komitmen   = nilai PO yang sudah terbit (subtotal, sebelum PPN)
--   realisasi  = material yang sudah diserahkan ke end user x harga PO
--   (manpower dari payroll & petty cash ditambahkan di fase berikutnya)
create or replace view finance.v_budget_vs_actual with (security_invoker = true) as
with latest_budget as (
  select distinct on (project_id, cost_category) project_id, cost_category, amount
  from finance.project_budget
  order by project_id, cost_category, created_at desc
),
budget as (
  select project_id, sum(amount) as budget_amount from latest_budget group by 1
),
commitment as (
  select d.project_id, sum(d.po_subtotal) as committed_amount
  from finance.v_po_detail_project d
  join public."purchaseOrder" po on po."POID" = d.po_id
  where coalesce(po."Status",'') not in ('Cancelled','CANCELLED','Rejected','REJECTED')
  group by 1
),
actual as (
  select d.project_id, sum(eu."QtyConfirmed" * d.po_unit_price) as actual_amount
  from public."endUserReceiving" eu
  join public."siteReceiving" sr on sr."ReceivingID" = eu."ReceivingID"
  join public.delivery dl        on dl."DeliveryID"  = sr."DeliveryID"
  join finance.v_po_detail_project d on d.po_detail_id = dl."PODetailID"
  group by 1
)
select p.project_id, p.code, p.name,
       coalesce(b.budget_amount,0)     as budget_amount,
       coalesce(c.committed_amount,0)  as committed_amount,
       coalesce(a.actual_amount,0)     as actual_amount,
       coalesce(b.budget_amount,0) - coalesce(c.committed_amount,0) as remaining_after_commitment,
       case when coalesce(b.budget_amount,0) > 0
            then round(coalesce(a.actual_amount,0) / b.budget_amount * 100, 1) end as actual_pct
from finance.v_project_map p
left join budget b     on b.project_id = p.project_id
left join commitment c on c.project_id = p.project_id
left join actual a     on a.project_id = p.project_id;

-- ---------------------------------------------------------------------
-- 6. Keamanan
--    RLS aktif tanpa policy = tertutup untuk anon/authenticated.
--    Akses dari web nanti lewat RPC/policy khusus Finance (dibahas setelah review).
-- ---------------------------------------------------------------------
alter table finance.coa                 enable row level security;
alter table finance.project_budget      enable row level security;
alter table finance.journal             enable row level security;
alter table finance.journal_line        enable row level security;
alter table finance.vendor_invoice      enable row level security;
alter table finance.vendor_invoice_line enable row level security;
alter table finance.payment_schedule    enable row level security;
