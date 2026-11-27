-- =====================================================================
-- SmartFin BIMA — Migration 011: Piutang Klien (AR) — tagihan ke klien & penerimaan
-- Status : ✅ Sudah dijalankan (27 Nov 2026)
--
-- PIC FIN-AR input, Author PJ (per proyek) approve. Saat disetujui jurnal langsung POSTED.
-- Dasar tagihan: SMS (Service/Work Measurement Sheet) yang sudah APPROVED di SMMS operational,
-- ditambah baris manual. Satu SMS hanya bisa ditagih sekali.
--
-- Jenis invoice:
--   PROGRESS   tagihan pekerjaan. Retensi % opsional ditahan klien.
--   RETENTION  pencairan retensi yang tertahan dari invoice PROGRESS proyek yang sama.
--
-- Pajak dipilih per invoice. Dasar PPN & PPh = nilai yang jatuh tagih di invoice itu
-- (PROGRESS: DPP − retensi; RETENTION: nilai retensi yang dicairkan).
--   PPN  NONE    tanpa PPN
--        WAPU    PPN dipungut klien (BUMN/WAPU) → dicatat untuk faktur, tidak masuk jurnal
--        COLLECT PPN dipungut BIMA → Cr 2-1500 PPN Keluaran, ikut ditagih
--   PPh  NONE / PPH23 (tarif default 2%) / PPH4_2 (final jasa konstruksi, tarif diisi)
--        dipotong klien saat bayar.
--
-- Jurnal invoice disetujui:
--   PROGRESS  Dr 1-1300 Piutang Usaha (DPP−retensi+PPN collect) | Dr 1-1310 Piutang Retensi
--             Cr 4-1000 Pendapatan Kontrak (DPP)                  | Cr 2-1500 PPN Keluaran
--   RETENTION Dr 1-1300 (nilai+PPN collect) / Cr 1-1310 nilai     | Cr 2-1500 PPN Keluaran
-- Jurnal penerimaan disetujui:
--   Dr Bank (uang diterima) | Dr 1-1450 PPh 23 Dibayar Dimuka atau 6-1420 Beban PPh Final
--   Cr 1-1300 Piutang Usaha (uang + PPh dipotong)
-- =====================================================================

insert into finance.coa (account_code, account_name, account_type, is_postable, notes) values
  ('1-1310', 'Piutang Retensi',                   'ASSET',   true, 'Retensi yang ditahan klien'),
  ('1-1450', 'PPh 23 Dibayar Dimuka',             'ASSET',   true, 'PPh 23 dipotong klien, kredit pajak'),
  ('6-1420', 'Beban PPh Final Jasa Konstruksi',   'EXPENSE', true, 'PPh 4(2) dipotong klien')
on conflict (account_code) do nothing;

alter table finance.journal drop constraint journal_source_system_check;
alter table finance.journal add constraint journal_source_system_check
  check (source_system in ('SMMS','FUSION4','PETTY_CASH','AP','MANUAL','ASSET','CASH','BANK','AR'));

-- PIC FIN-AR ----------------------------------------------------------
create or replace function finance.tokens(p_text text)
returns text[] language sql immutable set search_path = '' as $$
  with parsed as (
    select coalesce(array_agg(lower(btrim(x))) filter (where btrim(x) <> ''), array[]::text[]) as v
      from regexp_split_to_table(coalesce(p_text,''), '[,;\n\r]+') x
  )
  select case
           when 'all' = any(v)     then v || array['fin','fin-ap','fin-ar','fin-jv','fin-bva','fin-ast','fin-pc','fin-rpt','ai','pj','ab','apy','apc']
           when 'fin-all' = any(v) then v || array['fin','fin-ap','fin-ar','fin-jv','fin-bva','fin-ast','fin-pc','fin-rpt']
           else v end
    from parsed;
$$;

create or replace function public.fin_login(p_id bigint, p_password text)
returns jsonb language plpgsql security definer set search_path = '' as $$
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
  if not (v_pics && array['fin','fin-ap','fin-ar','fin-jv','fin-bva','fin-ast','fin-pc','fin-rpt']) then
    return jsonb_build_object('error','Akun ini belum punya akses SmartFin. Minta admin menambahkan PIC FIN.');
  end if;
  v_token := replace(gen_random_uuid()::text,'-','') || replace(gen_random_uuid()::text,'-','');
  insert into finance.sessions (token_hash, employee_id, credential_hash, expires_at)
  values (sha256(convert_to(v_token,'UTF8')), p_id, sha256(convert_to(v_cred,'UTF8')), now() + interval '8 hours');
  delete from finance.login_attempts where employee_id = p_id;
  return jsonb_build_object(
    'token', v_token, 'id', p_id, 'name', u.nama,
    'pic', (select coalesce(array_agg(x), array[]::text[]) from unnest(v_pics) x where x like 'fin%'),
    'author', (select coalesce(array_agg(x), array[]::text[]) from unnest(v_auth) x where x ~ '^(ai|pj|ab|apy|apc)(-|$)'),
    'expiresAt', now() + interval '8 hours');
