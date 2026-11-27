-- =====================================================================
-- SmartFin BIMA — Migration 005: Rekening Bank, Termin, Jadwal & Approval Pembayaran
-- Status : SUDAH DIJALANKAN ke Supabase (27 Nov 2026)
--
-- Keputusan user (27 Nov 2026):
--   * Rekening bank lebih dari satu -> master rekening, tiap rekening sub-akun COA 1-12xx
--   * Approve pembayaran (APY) dan tandai lunas boleh orang yang sama
--   * Jadwal uang muka dipicu PO/SO yang Approved
--
-- Alur:
--   PO Approved  -> termin Before Delivery / Partial: jadwal UANG MUKA (ADVANCE)
--   Invoice APPROVED -> jadwal PELUNASAN (SETTLEMENT) = total invoice - uang muka;
--                       uang muka yang sudah dibayar otomatis dipotongkan (jurnal Dr Hutang / Cr Uang Muka),
--                       uang muka yang belum dibayar dibatalkan dan digabung ke pelunasan
--   APY approve  -> status APPROVED
--   Tandai lunas -> status PAID + jurnal bank (lewat trigger 002)
--
-- Invoice kini bisa memuat BIAYA TAMBAHAN (mobilisasi / jasa lain) di luar item PO:
--   langsung dibebankan ke 5-1200, total dibatasi penawaran vendor di RFQ.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Perbaikan 004: ALL di kolom PIC juga memberi semua approval (super admin),
--    sesuai keputusan 26 Nov 2026 ("ALL di PIC atau Author = super admin")
-- ---------------------------------------------------------------------
create or replace function finance.check_session(
  p_token text, p_pic text[], p_author text default null, p_project_code text default null
) returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  who bigint; pics text[]; authors text[];
begin
  if p_token is null or length(p_token) <> 64 then
    raise exception 'Sesi tidak valid. Login kembali.' using errcode = '28000';
  end if;
  select s.employee_id,
         finance.tokens(coalesce(nullif(btrim(p."PIC"),''), p.pic)),
         finance.tokens(p."Author")
    into who, pics, authors
    from finance.sessions s
    join public."paswordTbl" p on p."Id" = s.employee_id
   where s.token_hash = sha256(convert_to(p_token,'UTF8'))
     and s.expires_at > now() and p."IsActive" = true
     and s.credential_hash = sha256(convert_to(coalesce(p."PasswordHas",''),'UTF8'));
  if who is null then
    raise exception 'Sesi berakhir atau akun dinonaktifkan. Login kembali.' using errcode = '28000';
  end if;
  if 'all' = any(pics) then authors := authors || pics; end if;
  if not (pics && p_pic) then
    raise exception 'Akun ini tidak punya akses ke menu tersebut.' using errcode = '42501';
  end if;
  if p_author is not null and not (
       lower(p_author) = any(authors)
       or (p_project_code is not null and lower(p_author || '-' || p_project_code) = any(authors))
     ) then
    raise exception 'Akun ini tidak punya level approval %.', upper(p_author) || coalesce(' untuk proyek ' || p_project_code, '')
      using errcode = '42501';
  end if;
  return who;
end;
$$;

-- ---------------------------------------------------------------------
-- 1. Rekening bank
-- ---------------------------------------------------------------------
create table finance.bank_account (
  bank_id        bigint generated always as identity primary key,
  bank_name      text not null,
  account_label  text not null,             -- mis. "Mandiri Operasional"
  account_last4  text check (account_last4 ~ '^[0-9]{4}$'),
  coa_code       text not null unique references finance.coa(account_code),
  is_active      boolean not null default true,
  created_at     timestamptz not null default now(),
  created_by     text
);
alter table finance.bank_account enable row level security;

