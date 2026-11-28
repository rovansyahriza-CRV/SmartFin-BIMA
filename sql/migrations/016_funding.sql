-- =====================================================================
-- SmartFin BIMA — Migration 016: Pendanaan (pinjaman bank / non-bank, modal kerja, leasing)
-- Status : ✅ Sudah dijalankan (28 Nov 2026)
--
-- Menu Pendanaan: input FIN-AP, register & pencairan disetujui PJ proyek, angsuran / biaya disetujui APY proyek.
-- Setiap pinjaman punya kode proyek (proyek klien atau internal 901–905): bunga & biaya dibebankan ke proyek itu.
-- Pinjaman yang sudah berjalan sebelum SmartFin dicatat sebagai "pinjaman berjalan" dengan sisa pokok per cut-off.
--
-- Akun:  2-1600 Hutang Bank (modal kerja / lainnya dari bank)
--        2-1610 Hutang Pinjaman Non-Bank
--        2-1700 Hutang Leasing
--        6-1600 Beban Bunga Pinjaman      6-1610 Beban Provisi & Administrasi Pinjaman
-- Jurnal (langsung POSTED saat disetujui; proyek = proyek pinjaman):
--   Sisa pokok awal (pinjaman berjalan) : Dr 3-9000 Ekuitas Saldo Awal / Cr Hutang pinjaman
--   Pencairan  : Dr Bank (atau akun lain, mis. 2-1100 kalau leasing langsung bayar ke vendor) + Dr 6-1610 provisi / Cr Hutang pinjaman
--   Angsuran   : Dr Hutang pinjaman (pokok) + Dr 6-1600 bunga + Dr 6-1610 biaya / Cr Bank + Cr 2-1410 PPh 23 bunga (lender non-bank)
--   Biaya lain : Dr 6-1610 / Cr Bank
-- Arus kas: jurnal yang menyentuh 2-16xx / 2-17xx masuk kategori PENDANAAN.
-- =====================================================================

insert into finance.coa (account_code, account_name, account_type, is_postable, notes) values
  ('2-1600', 'Hutang Bank', 'LIABILITY', true, 'Pinjaman bank: modal kerja / kredit lainnya'),
  ('2-1610', 'Hutang Pinjaman Non-Bank', 'LIABILITY', true, 'Pinjaman dari perusahaan / perorangan non-bank'),
  ('2-1700', 'Hutang Leasing', 'LIABILITY', true, 'Pembiayaan alat / kendaraan (leasing)'),
  ('6-1600', 'Beban Bunga Pinjaman', 'EXPENSE', true, 'Bunga bank, non-bank, leasing'),
  ('6-1610', 'Beban Provisi & Administrasi Pinjaman', 'EXPENSE', true, 'Provisi, biaya admin, notaris pinjaman')
on conflict (account_code) do nothing;

alter table finance.journal drop constraint journal_source_system_check;
alter table finance.journal add constraint journal_source_system_check
  check (source_system in ('SMMS','FUSION4','PETTY_CASH','AP','MANUAL','ASSET','CASH','BANK','AR','LOAN'));

create table finance.loan (
  loan_id        bigint generated always as identity primary key,
  loan_no        text not null,
  lender_name    text not null,
  lender_type    text not null check (lender_type in ('BANK','NON_BANK')),
  kind           text not null check (kind in ('MODAL_KERJA','LEASING','OTHER')),
  project_id     uuid not null references operational.projects(id),
  bank_id        bigint references finance.bank_account(bank_id),
  principal      numeric(18,2) not null check (principal > 0),   -- plafon / pokok; pinjaman berjalan: sisa pokok per cut-off
  is_existing    boolean not null default false,
  start_date     date not null,                                   -- tanggal akad / cut-off
  interest_rate  numeric(7,3) not null default 0 check (interest_rate >= 0),   -- % per tahun
  method         text not null default 'ANNUITY' check (method in ('ANNUITY','FLAT','INTEREST_ONLY','MANUAL')),
  tenor_months   int check (tenor_months between 1 and 360),      -- pinjaman berjalan: sisa tenor
  first_due_date date,
  pph23_interest boolean not null default false,                  -- potong PPh 23 atas bunga (umumnya lender non-bank)
  collateral     text,
  notes          text,
  status         text not null default 'DRAFT' check (status in ('DRAFT','ACTIVE','CLOSED','REJECTED')),
  created_by     text, created_by_id bigint,
  approved_by    text, approved_at timestamptz, reject_reason text,
  created_at     timestamptz not null default now(),
  unique (lender_name, loan_no),
  check (method = 'MANUAL' or (tenor_months is not null and first_due_date is not null))
);
alter table finance.loan enable row level security;

create table finance.loan_schedule (
  loan_id    bigint not null references finance.loan(loan_id) on delete cascade,
  seq        int not null,
  due_date   date not null,
  principal  numeric(18,2) not null,
  interest   numeric(18,2) not null,
  primary key (loan_id, seq)
);
alter table finance.loan_schedule enable row level security;

create table finance.loan_txn (
  txn_id           bigint generated always as identity primary key,
  loan_id          bigint not null references finance.loan(loan_id),
  kind             text not null check (kind in ('OPENING','DRAWDOWN','INSTALLMENT','FEE')),
  txn_date         date not null,
  principal_amount numeric(18,2) not null default 0 check (principal_amount >= 0),
  interest_amount  numeric(18,2) not null default 0 check (interest_amount >= 0),
  pph23_amount     numeric(18,2) not null default 0 check (pph23_amount >= 0),
  fee_amount       numeric(18,2) not null default 0 check (fee_amount >= 0),
  bank_id          bigint references finance.bank_account(bank_id),
  counter_account  text references finance.coa(account_code),
  schedule_seq     int,
  ref_no           text,
  notes            text,
  status           text not null default 'PLANNED' check (status in ('PLANNED','APPROVED','REJECTED')),
  requested_by     text, requested_by_id bigint,
  approved_by      text, approved_at timestamptz, reject_reason text,
  created_at       timestamptz not null default now(),
  check (pph23_amount <= interest_amount),
  check (principal_amount + interest_amount + fee_amount > 0)
);
create index on finance.loan_txn (loan_id, status);
alter table finance.loan_txn enable row level security;