end; $$;

-- Tabel -----------------------------------------------------------------
create table finance.ar_invoice (
  invoice_id        bigint generated always as identity primary key,
  invoice_no        text not null unique,
  kind              text not null default 'PROGRESS' check (kind in ('PROGRESS','RETENTION')),
  project_id        uuid not null references operational.projects(id),
  client_name       text,
  invoice_date      date not null,
  due_date          date not null,
  description       text not null,
  dpp               numeric(18,2) not null default 0,
  retention_pct     numeric(5,2)  not null default 0 check (retention_pct between 0 and 100),
  retention_amount  numeric(18,2) not null default 0,
  ppn_mode          text not null default 'NONE' check (ppn_mode in ('NONE','WAPU','COLLECT')),
  ppn_rate          numeric(5,2)  not null default 11,
  ppn_amount        numeric(18,2) not null default 0,
  pph_mode          text not null default 'NONE' check (pph_mode in ('NONE','PPH23','PPH4_2')),
  pph_rate          numeric(5,2)  not null default 0,
  pph_amount        numeric(18,2) not null default 0,
  receivable_amount numeric(18,2) not null default 0,   -- masuk 1-1300
  expected_cash     numeric(18,2) not null default 0,   -- receivable − PPh dipotong
  faktur_no         text,
  status            text not null default 'DRAFT' check (status in ('DRAFT','APPROVED','PARTIAL','PAID','REJECTED')),
  created_by        text, created_by_id bigint,
  approved_by       text, approved_at timestamptz, reject_reason text,
  created_at        timestamptz not null default now(),
  check (due_date >= invoice_date),
  check (kind = 'PROGRESS' or retention_pct = 0)
);
create index on finance.ar_invoice (project_id, status);
alter table finance.ar_invoice enable row level security;

create table finance.ar_invoice_line (
  line_id     bigint generated always as identity primary key,
  invoice_id  bigint not null references finance.ar_invoice(invoice_id) on delete cascade,
  sms_id      uuid references operational.sms_documents(id),
  sms_number  text,
  description text not null,
  amount      numeric(18,2) not null check (amount > 0)
);
-- satu SMS hanya ditagih sekali (baris dari invoice yang ditolak dilepas: sms_id dikosongkan)
create unique index ar_invoice_line_sms_once on finance.ar_invoice_line (sms_id) where sms_id is not null;
alter table finance.ar_invoice_line enable row level security;

create table finance.ar_receipt (
  receipt_id    bigint generated always as identity primary key,
  invoice_id    bigint not null references finance.ar_invoice(invoice_id),
  bank_id       bigint not null references finance.bank_account(bank_id),
  receipt_date  date not null,
  cash_amount   numeric(18,2) not null check (cash_amount >= 0),
  pph_amount    numeric(18,2) not null default 0 check (pph_amount >= 0),
  ref_no        text,
  notes         text,
  status        text not null default 'PLANNED' check (status in ('PLANNED','APPROVED','REJECTED')),
  requested_by  text, requested_by_id bigint,
  approved_by   text, approved_at timestamptz, reject_reason text,
  created_at    timestamptz not null default now(),
  check (cash_amount + pph_amount > 0)
);
create index on finance.ar_receipt (invoice_id);
alter table finance.ar_receipt enable row level security;

-- Helper ----------------------------------------------------------------
-- Nilai SMS (jumlah item) dan proyeknya (SMS → WO → kontrak → proyek)
create or replace function finance.sms_info(p_sms_id uuid)
returns table (sms_id uuid, number text, status text, project_id uuid, document_date date, amount numeric)
language sql stable security definer set search_path = '' as $$
  select d.id, d.number, d.status, c.project_id, d.document_date,
         coalesce((select sum(i.amount) from operational.sms_items i where i.sms_id = d.id), 0)
    from operational.sms_documents d
    join operational.work_orders w on w.id = d.wo_id
    join operational.contracts c on c.id = w.contract_id
   where d.id = p_sms_id;
$$;