-- ---------------------------------------------------------------------
-- 2. Termin vendor (kiriman terakhir per RFQVendorID) & normalisasi
-- ---------------------------------------------------------------------
create or replace function finance.term_kind(p_term text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_term is null or btrim(p_term) = ''                          then 'NET'
    when p_term ~* 'back\s*to\s*back'                                  then 'BACK_TO_BACK'
    when p_term ~* 'before|sebelum'                                    then 'BEFORE_DELIVERY'
    when p_term ~* 'partial|\mdp\M|uang muka'                          then 'PARTIAL'
    when p_term ~* 'net\s*[0-9]+|[0-9]+\s*(days|hari)'                 then 'NET'
    when p_term ~* 'after\s*received|setelah\s*(barang\s*)?diterima'   then 'AFTER_RECEIVED'
    else 'NET'
  end;
$$;

create or replace function finance.term_days(p_term text)
returns integer
language sql
immutable
set search_path = ''
as $$
  select coalesce(
    (regexp_match(coalesce(p_term,''), '(?i)net\s*([0-9]+)'))[1]::integer,
    (regexp_match(coalesce(p_term,''), '(?i)([0-9]+)\s*(days|hari)'))[1]::integer,
    case when finance.term_kind(p_term) = 'NET' then 30 else 0 end);
$$;

create or replace view finance.v_po_term with (security_invoker = true) as
select po."POID" as po_id, po."DocNumber" as po_number, po."VendorID" as vendor_id,
       po."Status" as po_status, po."ManagementApproval" as management_approval,
       po."TotalAmount" as po_total, po."CreatedDate" as po_date,
       t."PaymentTermType" as term_text,
       finance.term_kind(t."PaymentTermType") as term_kind,
       finance.term_days(t."PaymentTermType") as term_days,
       coalesce(t."DPPercentage", 0) as dp_pct,
       coalesce(t."MobilisasiCost", 0) as mobilisasi_cost,
       coalesce(t."OtherServiceCost", 0) as other_service_cost,
       coalesce(t."PPNAmount", 0) as term_ppn
from public."purchaseOrder" po
left join lateral (
  select * from public."rfqVendorTerm" x
   where x."RFQVendorID" = po."RFQVendorID"
   order by x."SubmitDate" desc nulls last, x."RFQVendorTermID" desc
   limit 1
) t on true;

-- ---------------------------------------------------------------------
-- 3. Jadwal bayar: kolom & status tambahan
-- ---------------------------------------------------------------------
alter table finance.payment_schedule drop constraint payment_schedule_status_check;
alter table finance.payment_schedule add constraint payment_schedule_status_check
  check (status in ('PLANNED','DUE','APPROVED','PAID','CANCELLED'));
alter table finance.payment_schedule
  add column schedule_type      text not null default 'SETTLEMENT' check (schedule_type in ('ADVANCE','SETTLEMENT')),
  add column waiting_client     boolean not null default false,
  add column bank_id            bigint references finance.bank_account(bank_id),
  add column approved_by        text,
  add column approved_at        timestamptz,
  add column paid_by            text,
  add column applied_invoice_id bigint references finance.vendor_invoice(invoice_id),
  add column parent_schedule_id bigint references finance.payment_schedule(schedule_id);

-- satu jadwal uang muka aktif per PO, satu pelunasan per invoice
create unique index payment_schedule_one_advance on finance.payment_schedule (po_id)
  where schedule_type = 'ADVANCE' and parent_schedule_id is null and status <> 'CANCELLED';
create unique index payment_schedule_one_settlement on finance.payment_schedule (invoice_id)
  where schedule_type = 'SETTLEMENT' and parent_schedule_id is null and status <> 'CANCELLED';

-- ---------------------------------------------------------------------
-- 4. Invoice: baris biaya tambahan (mobilisasi / jasa lain)
-- ---------------------------------------------------------------------
alter table finance.vendor_invoice_line alter column po_detail_id drop not null;
alter table finance.vendor_invoice_line
  add column charge_type text check (charge_type in ('MOBILISASI','OTHER_SERVICE')),
  add column description text;
alter table finance.vendor_invoice_line
  add constraint vendor_invoice_line_kind_check check ((po_detail_id is null) <> (charge_type is null));

-- 3-way match tidak ikut menghitung baris biaya tambahan (po_detail_id null) -> view 001 aman.

-- Validasi approve: item lolos 3-way match + biaya tambahan tidak melebihi penawaran RFQ
create or replace function finance.trg_vendor_invoice_validate()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare v_charge numeric; v_cap numeric;
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
    select coalesce(sum(l.subtotal),0) into v_charge
      from finance.vendor_invoice_line l
      join finance.vendor_invoice i on i.invoice_id = l.invoice_id
     where i.po_id = new.po_id and l.charge_type is not null and i.status <> 'CANCELLED';
    select mobilisasi_cost + other_service_cost into v_cap from finance.v_po_term where po_id = new.po_id;
    if v_charge > coalesce(v_cap,0) then
      raise exception 'Biaya tambahan invoice (Rp %) melebihi penawaran vendor di RFQ (Rp %)', v_charge, coalesce(v_cap,0);
    end if;
    new.approved_at := coalesce(new.approved_at, now());
  end if;
  return new;
end;
$$;

-- Jurnal invoice: item -> Dr 2-1150, biaya tambahan -> Dr 5-1200
create or replace function finance.journal_vendor_invoice(p_invoice_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  i        record;
  v_proj   uuid;
  v_items  numeric;
  v_charge numeric;
  v_lines  jsonb := '[]'::jsonb;
begin
  select vi.*, po."DocNumber" as po_no, v."VendorName" as vendor_name
    into i
    from finance.vendor_invoice vi
    join public."purchaseOrder" po on po."POID" = vi.po_id
    join public.vendor v on v."VendorID" = vi.vendor_id
   where vi.invoice_id = p_invoice_id;

  select d.project_id into v_proj
    from public."purchaseOrderDetail" pod
    join finance.v_po_detail_project d on d.po_detail_id = pod."PODetailID"
   where pod."POID" = i.po_id and d.project_id is not null
   limit 1;

  select coalesce(sum(subtotal) filter (where charge_type is null), 0),
         coalesce(sum(subtotal) filter (where charge_type is not null), 0)
    into v_items, v_charge
    from finance.vendor_invoice_line where invoice_id = p_invoice_id;

  if i.invoice_id is not null and i.status in ('APPROVED','PARTIAL_PAID','PAID') then
    v_lines := jsonb_build_array(
      jsonb_build_object('account','2-1150','debit', v_items,  'credit',0, 'project_id',v_proj,'vendor_id',i.vendor_id,'memo',i.invoice_no),
      jsonb_build_object('account','5-1200','debit', v_charge, 'credit',0, 'project_id',v_proj,'vendor_id',i.vendor_id,'memo','Mobilisasi / jasa lain ' || i.invoice_no),
      jsonb_build_object('account','1-1400','debit', i.ppn_amount, 'credit',0, 'project_id',v_proj,'vendor_id',i.vendor_id,'memo',coalesce(i.faktur_pajak_no,i.invoice_no)),
      jsonb_build_object('account','2-1100','debit', 0, 'credit', i.total_amount, 'project_id',v_proj,'vendor_id',i.vendor_id,'memo',i.invoice_no),
      jsonb_build_object('account','2-1410','debit', 0, 'credit', i.pph23_amount, 'project_id',v_proj,'vendor_id',i.vendor_id,'memo','PPh 23 ' || i.invoice_no));
  end if;

  perform finance.sync_auto_journal('AP', 'vendor_invoice', p_invoice_id::text, 'APPROVED',
          coalesce(i.invoice_date, current_date), v_proj,
          'Invoice ' || coalesce(i.invoice_no,'') || ' - ' || coalesce(i.vendor_name,'') || ' (' || coalesce(i.po_no,'') || ')',
          v_lines);
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Jadwal uang muka saat PO Approved
-- ---------------------------------------------------------------------
create or replace function finance.sync_po_advance(p_po_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  t        record;
  v_pct    numeric;
  v_amt    numeric;
  v_ok     boolean;
  v_cancel boolean;
begin
  select * into t from finance.v_po_term where po_id = p_po_id;
  if t.po_id is null then return; end if;

  v_cancel := coalesce(t.po_status,'') ~* 'cancel|reject|batal|tolak';
  v_ok     := not v_cancel and (upper(coalesce(t.po_status,'')) = 'APPROVED'
                                or upper(coalesce(t.management_approval,'')) = 'APPROVED');
  v_pct    := case t.term_kind when 'BEFORE_DELIVERY' then 100
                               when 'PARTIAL' then least(greatest(t.dp_pct,0),100)
                               else 0 end;
  v_amt    := round(coalesce(t.po_total,0) * v_pct / 100.0, 2);

  if v_cancel or not v_ok or v_amt <= 0 then
    -- PO batal / belum approved / termin tanpa uang muka: batalkan uang muka yang belum dibayar/disetujui
    update finance.payment_schedule set status = 'CANCELLED'
     where po_id = p_po_id and schedule_type = 'ADVANCE' and status in ('PLANNED','DUE');
    return;
  end if;

  insert into finance.payment_schedule (po_id, schedule_type, term_type, description, due_date, amount, status)
  values (p_po_id, 'ADVANCE', t.term_text,
          case when v_pct = 100 then 'Pembayaran 100% sebelum pengiriman' else 'Uang muka ' || v_pct || '%' end,
          coalesce(t.po_date::date, current_date), v_amt, 'PLANNED')
  on conflict (po_id) where schedule_type = 'ADVANCE' and parent_schedule_id is null and status <> 'CANCELLED'
  do update set amount = case when finance.payment_schedule.status in ('PLANNED','DUE') then excluded.amount
                              else finance.payment_schedule.amount end,
                description = excluded.description, term_type = excluded.term_type;
end;
$$;

create or replace function finance.trg_po_advance()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  begin
    perform finance.sync_po_advance(new."POID");
  exception when others then
    insert into finance.auto_journal_error (source_table, source_id, source_event, error_message)
    values ('purchaseOrder', new."POID"::text, 'ADVANCE_' || tg_op, sqlerrm);
  end;
  return null;
end;
$$;

create trigger trg_sfm_po_advance
  after insert or update of "Status", "ManagementApproval", "TotalAmount", "RFQVendorID" on public."purchaseOrder"
  for each row execute function finance.trg_po_advance();

-- ---------------------------------------------------------------------
-- 6. Jadwal pelunasan saat invoice APPROVED (+ potong uang muka)
-- ---------------------------------------------------------------------
create or replace function finance.create_settlement(p_invoice_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  i          finance.vendor_invoice%rowtype;
  t          record;
  v_applied  numeric := 0;
  v_amt      numeric;
  v_due      date;
  v_proj     uuid;
  v_lines    jsonb := '[]'::jsonb;
begin
  select * into i from finance.vendor_invoice where invoice_id = p_invoice_id;
  if i.invoice_id is null or i.status <> 'APPROVED' then return; end if;
  if exists (select 1 from finance.payment_schedule
              where invoice_id = p_invoice_id and schedule_type = 'SETTLEMENT' and status <> 'CANCELLED') then
    return;
  end if;
  select * into t from finance.v_po_term where po_id = i.po_id;

  -- uang muka yang belum dibayar/disetujui -> dibatalkan, digabung ke pelunasan
  update finance.payment_schedule set status = 'CANCELLED',
         description = coalesce(description,'') || ' (digabung ke pelunasan invoice ' || i.invoice_no || ')'
   where po_id = i.po_id and schedule_type = 'ADVANCE' and status in ('PLANNED','DUE');

  -- uang muka yang sudah dibayar & belum dipakai -> dipotongkan ke invoice ini
  with adv as (
    select schedule_id, coalesce(paid_amount, amount) as amt,
           sum(coalesce(paid_amount, amount)) over (order by schedule_id) as running
      from finance.payment_schedule
     where po_id = i.po_id and schedule_type = 'ADVANCE' and status = 'PAID' and applied_invoice_id is null
  ), picked as (
    select schedule_id, amt from adv where running - amt < i.total_amount
  ), upd as (
    update finance.payment_schedule ps set applied_invoice_id = p_invoice_id
      from picked where ps.schedule_id = picked.schedule_id
    returning picked.amt
  )
  select coalesce(sum(amt),0) into v_applied from upd;
  v_applied := least(v_applied, i.total_amount);

  if v_applied > 0 then
    select project_id into v_proj from finance.v_po_detail_project where po_id = i.po_id and project_id is not null limit 1;
    v_lines := jsonb_build_array(
      jsonb_build_object('account','2-1100','debit',v_applied,'credit',0,'project_id',v_proj,'vendor_id',i.vendor_id,'memo','Potong uang muka ' || i.invoice_no),
      jsonb_build_object('account','1-1500','debit',0,'credit',v_applied,'project_id',v_proj,'vendor_id',i.vendor_id,'memo','Uang muka dipakai'));
    perform finance.sync_auto_journal('AP', 'vendor_invoice', p_invoice_id::text, 'ADVANCE_APPLIED',
            coalesce(i.invoice_date, current_date), v_proj, 'Potong uang muka - invoice ' || i.invoice_no, v_lines);
  end if;

  v_amt := i.total_amount - v_applied;
  if v_amt <= 0 then return; end if;

  v_due := case coalesce(t.term_kind,'NET')
             when 'BACK_TO_BACK'   then null
             when 'NET'            then coalesce(i.invoice_date, current_date) + coalesce(t.term_days, 30)
             else coalesce(i.invoice_date, current_date)
           end;

  insert into finance.payment_schedule (po_id, invoice_id, schedule_type, term_type, description, due_date,
                                        amount, status, waiting_client)
  values (i.po_id, p_invoice_id, 'SETTLEMENT', t.term_text,
          'Pelunasan invoice ' || i.invoice_no || case when v_applied > 0 then ' (setelah potong uang muka)' else '' end,
          v_due, v_amt, 'PLANNED', coalesce(t.term_kind,'') = 'BACK_TO_BACK');
end;
$$;

create or replace function finance.trg_invoice_settlement()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'APPROVED' and (tg_op = 'INSERT' or (to_jsonb(old)->>'status') is distinct from 'APPROVED') then
    perform finance.create_settlement(new.invoice_id);
  end if;
  return null;
end;
$$;

create trigger trg_sfm_invoice_settlement
  after insert or update on finance.vendor_invoice
  for each row execute function finance.trg_invoice_settlement();

-- ---------------------------------------------------------------------
-- 7. API web
-- ---------------------------------------------------------------------
create or replace function finance.next_bank_coa()
returns text
language sql
set search_path = ''
as $$
  select '1-12' || lpad((coalesce(max(substring(account_code from 5)::integer), 0) + 1)::text, 2, '0')
    from finance.coa where account_code ~ '^1-12[0-9]{2}$' and account_code <> '1-1200';
$$;

create or replace function public.fin_save_bank(p_token text, p_bank_id bigint, p_bank_name text,
                                                p_account_label text, p_account_last4 text, p_is_active boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare who bigint; v_code text; v_id bigint;
begin
  who := finance.check_session(p_token, array['fin-ap']);
  if coalesce(btrim(p_bank_name),'') = '' or coalesce(btrim(p_account_label),'') = '' then
    raise exception 'Nama bank dan label rekening wajib diisi';
  end if;
  if p_bank_id is null then
    v_code := finance.next_bank_coa();
    insert into finance.coa (account_code, account_name, account_type, parent_code)
    values (v_code, 'Bank - ' || btrim(p_account_label), 'ASSET', '1-1200');
    insert into finance.bank_account (bank_name, account_label, account_last4, coa_code, created_by)
    values (btrim(p_bank_name), btrim(p_account_label), nullif(btrim(p_account_last4),''), v_code, finance.employee_name(who))
    returning bank_id into v_id;
  else
    update finance.bank_account
       set bank_name = btrim(p_bank_name), account_label = btrim(p_account_label),
           account_last4 = nullif(btrim(p_account_last4),''), is_active = coalesce(p_is_active, is_active)
     where bank_id = p_bank_id
    returning bank_id, coa_code into v_id, v_code;
    if v_id is null then raise exception 'Rekening % tidak ditemukan', p_bank_id; end if;
    update finance.coa set account_name = 'Bank - ' || btrim(p_account_label) where account_code = v_code;
  end if;
  return jsonb_build_object('bank_id', v_id, 'coa_code', v_code);
end;
$$;

create or replace function public.fin_payments(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform finance.check_session(p_token, array['fin-ap']);
  return jsonb_build_object(
    'schedules', (select coalesce(jsonb_agg(x order by x.sort_key, x.due_date nulls last, x.schedule_id), '[]'::jsonb) from (
       select ps.schedule_id, ps.schedule_type, ps.description, ps.term_type, ps.due_date, ps.amount, ps.status,
              ps.waiting_client, ps.approved_by, ps.approved_at, ps.paid_amount, ps.paid_at, ps.paid_by, ps.payment_ref,
              ps.applied_invoice_id, ps.po_id, po."DocNumber" as po_number, v."VendorName" as vendor_name,
              i.invoice_no, b.account_label as bank_label, p.code as project_code,
              case ps.status when 'APPROVED' then 1 when 'PLANNED' then 2 when 'DUE' then 2 when 'PAID' then 3 else 4 end as sort_key
         from finance.payment_schedule ps
         join public."purchaseOrder" po on po."POID" = ps.po_id
         left join public.vendor v on v."VendorID" = po."VendorID"
         left join finance.vendor_invoice i on i.invoice_id = ps.invoice_id
         left join finance.bank_account b on b.bank_id = ps.bank_id
         left join lateral (select pr.code from finance.v_po_detail_project d
                              join operational.projects pr on pr.id = d.project_id
                             where d.po_id = ps.po_id limit 1) p on true) x),
    'banks', (select coalesce(jsonb_agg(to_jsonb(b) order by b.is_active desc, b.bank_name), '[]'::jsonb) from finance.bank_account b),
    'bankBalances', (select coalesce(jsonb_object_agg(b.bank_id, coalesce(s.bal,0)), '{}'::jsonb)
                       from finance.bank_account b
                       left join (select l.account_code, sum(l.debit - l.credit) bal
                                    from finance.journal_line l join finance.journal j using (journal_id)
                                   where j.status <> 'VOID' group by 1) s on s.account_code = b.coa_code));
end;
$$;

create or replace function public.fin_approve_payment(p_token text, p_schedule_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare who bigint; v_code text;
begin
  select pr.code into v_code
    from finance.payment_schedule ps
    join finance.v_po_detail_project d on d.po_id = ps.po_id
    join operational.projects pr on pr.id = d.project_id
   where ps.schedule_id = p_schedule_id limit 1;
  who := finance.check_session(p_token, array['fin-ap'], 'APY', v_code);
  update finance.payment_schedule
     set status = 'APPROVED', approved_by = finance.employee_name(who), approved_at = now()
   where schedule_id = p_schedule_id and status in ('PLANNED','DUE');
  if not found then raise exception 'Jadwal % tidak bisa disetujui (status bukan Rencana)', p_schedule_id; end if;
  return jsonb_build_object('schedule_id', p_schedule_id, 'status', 'APPROVED');
end;
$$;

-- Tandai lunas. Bayar sebagian -> sisanya otomatis jadi jadwal baru (status Rencana).
create or replace function public.fin_mark_paid(p_token text, p_schedule_id bigint, p_bank_id bigint,
                                                p_paid_date date, p_paid_amount numeric, p_payment_ref text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare who bigint; s finance.payment_schedule%rowtype; b finance.bank_account%rowtype; v_amt numeric;
begin
  who := finance.check_session(p_token, array['fin-ap']);
  select * into s from finance.payment_schedule where schedule_id = p_schedule_id for update;
  if s.schedule_id is null then raise exception 'Jadwal % tidak ditemukan', p_schedule_id; end if;
  if s.status <> 'APPROVED' then raise exception 'Pembayaran harus disetujui (APY) dulu sebelum ditandai lunas'; end if;
  select * into b from finance.bank_account where bank_id = p_bank_id and is_active;
  if b.bank_id is null then raise exception 'Pilih rekening bank yang aktif'; end if;
  v_amt := coalesce(p_paid_amount, s.amount);
  if v_amt <= 0 or v_amt > s.amount then
    raise exception 'Nilai bayar harus lebih dari 0 dan tidak melebihi Rp %', s.amount;
  end if;

  if v_amt < s.amount then
    insert into finance.payment_schedule (po_id, invoice_id, schedule_type, term_type, description, due_date,
                                          amount, status, waiting_client, parent_schedule_id)
    values (s.po_id, s.invoice_id, s.schedule_type, s.term_type, 'Sisa: ' || coalesce(s.description,''),
            s.due_date, s.amount - v_amt, 'PLANNED', s.waiting_client, s.schedule_id);
    update finance.payment_schedule set amount = v_amt where schedule_id = s.schedule_id;
  end if;

  update finance.payment_schedule
     set status = 'PAID', bank_id = b.bank_id, paid_from_account = b.coa_code, paid_amount = v_amt,
         paid_at = coalesce(p_paid_date, current_date)::timestamptz, payment_ref = nullif(btrim(p_payment_ref),''),
         paid_by = finance.employee_name(who)
   where schedule_id = s.schedule_id;

  -- status invoice ikut: lunas penuh / sebagian
  if s.invoice_id is not null then
    update finance.vendor_invoice i
       set status = case when not exists (select 1 from finance.payment_schedule
                                           where invoice_id = i.invoice_id and status not in ('PAID','CANCELLED'))
                         then 'PAID' else 'PARTIAL_PAID' end
     where i.invoice_id = s.invoice_id and i.status in ('APPROVED','PARTIAL_PAID');
  end if;

  return jsonb_build_object('schedule_id', s.schedule_id, 'status', 'PAID', 'paid_amount', v_amt);
end;
$$;

-- fin_create_invoice: terima baris biaya tambahan
-- p_lines: [{"po_detail_id":17,"qty":2,"unit_price":1250000}, {"charge_type":"MOBILISASI","amount":100000,"description":"..."}]
create or replace function public.fin_create_invoice(
  p_token text, p_po_id bigint, p_invoice_no text, p_invoice_date date, p_due_date date,
  p_ppn_amount numeric, p_pph23_amount numeric, p_faktur_pajak_no text, p_notes text, p_lines jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare who bigint; v_id bigint; v_vendor bigint; v_sub numeric; v_charge numeric; v_cap numeric; v_hold text;
begin
  who := finance.check_session(p_token, array['fin-ap']);
  select "VendorID" into v_vendor from public."purchaseOrder" where "POID" = p_po_id;
  if v_vendor is null then raise exception 'PO % tidak ditemukan', p_po_id; end if;
  if p_lines is null or jsonb_array_length(p_lines) = 0 then raise exception 'Invoice harus punya minimal 1 baris'; end if;
  if exists (select 1 from jsonb_array_elements(p_lines) l
              left join public."purchaseOrderDetail" d on d."PODetailID" = (l->>'po_detail_id')::bigint
             where l ? 'po_detail_id' and d."POID" is distinct from p_po_id) then
    raise exception 'Ada baris item yang bukan milik PO ini';
  end if;
  if exists (select 1 from jsonb_array_elements(p_lines) l
              where not (l ? 'po_detail_id') and coalesce(l->>'charge_type','') not in ('MOBILISASI','OTHER_SERVICE')) then
    raise exception 'Jenis biaya tambahan harus MOBILISASI atau OTHER_SERVICE';
  end if;

  select sum(case when l ? 'po_detail_id' then round((l->>'qty')::numeric * (l->>'unit_price')::numeric, 2)
                  else round((l->>'amount')::numeric, 2) end)
    into v_sub from jsonb_array_elements(p_lines) l;

  insert into finance.vendor_invoice (invoice_no, vendor_id, po_id, invoice_date, due_date, subtotal,
                                      ppn_amount, pph23_amount, faktur_pajak_no, notes, created_by)
  values (btrim(p_invoice_no), v_vendor, p_po_id, p_invoice_date, p_due_date, v_sub,
          coalesce(p_ppn_amount,0), coalesce(p_pph23_amount,0), p_faktur_pajak_no, p_notes, finance.employee_name(who))
  returning invoice_id into v_id;

  insert into finance.vendor_invoice_line (invoice_id, po_detail_id, qty, unit_price, charge_type, description)
  select v_id,
         case when l ? 'po_detail_id' then (l->>'po_detail_id')::bigint end,
         case when l ? 'po_detail_id' then (l->>'qty')::numeric else 1 end,
         case when l ? 'po_detail_id' then (l->>'unit_price')::numeric else (l->>'amount')::numeric end,
         case when l ? 'po_detail_id' then null else l->>'charge_type' end,
         nullif(l->>'description','')
    from jsonb_array_elements(p_lines) l
   where (l ? 'po_detail_id' and (l->>'qty')::numeric > 0) or (not (l ? 'po_detail_id') and (l->>'amount')::numeric > 0);

  select string_agg(distinct m.item_description || ': ' || m.match_status, '; ') into v_hold
    from finance.vendor_invoice_line l
    join finance.v_three_way_match m on m.po_detail_id = l.po_detail_id
   where l.invoice_id = v_id and m.match_status <> 'COCOK';

  select coalesce(sum(l.subtotal),0) into v_charge
    from finance.vendor_invoice_line l join finance.vendor_invoice i on i.invoice_id = l.invoice_id
   where i.po_id = p_po_id and l.charge_type is not null and i.status <> 'CANCELLED';
  select mobilisasi_cost + other_service_cost into v_cap from finance.v_po_term where po_id = p_po_id;
  if v_charge > coalesce(v_cap,0) then
    v_hold := concat_ws('; ', v_hold, 'Biaya tambahan Rp ' || v_charge || ' melebihi penawaran RFQ Rp ' || coalesce(v_cap,0));
  end if;

  update finance.vendor_invoice
     set status = case when v_hold is null then 'MATCHED' else 'HOLD' end, hold_reason = v_hold
   where invoice_id = v_id;

  return (select jsonb_build_object('invoice_id', invoice_id, 'status', status, 'hold_reason', hold_reason,
                                    'total_amount', total_amount)
            from finance.vendor_invoice where invoice_id = v_id);
end;
$$;

-- fin_ap_overview: tambah info termin & biaya tambahan per PO
create or replace function public.fin_ap_overview(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform finance.check_session(p_token, array['fin-ap']);
  return jsonb_build_object(
    'poLines', (select coalesce(jsonb_agg(x order by x.po_id, x.po_detail_id), '[]'::jsonb) from (
       select m.*, po."DocNumber" as po_number, v."VendorName" as vendor_name, p.code as project_code
         from finance.v_three_way_match m
         join public."purchaseOrder" po on po."POID" = m.po_id
         left join public.vendor v on v."VendorID" = m.vendor_id
         left join operational.projects p on p.id = m.project_id) x),
    'poTerms', (select coalesce(jsonb_agg(jsonb_build_object(
                   'po_id', t.po_id, 'term_text', t.term_text, 'term_kind', t.term_kind, 'term_days', t.term_days,
                   'dp_pct', t.dp_pct, 'mobilisasi_cost', t.mobilisasi_cost, 'other_service_cost', t.other_service_cost,
                   'charges_invoiced', (select coalesce(sum(l.subtotal),0) from finance.vendor_invoice_line l
                                          join finance.vendor_invoice i on i.invoice_id = l.invoice_id
                                         where i.po_id = t.po_id and l.charge_type is not null and i.status <> 'CANCELLED'))), '[]'::jsonb)
                  from finance.v_po_term t),
    'invoices', (select coalesce(jsonb_agg(x order by x.invoice_id desc), '[]'::jsonb) from (
       select i.invoice_id, i.invoice_no, i.invoice_date, i.due_date, i.status, i.subtotal, i.ppn_amount,
              i.pph23_amount, i.total_amount, i.hold_reason, i.approved_by, i.approved_at,
              po."DocNumber" as po_number, v."VendorName" as vendor_name
         from finance.vendor_invoice i
         join public."purchaseOrder" po on po."POID" = i.po_id
         join public.vendor v on v."VendorID" = i.vendor_id) x));
end;
$$;

-- Dashboard: jatuh tempo termasuk yang sudah disetujui
create or replace function public.fin_dashboard(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform finance.check_session(p_token, array['fin','fin-ap','fin-jv','fin-bva','fin-ast']);
  return jsonb_build_object(
    'generatedAt', now(),
    'kpi', jsonb_build_object(
      'hutangBelumDitagih', (select coalesce(-sum(debit - credit),0) from finance.journal_line l
                               join finance.journal j using (journal_id)
                              where l.account_code = '2-1150' and j.status <> 'VOID'),
      'hutangUsaha',        (select coalesce(-sum(debit - credit),0) from finance.journal_line l
                               join finance.journal j using (journal_id)
                              where l.account_code = '2-1100' and j.status <> 'VOID'),
      'jatuhTempo7Hari',    (select coalesce(sum(amount),0) from finance.payment_schedule
                              where status in ('PLANNED','DUE','APPROVED') and due_date <= current_date + 7),
      'menungguApproval',   (select count(*) from finance.payment_schedule where status in ('PLANNED','DUE')),
      'siapDibayar',        (select coalesce(sum(amount),0) from finance.payment_schedule where status = 'APPROVED'),
      'budgetTotal',        (select coalesce(sum(budget_amount),0)    from finance.v_budget_vs_actual),
      'komitmenTotal',      (select coalesce(sum(committed_amount),0) from finance.v_budget_vs_actual),
      'realisasiTotal',     (select coalesce(sum(actual_amount),0)    from finance.v_budget_vs_actual),
      'jurnalDraft',        (select count(*) from finance.journal where status = 'DRAFT'),
      'asetPerluDilengkapi',(select count(*) from finance.fixed_asset where status in ('PERLU_DILENGKAPI','PERLU_DICEK')),
      'errorJurnal',        (select count(*) from finance.auto_journal_error where not resolved)
    ),
    'budgetVsActual', (select coalesce(jsonb_agg(to_jsonb(b) order by b.code), '[]'::jsonb)
                         from finance.v_budget_vs_actual b
                        where b.committed_amount > 0 or b.actual_amount > 0 or b.budget_amount > 0),
    'matchSummary',   (select coalesce(jsonb_object_agg(match_status, n), '{}'::jsonb)
                         from (select match_status, count(*) n from finance.v_three_way_match group by 1) m),
    'draftJournals',  (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
                         select j.journal_id, j.journal_date, j.source_system, j.description,
                                (select sum(debit) from finance.journal_line where journal_id = j.journal_id) as amount
                           from finance.journal j where j.status = 'DRAFT'
                          order by j.journal_date desc, j.journal_id desc limit 8) x),
    'upcomingPayments', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
                         select ps.schedule_id, ps.due_date, ps.amount, ps.status, ps.description, ps.waiting_client,
                                po."DocNumber" as po_number, v."VendorName" as vendor_name
                           from finance.payment_schedule ps
                           join public."purchaseOrder" po on po."POID" = ps.po_id
                           left join public.vendor v on v."VendorID" = po."VendorID"
                          where ps.status in ('PLANNED','DUE','APPROVED')
                          order by ps.due_date nulls last limit 8) x)
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 8. Hak eksekusi
-- ---------------------------------------------------------------------
revoke execute on function finance.term_kind(text)              from public, anon, authenticated;
revoke execute on function finance.term_days(text)              from public, anon, authenticated;
revoke execute on function finance.sync_po_advance(bigint)      from public, anon, authenticated;
revoke execute on function finance.trg_po_advance()             from public, anon, authenticated;
revoke execute on function finance.create_settlement(bigint)    from public, anon, authenticated;
revoke execute on function finance.trg_invoice_settlement()     from public, anon, authenticated;
revoke execute on function finance.next_bank_coa()              from public, anon, authenticated;
revoke execute on function finance.journal_vendor_invoice(bigint)  from public, anon, authenticated;
revoke execute on function finance.trg_vendor_invoice_validate()   from public, anon, authenticated;

revoke execute on function public.fin_save_bank(text, bigint, text, text, text, boolean) from public;
revoke execute on function public.fin_payments(text)                                     from public;
revoke execute on function public.fin_approve_payment(text, bigint)                      from public;
revoke execute on function public.fin_mark_paid(text, bigint, bigint, date, numeric, text) from public;
grant execute on function public.fin_save_bank(text, bigint, text, text, text, boolean)  to anon, authenticated;
grant execute on function public.fin_payments(text)                                      to anon, authenticated;
grant execute on function public.fin_approve_payment(text, bigint)                       to anon, authenticated;
grant execute on function public.fin_mark_paid(text, bigint, bigint, date, numeric, text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 9. Backfill: uang muka untuk PO yang sudah approved & pelunasan untuk invoice yang sudah approved
-- ---------------------------------------------------------------------
select finance.sync_po_advance("POID") from public."purchaseOrder";
select finance.create_settlement(invoice_id) from finance.vendor_invoice where status = 'APPROVED';