-- Helper ----------------------------------------------------------------
create or replace function finance.loan_account(p_loan_id bigint)
returns text language sql stable security definer set search_path = '' as $$
  select case when kind = 'LEASING' then '2-1700' when lender_type = 'BANK' then '2-1600' else '2-1610' end
    from finance.loan where loan_id = p_loan_id;
$$;

create or replace function finance.loan_outstanding(p_loan_id bigint, p_include_planned boolean default false)
returns numeric language sql stable security definer set search_path = '' as $$
  select coalesce(sum(case when kind in ('OPENING','DRAWDOWN') then principal_amount
                           when kind = 'INSTALLMENT' then -principal_amount else 0 end), 0)
    from finance.loan_txn
   where loan_id = p_loan_id and (status = 'APPROVED' or (p_include_planned and status = 'PLANNED'));
$$;

-- Jadwal angsuran dari pokok, bunga % per tahun, tenor, metode
create or replace function finance.loan_build_schedule(p_loan_id bigint)
returns int language plpgsql security definer set search_path = '' as $$
declare l finance.loan%rowtype; r numeric; pmt numeric; bal numeric; i int; v_int numeric; v_pri numeric;
begin
  select * into l from finance.loan where loan_id = p_loan_id;
  delete from finance.loan_schedule where loan_id = p_loan_id;
  if l.method = 'MANUAL' then return 0; end if;
  r := l.interest_rate / 1200; bal := l.principal;
  if l.method = 'ANNUITY' then
    pmt := case when r = 0 then l.principal / l.tenor_months else l.principal * r / (1 - power(1 + r, -l.tenor_months)) end;
  end if;
  for i in 1..l.tenor_months loop
    if l.method = 'ANNUITY' then
      v_int := round(bal * r, 2); v_pri := case when i = l.tenor_months then bal else round(pmt - v_int, 2) end;
    elsif l.method = 'FLAT' then
      v_int := round(l.principal * r, 2); v_pri := case when i = l.tenor_months then bal else round(l.principal / l.tenor_months, 2) end;
    else -- INTEREST_ONLY
      v_int := round(l.principal * r, 2); v_pri := case when i = l.tenor_months then bal else 0 end;
    end if;
    insert into finance.loan_schedule (loan_id, seq, due_date, principal, interest)
    values (p_loan_id, i, (l.first_due_date + make_interval(months => i - 1))::date, v_pri, v_int);
    bal := bal - v_pri;
  end loop;
  return l.tenor_months;
end; $$;

create or replace function finance.journal_loan_txn(p_txn_id bigint)
returns void language plpgsql security definer set search_path = '' as $$
declare t record; v_acc text; v_lines jsonb := '[]'::jsonb; v_memo text; v_label text;
begin
  select x.*, l.loan_no, l.lender_name, l.project_id, b.coa_code as bank_coa
    into t
    from finance.loan_txn x join finance.loan l on l.loan_id = x.loan_id
    left join finance.bank_account b on b.bank_id = x.bank_id
   where x.txn_id = p_txn_id;
  if t.txn_id is null then return; end if;
  v_acc := finance.loan_account(t.loan_id);
  v_memo := t.lender_name || ' ' || t.loan_no;
  v_label := case t.kind when 'OPENING' then 'Sisa pokok awal pinjaman' when 'DRAWDOWN' then 'Pencairan pinjaman'
                         when 'INSTALLMENT' then 'Angsuran pinjaman' else 'Biaya pinjaman' end;
  if t.status = 'APPROVED' then
    if t.kind = 'OPENING' then
      v_lines := jsonb_build_array(
        jsonb_build_object('account', '3-9000', 'debit', t.principal_amount, 'project_id', t.project_id, 'memo', v_memo),
        jsonb_build_object('account', v_acc, 'credit', t.principal_amount, 'project_id', t.project_id, 'memo', v_memo));
    elsif t.kind = 'DRAWDOWN' then
      v_lines := jsonb_build_array(
        jsonb_build_object('account', coalesce(t.bank_coa, t.counter_account), 'debit', t.principal_amount - t.fee_amount, 'project_id', t.project_id, 'memo', v_memo),
        jsonb_build_object('account', '6-1610', 'debit', t.fee_amount, 'project_id', t.project_id, 'memo', v_memo || ' provisi/admin'),
        jsonb_build_object('account', v_acc, 'credit', t.principal_amount, 'project_id', t.project_id, 'memo', v_memo));
    else
      v_lines := jsonb_build_array(
        jsonb_build_object('account', v_acc, 'debit', t.principal_amount, 'project_id', t.project_id, 'memo', v_memo || ' pokok'),
        jsonb_build_object('account', '6-1600', 'debit', t.interest_amount, 'project_id', t.project_id, 'memo', v_memo || ' bunga'),
        jsonb_build_object('account', '6-1610', 'debit', t.fee_amount, 'project_id', t.project_id, 'memo', v_memo || ' biaya'),
        jsonb_build_object('account', t.bank_coa, 'credit', t.principal_amount + t.interest_amount + t.fee_amount - t.pph23_amount, 'project_id', t.project_id, 'memo', coalesce(t.ref_no, v_memo)),
        jsonb_build_object('account', '2-1410', 'credit', t.pph23_amount, 'project_id', t.project_id, 'memo', v_memo || ' PPh 23 bunga'));
    end if;
  end if;
  perform finance.sync_auto_journal('LOAN', 'loan_txn', p_txn_id::text, 'APPROVED', t.txn_date, t.project_id,
          v_label || ' - ' || v_memo || coalesce(' - ' || t.notes, ''), v_lines);
