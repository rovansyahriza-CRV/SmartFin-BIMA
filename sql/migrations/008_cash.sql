-- =====================================================================
-- SmartFin BIMA — Migration 008: Petty Cash Site, Pengeluaran Langsung, Kasbon
-- Status : ✅ Sudah dijalankan (27 Nov 2026)
--
-- Hak akses baru
--   PIC    FIN-PC : menu Kas & Kasbon (pemegang kas site input nota, ajukan isi kas / kasbon)
--   Author APC    : approve nota petty cash & nota kasbon (boleh pakai suffix proyek, mis. APC-014)
--   APY (lama)    : approve uang keluar dari bank (isi kas, pengeluaran langsung, kasbon)
--   FIN-AP (lama) : kelola kas site, input pengeluaran langsung, tandai dibayar, tutup kasbon
--
-- Alur
--   1. Isi kas site   : pengajuan -> APY -> dibayar dari bank HO      Dr Kas Site       / Cr Bank
--   2. Nota kas site  : input + foto nota -> APC                      Dr Beban (+PPN)   / Cr Kas Site
--   3. Peng. langsung : input + nota/tagihan -> APY -> dibayar         Dr Beban (+PPN)   / Cr Bank (+PPh23)
--   4. Kasbon         : pengajuan -> APY -> dibayar                    Dr Uang Muka Kary / Cr Bank
--      Nota kasbon    : input + foto nota -> APC                      Dr Beban (+PPN)   / Cr Uang Muka Kary
--      Tutup kasbon   : sisa dikembalikan / kekurangan dibayar        Dr/Cr Bank        / Uang Muka Kary
--   Plafon kas dan batas per nota diisi manual per kas site.
--   Nota dan pengeluaran langsung yang disetujui masuk ke realisasi Budget vs Actual proyek.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Hak akses: FIN-PC & APC
-- ---------------------------------------------------------------------
create or replace function finance.tokens(p_text text)
returns text[]
language sql
immutable
set search_path = ''
as $$
  with parsed as (
    select coalesce(array_agg(lower(btrim(x))) filter (where btrim(x) <> ''), array[]::text[]) as v
      from regexp_split_to_table(coalesce(p_text,''), '[,;\n\r]+') x
  )
  select case
           when 'all' = any(v)     then v || array['fin','fin-ap','fin-jv','fin-bva','fin-ast','fin-pc','ai','pj','ab','apy','apc']
           when 'fin-all' = any(v) then v || array['fin','fin-ap','fin-jv','fin-bva','fin-ast','fin-pc']
           else v end
    from parsed;
$$;

-- Dipakai di dalam API untuk membedakan HO (FIN-AP) dan pemegang kas (FIN-PC)
create or replace function finance.emp_has(p_who bigint, p_code text, p_project_code text default null)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  with t as (
    select finance.tokens(coalesce(nullif(btrim(p."PIC"),''), p.pic)) pics, finance.tokens(p."Author") auth
      from public."paswordTbl" p where p."Id" = p_who
  )
  -- PIC 'ALL' sudah diperluas finance.tokens() menjadi semua menu + semua level approval
  select coalesce((select lower(p_code) = any(pics || auth)
                       or (p_project_code is not null and lower(p_code || '-' || p_project_code) = any(auth))
                     from t), false);
$$;