-- Sisa retensi proyek yang belum dicairkan (invoice RETENTION non-REJECTED ikut mengurangi)
create or replace function finance.retention_open(p_project_id uuid, p_except_invoice bigint default null)
returns numeric language sql stable security definer set search_path = '' as $$
  select coalesce((select sum(retention_amount) from finance.ar_invoice
                    where project_id = p_project_id and kind = 'PROGRESS' and status in ('APPROVED','PARTIAL','PAID')), 0)
       - coalesce((select sum(dpp) from finance.ar_invoice
                    where project_id = p_project_id and kind = 'RETENTION' and status <> 'REJECTED'
                      and invoice_id is distinct from p_except_invoice), 0);
$$;

-- Sudah diterima / dipotong (APPROVED) dan yang masih menunggu approval
create or replace function finance.ar_settled(p_invoice_id bigint, p_include_planned boolean default false)
returns numeric language sql stable security definer set search_path = '' as $$
  select coalesce(sum(cash_amount + pph_amount), 0) from finance.ar_receipt
   where invoice_id = p_invoice_id and (status = 'APPROVED' or (p_include_planned and status = 'PLANNED'));
$$;

-- Jurnal ----------------------------------------------------------------
create or replace function finance.journal_ar_invoice(p_invoice_id bigint)
returns void language plpgsql security definer set search_path = '' as $$
declare i finance.ar_invoice%rowtype; v_lines jsonb := '[]'::jsonb; v_due numeric; v_memo text;
begin
  select * into i from finance.ar_invoice where invoice_id = p_invoice_id;
  if i.invoice_id is null then return; end if;
  v_memo := i.invoice_no;
  if i.status in ('APPROVED','PARTIAL','PAID') then
    v_due := case when i.kind = 'PROGRESS' then i.dpp - i.retention_amount else i.dpp end;
    v_lines := jsonb_build_array(
      jsonb_build_object('account', '1-1300', 'debit', i.receivable_amount, 'project_id', i.project_id, 'memo', v_memo));
    if i.kind = 'PROGRESS' then
      v_lines := v_lines
        || jsonb_build_array(jsonb_build_object('account', '1-1310', 'debit', i.retention_amount, 'project_id', i.project_id, 'memo', v_memo || ' retensi'))
        || jsonb_build_array(jsonb_build_object('account', '4-1000', 'credit', i.dpp, 'project_id', i.project_id, 'memo', v_memo));
    else
      v_lines := v_lines
        || jsonb_build_array(jsonb_build_object('account', '1-1310', 'credit', i.dpp, 'project_id', i.project_id, 'memo', v_memo || ' pencairan retensi'));
    end if;
    if i.ppn_mode = 'COLLECT' and i.ppn_amount > 0 then
      v_lines := v_lines || jsonb_build_array(jsonb_build_object('account', '2-1500', 'credit', i.ppn_amount, 'project_id', i.project_id, 'memo', v_memo || ' PPN'));
    end if;
  end if;
  perform finance.sync_auto_journal('AR', 'ar_invoice', p_invoice_id::text, 'APPROVED', i.invoice_date, i.project_id,
          'Invoice klien ' || i.invoice_no || ' - ' || coalesce(i.client_name, '') || ' - ' || i.description, v_lines);
end; $$;

create or replace function finance.journal_ar_receipt(p_receipt_id bigint)
returns void language plpgsql security definer set search_path = '' as $$
declare r record; v_lines jsonb := '[]'::jsonb;
begin
  select x.*, i.invoice_no, i.project_id, i.pph_mode, i.client_name, b.coa_code as bank_coa, b.account_label
    into r
    from finance.ar_receipt x
    join finance.ar_invoice i on i.invoice_id = x.invoice_id
    join finance.bank_account b on b.bank_id = x.bank_id
   where x.receipt_id = p_receipt_id;
  if r.receipt_id is null then return; end if;
  if r.status = 'APPROVED' then
    v_lines := jsonb_build_array(
      jsonb_build_object('account', r.bank_coa, 'debit', r.cash_amount, 'project_id', r.project_id, 'memo', coalesce(r.ref_no, r.invoice_no)),
      jsonb_build_object('account', case r.pph_mode when 'PPH4_2' then '6-1420' else '1-1450' end, 'debit', r.pph_amount,
                         'project_id', r.project_id, 'memo', r.invoice_no || ' PPh dipotong klien'),
      jsonb_build_object('account', '1-1300', 'credit', r.cash_amount + r.pph_amount, 'project_id', r.project_id, 'memo', r.invoice_no));
  end if;
  perform finance.sync_auto_journal('AR', 'ar_receipt', p_receipt_id::text, 'APPROVED', r.receipt_date, r.project_id,
          'Penerimaan ' || r.invoice_no || ' - ' || coalesce(r.client_name, '') || ' ke ' || r.account_label, v_lines);