end; $$;

create or replace function finance.trg_loan_txn_journal()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  begin
    perform finance.journal_loan_txn(new.txn_id);
  exception when others then
    insert into finance.auto_journal_error (source_table, source_id, source_event, error_message)
    values ('loan_txn', new.txn_id::text, tg_op, sqlerrm);
  end;
  return null;
end; $$;
create trigger trg_sfm_loan_txn after insert or update on finance.loan_txn
  for each row execute function finance.trg_loan_txn_journal();

-- API -------------------------------------------------------------------
create or replace function public.fin_loans(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform finance.check_session(p_token, array['fin-ap','fin-jv']);
  return jsonb_build_object(
    'kpi', jsonb_build_object(
      'outstanding', (select coalesce(sum(finance.loan_outstanding(loan_id)), 0) from finance.loan where status in ('ACTIVE','CLOSED')),
      'bank',        (select coalesce(sum(finance.loan_outstanding(loan_id)), 0) from finance.loan where status in ('ACTIVE','CLOSED') and kind <> 'LEASING' and lender_type = 'BANK'),
      'nonbank',     (select coalesce(sum(finance.loan_outstanding(loan_id)), 0) from finance.loan where status in ('ACTIVE','CLOSED') and kind <> 'LEASING' and lender_type = 'NON_BANK'),
      'leasing',     (select coalesce(sum(finance.loan_outstanding(loan_id)), 0) from finance.loan where status in ('ACTIVE','CLOSED') and kind = 'LEASING'),
      'due30',       (select coalesce(sum(s.principal + s.interest), 0) from finance.loan_schedule s join finance.loan l on l.loan_id = s.loan_id
                       where l.status = 'ACTIVE' and s.due_date <= current_date + 30
                         and not exists (select 1 from finance.loan_txn t where t.loan_id = s.loan_id and t.schedule_seq = s.seq and t.kind = 'INSTALLMENT' and t.status <> 'REJECTED')),
      'interestYtd', (select coalesce(sum(interest_amount), 0) from finance.loan_txn where kind = 'INSTALLMENT' and status = 'APPROVED'
                       and txn_date >= date_trunc('year', current_date)::date),
      'pending',     (select count(*) from finance.loan where status = 'DRAFT') + (select count(*) from finance.loan_txn where status = 'PLANNED')),
    'loans', (select coalesce(jsonb_agg(jsonb_build_object(
                 'loan_id', l.loan_id, 'loan_no', l.loan_no, 'lender_name', l.lender_name, 'lender_type', l.lender_type, 'kind', l.kind,
                 'project_id', l.project_id, 'project_code', p.code, 'project_name', p.name, 'bank_id', l.bank_id, 'bank_label', b.account_label,
                 'principal', l.principal, 'is_existing', l.is_existing, 'start_date', l.start_date, 'interest_rate', l.interest_rate,
                 'method', l.method, 'tenor_months', l.tenor_months, 'first_due_date', l.first_due_date, 'pph23_interest', l.pph23_interest,
                 'collateral', l.collateral, 'notes', l.notes, 'status', l.status, 'created_by', l.created_by, 'approved_by', l.approved_by,
                 'reject_reason', l.reject_reason, 'account', finance.loan_account(l.loan_id),
                 'outstanding', finance.loan_outstanding(l.loan_id),
                 'outstanding_planned', finance.loan_outstanding(l.loan_id, true),
                 'schedule', (select coalesce(jsonb_agg(jsonb_build_object('seq', s.seq, 'due_date', s.due_date, 'principal', s.principal, 'interest', s.interest,
                                 'paid', exists (select 1 from finance.loan_txn t where t.loan_id = s.loan_id and t.schedule_seq = s.seq and t.kind = 'INSTALLMENT' and t.status = 'APPROVED'),
                                 'planned', exists (select 1 from finance.loan_txn t where t.loan_id = s.loan_id and t.schedule_seq = s.seq and t.kind = 'INSTALLMENT' and t.status = 'PLANNED'))
                               order by s.seq), '[]'::jsonb) from finance.loan_schedule s where s.loan_id = l.loan_id),
                 'txns', (select coalesce(jsonb_agg(jsonb_build_object('txn_id', t.txn_id, 'kind', t.kind, 'txn_date', t.txn_date,
                             'principal_amount', t.principal_amount, 'interest_amount', t.interest_amount, 'pph23_amount', t.pph23_amount,
                             'fee_amount', t.fee_amount, 'bank_label', tb.account_label, 'counter_account', t.counter_account, 'schedule_seq', t.schedule_seq,
                             'ref_no', t.ref_no, 'notes', t.notes, 'status', t.status, 'requested_by', t.requested_by, 'approved_by', t.approved_by,
                             'reject_reason', t.reject_reason) order by t.txn_date, t.txn_id), '[]'::jsonb)
                          from finance.loan_txn t left join finance.bank_account tb on tb.bank_id = t.bank_id where t.loan_id = l.loan_id))
               order by case l.status when 'DRAFT' then 0 when 'ACTIVE' then 1 when 'CLOSED' then 2 else 3 end, l.lender_name, l.loan_no), '[]'::jsonb)
               from finance.loan l
               join operational.projects p on p.id = l.project_id
               left join finance.bank_account b on b.bank_id = l.bank_id),
    'projects', (select coalesce(jsonb_agg(jsonb_build_object('project_id', id, 'code', code, 'name', name) order by code), '[]'::jsonb) from operational.projects),
    'banks', (select coalesce(jsonb_agg(jsonb_build_object('bank_id', bank_id, 'label', account_label) order by bank_name), '[]'::jsonb)
                from finance.bank_account where is_active),
    'accounts', (select coalesce(jsonb_agg(jsonb_build_object('code', account_code, 'name', account_name) order by account_code), '[]'::jsonb)
                   from finance.coa where is_postable and is_active and account_code !~ '^1-1[12][0-9]{2}$'
                     and account_code not in ('2-1600','2-1610','2-1700')));
end; $$;

create or replace function public.fin_save_loan(
  p_token text, p_loan_id bigint, p_loan_no text, p_lender_name text, p_lender_type text, p_kind text, p_project_id uuid,
  p_bank_id bigint, p_principal numeric, p_is_existing boolean, p_start_date date, p_interest_rate numeric, p_method text,
  p_tenor_months int, p_first_due_date date, p_pph23_interest boolean, p_collateral text, p_notes text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare who bigint; v_id bigint;
begin
  who := finance.check_session(p_token, array['fin-ap']);
  if coalesce(btrim(p_loan_no),'') = '' or coalesce(btrim(p_lender_name),'') = '' then raise exception 'Isi nomor perjanjian dan nama pemberi pinjaman'; end if;
  if p_lender_type not in ('BANK','NON_BANK') then raise exception 'Jenis pemberi pinjaman tidak dikenal'; end if;
  if p_kind not in ('MODAL_KERJA','LEASING','OTHER') then raise exception 'Jenis pinjaman tidak dikenal'; end if;
  if p_method not in ('ANNUITY','FLAT','INTEREST_ONLY','MANUAL') then raise exception 'Metode angsuran tidak dikenal'; end if;
  if not exists (select 1 from operational.projects where id = p_project_id) then raise exception 'Pilih kode proyek'; end if;
  if p_bank_id is not null and not exists (select 1 from finance.bank_account where bank_id = p_bank_id and is_active) then raise exception 'Rekening tidak aktif'; end if;
  if coalesce(p_principal, 0) <= 0 then raise exception 'Isi %', case when p_is_existing then 'sisa pokok per tanggal cut-off' else 'plafon / pokok pinjaman' end; end if;
  if p_start_date is null or p_start_date > current_date + 31 then raise exception 'Tanggal akad / cut-off tidak valid'; end if;
  if coalesce(p_interest_rate, 0) < 0 or p_interest_rate > 100 then raise exception 'Bunga per tahun tidak valid'; end if;
  if p_method <> 'MANUAL' and (coalesce(p_tenor_months, 0) not between 1 and 360 or p_first_due_date is null) then
    raise exception 'Isi tenor (bulan) dan tanggal angsuran pertama, atau pilih metode Manual';
  end if;
  if p_method <> 'MANUAL' and p_first_due_date < p_start_date then raise exception 'Angsuran pertama tidak boleh sebelum tanggal akad / cut-off'; end if;
  if p_loan_id is not null then
    update finance.loan set loan_no = btrim(p_loan_no), lender_name = btrim(p_lender_name), lender_type = p_lender_type, kind = p_kind,
           project_id = p_project_id, bank_id = p_bank_id, principal = round(p_principal, 2), is_existing = coalesce(p_is_existing, false),
           start_date = p_start_date, interest_rate = coalesce(p_interest_rate, 0), method = p_method,
           tenor_months = case when p_method = 'MANUAL' then p_tenor_months else p_tenor_months end,
           first_due_date = p_first_due_date, pph23_interest = coalesce(p_pph23_interest, false),
           collateral = nullif(btrim(p_collateral),''), notes = nullif(btrim(p_notes),'')
     where loan_id = p_loan_id and status = 'DRAFT'
    returning loan_id into v_id;
    if v_id is null then raise exception 'Pinjaman hanya bisa diubah selama masih DRAFT'; end if;
  else
    insert into finance.loan (loan_no, lender_name, lender_type, kind, project_id, bank_id, principal, is_existing, start_date,
                              interest_rate, method, tenor_months, first_due_date, pph23_interest, collateral, notes, created_by, created_by_id)
    values (btrim(p_loan_no), btrim(p_lender_name), p_lender_type, p_kind, p_project_id, p_bank_id, round(p_principal, 2), coalesce(p_is_existing, false),
            p_start_date, coalesce(p_interest_rate, 0), p_method, p_tenor_months, p_first_due_date, coalesce(p_pph23_interest, false),
            nullif(btrim(p_collateral),''), nullif(btrim(p_notes),''), finance.employee_name(who), who)
    returning loan_id into v_id;
  end if;
  perform finance.loan_build_schedule(v_id);
  return jsonb_build_object('loan_id', v_id, 'status', 'DRAFT');
end; $$;

-- PJ menyetujui register pinjaman. Pinjaman berjalan: sisa pokok awal langsung dijurnal (Dr 3-9000 / Cr Hutang).
create or replace function public.fin_decide_loan(p_token text, p_loan_id bigint, p_approve boolean, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare who bigint; l finance.loan%rowtype; v_code text; v_t bigint; v_j bigint;
begin
  select * into l from finance.loan where loan_id = p_loan_id for update;
  if l.loan_id is null then raise exception 'Pinjaman tidak ditemukan'; end if;
  select code into v_code from operational.projects where id = l.project_id;
  who := finance.check_session(p_token, array['fin-ap','fin-jv'], 'PJ', v_code);
  if l.status <> 'DRAFT' then raise exception 'Pinjaman ini sudah diproses (status %)', l.status; end if;
  if coalesce(p_approve, false) then
    update finance.loan set status = 'ACTIVE', approved_by = finance.employee_name(who), approved_at = now() where loan_id = l.loan_id;
    if l.is_existing then
      insert into finance.loan_txn (loan_id, kind, txn_date, principal_amount, notes, status, requested_by, requested_by_id, approved_by, approved_at)
      values (l.loan_id, 'OPENING', l.start_date, l.principal, 'Sisa pokok per cut-off', 'APPROVED',
              coalesce(l.created_by, finance.employee_name(who)), l.created_by_id, finance.employee_name(who), now())
      returning txn_id into v_t;
      select journal_id into v_j from finance.journal where source_table = 'loan_txn' and source_id = v_t::text and source_event = 'APPROVED';
      if v_j is null then raise exception 'Jurnal sisa pokok awal gagal dibuat, cek log error jurnal'; end if;
      perform finance.post_journal(v_j, finance.employee_name(who));
    end if;
  else
    if coalesce(btrim(p_reason),'') = '' then raise exception 'Alasan penolakan wajib diisi'; end if;
    update finance.loan set status = 'REJECTED', reject_reason = btrim(p_reason), approved_by = finance.employee_name(who), approved_at = now()
     where loan_id = l.loan_id;
  end if;
  return jsonb_build_object('loan_id', l.loan_id, 'status', case when p_approve then 'ACTIVE' else 'REJECTED' end);
end; $$;

create or replace function public.fin_save_loan_txn(
  p_token text, p_loan_id bigint, p_kind text, p_txn_date date, p_principal numeric, p_interest numeric, p_pph23 numeric,
  p_fee numeric, p_bank_id bigint, p_counter_account text, p_schedule_seq int, p_ref_no text, p_notes text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare who bigint; l finance.loan%rowtype; v_pri numeric := round(coalesce(p_principal,0),2); v_int numeric := round(coalesce(p_interest,0),2);
        v_pph numeric := round(coalesce(p_pph23,0),2); v_fee numeric := round(coalesce(p_fee,0),2); v_id bigint; v_out numeric;
begin
  who := finance.check_session(p_token, array['fin-ap']);
  select * into l from finance.loan where loan_id = p_loan_id for update;
  if l.loan_id is null then raise exception 'Pinjaman tidak ditemukan'; end if;
  if l.status not in ('ACTIVE','CLOSED') then raise exception 'Pinjaman belum disetujui PJ'; end if;
  if p_kind not in ('DRAWDOWN','INSTALLMENT','FEE') then raise exception 'Jenis transaksi tidak dikenal'; end if;
  if p_txn_date is null or p_txn_date > current_date or p_txn_date < l.start_date then raise exception 'Tanggal tidak valid'; end if;
  if v_pri < 0 or v_int < 0 or v_pph < 0 or v_fee < 0 then raise exception 'Nilai tidak boleh negatif'; end if;
  if p_bank_id is not null and not exists (select 1 from finance.bank_account where bank_id = p_bank_id and is_active) then raise exception 'Rekening tidak aktif'; end if;
  v_out := finance.loan_outstanding(l.loan_id, true);
  if p_kind = 'DRAWDOWN' then
    if v_pri <= 0 then raise exception 'Isi nilai pencairan'; end if;
    if v_fee >= v_pri then raise exception 'Provisi / biaya tidak boleh sebesar pencairan'; end if;
    if p_bank_id is null and nullif(p_counter_account,'') is null then raise exception 'Pilih rekening penerima atau akun lawan'; end if;
    if p_bank_id is null and not exists (select 1 from finance.coa where account_code = p_counter_account and is_postable and is_active
                                           and account_code !~ '^1-1[12][0-9]{2}$' and account_code not in ('2-1600','2-1610','2-1700')) then
      raise exception 'Akun lawan tidak valid';
    end if;
    if l.is_existing = false and v_out + v_pri > l.principal then
      raise exception 'Melebihi plafon (sisa plafon Rp %)', l.principal - v_out;
    end if;
    v_int := 0; v_pph := 0;
  elsif p_kind = 'INSTALLMENT' then
    if p_bank_id is null then raise exception 'Pilih rekening pembayar'; end if;
    if v_pri + v_int + v_fee <= 0 then raise exception 'Isi pokok dan/atau bunga'; end if;
    if v_pri > v_out then raise exception 'Pokok melebihi sisa pinjaman (Rp %, termasuk yang menunggu approval)', v_out; end if;
    if v_pph > v_int then raise exception 'PPh 23 tidak boleh melebihi bunga'; end if;
    if p_schedule_seq is not null then
      if not exists (select 1 from finance.loan_schedule where loan_id = l.loan_id and seq = p_schedule_seq) then raise exception 'Angsuran ke-% tidak ada di jadwal', p_schedule_seq; end if;
      if exists (select 1 from finance.loan_txn where loan_id = l.loan_id and schedule_seq = p_schedule_seq and kind = 'INSTALLMENT' and status <> 'REJECTED') then
        raise exception 'Angsuran ke-% sudah dicatat', p_schedule_seq;
      end if;
    end if;
  else
    if p_bank_id is null then raise exception 'Pilih rekening pembayar'; end if;
    if v_fee <= 0 then raise exception 'Isi nilai biaya'; end if;
    v_pri := 0; v_int := 0; v_pph := 0;
  end if;
  insert into finance.loan_txn (loan_id, kind, txn_date, principal_amount, interest_amount, pph23_amount, fee_amount, bank_id, counter_account,
                                schedule_seq, ref_no, notes, requested_by, requested_by_id)
  values (l.loan_id, p_kind, p_txn_date, v_pri, v_int, v_pph, v_fee, p_bank_id,
          case when p_kind = 'DRAWDOWN' and p_bank_id is null then p_counter_account end,
          case when p_kind = 'INSTALLMENT' then p_schedule_seq end, nullif(btrim(p_ref_no),''), nullif(btrim(p_notes),''),
          finance.employee_name(who), who)
  returning txn_id into v_id;
  return jsonb_build_object('txn_id', v_id, 'status', 'PLANNED');
end; $$;

-- Pencairan disetujui PJ; angsuran & biaya disetujui APY (per proyek pinjaman)
create or replace function public.fin_decide_loan_txn(p_token text, p_txn_id bigint, p_approve boolean, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare who bigint; t finance.loan_txn%rowtype; l finance.loan%rowtype; v_code text; v_j bigint; v_out numeric;
begin
  select * into t from finance.loan_txn where txn_id = p_txn_id for update;
  if t.txn_id is null then raise exception 'Transaksi tidak ditemukan'; end if;
  select * into l from finance.loan where loan_id = t.loan_id for update;
  select code into v_code from operational.projects where id = l.project_id;
  if t.kind = 'DRAWDOWN' then who := finance.check_session(p_token, array['fin-ap','fin-jv'], 'PJ', v_code);
  else who := finance.check_session(p_token, array['fin-ap'], 'APY', v_code); end if;
  if t.status <> 'PLANNED' then raise exception 'Transaksi ini sudah diproses (status %)', t.status; end if;
  if coalesce(p_approve, false) then
    if t.kind = 'INSTALLMENT' and t.principal_amount > finance.loan_outstanding(l.loan_id) then
      raise exception 'Pokok melebihi sisa pinjaman';
    end if;
    update finance.loan_txn set status = 'APPROVED', approved_by = finance.employee_name(who), approved_at = now() where txn_id = t.txn_id;
    select journal_id into v_j from finance.journal where source_table = 'loan_txn' and source_id = t.txn_id::text and source_event = 'APPROVED';
    if v_j is null then raise exception 'Jurnal gagal dibuat, cek log error jurnal'; end if;
    perform finance.post_journal(v_j, finance.employee_name(who));
    v_out := finance.loan_outstanding(l.loan_id);
    update finance.loan set status = case when v_out <= 0 then 'CLOSED' else 'ACTIVE' end where loan_id = l.loan_id;
  else
    if coalesce(btrim(p_reason),'') = '' then raise exception 'Alasan penolakan wajib diisi'; end if;
    update finance.loan_txn set status = 'REJECTED', reject_reason = btrim(p_reason), approved_by = finance.employee_name(who), approved_at = now()
     where txn_id = t.txn_id;
  end if;
  return jsonb_build_object('txn_id', t.txn_id, 'status', case when p_approve then 'APPROVED' else 'REJECTED' end);
end; $$;

-- Arus kas: pinjaman (2-16xx / 2-17xx) masuk kategori PENDANAAN
create or replace function public.fin_report(
  p_token text, p_report text, p_from date, p_to date, p_project_id uuid,
  p_account text, p_include_draft boolean, p_journal_id bigint
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_out jsonb; v_from date := coalesce(p_from, date_trunc('month', current_date)::date); v_to date := coalesce(p_to, current_date);
        v_draft boolean := coalesce(p_include_draft, true); v_fy date;
begin
  perform finance.check_session(p_token, array['fin-rpt']);
  if v_from > v_to then raise exception 'Tanggal awal lebih besar dari tanggal akhir'; end if;
  v_fy := date_trunc('year', v_to)::date;

  if p_report = 'TB' then
    select coalesce(jsonb_agg(x order by x.account_code), '[]'::jsonb) into v_out from (
      select c.account_code, c.account_name, c.account_type,
             coalesce(sum(r.debit - r.credit) filter (where r.journal_date < v_from), 0) as opening,
             coalesce(sum(r.debit)  filter (where r.journal_date between v_from and v_to), 0) as debit,
             coalesce(sum(r.credit) filter (where r.journal_date between v_from and v_to), 0) as credit,
             coalesce(sum(r.debit - r.credit) filter (where r.journal_date <= v_to), 0) as closing
        from finance.coa c
        left join finance.report_lines(v_draft, p_project_id) r on r.account_code = c.account_code
       group by c.account_code, c.account_name, c.account_type
      having count(r.journal_id) > 0) x;

  elsif p_report = 'GL' then
    if p_account is null then raise exception 'Pilih akun untuk buku besar'; end if;
    select jsonb_build_object(
      'account', (select jsonb_build_object('code', account_code, 'name', account_name, 'type', account_type) from finance.coa where account_code = p_account),
      'opening', (select coalesce(sum(debit - credit), 0) from finance.report_lines(v_draft, p_project_id) where account_code = p_account and journal_date < v_from),
      'lines', (select coalesce(jsonb_agg(x order by x.journal_date, x.journal_id), '[]'::jsonb) from (
          select r.journal_id, r.journal_no, r.journal_date, r.status, r.source_system, r.description, r.memo,
                 p.code as project_code, r.debit, r.credit
            from finance.report_lines(v_draft, p_project_id) r
            left join operational.projects p on p.id = r.project_id
           where r.account_code = p_account and r.journal_date between v_from and v_to) x))
      into v_out;

  elsif p_report = 'PL' then
    select jsonb_build_object(
      'accounts', (select coalesce(jsonb_agg(x order by x.account_code), '[]'::jsonb) from (
          select c.account_code, c.account_name, c.account_type,
                 sum(case when c.account_type = 'REVENUE' then r.credit - r.debit else r.debit - r.credit end) as amount
            from finance.report_lines(v_draft, p_project_id) r
            join finance.coa c on c.account_code = r.account_code
           where c.account_type in ('REVENUE','EXPENSE') and r.journal_date between v_from and v_to
           group by c.account_code, c.account_name, c.account_type) x),
      'projects', (select coalesce(jsonb_agg(x order by x.code nulls last), '[]'::jsonb) from (
          select p.code, coalesce(p.name, 'Tanpa proyek / overhead') as name,
                 sum(case when c.account_type = 'REVENUE' then r.credit - r.debit else 0 end) as revenue,
                 sum(case when c.account_type = 'EXPENSE' then r.debit - r.credit else 0 end) as expense
            from finance.report_lines(v_draft, p_project_id) r
            join finance.coa c on c.account_code = r.account_code
            left join operational.projects p on p.id = r.project_id
           where c.account_type in ('REVENUE','EXPENSE') and r.journal_date between v_from and v_to
           group by p.code, p.name) x))
      into v_out;

  elsif p_report = 'BS' then
    select jsonb_build_object(
      'accounts', (select coalesce(jsonb_agg(x order by x.account_code), '[]'::jsonb) from (
          select c.account_code, c.account_name, c.account_type,
                 sum(case when c.account_type = 'ASSET' then r.debit - r.credit else r.credit - r.debit end) as amount
            from finance.report_lines(v_draft, p_project_id) r
            join finance.coa c on c.account_code = r.account_code
           where c.account_type in ('ASSET','LIABILITY','EQUITY') and r.journal_date <= v_to
           group by c.account_code, c.account_name, c.account_type
          having sum(r.debit - r.credit) <> 0) x),
      'currentEarnings', (select coalesce(sum(r.credit - r.debit), 0)
                            from finance.report_lines(v_draft, p_project_id) r join finance.coa c on c.account_code = r.account_code
                           where c.account_type in ('REVENUE','EXPENSE') and r.journal_date between v_fy and v_to),
      'priorEarnings', (select coalesce(sum(r.credit - r.debit), 0)
                          from finance.report_lines(v_draft, p_project_id) r join finance.coa c on c.account_code = r.account_code
                         where c.account_type in ('REVENUE','EXPENSE') and r.journal_date < v_fy),
      'fiscalYearStart', v_fy)
      into v_out;

  elsif p_report = 'CF' then
    with cash_acc as (
      select account_code from finance.coa where account_code ~ '^1-1[12][0-9]{2}$'
    ), lines as (
      select r.*, (r.account_code in (select account_code from cash_acc)) as is_cash
        from finance.report_lines(v_draft, p_project_id) r
    ), per_journal as (
      select journal_id, min(journal_date) as journal_date, min(journal_no) as journal_no, min(description) as description,
             sum(case when is_cash then debit - credit else 0 end) as cash_delta,
             case
               when bool_or(not is_cash and account_code = '3-9000') then 'SALDO_AWAL'
               when bool_or(not is_cash and (account_code like '2-16%' or account_code like '2-17%')) then 'PENDANAAN'
               when bool_or(not is_cash and account_code like '1-2%') then 'INVESTASI'
               when bool_or(not is_cash and account_code like '3-%') then 'PENDANAAN'
               when not bool_or(not is_cash) then 'INTERNAL'
               else 'OPERASI' end as category
        from lines group by journal_id
    )
    select jsonb_build_object(
      'opening', (select coalesce(sum(debit - credit), 0) from lines where is_cash and journal_date < v_from),
      'closing', (select coalesce(sum(debit - credit), 0) from lines where is_cash and journal_date <= v_to),
      'categories', (select coalesce(jsonb_object_agg(category, total), '{}'::jsonb) from (
          select category, sum(cash_delta) as total from per_journal
           where journal_date between v_from and v_to and cash_delta <> 0 group by category) c),
      'detail', (select coalesce(jsonb_agg(x order by x.journal_date, x.journal_id), '[]'::jsonb) from (
          select journal_id, journal_no, journal_date, description, category, cash_delta from per_journal
           where journal_date between v_from and v_to and cash_delta <> 0 and category <> 'INTERNAL') x))
      into v_out;

  elsif p_report = 'JOURNAL' then
    select jsonb_build_object('journal_id', j.journal_id, 'journal_no', j.journal_no, 'journal_date', j.journal_date,
             'status', j.status, 'source_system', j.source_system, 'source_table', j.source_table, 'description', j.description,
             'posted_by', j.posted_by, 'posted_at', j.posted_at,
             'lines', (select coalesce(jsonb_agg(jsonb_build_object('account_code', l.account_code, 'account_name', c.account_name,
                          'debit', l.debit, 'credit', l.credit, 'project_code', p.code, 'memo', l.memo) order by l.line_id), '[]'::jsonb)
                         from finance.journal_line l left join finance.coa c on c.account_code = l.account_code
                         left join operational.projects p on p.id = l.project_id where l.journal_id = j.journal_id))
      into v_out from finance.journal j where j.journal_id = p_journal_id;
    if v_out is null then raise exception 'Jurnal tidak ditemukan'; end if;

  else
    raise exception 'Jenis laporan tidak dikenal';
  end if;

  return jsonb_build_object('report', p_report, 'from', v_from, 'to', v_to, 'includeDraft', v_draft,
           'project', (select jsonb_build_object('code', code, 'name', name) from operational.projects where id = p_project_id),
           'draftCount', (select count(*) from finance.journal where status = 'DRAFT' and journal_date <= v_to),
           'data', v_out,
           'meta', case when p_report <> 'JOURNAL' then jsonb_build_object(
               'projects', (select coalesce(jsonb_agg(jsonb_build_object('project_id', id, 'code', code, 'name', name) order by code), '[]'::jsonb) from operational.projects),
               'accounts', (select coalesce(jsonb_agg(jsonb_build_object('code', account_code, 'name', account_name) order by account_code), '[]'::jsonb) from finance.coa where is_postable))
             end);
end;
$$;

-- Rekap pajak: PPh 23 atas bunga pinjaman non-bank ikut di "PPh 23 dipotong BIMA"
create or replace function public.fin_tax_report(p_token text, p_year int, p_month int)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_from date; v_to date;
begin
  perform finance.check_session(p_token, array['fin-tax']);
  if p_year is null or p_month is null or p_month not between 1 and 12 then raise exception 'Pilih masa pajak'; end if;
  v_from := make_date(p_year, p_month, 1);
  v_to   := (v_from + interval '1 month - 1 day')::date;
  return jsonb_build_object(
    'year', p_year, 'month', p_month, 'from', v_from, 'to', v_to,
    'ppn', (select coalesce(jsonb_agg(jsonb_build_object('direction', direction, 'source', source, 'ref_id', ref_id, 'doc_no', doc_no,
               'trx_date', trx_date, 'faktur_no', faktur_no, 'faktur_date', faktur_date, 'counterparty', counterparty, 'npwp', npwp,
               'dpp', dpp, 'ppn', ppn, 'project_code', project_code) order by direction, coalesce(faktur_date, trx_date), doc_no), '[]'::jsonb)
              from finance.tax_ppn_rows(p_year, p_month)),
    'pph21', jsonb_build_object(
               'payroll_exists', exists (select 1 from public."payrollBulananTbl" where "Tahun" = p_year and "Bulan" = p_month),
               'employees', (select count(*) from public."payrollBulananTbl" where "Tahun" = p_year and "Bulan" = p_month),
               'bruto', (select coalesce(sum("PenghasilanBruto"), 0) from public."payrollBulananTbl" where "Tahun" = p_year and "Bulan" = p_month),
               'amount', finance.payroll_owed(p_year, p_month, 'PPH21'),
               'paid', finance.payroll_paid(p_year, p_month, 'PPH21'),
               'pending', finance.payroll_paid(p_year, p_month, 'PPH21', true) - finance.payroll_paid(p_year, p_month, 'PPH21'),
               'journal_status', (select status from finance.journal where source_table = 'payroll_batch'
                                   and source_id = p_year || '-' || lpad(p_month::text, 2, '0') and source_event = 'ACCRUAL'),
               'payments', (select coalesce(jsonb_agg(jsonb_build_object('pay_date', pay_date, 'amount', amount, 'ref_no', ref_no, 'status', status) order by pay_date), '[]'::jsonb)
                              from finance.payroll_payment where period_year = p_year and period_month = p_month and kind = 'PPH21' and status <> 'REJECTED')),
    'pph23_withheld', (select coalesce(jsonb_agg(x order by x.trx_date, x.doc_no), '[]'::jsonb) from (
        select 'VENDOR_INVOICE' as source, vi.invoice_id as ref_id, vi.invoice_no as doc_no, vi.invoice_date as trx_date,
               v."VendorName" as counterparty, v."NPWP" as npwp, vi.subtotal as dpp, vi.pph23_amount as pph
          from finance.vendor_invoice vi left join public.vendor v on v."VendorID" = vi.vendor_id
         where vi.pph23_amount > 0 and vi.status in ('APPROVED','PARTIAL_PAID','PAID') and vi.invoice_date between v_from and v_to
        union all
        select 'CASH_DIRECT', r.request_id, 'DIRECT-' || r.request_id, coalesce(r.paid_at, r.created_at::date), r.payee, null,
               r.amount - r.ppn_amount, r.pph23_amount
          from finance.cash_request r
         where r.kind = 'DIRECT' and r.pph23_amount > 0 and r.status in ('PAID','CLOSED') and coalesce(r.paid_at, r.created_at::date) between v_from and v_to
        union all
        select 'LOAN_INTEREST', t.txn_id, l.loan_no, t.txn_date, l.lender_name, null, t.interest_amount, t.pph23_amount
          from finance.loan_txn t join finance.loan l on l.loan_id = t.loan_id
         where t.kind = 'INSTALLMENT' and t.pph23_amount > 0 and t.status = 'APPROVED' and t.txn_date between v_from and v_to) x),
    'pph_by_client', (select coalesce(jsonb_agg(jsonb_build_object('receipt_id', r.receipt_id, 'receipt_date', r.receipt_date, 'invoice_no', i.invoice_no,
                         'client', i.client_name, 'project_code', p.code, 'pph_mode', i.pph_mode, 'pph_rate', i.pph_rate,
                         'base', i.dpp - i.retention_amount, 'pph', r.pph_amount, 'ref_no', r.ref_no) order by r.receipt_date, r.receipt_id), '[]'::jsonb)
                        from finance.ar_receipt r join finance.ar_invoice i on i.invoice_id = r.invoice_id
                        left join operational.projects p on p.id = i.project_id
                       where r.status = 'APPROVED' and r.pph_amount > 0 and r.receipt_date between v_from and v_to),
    'bank_interest_tax', (select coalesce(jsonb_agg(jsonb_build_object('txn_date', t.txn_date, 'bank', b.account_label, 'amount', t.amount, 'ref_no', t.ref_no) order by t.txn_date), '[]'::jsonb)
                            from finance.bank_txn t join finance.bank_account b on b.bank_id = t.bank_id
                           where t.kind = 'INTEREST_TAX' and t.status = 'APPROVED' and t.txn_date between v_from and v_to),
    'balances', (select jsonb_object_agg(c.account_code, jsonb_build_object('name', c.account_name, 'balance', finance.account_balance(c.account_code, v_to)))
                   from finance.coa c where c.account_code in ('1-1400','2-1500','2-1400','2-1410','1-1450')));
end; $$;

revoke execute on function finance.loan_account(bigint)               from public, anon, authenticated;
revoke execute on function finance.loan_outstanding(bigint, boolean)  from public, anon, authenticated;
revoke execute on function finance.loan_build_schedule(bigint)        from public, anon, authenticated;
revoke execute on function finance.journal_loan_txn(bigint)           from public, anon, authenticated;
revoke execute on function finance.trg_loan_txn_journal()             from public, anon, authenticated;
revoke execute on function public.fin_loans(text) from public;
revoke execute on function public.fin_save_loan(text, bigint, text, text, text, text, uuid, bigint, numeric, boolean, date, numeric, text, int, date, boolean, text, text) from public;
revoke execute on function public.fin_decide_loan(text, bigint, boolean, text) from public;
revoke execute on function public.fin_save_loan_txn(text, bigint, text, date, numeric, numeric, numeric, numeric, bigint, text, int, text, text) from public;
revoke execute on function public.fin_decide_loan_txn(text, bigint, boolean, text) from public;
grant execute on function public.fin_loans(text) to anon, authenticated;
grant execute on function public.fin_save_loan(text, bigint, text, text, text, text, uuid, bigint, numeric, boolean, date, numeric, text, int, date, boolean, text, text) to anon, authenticated;
grant execute on function public.fin_decide_loan(text, bigint, boolean, text) to anon, authenticated;
grant execute on function public.fin_save_loan_txn(text, bigint, text, date, numeric, numeric, numeric, numeric, bigint, text, int, text, text) to anon, authenticated;
grant execute on function public.fin_decide_loan_txn(text, bigint, boolean, text) to anon, authenticated;