create or replace function public.fin_login(p_id bigint, p_password text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  u record; a finance.login_attempts; v_token text; v_cred text; v_pics text[]; v_auth text[];
begin
  if p_id is null or p_password is null or length(p_password) > 1024 then
    return jsonb_build_object('error','Login gagal. Periksa akun dan password.');
  end if;
  perform pg_advisory_xact_lock(hashtextextended('smartfin-login:' || p_id::text, 0));
  delete from finance.sessions where expires_at < now();
  delete from finance.login_attempts where window_start < now() - interval '15 minutes';
  select * into a from finance.login_attempts where employee_id = p_id;
  if a.attempts >= 5 then
    return jsonb_build_object('error','Terlalu banyak percobaan. Coba lagi setelah 15 menit.');
  end if;
  insert into finance.login_attempts values (p_id, 1, now())
  on conflict (employee_id) do update set attempts = finance.login_attempts.attempts + 1;
  select * into u from public.verify_login(p_id, p_password) limit 1;
  if u.id is null then
    return jsonb_build_object('error','Login gagal. Periksa akun dan password.');
  end if;
  select finance.tokens(coalesce(nullif(btrim(p."PIC"),''), p.pic)), finance.tokens(p."Author"), p."PasswordHas"
    into v_pics, v_auth, v_cred
    from public."paswordTbl" p where p."Id" = p_id and p."IsActive" = true;
  if not (v_pics && array['fin','fin-ap','fin-jv','fin-bva','fin-ast','fin-pc']) then
    return jsonb_build_object('error','Akun ini belum punya akses SmartFin. Minta admin menambahkan PIC FIN.');
  end if;
  v_token := replace(gen_random_uuid()::text,'-','') || replace(gen_random_uuid()::text,'-','');
  insert into finance.sessions (token_hash, employee_id, credential_hash, expires_at)
  values (sha256(convert_to(v_token,'UTF8')), p_id,
          sha256(convert_to(v_cred,'UTF8')), now() + interval '8 hours');
  delete from finance.login_attempts where employee_id = p_id;
  return jsonb_build_object(
    'token', v_token, 'id', p_id, 'name', u.nama,
    'pic', (select coalesce(array_agg(x), array[]::text[]) from unnest(v_pics) x where x like 'fin%'),
    'author', (select coalesce(array_agg(x), array[]::text[]) from unnest(v_auth) x
                where x ~ '^(ai|pj|ab|apy|apc)(-|$)'),
    'expiresAt', now() + interval '8 hours');
end;
$$;

-- ---------------------------------------------------------------------
-- 1. COA & sumber jurnal
-- ---------------------------------------------------------------------
insert into finance.coa (account_code, account_name, account_type, is_postable, notes) values
  ('1-1700', 'Uang Muka Karyawan (Kasbon)', 'ASSET', true, 'Kasbon karyawan yang belum dipertanggungjawabkan')
on conflict (account_code) do nothing;

alter table finance.journal drop constraint journal_source_system_check;
alter table finance.journal add constraint journal_source_system_check
  check (source_system in ('SMMS','FUSION4','PETTY_CASH','AP','MANUAL','ASSET','CASH'));

-- Sub-akun kas per site: 1-1101, 1-1102, ...
create or replace function finance.next_cash_coa()
returns text
language sql
set search_path = ''
as $$
  select '1-11' || lpad((coalesce(max(substring(account_code from 5)::integer), 0) + 1)::text, 2, '0')
    from finance.coa where account_code ~ '^1-11[0-9]{2}$' and account_code <> '1-1100';
$$;

-- ---------------------------------------------------------------------
-- 2. Tabel
-- ---------------------------------------------------------------------
create table finance.cash_fund (
  fund_id       bigint generated always as identity primary key,
  fund_name     text not null,
  project_id    uuid references operational.projects(id),
  custodian_id  bigint not null,                 -- paswordTbl.Id pemegang kas
  coa_code      text not null unique references finance.coa(account_code),
  ceiling       numeric(18,2) not null check (ceiling > 0),          -- plafon kas
  max_per_note  numeric(18,2) not null check (max_per_note > 0),     -- batas per nota
  is_active     boolean not null default true,
  created_by    text,
  created_at    timestamptz not null default now()
);
alter table finance.cash_fund enable row level security;

-- Uang keluar dari bank HO: isi kas site, pengeluaran langsung, kasbon
create table finance.cash_request (
  request_id     bigint generated always as identity primary key,
  kind           text not null check (kind in ('TOPUP','DIRECT','KASBON')),
  fund_id        bigint references finance.cash_fund(fund_id),          -- TOPUP
  employee_id    bigint,                                                -- KASBON: karyawan penerima
  project_id     uuid references operational.projects(id),
  payee          text,                                                  -- DIRECT: penerima
  account_code   text references finance.coa(account_code),             -- DIRECT: akun beban
  amount         numeric(18,2) not null check (amount > 0),             -- DIRECT: total tagihan termasuk PPN
  ppn_amount     numeric(18,2) not null default 0 check (ppn_amount >= 0),
  pph23_amount   numeric(18,2) not null default 0 check (pph23_amount >= 0),
  due_date       date,
  description    text not null,
  status         text not null default 'PLANNED' check (status in ('PLANNED','APPROVED','PAID','CLOSED','REJECTED','CANCELLED')),
  requested_by   text,
  requested_by_id bigint,
  approved_by    text, approved_at timestamptz,
  reject_reason  text,
  bank_id        bigint references finance.bank_account(bank_id),
  paid_amount    numeric(18,2), paid_at date, paid_by text, payment_ref text,
  -- penutupan kasbon
  close_bank_id  bigint references finance.bank_account(bank_id),
  close_date     date, close_ref text, closed_by text,
  created_at     timestamptz not null default now(),
  check (kind <> 'TOPUP'  or fund_id is not null),
  check (kind <> 'KASBON' or employee_id is not null),
  check (kind <> 'DIRECT' or (account_code is not null and payee is not null and ppn_amount + pph23_amount < amount))
);
create index on finance.cash_request (kind, status);
alter table finance.cash_request enable row level security;

-- Nota: dari kas site atau dari kasbon
create table finance.cash_expense (
  expense_id     bigint generated always as identity primary key,
  source         text not null check (source in ('PETTY_CASH','KASBON')),
  fund_id        bigint references finance.cash_fund(fund_id),
  kasbon_id      bigint references finance.cash_request(request_id),
  expense_date   date not null,
  project_id     uuid references operational.projects(id),
  account_code   text not null references finance.coa(account_code),
  description    text not null,
  amount         numeric(18,2) not null check (amount > 0),   -- total nota termasuk PPN
  ppn_amount     numeric(18,2) not null default 0 check (ppn_amount >= 0),
  status         text not null default 'SUBMITTED' check (status in ('SUBMITTED','APPROVED','REJECTED')),
  submitted_by   text, submitted_by_id bigint,
  approved_by    text, approved_at timestamptz,
  reject_reason  text,
  created_at     timestamptz not null default now(),
  check ((source = 'PETTY_CASH') = (fund_id is not null)),
  check ((source = 'KASBON') = (kasbon_id is not null)),
  check (ppn_amount < amount)
);
create index on finance.cash_expense (fund_id, status);
create index on finance.cash_expense (kasbon_id, status);
alter table finance.cash_expense enable row level security;

-- ---------------------------------------------------------------------
-- 3. Dokumen: gate NOTA (nota kas / kasbon) & DIRECT (pengeluaran langsung)
-- ---------------------------------------------------------------------
alter table finance.document_type drop constraint document_type_gate_check;
alter table finance.document_type add constraint document_type_gate_check
  check (gate in ('ADVANCE','INVOICE','NOTA','DIRECT'));

insert into finance.document_type (doc_type, gate, doc_name, source, rule, setting_key, sort_order) values
  ('NOTA_RECEIPT', 'NOTA',   'Foto nota / kwitansi',          'UPLOAD', 'ALWAYS',   null, 10),
  ('NOTA_TAX',     'NOTA',   'Faktur Pajak',                  'UPLOAD', 'IF_PPN',   null, 20),
  ('DIR_BILL',     'DIRECT', 'Nota / tagihan',                'UPLOAD', 'ALWAYS',   null, 10),
  ('DIR_TAX',      'DIRECT', 'Faktur Pajak',                  'UPLOAD', 'IF_PPN',   null, 20),
  ('DIR_RECEIPT',  'DIRECT', 'Kwitansi',                      'UPLOAD', 'OPTIONAL', null, 30);

alter table finance.document add column expense_id bigint references finance.cash_expense(expense_id) on delete cascade;
alter table finance.document add column request_id bigint references finance.cash_request(request_id) on delete cascade;
alter table finance.document drop constraint document_check;
alter table finance.document add constraint document_check
  check (num_nonnulls(invoice_id, schedule_id, expense_id, request_id) = 1);
create index on finance.document (expense_id);
create index on finance.document (request_id);

create or replace function finance.doc_checklist(p_gate text, p_ref_id bigint)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_po_id bigint; v_is_so boolean; v_has_ppn boolean := false; v_lines bigint[];
  v_out jsonb := '[]'::jsonb; t record; v_req boolean; v_links jsonb; v_note text;
begin
  -- Nota kas / kasbon & pengeluaran langsung: hanya dokumen upload
  if p_gate in ('NOTA','DIRECT') then
    if p_gate = 'NOTA' then
      select e.ppn_amount > 0 into v_has_ppn from finance.cash_expense e where e.expense_id = p_ref_id;
      if not found then return '[]'::jsonb; end if;
    else
      select r.ppn_amount > 0 into v_has_ppn from finance.cash_request r where r.request_id = p_ref_id and r.kind = 'DIRECT';
      if not found then return '[]'::jsonb; end if;
    end if;
    for t in select * from finance.document_type where gate = p_gate and is_active order by sort_order loop
      v_req := case t.rule when 'ALWAYS' then true when 'IF_PPN' then v_has_ppn else false end;
      select coalesce(jsonb_agg(jsonb_build_object('doc_id', doc_id, 'label', coalesce(ref_no, file_name, 'Dokumen'),
               'url', file_url, 'uploaded_by', uploaded_by, 'uploaded_at', uploaded_at) order by uploaded_at), '[]'::jsonb)
        into v_links from finance.document
       where doc_type = t.doc_type
         and ((p_gate = 'NOTA' and expense_id = p_ref_id) or (p_gate = 'DIRECT' and request_id = p_ref_id));
      v_out := v_out || jsonb_build_object('doc_type', t.doc_type, 'doc_name', t.doc_name, 'source', t.source,
                 'required', v_req, 'ok', jsonb_array_length(v_links) > 0, 'items', v_links, 'note', null);
    end loop;
    return v_out;
  end if;

  if p_gate = 'INVOICE' then
    select i.po_id, i.ppn_amount > 0 into v_po_id, v_has_ppn from finance.vendor_invoice i where i.invoice_id = p_ref_id;
    select array_agg(po_detail_id) into v_lines from finance.vendor_invoice_line where invoice_id = p_ref_id and po_detail_id is not null;
  else
    select s.po_id into v_po_id from finance.payment_schedule s where s.schedule_id = p_ref_id;
  end if;
  if v_po_id is null then return '[]'::jsonb; end if;
  select upper(coalesce("DocType",'PO')) = 'SO' into v_is_so from public."purchaseOrder" where "POID" = v_po_id;
  if v_lines is null then
    select array_agg("PODetailID") into v_lines from public."purchaseOrderDetail" where "POID" = v_po_id;
  end if;
  for t in select * from finance.document_type where gate = p_gate and is_active order by sort_order loop
    v_note := null;
    v_req := case t.rule when 'ALWAYS' then true when 'IF_PO' then not v_is_so when 'IF_SO' then v_is_so when 'IF_PPN' then v_has_ppn
               when 'SETTING' then coalesce((select lower(value) in ('true','1','ya','yes') from finance.setting where key = t.setting_key), true)
               else false end;
    if t.source = 'SMMS' then
      v_links := case t.doc_type
        when 'ADV_PO' then (select coalesce(jsonb_agg(jsonb_build_object('label', "DocNumber", 'url', "ReportURL")), '[]'::jsonb)
                              from public."purchaseOrder" where "POID" = v_po_id and "ReportURL" is not null)
        when 'INV_PO' then (select coalesce(jsonb_agg(jsonb_build_object('label', "DocNumber", 'url', "ReportURL")), '[]'::jsonb)
                              from public."purchaseOrder" where "POID" = v_po_id and "ReportURL" is not null)
        when 'INV_DELIVERY' then (select coalesce(jsonb_agg(distinct jsonb_build_object('label', 'SJ ' || "VendorDocNumber", 'url', null)), '[]'::jsonb)
                              from public."vendorReceiving" where "PODetailID" = any(v_lines) and nullif(btrim("VendorDocNumber"),'') is not null)
        when 'INV_SITE_RECEIPT' then (
          select coalesce(jsonb_agg(distinct x.j), '[]'::jsonb) from (
            select jsonb_build_object('label', coalesce(sr."NoTransaksi", 'Terima site'), 'url', sr."ReportURL") j
              from public."siteReceiving" sr join public.delivery d on d."DeliveryID" = sr."DeliveryID"
             where d."PODetailID" = any(v_lines) and sr."ReportURL" is not null
            union all
            select jsonb_build_object('label', coalesce(eu."NoTransaksi", 'Hand over'), 'url', eu."ReportURL")
              from public."endUserReceiving" eu
              join public."siteReceiving" sr on sr."ReceivingID" = eu."ReceivingID"
              join public.delivery d on d."DeliveryID" = sr."DeliveryID"
             where d."PODetailID" = any(v_lines) and eu."ReportURL" is not null) x)
        else '[]'::jsonb end;
      if t.doc_type = 'INV_SITE_RECEIPT' and jsonb_array_length(v_links) = 0 then
        select string_agg(distinct concat_ws(' ', 'Dikirim', d."SuratJalanNo", 'ke ' || d."DestinationSite"), '; ')
          into v_note from public.delivery d
         where d."PODetailID" = any(v_lines)
           and not exists (select 1 from public."siteReceiving" sr where sr."DeliveryID" = d."DeliveryID");
        v_note := coalesce(v_note || ', belum dikonfirmasi terima di SMMS', 'Belum dikirim ke site di SMMS');
      end if;
    else
      select coalesce(jsonb_agg(jsonb_build_object('doc_id', doc_id, 'label', coalesce(ref_no, file_name, 'Dokumen'),
               'url', file_url, 'uploaded_by', uploaded_by, 'uploaded_at', uploaded_at,
               'bond_issuer', bond_issuer, 'bond_amount', bond_amount, 'bond_expiry', bond_expiry) order by uploaded_at), '[]'::jsonb)
        into v_links from finance.document
       where doc_type = t.doc_type
         and ((p_gate = 'INVOICE' and invoice_id = p_ref_id) or (p_gate = 'ADVANCE' and schedule_id = p_ref_id));
    end if;
    v_out := v_out || jsonb_build_object('doc_type', t.doc_type, 'doc_name', t.doc_name, 'source', t.source,
               'required', v_req, 'ok', jsonb_array_length(v_links) > 0, 'items', v_links, 'note', v_note);
  end loop;
  return v_out;
end; $$;

-- Boleh mengelola dokumen untuk gate & ref ini? (FIN-AP semua; FIN-PC hanya nota miliknya)
create or replace function finance.doc_access(p_who bigint, p_gate text, p_ref_id bigint)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when finance.emp_has(p_who, 'fin-ap') then true
    when p_gate = 'NOTA' then exists (
      select 1 from finance.cash_expense e
        left join finance.cash_fund f on f.fund_id = e.fund_id
        left join finance.cash_request k on k.request_id = e.kasbon_id
       where e.expense_id = p_ref_id
         and (e.submitted_by_id = p_who or f.custodian_id = p_who or k.employee_id = p_who or k.requested_by_id = p_who)
         and finance.emp_has(p_who, 'fin-pc'))
    else false end;
$$;

create or replace function public.fin_doc_checklist(p_token text, p_gate text, p_ref_id bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare who bigint;
begin
  who := finance.check_session(p_token, array['fin-ap','fin-pc']);
  if p_gate not in ('ADVANCE','INVOICE','NOTA','DIRECT') then raise exception 'Gate tidak dikenal'; end if;
  if not finance.doc_access(who, p_gate, p_ref_id)
     and not finance.emp_has(who, 'apc') and not finance.emp_has(who, 'apy') then
    raise exception 'Akun ini tidak punya akses ke dokumen tersebut.' using errcode = '42501';
  end if;
  return jsonb_build_object('gate', p_gate, 'ref_id', p_ref_id, 'items', finance.doc_checklist(p_gate, p_ref_id),
                            'missing', finance.doc_missing(p_gate, p_ref_id),
                            'locked', case p_gate
                              when 'INVOICE' then exists (select 1 from finance.vendor_invoice where invoice_id = p_ref_id
                                                            and status in ('APPROVED','PARTIAL_PAID','PAID'))
                              when 'ADVANCE' then exists (select 1 from finance.payment_schedule where schedule_id = p_ref_id
                                                            and status in ('APPROVED','PAID'))
                              when 'NOTA'    then exists (select 1 from finance.cash_expense where expense_id = p_ref_id
                                                            and status <> 'SUBMITTED')
                              else exists (select 1 from finance.cash_request where request_id = p_ref_id
                                             and status <> 'PLANNED') end
                              or not finance.doc_access(who, p_gate, p_ref_id));
end; $$;

create or replace function public.fin_add_document(
  p_token text, p_gate text, p_ref_id bigint, p_doc_type text, p_file_url text, p_file_id text,
  p_file_name text, p_ref_no text, p_bond_issuer text, p_bond_amount numeric, p_bond_expiry date, p_notes text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare who bigint; t finance.document_type%rowtype; v_id bigint;
begin
  who := finance.check_session(p_token, array['fin-ap','fin-pc']);
  if not finance.doc_access(who, p_gate, p_ref_id) then
    raise exception 'Akun ini tidak bisa menambah dokumen di sini.' using errcode = '42501';
  end if;
  select * into t from finance.document_type where doc_type = p_doc_type and is_active;
  if t.doc_type is null or t.gate <> p_gate or t.source <> 'UPLOAD' then
    raise exception 'Jenis dokumen % tidak bisa di-upload untuk tahap ini', p_doc_type;
  end if;
  if coalesce(p_file_url,'') !~* '^https://' then raise exception 'Link file tidak valid'; end if;
  if p_doc_type = 'ADV_BOND' and (coalesce(btrim(p_ref_no),'') = '' or p_bond_expiry is null) then
    raise exception 'Jaminan Uang Muka wajib diisi nomor jaminan dan tanggal berlaku';
  end if;
  if p_gate = 'INVOICE' and not exists (select 1 from finance.vendor_invoice where invoice_id = p_ref_id and status not in ('CANCELLED')) then
    raise exception 'Invoice % tidak ditemukan', p_ref_id;
  end if;
  if p_gate = 'ADVANCE' and not exists (select 1 from finance.payment_schedule where schedule_id = p_ref_id and schedule_type = 'ADVANCE') then
    raise exception 'Jadwal uang muka % tidak ditemukan', p_ref_id;
  end if;
  if p_gate = 'NOTA' and not exists (select 1 from finance.cash_expense where expense_id = p_ref_id and status = 'SUBMITTED') then
    raise exception 'Nota % tidak ditemukan atau sudah diproses', p_ref_id;
  end if;
  if p_gate = 'DIRECT' and not exists (select 1 from finance.cash_request where request_id = p_ref_id and kind = 'DIRECT' and status = 'PLANNED') then
    raise exception 'Pengeluaran % tidak ditemukan atau sudah disetujui', p_ref_id;
  end if;

  insert into finance.document (doc_type, invoice_id, schedule_id, expense_id, request_id, file_url, file_id, file_name, ref_no,
                                bond_issuer, bond_amount, bond_expiry, notes, uploaded_by)
  values (p_doc_type,
          case when p_gate = 'INVOICE' then p_ref_id end,
          case when p_gate = 'ADVANCE' then p_ref_id end,
          case when p_gate = 'NOTA'    then p_ref_id end,
          case when p_gate = 'DIRECT'  then p_ref_id end,
          p_file_url, p_file_id, p_file_name, nullif(btrim(p_ref_no),''),
          nullif(btrim(p_bond_issuer),''), p_bond_amount, p_bond_expiry, p_notes, finance.employee_name(who))
  returning doc_id into v_id;

  if p_gate = 'INVOICE' then perform finance.refresh_invoice_status(p_ref_id); end if;
  return jsonb_build_object('doc_id', v_id, 'missing', finance.doc_missing(p_gate, p_ref_id),
                            'invoice_status', (select status from finance.vendor_invoice where p_gate = 'INVOICE' and invoice_id = p_ref_id));
end;
$$;

create or replace function public.fin_remove_document(p_token text, p_doc_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare who bigint; d finance.document%rowtype; v_gate text; v_ref bigint;
begin
  who := finance.check_session(p_token, array['fin-ap','fin-pc']);
  select * into d from finance.document where doc_id = p_doc_id;
  if d.doc_id is null then raise exception 'Dokumen tidak ditemukan'; end if;
  v_gate := case when d.invoice_id is not null then 'INVOICE' when d.schedule_id is not null then 'ADVANCE'
                 when d.expense_id is not null then 'NOTA' else 'DIRECT' end;
  v_ref  := coalesce(d.invoice_id, d.schedule_id, d.expense_id, d.request_id);
  if not finance.doc_access(who, v_gate, v_ref) then
    raise exception 'Akun ini tidak bisa menghapus dokumen ini.' using errcode = '42501';
  end if;
  if d.invoice_id is not null and exists (select 1 from finance.vendor_invoice where invoice_id = d.invoice_id
                                           and status in ('APPROVED','PARTIAL_PAID','PAID')) then
    raise exception 'Dokumen invoice yang sudah di-approve tidak bisa dihapus';
  end if;
  if d.schedule_id is not null and exists (select 1 from finance.payment_schedule where schedule_id = d.schedule_id
                                            and status in ('APPROVED','PAID')) then
    raise exception 'Dokumen uang muka yang sudah disetujui tidak bisa dihapus';
  end if;
  if d.expense_id is not null and exists (select 1 from finance.cash_expense where expense_id = d.expense_id and status <> 'SUBMITTED') then
    raise exception 'Dokumen nota yang sudah diproses tidak bisa dihapus';
  end if;
  if d.request_id is not null and exists (select 1 from finance.cash_request where request_id = d.request_id and status <> 'PLANNED') then
    raise exception 'Dokumen pengeluaran yang sudah disetujui tidak bisa dihapus';
  end if;
  delete from finance.document where doc_id = p_doc_id;
  if d.invoice_id is not null then perform finance.refresh_invoice_status(d.invoice_id); end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Saldo kas & jurnal otomatis
-- ---------------------------------------------------------------------
-- Saldo kas site menurut jurnal (tidak termasuk VOID)
create or replace function finance.fund_balance(p_fund_id bigint)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(l.debit - l.credit), 0)
    from finance.cash_fund f
    join finance.journal_line l on l.account_code = f.coa_code
    join finance.journal j on j.journal_id = l.journal_id and j.status <> 'VOID'
   where f.fund_id = p_fund_id;
$$;

create or replace function finance.journal_cash_request(p_request_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record; v_lines jsonb := '[]'::jsonb; v_close jsonb := '[]'::jsonb; v_desc text; v_bank text; v_settled numeric; v_diff numeric;
begin
  select cr.*, f.coa_code as fund_coa, f.fund_name, f.project_id as fund_project, b.coa_code as bank_coa, cb.coa_code as close_bank_coa
    into r
    from finance.cash_request cr
    left join finance.cash_fund f on f.fund_id = cr.fund_id
    left join finance.bank_account b on b.bank_id = cr.bank_id
    left join finance.bank_account cb on cb.bank_id = cr.close_bank_id
   where cr.request_id = p_request_id;
  if r.request_id is null then return; end if;
  v_bank := coalesce(r.bank_coa, '1-1200');
  v_desc := case r.kind when 'TOPUP' then 'Isi kas ' || coalesce(r.fund_name,'')
                        when 'DIRECT' then 'Pengeluaran langsung: ' || coalesce(r.payee,'')
                        else 'Kasbon ' || finance.employee_name(r.employee_id) end || ' - ' || r.description;

  if r.status in ('PAID','CLOSED') then
    if r.kind = 'TOPUP' then
      v_lines := jsonb_build_array(
        jsonb_build_object('account', r.fund_coa, 'debit', r.paid_amount, 'project_id', coalesce(r.project_id, r.fund_project), 'memo', r.description),
        jsonb_build_object('account', v_bank, 'credit', r.paid_amount, 'project_id', coalesce(r.project_id, r.fund_project), 'memo', r.payment_ref));
    elsif r.kind = 'DIRECT' then
      v_lines := jsonb_build_array(
        jsonb_build_object('account', r.account_code, 'debit', r.amount - r.ppn_amount, 'project_id', r.project_id, 'memo', r.payee || ' - ' || r.description),
        jsonb_build_object('account', '1-1400', 'debit', r.ppn_amount, 'project_id', r.project_id, 'memo', 'PPN masukan'),
        jsonb_build_object('account', '2-1410', 'credit', r.pph23_amount, 'project_id', r.project_id, 'memo', 'PPh 23 dipotong'),
        jsonb_build_object('account', v_bank, 'credit', r.amount - r.pph23_amount, 'project_id', r.project_id, 'memo', r.payment_ref));
    else
      v_lines := jsonb_build_array(
        jsonb_build_object('account', '1-1700', 'debit', r.paid_amount, 'project_id', r.project_id, 'memo', 'Kasbon ' || finance.employee_name(r.employee_id)),
        jsonb_build_object('account', v_bank, 'credit', r.paid_amount, 'project_id', r.project_id, 'memo', r.payment_ref));
    end if;
  end if;
  perform finance.sync_auto_journal(case when r.kind = 'TOPUP' then 'PETTY_CASH' else 'CASH' end,
          'cash_request', p_request_id::text, 'PAID', coalesce(r.paid_at, current_date),
          coalesce(r.project_id, r.fund_project), v_desc, v_lines);

  -- Penutupan kasbon: selisih kasbon vs nota disetujui
  if r.kind = 'KASBON' then
    if r.status = 'CLOSED' then
      select coalesce(sum(amount),0) into v_settled from finance.cash_expense where kasbon_id = r.request_id and status = 'APPROVED';
      v_diff := r.paid_amount - v_settled;     -- > 0: karyawan mengembalikan sisa; < 0: perusahaan membayar kekurangan
      if v_diff > 0 then
        v_close := jsonb_build_array(
          jsonb_build_object('account', coalesce(r.close_bank_coa, '1-1200'), 'debit', v_diff, 'project_id', r.project_id, 'memo', 'Pengembalian sisa kasbon ' || coalesce(r.close_ref,'')),
          jsonb_build_object('account', '1-1700', 'credit', v_diff, 'project_id', r.project_id, 'memo', 'Tutup kasbon'));
      elsif v_diff < 0 then
        v_close := jsonb_build_array(
          jsonb_build_object('account', '1-1700', 'debit', -v_diff, 'project_id', r.project_id, 'memo', 'Tutup kasbon'),
          jsonb_build_object('account', coalesce(r.close_bank_coa, '1-1200'), 'credit', -v_diff, 'project_id', r.project_id, 'memo', 'Kekurangan kasbon dibayar ' || coalesce(r.close_ref,'')));
      end if;
    end if;
    perform finance.sync_auto_journal('CASH', 'cash_request', p_request_id::text, 'CLOSE', coalesce(r.close_date, current_date),
            r.project_id, 'Tutup kasbon ' || finance.employee_name(r.employee_id) || ' - ' || r.description, v_close);
  end if;
end;
$$;

create or replace function finance.journal_cash_expense(p_expense_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare e record; v_lines jsonb := '[]'::jsonb;
begin
  select ce.*, f.coa_code as fund_coa, f.fund_name, k.employee_id
    into e
    from finance.cash_expense ce
    left join finance.cash_fund f on f.fund_id = ce.fund_id
    left join finance.cash_request k on k.request_id = ce.kasbon_id
   where ce.expense_id = p_expense_id;
  if e.expense_id is null then return; end if;
  if e.status = 'APPROVED' then
    v_lines := jsonb_build_array(
      jsonb_build_object('account', e.account_code, 'debit', e.amount - e.ppn_amount, 'project_id', e.project_id, 'memo', e.description),
      jsonb_build_object('account', '1-1400', 'debit', e.ppn_amount, 'project_id', e.project_id, 'memo', 'PPN masukan'),
      jsonb_build_object('account', case when e.source = 'PETTY_CASH' then e.fund_coa else '1-1700' end,
                         'credit', e.amount, 'project_id', e.project_id,
                         'memo', case when e.source = 'PETTY_CASH' then e.fund_name else 'Kasbon ' || finance.employee_name(e.employee_id) end));
  end if;
  perform finance.sync_auto_journal(case when e.source = 'PETTY_CASH' then 'PETTY_CASH' else 'CASH' end,
          'cash_expense', p_expense_id::text, 'APPROVED', e.expense_date, e.project_id,
          case when e.source = 'PETTY_CASH' then 'Nota kas ' || coalesce(e.fund_name,'') else 'Nota kasbon ' || finance.employee_name(e.employee_id) end
            || ' - ' || e.description, v_lines);
end;
$$;

create or replace function finance.trg_cash_journal()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare v_id text;
begin
  begin
    if tg_table_name = 'cash_request' then
      v_id := new.request_id::text;
      perform finance.journal_cash_request(v_id::bigint);
    else
      v_id := new.expense_id::text;
      perform finance.journal_cash_expense(v_id::bigint);
    end if;
  exception when others then
    insert into finance.auto_journal_error (source_table, source_id, source_event, error_message)
    values (tg_table_name, v_id, tg_op, sqlerrm);
  end;
  return null;
end;
$$;

create trigger trg_sfm_cash_request after insert or update on finance.cash_request
  for each row execute function finance.trg_cash_journal();
create trigger trg_sfm_cash_expense after insert or update on finance.cash_expense
  for each row execute function finance.trg_cash_journal();

-- ---------------------------------------------------------------------
-- 5. Budget vs Actual: nota & pengeluaran langsung masuk komitmen dan realisasi
-- ---------------------------------------------------------------------
create or replace view finance.v_cash_actual as
  select project_id, sum(amount - ppn_amount) as amount
    from (select project_id, amount, ppn_amount from finance.cash_expense where status = 'APPROVED'
          union all
          select project_id, amount, ppn_amount from finance.cash_request where kind = 'DIRECT' and status = 'PAID') x
   where project_id is not null
   group by project_id;

create or replace view finance.v_budget_vs_actual as
 WITH latest_budget AS (
         SELECT DISTINCT ON (project_budget.project_id, project_budget.cost_category) project_budget.project_id,
            project_budget.cost_category, project_budget.amount
           FROM finance.project_budget
          ORDER BY project_budget.project_id, project_budget.cost_category, project_budget.created_at DESC
        ), budget AS (
         SELECT latest_budget.project_id, sum(latest_budget.amount) AS budget_amount
           FROM latest_budget GROUP BY latest_budget.project_id
        ), commitment AS (
         SELECT d.project_id, sum(d.po_subtotal) AS committed_amount
           FROM finance.v_po_detail_project d
           JOIN public."purchaseOrder" po ON po."POID" = d.po_id
          WHERE COALESCE(po."Status", ''::text) <> ALL (ARRAY['Cancelled'::text, 'CANCELLED'::text, 'Rejected'::text, 'REJECTED'::text])
          GROUP BY d.project_id
        ), actual AS (
         SELECT d.project_id, sum(eu."QtyConfirmed" * d.po_unit_price) AS actual_amount
           FROM public."endUserReceiving" eu
           JOIN public."siteReceiving" sr ON sr."ReceivingID" = eu."ReceivingID"
           JOIN public.delivery dl ON dl."DeliveryID" = sr."DeliveryID"
           JOIN finance.v_po_detail_project d ON d.po_detail_id = dl."PODetailID"
          GROUP BY d.project_id
        )
 SELECT p.project_id, p.code, p.name,
    COALESCE(b.budget_amount, 0::numeric) AS budget_amount,
    COALESCE(c.committed_amount, 0::numeric) + COALESCE(k.amount, 0::numeric) AS committed_amount,
    COALESCE(a.actual_amount, 0::numeric) + COALESCE(k.amount, 0::numeric) AS actual_amount,
    COALESCE(b.budget_amount, 0::numeric) - (COALESCE(c.committed_amount, 0::numeric) + COALESCE(k.amount, 0::numeric)) AS remaining_after_commitment,
        CASE WHEN COALESCE(b.budget_amount, 0::numeric) > 0::numeric
             THEN round((COALESCE(a.actual_amount, 0::numeric) + COALESCE(k.amount, 0::numeric)) / b.budget_amount * 100::numeric, 1)
             ELSE NULL::numeric END AS actual_pct
   FROM finance.v_project_map p
     LEFT JOIN budget b ON b.project_id = p.project_id
     LEFT JOIN commitment c ON c.project_id = p.project_id
     LEFT JOIN actual a ON a.project_id = p.project_id
     LEFT JOIN finance.v_cash_actual k ON k.project_id = p.project_id;

-- ---------------------------------------------------------------------
-- 6. API
-- ---------------------------------------------------------------------
create or replace function public.fin_cash_overview(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare who bigint; v_ho boolean; v_appr boolean;
begin
  who := finance.check_session(p_token, array['fin-ap','fin-pc']);
  v_ho := finance.emp_has(who, 'fin-ap');
  v_appr := v_ho or exists (select 1 from public."paswordTbl" p, unnest(finance.tokens(p."Author")) a
                             where p."Id" = who and a ~ '^(apc|apy)(-|$)');
  return jsonb_build_object(
    'me', who, 'isHO', v_ho,
    'funds', (select coalesce(jsonb_agg(x order by x.fund_name), '[]'::jsonb) from (
       select f.fund_id, f.fund_name, f.project_id, p.code as project_code, f.custodian_id,
              finance.employee_name(f.custodian_id) as custodian_name, f.coa_code, f.ceiling, f.max_per_note, f.is_active,
              finance.fund_balance(f.fund_id) as balance,
              (select coalesce(sum(amount),0) from finance.cash_expense e where e.fund_id = f.fund_id and e.status = 'SUBMITTED') as pending_notes,
              (select coalesce(sum(amount),0) from finance.cash_request r where r.fund_id = f.fund_id and r.status in ('PLANNED','APPROVED')) as pending_topup
         from finance.cash_fund f left join operational.projects p on p.id = f.project_id
        where v_appr or f.custodian_id = who) x),
    'requests', (select coalesce(jsonb_agg(x order by x.sort_key, x.created_at desc), '[]'::jsonb) from (
       select r.request_id, r.kind, r.fund_id, f.fund_name, r.employee_id,
              case when r.employee_id is not null then finance.employee_name(r.employee_id) end as employee_name,
              r.project_id, p.code as project_code, r.payee, r.account_code, c.account_name, r.amount, r.ppn_amount, r.pph23_amount,
              r.due_date, r.description, r.status, r.requested_by, r.approved_by, r.approved_at, r.reject_reason,
              r.paid_amount, r.paid_at, r.paid_by, r.payment_ref, b.account_label as bank_label, r.close_date, r.close_ref, r.closed_by,
              r.created_at,
              case when r.kind = 'DIRECT' and r.status = 'PLANNED' then finance.doc_missing('DIRECT', r.request_id) end as docs_missing,
              case when r.kind = 'KASBON' then (select coalesce(sum(amount),0) from finance.cash_expense e where e.kasbon_id = r.request_id and e.status = 'APPROVED') end as settled,
              case when r.kind = 'KASBON' then (select coalesce(sum(amount),0) from finance.cash_expense e where e.kasbon_id = r.request_id and e.status = 'SUBMITTED') end as pending_notes,
              case r.status when 'PLANNED' then 1 when 'APPROVED' then 2 when 'PAID' then 3 else 4 end as sort_key
         from finance.cash_request r
         left join finance.cash_fund f on f.fund_id = r.fund_id
         left join operational.projects p on p.id = r.project_id
         left join finance.coa c on c.account_code = r.account_code
         left join finance.bank_account b on b.bank_id = r.bank_id
        where v_appr or f.custodian_id = who or r.employee_id = who or r.requested_by_id = who) x),
    'expenses', (select coalesce(jsonb_agg(x order by x.sort_key, x.expense_date desc, x.expense_id desc), '[]'::jsonb) from (
       select e.expense_id, e.source, e.fund_id, f.fund_name, e.kasbon_id,
              case when e.kasbon_id is not null then finance.employee_name(k.employee_id) end as kasbon_employee,
              e.expense_date, e.project_id, p.code as project_code, e.account_code, c.account_name, e.description,
              e.amount, e.ppn_amount, e.status, e.submitted_by, e.approved_by, e.approved_at, e.reject_reason,
              finance.doc_missing('NOTA', e.expense_id) as docs_missing,
              (select count(*) from finance.document d where d.expense_id = e.expense_id) as docs_uploaded,
              case e.status when 'SUBMITTED' then 1 else 2 end as sort_key
         from finance.cash_expense e
         left join finance.cash_fund f on f.fund_id = e.fund_id
         left join finance.cash_request k on k.request_id = e.kasbon_id
         left join operational.projects p on p.id = e.project_id
         left join finance.coa c on c.account_code = e.account_code
        where (v_appr or f.custodian_id = who or k.employee_id = who or e.submitted_by_id = who)
          and (e.status = 'SUBMITTED' or e.created_at > now() - interval '120 days')) x),
    'accounts', (select coalesce(jsonb_agg(jsonb_build_object('code', account_code, 'name', account_name) order by account_code), '[]'::jsonb)
                   from finance.coa where account_type = 'EXPENSE' and is_postable and is_active),
    'projects', (select coalesce(jsonb_agg(jsonb_build_object('project_id', id, 'code', code, 'name', name) order by code), '[]'::jsonb)
                   from operational.projects),
    'employees', (select coalesce(jsonb_agg(jsonb_build_object('id', p."Id", 'name', coalesce(k."NamaPersonnel", p."Nama")) order by coalesce(k."NamaPersonnel", p."Nama")), '[]'::jsonb)
                    from public."paswordTbl" p left join public."karyawanTbl" k on k."Id" = p."Id"
                   where p."IsActive" = true and coalesce(k."IsActive", true)),
    'banks', (select coalesce(jsonb_agg(jsonb_build_object('bank_id', bank_id, 'label', account_label, 'bank_name', bank_name) order by bank_name), '[]'::jsonb)
                from finance.bank_account where is_active),
    'docTypes', (select coalesce(jsonb_agg(to_jsonb(d) order by d.gate, d.sort_order), '[]'::jsonb)
                   from finance.document_type d where d.is_active and d.gate in ('NOTA','DIRECT')));
end;
$$;

create or replace function public.fin_save_fund(
  p_token text, p_fund_id bigint, p_fund_name text, p_project_id uuid, p_custodian_id bigint,
  p_ceiling numeric, p_max_per_note numeric, p_is_active boolean
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare who bigint; v_coa text; v_id bigint;
begin
  who := finance.check_session(p_token, array['fin-ap']);
  if coalesce(btrim(p_fund_name),'') = '' then raise exception 'Nama kas wajib diisi'; end if;
  if not exists (select 1 from public."paswordTbl" where "Id" = p_custodian_id and "IsActive") then
    raise exception 'Pemegang kas tidak ditemukan atau tidak aktif';
  end if;
  if coalesce(p_ceiling,0) <= 0 or coalesce(p_max_per_note,0) <= 0 then raise exception 'Plafon dan batas per nota harus lebih dari 0'; end if;
  if p_max_per_note > p_ceiling then raise exception 'Batas per nota tidak boleh melebihi plafon kas'; end if;
  if p_fund_id is null then
    v_coa := finance.next_cash_coa();
    insert into finance.coa (account_code, account_name, account_type, parent_code, is_postable, notes)
    values (v_coa, 'Kas Kecil - ' || btrim(p_fund_name), 'ASSET', '1-1100', true, 'Dibuat otomatis untuk kas site');
    insert into finance.cash_fund (fund_name, project_id, custodian_id, coa_code, ceiling, max_per_note, created_by)
    values (btrim(p_fund_name), p_project_id, p_custodian_id, v_coa, p_ceiling, p_max_per_note, finance.employee_name(who))
    returning fund_id into v_id;
  else
    update finance.cash_fund
       set fund_name = btrim(p_fund_name), project_id = p_project_id, custodian_id = p_custodian_id,
           ceiling = p_ceiling, max_per_note = p_max_per_note, is_active = coalesce(p_is_active, true)
     where fund_id = p_fund_id
    returning fund_id, coa_code into v_id, v_coa;
    if v_id is null then raise exception 'Kas % tidak ditemukan', p_fund_id; end if;
    update finance.coa set account_name = 'Kas Kecil - ' || btrim(p_fund_name) where account_code = v_coa;
  end if;
  return jsonb_build_object('fund_id', v_id, 'coa_code', v_coa);
end;
$$;

create or replace function public.fin_request_cash(
  p_token text, p_kind text, p_fund_id bigint, p_employee_id bigint, p_project_id uuid, p_payee text,
  p_account_code text, p_amount numeric, p_ppn_amount numeric, p_pph23_amount numeric, p_due_date date, p_description text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare who bigint; v_ho boolean; f finance.cash_fund%rowtype; v_id bigint; v_bal numeric; v_pending numeric;
begin
  who := finance.check_session(p_token, array['fin-ap','fin-pc']);
  v_ho := finance.emp_has(who, 'fin-ap');
  if coalesce(p_amount,0) <= 0 then raise exception 'Nilai harus lebih dari 0'; end if;
  if coalesce(btrim(p_description),'') = '' then raise exception 'Keterangan wajib diisi'; end if;

  if p_kind = 'TOPUP' then
    select * into f from finance.cash_fund where fund_id = p_fund_id and is_active;
    if f.fund_id is null then raise exception 'Kas site tidak ditemukan atau tidak aktif'; end if;
    if not v_ho and f.custodian_id <> who then raise exception 'Hanya pemegang kas atau finance HO yang bisa mengajukan isi kas' using errcode = '42501'; end if;
    v_bal := finance.fund_balance(f.fund_id);
    select coalesce(sum(amount),0) into v_pending from finance.cash_request where fund_id = f.fund_id and status in ('PLANNED','APPROVED');
    if v_bal + v_pending + p_amount > f.ceiling then
      raise exception 'Isi kas melebihi plafon. Saldo Rp %, pengajuan berjalan Rp %, plafon Rp % (maksimal isi Rp %)',
        v_bal, v_pending, f.ceiling, greatest(f.ceiling - v_bal - v_pending, 0);
    end if;
    insert into finance.cash_request (kind, fund_id, project_id, amount, due_date, description, requested_by, requested_by_id)
    values ('TOPUP', f.fund_id, f.project_id, p_amount, p_due_date, btrim(p_description), finance.employee_name(who), who)
    returning request_id into v_id;

  elsif p_kind = 'DIRECT' then
    if not v_ho then raise exception 'Pengeluaran langsung hanya bisa diinput finance HO (FIN-AP)' using errcode = '42501'; end if;
    if coalesce(btrim(p_payee),'') = '' then raise exception 'Penerima wajib diisi'; end if;
    if not exists (select 1 from finance.coa where account_code = p_account_code and account_type = 'EXPENSE' and is_postable and is_active) then
      raise exception 'Pilih akun beban yang valid';
    end if;
    if coalesce(p_ppn_amount,0) + coalesce(p_pph23_amount,0) >= p_amount then raise exception 'PPN + PPh 23 harus lebih kecil dari total'; end if;
    insert into finance.cash_request (kind, project_id, payee, account_code, amount, ppn_amount, pph23_amount, due_date, description, requested_by, requested_by_id)
    values ('DIRECT', p_project_id, btrim(p_payee), p_account_code, p_amount, coalesce(p_ppn_amount,0), coalesce(p_pph23_amount,0),
            p_due_date, btrim(p_description), finance.employee_name(who), who)
    returning request_id into v_id;

  elsif p_kind = 'KASBON' then
    if not exists (select 1 from public."paswordTbl" where "Id" = p_employee_id and "IsActive") then
      raise exception 'Karyawan tidak ditemukan atau tidak aktif';
    end if;
    if not v_ho and p_employee_id <> who and not exists (select 1 from finance.cash_fund where custodian_id = who and is_active) then
      raise exception 'Kasbon untuk orang lain hanya bisa diajukan finance HO atau pemegang kas site' using errcode = '42501';
    end if;
    insert into finance.cash_request (kind, employee_id, project_id, amount, due_date, description, requested_by, requested_by_id)
    values ('KASBON', p_employee_id, p_project_id, p_amount, p_due_date, btrim(p_description), finance.employee_name(who), who)
    returning request_id into v_id;
  else
    raise exception 'Jenis pengajuan tidak dikenal';
  end if;
  return jsonb_build_object('request_id', v_id, 'status', 'PLANNED',
                            'docs_missing', case when p_kind = 'DIRECT' then finance.doc_missing('DIRECT', v_id) end);
end;
$$;

-- Approve / tolak uang keluar dari bank (APY)
create or replace function public.fin_decide_cash(p_token text, p_request_id bigint, p_approve boolean, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare who bigint; r finance.cash_request%rowtype; v_code text; v_docs text; f finance.cash_fund%rowtype; v_bal numeric; v_pending numeric;
begin
  select * into r from finance.cash_request where request_id = p_request_id for update;
  if r.request_id is null then raise exception 'Pengajuan % tidak ditemukan', p_request_id; end if;
  select code into v_code from operational.projects where id = r.project_id;
  who := finance.check_session(p_token, array['fin-ap','fin-pc'], 'APY', v_code);
  if r.status <> 'PLANNED' then raise exception 'Pengajuan ini sudah diproses (status %)', r.status; end if;
  if not coalesce(p_approve, false) then
    if coalesce(btrim(p_reason),'') = '' then raise exception 'Alasan penolakan wajib diisi'; end if;
    update finance.cash_request set status = 'REJECTED', reject_reason = btrim(p_reason),
           approved_by = finance.employee_name(who), approved_at = now() where request_id = r.request_id;
    return jsonb_build_object('request_id', r.request_id, 'status', 'REJECTED');
  end if;
  if r.kind = 'DIRECT' then
    v_docs := finance.doc_missing('DIRECT', r.request_id);
    if v_docs is not null then raise exception 'Pengeluaran ditahan (HOLD). Dokumen belum lengkap: %', v_docs; end if;
  end if;
  if r.kind = 'TOPUP' then
    select * into f from finance.cash_fund where fund_id = r.fund_id;
    v_bal := finance.fund_balance(f.fund_id);
    select coalesce(sum(amount),0) into v_pending from finance.cash_request
     where fund_id = f.fund_id and status = 'APPROVED';
    if v_bal + v_pending + r.amount > f.ceiling then
      raise exception 'Isi kas melebihi plafon Rp % (saldo Rp %, sudah disetujui Rp %)', f.ceiling, v_bal, v_pending;
    end if;
  end if;
  update finance.cash_request set status = 'APPROVED', approved_by = finance.employee_name(who), approved_at = now()
   where request_id = r.request_id;
  return jsonb_build_object('request_id', r.request_id, 'status', 'APPROVED');
end;
$$;

-- Tandai dibayar dari bank (FIN-AP)
create or replace function public.fin_pay_cash(p_token text, p_request_id bigint, p_bank_id bigint, p_paid_date date, p_payment_ref text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare who bigint; r finance.cash_request%rowtype; v_amt numeric;
begin
  who := finance.check_session(p_token, array['fin-ap']);
  select * into r from finance.cash_request where request_id = p_request_id for update;
  if r.request_id is null then raise exception 'Pengajuan % tidak ditemukan', p_request_id; end if;
  if r.status <> 'APPROVED' then raise exception 'Pengajuan harus disetujui (APY) dulu sebelum dibayar'; end if;
  if r.kind = 'DIRECT' and finance.doc_missing('DIRECT', r.request_id) is not null then
    raise exception 'Pengeluaran ditahan (HOLD). Dokumen belum lengkap: %', finance.doc_missing('DIRECT', r.request_id);
  end if;
  if not exists (select 1 from finance.bank_account where bank_id = p_bank_id and is_active) then
    raise exception 'Pilih rekening bank yang aktif';
  end if;
  v_amt := case when r.kind = 'DIRECT' then r.amount - r.pph23_amount else r.amount end;
  update finance.cash_request
     set status = 'PAID', bank_id = p_bank_id, paid_amount = v_amt, paid_at = coalesce(p_paid_date, current_date),
         paid_by = finance.employee_name(who), payment_ref = nullif(btrim(p_payment_ref),'')
   where request_id = r.request_id;
  return jsonb_build_object('request_id', r.request_id, 'status', 'PAID', 'paid_amount', v_amt);
end;
$$;

-- Input nota (kas site atau kasbon)
create or replace function public.fin_create_expense(
  p_token text, p_source text, p_ref_id bigint, p_expense_date date, p_project_id uuid,
  p_account_code text, p_description text, p_amount numeric, p_ppn_amount numeric
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare who bigint; v_ho boolean; f finance.cash_fund%rowtype; k finance.cash_request%rowtype; v_id bigint; v_avail numeric; v_proj uuid;
begin
  who := finance.check_session(p_token, array['fin-ap','fin-pc']);
  v_ho := finance.emp_has(who, 'fin-ap');
  if coalesce(p_amount,0) <= 0 then raise exception 'Nilai nota harus lebih dari 0'; end if;
  if coalesce(p_ppn_amount,0) >= p_amount then raise exception 'PPN harus lebih kecil dari total nota'; end if;
  if coalesce(btrim(p_description),'') = '' then raise exception 'Keterangan nota wajib diisi'; end if;
  if p_expense_date is null or p_expense_date > current_date then raise exception 'Tanggal nota tidak valid'; end if;
  if not exists (select 1 from finance.coa where account_code = p_account_code and account_type = 'EXPENSE' and is_postable and is_active) then
    raise exception 'Pilih kategori biaya yang valid';
  end if;

  if p_source = 'PETTY_CASH' then
    select * into f from finance.cash_fund where fund_id = p_ref_id and is_active for update;
    if f.fund_id is null then raise exception 'Kas site tidak ditemukan atau tidak aktif'; end if;
    if not v_ho and f.custodian_id <> who then raise exception 'Hanya pemegang kas yang bisa input nota kas ini' using errcode = '42501'; end if;
    if p_amount > f.max_per_note then
      raise exception 'Nota Rp % melebihi batas per nota Rp %. Pembelian sebesar ini harus lewat PO di SMMS.', p_amount, f.max_per_note;
    end if;
    select finance.fund_balance(f.fund_id) - coalesce(sum(amount),0) into v_avail
      from finance.cash_expense where fund_id = f.fund_id and status = 'SUBMITTED';
    if p_amount > v_avail then raise exception 'Saldo kas tidak cukup. Tersedia Rp % (setelah nota yang menunggu approval)', greatest(v_avail,0); end if;
    v_proj := coalesce(p_project_id, f.project_id);
    insert into finance.cash_expense (source, fund_id, expense_date, project_id, account_code, description, amount, ppn_amount, submitted_by, submitted_by_id)
    values ('PETTY_CASH', f.fund_id, p_expense_date, v_proj, p_account_code, btrim(p_description), p_amount, coalesce(p_ppn_amount,0),
            finance.employee_name(who), who)
    returning expense_id into v_id;
  elsif p_source = 'KASBON' then
    select * into k from finance.cash_request where request_id = p_ref_id and kind = 'KASBON' for update;
    if k.request_id is null then raise exception 'Kasbon tidak ditemukan'; end if;
    if k.status <> 'PAID' then raise exception 'Nota hanya bisa diinput untuk kasbon yang sudah dibayar dan belum ditutup'; end if;
    if not v_ho and who is distinct from k.employee_id and who is distinct from k.requested_by_id then
      raise exception 'Hanya penerima kasbon atau finance HO yang bisa input nota kasbon ini' using errcode = '42501';
    end if;
    v_proj := coalesce(p_project_id, k.project_id);
    insert into finance.cash_expense (source, kasbon_id, expense_date, project_id, account_code, description, amount, ppn_amount, submitted_by, submitted_by_id)
    values ('KASBON', k.request_id, p_expense_date, v_proj, p_account_code, btrim(p_description), p_amount, coalesce(p_ppn_amount,0),
            finance.employee_name(who), who)
    returning expense_id into v_id;
  else
    raise exception 'Sumber nota tidak dikenal';
  end if;
  return jsonb_build_object('expense_id', v_id, 'status', 'SUBMITTED', 'docs_missing', finance.doc_missing('NOTA', v_id));
end;
$$;

-- Approve / tolak nota (APC)
create or replace function public.fin_decide_expense(p_token text, p_expense_id bigint, p_approve boolean, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare who bigint; e finance.cash_expense%rowtype; v_code text; v_docs text;
begin
  select * into e from finance.cash_expense where expense_id = p_expense_id for update;
  if e.expense_id is null then raise exception 'Nota % tidak ditemukan', p_expense_id; end if;
  select code into v_code from operational.projects where id = e.project_id;
  who := finance.check_session(p_token, array['fin-ap','fin-pc'], 'APC', v_code);
  if e.status <> 'SUBMITTED' then raise exception 'Nota ini sudah diproses (status %)', e.status; end if;
  if coalesce(p_approve, false) then
    v_docs := finance.doc_missing('NOTA', e.expense_id);
    if v_docs is not null then raise exception 'Nota belum bisa disetujui. Dokumen belum lengkap: %', v_docs; end if;
    update finance.cash_expense set status = 'APPROVED', approved_by = finance.employee_name(who), approved_at = now()
     where expense_id = e.expense_id;
  else
    if coalesce(btrim(p_reason),'') = '' then raise exception 'Alasan penolakan wajib diisi'; end if;
    update finance.cash_expense set status = 'REJECTED', reject_reason = btrim(p_reason),
           approved_by = finance.employee_name(who), approved_at = now()
     where expense_id = e.expense_id;
  end if;
  return jsonb_build_object('expense_id', e.expense_id, 'status', case when p_approve then 'APPROVED' else 'REJECTED' end);
end;
$$;

-- Tutup kasbon: selisih dikembalikan karyawan / dibayar perusahaan (FIN-AP)
create or replace function public.fin_close_kasbon(p_token text, p_request_id bigint, p_bank_id bigint, p_close_date date, p_ref text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare who bigint; k finance.cash_request%rowtype; v_settled numeric; v_diff numeric;
begin
  who := finance.check_session(p_token, array['fin-ap']);
  select * into k from finance.cash_request where request_id = p_request_id and kind = 'KASBON' for update;
  if k.request_id is null then raise exception 'Kasbon tidak ditemukan'; end if;
  if k.status <> 'PAID' then raise exception 'Hanya kasbon yang sudah dibayar dan belum ditutup yang bisa ditutup'; end if;
  if exists (select 1 from finance.cash_expense where kasbon_id = k.request_id and status = 'SUBMITTED') then
    raise exception 'Masih ada nota kasbon yang menunggu approval APC';
  end if;
  select coalesce(sum(amount),0) into v_settled from finance.cash_expense where kasbon_id = k.request_id and status = 'APPROVED';
  v_diff := k.paid_amount - v_settled;
  if v_diff <> 0 and not exists (select 1 from finance.bank_account where bank_id = p_bank_id and is_active) then
    raise exception 'Pilih rekening bank untuk % selisih Rp %', case when v_diff > 0 then 'menerima pengembalian' else 'membayar' end, abs(v_diff);
  end if;
  update finance.cash_request
     set status = 'CLOSED', close_bank_id = case when v_diff <> 0 then p_bank_id end,
         close_date = coalesce(p_close_date, current_date), close_ref = nullif(btrim(p_ref),''), closed_by = finance.employee_name(who)
   where request_id = k.request_id;
  return jsonb_build_object('request_id', k.request_id, 'status', 'CLOSED', 'kasbon', k.paid_amount, 'nota', v_settled,
                            'dikembalikan', greatest(v_diff, 0), 'dibayar', greatest(-v_diff, 0));
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Hak eksekusi
-- ---------------------------------------------------------------------
revoke execute on function finance.emp_has(bigint, text, text)        from public, anon, authenticated;
revoke execute on function finance.next_cash_coa()                     from public, anon, authenticated;
revoke execute on function finance.doc_access(bigint, text, bigint)    from public, anon, authenticated;
revoke execute on function finance.fund_balance(bigint)                from public, anon, authenticated;
revoke execute on function finance.journal_cash_request(bigint)        from public, anon, authenticated;
revoke execute on function finance.journal_cash_expense(bigint)        from public, anon, authenticated;
revoke execute on function finance.trg_cash_journal()                  from public, anon, authenticated;
revoke execute on function finance.doc_checklist(text, bigint)         from public, anon, authenticated;
revoke all on finance.v_cash_actual from public, anon, authenticated;

revoke execute on function public.fin_cash_overview(text) from public;
revoke execute on function public.fin_save_fund(text, bigint, text, uuid, bigint, numeric, numeric, boolean) from public;
revoke execute on function public.fin_request_cash(text, text, bigint, bigint, uuid, text, text, numeric, numeric, numeric, date, text) from public;
revoke execute on function public.fin_decide_cash(text, bigint, boolean, text) from public;
revoke execute on function public.fin_pay_cash(text, bigint, bigint, date, text) from public;
revoke execute on function public.fin_create_expense(text, text, bigint, date, uuid, text, text, numeric, numeric) from public;
revoke execute on function public.fin_decide_expense(text, bigint, boolean, text) from public;
revoke execute on function public.fin_close_kasbon(text, bigint, bigint, date, text) from public;
grant execute on function public.fin_cash_overview(text) to anon, authenticated;
grant execute on function public.fin_save_fund(text, bigint, text, uuid, bigint, numeric, numeric, boolean) to anon, authenticated;
grant execute on function public.fin_request_cash(text, text, bigint, bigint, uuid, text, text, numeric, numeric, numeric, date, text) to anon, authenticated;
grant execute on function public.fin_decide_cash(text, bigint, boolean, text) to anon, authenticated;
grant execute on function public.fin_pay_cash(text, bigint, bigint, date, text) to anon, authenticated;
grant execute on function public.fin_create_expense(text, text, bigint, date, uuid, text, text, numeric, numeric) to anon, authenticated;
grant execute on function public.fin_decide_expense(text, bigint, boolean, text) to anon, authenticated;
grant execute on function public.fin_close_kasbon(text, bigint, bigint, date, text) to anon, authenticated;