end; $$;

create or replace function finance.trg_ar_journal()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  begin
    if tg_table_name = 'ar_invoice' then perform finance.journal_ar_invoice(new.invoice_id);
    else perform finance.journal_ar_receipt(new.receipt_id); end if;
  exception when others then
    insert into finance.auto_journal_error (source_table, source_id, source_event, error_message)
    values (tg_table_name, case when tg_table_name = 'ar_invoice' then new.invoice_id else new.receipt_id end::text, tg_op, sqlerrm);
  end;
  return null;
end; $$;
create trigger trg_sfm_ar_invoice after insert or update on finance.ar_invoice
  for each row execute function finance.trg_ar_journal();
create trigger trg_sfm_ar_receipt after insert or update on finance.ar_receipt
  for each row execute function finance.trg_ar_journal();

-- API -------------------------------------------------------------------
create or replace function public.fin_ar_overview(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform finance.check_session(p_token, array['fin-ar','fin-jv']);
  return jsonb_build_object(
    'kpi', jsonb_build_object(
      'piutang',   (select coalesce(sum(receivable_amount - finance.ar_settled(invoice_id)), 0) from finance.ar_invoice where status in ('APPROVED','PARTIAL')),
      'jatuhTempo',(select coalesce(sum(receivable_amount - finance.ar_settled(invoice_id)), 0) from finance.ar_invoice where status in ('APPROVED','PARTIAL') and due_date < current_date),
      'retensi',   (select coalesce(sum(finance.retention_open(id)), 0) from operational.projects),
      'menunggu',  (select count(*) from finance.ar_invoice where status = 'DRAFT') + (select count(*) from finance.ar_receipt where status = 'PLANNED'),
      'smsBelumDitagih', (select coalesce(sum(s.amount), 0) from operational.sms_documents d
                            cross join lateral finance.sms_info(d.id) s
                           where d.status = 'APPROVED' and not exists (select 1 from finance.ar_invoice_line l where l.sms_id = d.id))),
    'invoices', (select coalesce(jsonb_agg(x order by x.sort_key, x.invoice_date desc, x.invoice_id desc), '[]'::jsonb) from (
       select i.invoice_id, i.invoice_no, i.kind, i.project_id, p.code as project_code, p.name as project_name, i.client_name,
              i.invoice_date, i.due_date, i.description, i.dpp, i.retention_pct, i.retention_amount,
              i.ppn_mode, i.ppn_rate, i.ppn_amount, i.pph_mode, i.pph_rate, i.pph_amount,
              i.receivable_amount, i.expected_cash, i.faktur_no, i.status,
              i.created_by, i.approved_by, i.approved_at, i.reject_reason,
              finance.ar_settled(i.invoice_id) as settled,
              finance.ar_settled(i.invoice_id, true) - finance.ar_settled(i.invoice_id) as pending,
              (select coalesce(jsonb_agg(jsonb_build_object('line_id', l.line_id, 'sms_id', l.sms_id, 'sms_number', l.sms_number,
                        'description', l.description, 'amount', l.amount) order by l.line_id), '[]'::jsonb)
                 from finance.ar_invoice_line l where l.invoice_id = i.invoice_id) as lines,
              (select coalesce(jsonb_agg(jsonb_build_object('receipt_id', r.receipt_id, 'receipt_date', r.receipt_date, 'bank_label', b.account_label,
                        'cash_amount', r.cash_amount, 'pph_amount', r.pph_amount, 'ref_no', r.ref_no, 'notes', r.notes, 'status', r.status,
                        'requested_by', r.requested_by, 'approved_by', r.approved_by, 'reject_reason', r.reject_reason) order by r.receipt_date, r.receipt_id), '[]'::jsonb)
                 from finance.ar_receipt r join finance.bank_account b on b.bank_id = r.bank_id where r.invoice_id = i.invoice_id) as receipts,
              case when i.status = 'DRAFT' or exists (select 1 from finance.ar_receipt r where r.invoice_id = i.invoice_id and r.status = 'PLANNED') then 1
                   when i.status in ('APPROVED','PARTIAL') then 2 else 3 end as sort_key
         from finance.ar_invoice i
         join operational.projects p on p.id = i.project_id
        where i.status not in ('PAID','REJECTED') or i.created_at > now() - interval '365 days') x),
    'billableSms', (select coalesce(jsonb_agg(jsonb_build_object('sms_id', s.sms_id, 'number', s.number, 'project_id', s.project_id,
                       'project_code', p.code, 'document_date', s.document_date, 'amount', s.amount) order by p.code, s.number), '[]'::jsonb)
                      from operational.sms_documents d
                      cross join lateral finance.sms_info(d.id) s
                      join operational.projects p on p.id = s.project_id
                     where d.status = 'APPROVED' and not exists (select 1 from finance.ar_invoice_line l where l.sms_id = d.id)),
    'projects', (select coalesce(jsonb_agg(jsonb_build_object('project_id', p.id, 'code', p.code, 'name', p.name, 'client', p.client,
                    'retention_open', finance.retention_open(p.id)) order by p.code), '[]'::jsonb) from operational.projects p),
    'banks', (select coalesce(jsonb_agg(jsonb_build_object('bank_id', bank_id, 'label', account_label) order by bank_name), '[]'::jsonb)
                from finance.bank_account where is_active));
end; $$;

create or replace function public.fin_save_ar_invoice(
  p_token text, p_invoice_id bigint, p_kind text, p_project_id uuid, p_invoice_no text, p_invoice_date date, p_due_date date,
  p_description text, p_retention_pct numeric, p_ppn_mode text, p_ppn_rate numeric, p_pph_mode text, p_pph_rate numeric,
  p_faktur_no text, p_lines jsonb
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  who bigint; v_id bigint; v_no text; v_client text; l jsonb; s record; v_dpp numeric := 0; v_ret numeric; v_base numeric;
  v_ppn numeric; v_pph numeric; v_recv numeric; v_n int := 0; v_sms uuid[] := array[]::uuid[]; v_open numeric;
begin
  who := finance.check_session(p_token, array['fin-ar']);
  if p_kind not in ('PROGRESS','RETENTION') then raise exception 'Jenis invoice tidak dikenal'; end if;
  if p_ppn_mode not in ('NONE','WAPU','COLLECT') then raise exception 'Pilihan PPN tidak dikenal'; end if;
  if p_pph_mode not in ('NONE','PPH23','PPH4_2') then raise exception 'Pilihan PPh tidak dikenal'; end if;
  select client into v_client from operational.projects where id = p_project_id;
  if not found then raise exception 'Pilih proyek'; end if;
  if p_invoice_date is null or p_invoice_date > current_date + 31 then raise exception 'Tanggal invoice tidak valid'; end if;
  if p_due_date is null or p_due_date < p_invoice_date then raise exception 'Jatuh tempo harus sama atau setelah tanggal invoice'; end if;
  if coalesce(btrim(p_description),'') = '' then raise exception 'Keterangan wajib diisi'; end if;
  if p_ppn_mode <> 'NONE' and coalesce(p_ppn_rate,0) not between 0.01 and 100 then raise exception 'Tarif PPN tidak valid'; end if;
  if p_pph_mode <> 'NONE' and coalesce(p_pph_rate,0) not between 0.01 and 100 then raise exception 'Tarif PPh tidak valid'; end if;
  if p_kind = 'PROGRESS' and coalesce(p_retention_pct,0) not between 0 and 100 then raise exception 'Retensi harus 0–100%%'; end if;
  if jsonb_typeof(coalesce(p_lines,'null')) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Isi minimal satu baris tagihan'; end if;

  if p_invoice_id is not null then
    select invoice_id into v_id from finance.ar_invoice where invoice_id = p_invoice_id and status = 'DRAFT' for update;
    if v_id is null then raise exception 'Invoice hanya bisa diubah selama masih DRAFT'; end if;
    delete from finance.ar_invoice_line where invoice_id = v_id;
  end if;

  -- validasi baris
  for l in select * from jsonb_array_elements(p_lines) loop
    v_n := v_n + 1;
    if nullif(l->>'sms_id','') is not null then
      if p_kind <> 'PROGRESS' then raise exception 'Invoice retensi tidak memakai SMS'; end if;
      select * into s from finance.sms_info((l->>'sms_id')::uuid);
      if s.sms_id is null then raise exception 'SMS baris % tidak ditemukan', v_n; end if;
      if s.status <> 'APPROVED' then raise exception 'SMS % belum APPROVED (status %)', s.number, s.status; end if;
      if s.project_id <> p_project_id then raise exception 'SMS % bukan milik proyek ini', s.number; end if;
      if s.sms_id = any(v_sms) then raise exception 'SMS % dobel di invoice ini', s.number; end if;
      perform pg_advisory_xact_lock(hashtextextended('smartfin-sms:' || s.sms_id::text, 0));
      if exists (select 1 from finance.ar_invoice_line x where x.sms_id = s.sms_id) then
        raise exception 'SMS % sudah ditagih di invoice lain', s.number;
      end if;
      if s.amount <= 0 then raise exception 'SMS % belum punya nilai item', s.number; end if;
      v_sms := v_sms || s.sms_id;
      v_dpp := v_dpp + s.amount;
    else
      if coalesce((l->>'amount')::numeric, 0) <= 0 then raise exception 'Nilai baris % harus lebih dari 0', v_n; end if;
      if coalesce(btrim(l->>'description'),'') = '' then raise exception 'Keterangan baris % wajib diisi', v_n; end if;
      v_dpp := v_dpp + round((l->>'amount')::numeric, 2);
    end if;
  end loop;

  if p_kind = 'RETENTION' then
    v_open := finance.retention_open(p_project_id, p_invoice_id);
    if v_dpp > v_open then raise exception 'Nilai pencairan melebihi sisa retensi proyek (Rp %)', v_open; end if;
  end if;

  v_ret  := case when p_kind = 'PROGRESS' then round(v_dpp * coalesce(p_retention_pct,0) / 100, 0) else 0 end;
  v_base := v_dpp - v_ret;
  v_ppn  := case when p_ppn_mode = 'NONE' then 0 else floor(v_base * p_ppn_rate / 100) end;
  v_pph  := case when p_pph_mode = 'NONE' then 0 else floor(v_base * p_pph_rate / 100) end;
  v_recv := v_base + case when p_ppn_mode = 'COLLECT' then v_ppn else 0 end;

  v_no := nullif(btrim(p_invoice_no), '');
  if v_no is null then
    perform pg_advisory_xact_lock(hashtextextended('smartfin-arno', 0));
    v_no := 'INV/BIMA/' || to_char(p_invoice_date, 'YYYY/MM') || '/' || lpad((
              select coalesce(max(nullif(regexp_replace(invoice_no, '^.*/', ''), '')::int), 0) + 1
                from finance.ar_invoice where invoice_no ~ ('^INV/BIMA/' || to_char(p_invoice_date, 'YYYY/MM') || '/[0-9]+$'))::text, 3, '0');
  end if;
  if exists (select 1 from finance.ar_invoice where invoice_no = v_no and invoice_id is distinct from p_invoice_id) then
    raise exception 'Nomor invoice % sudah dipakai', v_no;
  end if;

  if v_id is null then
    insert into finance.ar_invoice (invoice_no, kind, project_id, client_name, invoice_date, due_date, description, dpp,
                                    retention_pct, retention_amount, ppn_mode, ppn_rate, ppn_amount, pph_mode, pph_rate, pph_amount,
                                    receivable_amount, expected_cash, faktur_no, created_by, created_by_id)
    values (v_no, p_kind, p_project_id, v_client, p_invoice_date, p_due_date, btrim(p_description), v_dpp,
            case when p_kind = 'PROGRESS' then coalesce(p_retention_pct,0) else 0 end, v_ret,
            p_ppn_mode, case when p_ppn_mode = 'NONE' then 0 else p_ppn_rate end, v_ppn,
            p_pph_mode, case when p_pph_mode = 'NONE' then 0 else p_pph_rate end, v_pph,
            v_recv, v_recv - v_pph, nullif(btrim(p_faktur_no),''), finance.employee_name(who), who)
    returning invoice_id into v_id;
  else
    update finance.ar_invoice set invoice_no = v_no, kind = p_kind, project_id = p_project_id, client_name = v_client,
           invoice_date = p_invoice_date, due_date = p_due_date, description = btrim(p_description), dpp = v_dpp,
           retention_pct = case when p_kind = 'PROGRESS' then coalesce(p_retention_pct,0) else 0 end, retention_amount = v_ret,
           ppn_mode = p_ppn_mode, ppn_rate = case when p_ppn_mode = 'NONE' then 0 else p_ppn_rate end, ppn_amount = v_ppn,
           pph_mode = p_pph_mode, pph_rate = case when p_pph_mode = 'NONE' then 0 else p_pph_rate end, pph_amount = v_pph,
           receivable_amount = v_recv, expected_cash = v_recv - v_pph, faktur_no = nullif(btrim(p_faktur_no),'')
     where invoice_id = v_id;
  end if;

  insert into finance.ar_invoice_line (invoice_id, sms_id, sms_number, description, amount)
  select v_id, si.sms_id, si.number,
         coalesce(nullif(btrim(je.value->>'description'),''), 'SMS ' || si.number),
         case when si.sms_id is not null then si.amount else round((je.value->>'amount')::numeric, 2) end
    from jsonb_array_elements(p_lines) je
    left join lateral finance.sms_info(nullif(je.value->>'sms_id','')::uuid) si on true;

  return jsonb_build_object('invoice_id', v_id, 'invoice_no', v_no, 'dpp', v_dpp, 'receivable_amount', v_recv, 'status', 'DRAFT');
end; $$;

create or replace function public.fin_decide_ar_invoice(p_token text, p_invoice_id bigint, p_approve boolean, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare who bigint; i finance.ar_invoice%rowtype; v_code text; v_j bigint;
begin
  select * into i from finance.ar_invoice where invoice_id = p_invoice_id for update;
  if i.invoice_id is null then raise exception 'Invoice % tidak ditemukan', p_invoice_id; end if;
  select code into v_code from operational.projects where id = i.project_id;
  who := finance.check_session(p_token, array['fin-ar','fin-jv'], 'PJ', v_code);
  if i.status <> 'DRAFT' then raise exception 'Invoice ini sudah diproses (status %)', i.status; end if;
  if coalesce(p_approve, false) then
    if i.kind = 'RETENTION' and i.dpp > finance.retention_open(i.project_id, i.invoice_id) then
      raise exception 'Nilai pencairan melebihi sisa retensi proyek';
    end if;
    update finance.ar_invoice set status = 'APPROVED', approved_by = finance.employee_name(who), approved_at = now() where invoice_id = i.invoice_id;
    select journal_id into v_j from finance.journal where source_table = 'ar_invoice' and source_id = i.invoice_id::text and source_event = 'APPROVED';
    if v_j is null then raise exception 'Jurnal invoice gagal dibuat, cek log error jurnal'; end if;
    perform finance.post_journal(v_j, finance.employee_name(who));
  else
    if coalesce(btrim(p_reason),'') = '' then raise exception 'Alasan penolakan wajib diisi'; end if;
    -- lepas SMS supaya bisa ditagih ulang
    update finance.ar_invoice_line set sms_id = null where invoice_id = i.invoice_id;
    update finance.ar_invoice set status = 'REJECTED', reject_reason = btrim(p_reason),
           approved_by = finance.employee_name(who), approved_at = now() where invoice_id = i.invoice_id;
  end if;
  return jsonb_build_object('invoice_id', i.invoice_id, 'status', case when p_approve then 'APPROVED' else 'REJECTED' end);
end; $$;

-- Nomor faktur pajak boleh dilengkapi setelah invoice disetujui
create or replace function public.fin_set_ar_faktur(p_token text, p_invoice_id bigint, p_faktur_no text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform finance.check_session(p_token, array['fin-ar']);
  update finance.ar_invoice set faktur_no = nullif(btrim(p_faktur_no),'') where invoice_id = p_invoice_id and status <> 'REJECTED';
  if not found then raise exception 'Invoice tidak ditemukan'; end if;
  return jsonb_build_object('invoice_id', p_invoice_id, 'faktur_no', nullif(btrim(p_faktur_no),''));
end; $$;

create or replace function public.fin_save_ar_receipt(
  p_token text, p_invoice_id bigint, p_bank_id bigint, p_receipt_date date, p_cash_amount numeric, p_pph_amount numeric,
  p_ref_no text, p_notes text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare who bigint; i finance.ar_invoice%rowtype; v_left numeric; v_id bigint;
begin
  who := finance.check_session(p_token, array['fin-ar']);
  select * into i from finance.ar_invoice where invoice_id = p_invoice_id for update;
  if i.invoice_id is null then raise exception 'Invoice tidak ditemukan'; end if;
  if i.status not in ('APPROVED','PARTIAL') then raise exception 'Penerimaan hanya untuk invoice yang sudah disetujui dan belum lunas'; end if;
  if not exists (select 1 from finance.bank_account where bank_id = p_bank_id and is_active) then raise exception 'Pilih rekening bank yang aktif'; end if;
  if p_receipt_date is null or p_receipt_date > current_date or p_receipt_date < i.invoice_date then raise exception 'Tanggal terima tidak valid'; end if;
  if coalesce(p_cash_amount,0) < 0 or coalesce(p_pph_amount,0) < 0 or coalesce(p_cash_amount,0) + coalesce(p_pph_amount,0) <= 0 then
    raise exception 'Isi nilai uang diterima';
  end if;
  if i.pph_mode = 'NONE' and coalesce(p_pph_amount,0) > 0 then raise exception 'Invoice ini tanpa PPh, isi PPh dipotong 0'; end if;
  v_left := i.receivable_amount - finance.ar_settled(i.invoice_id, true);
  if coalesce(p_cash_amount,0) + coalesce(p_pph_amount,0) > v_left then
    raise exception 'Melebihi sisa piutang (Rp %, termasuk penerimaan yang menunggu approval)', v_left;
  end if;
  insert into finance.ar_receipt (invoice_id, bank_id, receipt_date, cash_amount, pph_amount, ref_no, notes, requested_by, requested_by_id)
  values (i.invoice_id, p_bank_id, p_receipt_date, coalesce(p_cash_amount,0), coalesce(p_pph_amount,0),
          nullif(btrim(p_ref_no),''), nullif(btrim(p_notes),''), finance.employee_name(who), who)
  returning receipt_id into v_id;
  return jsonb_build_object('receipt_id', v_id, 'status', 'PLANNED');
end; $$;

create or replace function public.fin_decide_ar_receipt(p_token text, p_receipt_id bigint, p_approve boolean, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare who bigint; r finance.ar_receipt%rowtype; i finance.ar_invoice%rowtype; v_code text; v_j bigint; v_set numeric;
begin
  select * into r from finance.ar_receipt where receipt_id = p_receipt_id for update;
  if r.receipt_id is null then raise exception 'Penerimaan % tidak ditemukan', p_receipt_id; end if;
  select * into i from finance.ar_invoice where invoice_id = r.invoice_id for update;
  select code into v_code from operational.projects where id = i.project_id;
  who := finance.check_session(p_token, array['fin-ar','fin-jv'], 'PJ', v_code);
  if r.status <> 'PLANNED' then raise exception 'Penerimaan ini sudah diproses (status %)', r.status; end if;
  if coalesce(p_approve, false) then
    update finance.ar_receipt set status = 'APPROVED', approved_by = finance.employee_name(who), approved_at = now() where receipt_id = r.receipt_id;
    select journal_id into v_j from finance.journal where source_table = 'ar_receipt' and source_id = r.receipt_id::text and source_event = 'APPROVED';
    if v_j is null then raise exception 'Jurnal penerimaan gagal dibuat, cek log error jurnal'; end if;
    perform finance.post_journal(v_j, finance.employee_name(who));
    v_set := finance.ar_settled(i.invoice_id);
    update finance.ar_invoice set status = case when v_set >= receivable_amount then 'PAID' else 'PARTIAL' end where invoice_id = i.invoice_id;
  else
    if coalesce(btrim(p_reason),'') = '' then raise exception 'Alasan penolakan wajib diisi'; end if;
    update finance.ar_receipt set status = 'REJECTED', reject_reason = btrim(p_reason),
           approved_by = finance.employee_name(who), approved_at = now() where receipt_id = r.receipt_id;
  end if;
  return jsonb_build_object('receipt_id', r.receipt_id, 'status', case when p_approve then 'APPROVED' else 'REJECTED' end);
end; $$;

-- Hak eksekusi ------------------------------------------------------------
revoke execute on function finance.sms_info(uuid)                  from public, anon, authenticated;
revoke execute on function finance.retention_open(uuid, bigint)    from public, anon, authenticated;
revoke execute on function finance.ar_settled(bigint, boolean)     from public, anon, authenticated;
revoke execute on function finance.journal_ar_invoice(bigint)      from public, anon, authenticated;
revoke execute on function finance.journal_ar_receipt(bigint)      from public, anon, authenticated;
revoke execute on function finance.trg_ar_journal()                from public, anon, authenticated;
revoke execute on function public.fin_ar_overview(text) from public;
revoke execute on function public.fin_save_ar_invoice(text, bigint, text, uuid, text, date, date, text, numeric, text, numeric, text, numeric, text, jsonb) from public;
revoke execute on function public.fin_decide_ar_invoice(text, bigint, boolean, text) from public;
revoke execute on function public.fin_set_ar_faktur(text, bigint, text) from public;
revoke execute on function public.fin_save_ar_receipt(text, bigint, bigint, date, numeric, numeric, text, text) from public;
revoke execute on function public.fin_decide_ar_receipt(text, bigint, boolean, text) from public;
grant execute on function public.fin_ar_overview(text) to anon, authenticated;
grant execute on function public.fin_save_ar_invoice(text, bigint, text, uuid, text, date, date, text, numeric, text, numeric, text, numeric, text, jsonb) to anon, authenticated;
grant execute on function public.fin_decide_ar_invoice(text, bigint, boolean, text) to anon, authenticated;
grant execute on function public.fin_set_ar_faktur(text, bigint, text) to anon, authenticated;
grant execute on function public.fin_save_ar_receipt(text, bigint, bigint, date, numeric, numeric, text, text) to anon, authenticated;
grant execute on function public.fin_decide_ar_receipt(text, bigint, boolean, text) to anon, authenticated;
