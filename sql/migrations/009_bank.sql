-- =====================================================================
-- SmartFin BIMA — Migration 009: Saldo Awal, Mutasi Bank & Rekonsiliasi
-- Status : ✅ Sudah dijalankan (27 Nov 2026)
--
-- Diinput PIC FIN-AP, disetujui Author PJ. Saat disetujui jurnalnya langsung POSTED.
--   OPENING      Saldo awal (tanggal cut-off diisi manual)  Dr Bank            / Cr 3-9000 Ekuitas Saldo Awal
--   ADMIN_FEE    Biaya administrasi bank                     Dr 6-1400          / Cr Bank
--   INTEREST     Bunga / jasa giro                           Dr Bank            / Cr 4-9100 Pendapatan Bunga
--   INTEREST_TAX Pajak bunga (PPh final dipotong bank)       Dr 6-1410          / Cr Bank
--   TRANSFER     Pindah dana antar rekening sendiri          Dr Bank tujuan     / Cr Bank asal
--   OTHER_IN     Uang masuk lain (pilih akun lawan)          Dr Bank            / Cr akun
--   OTHER_OUT    Uang keluar lain (pilih akun lawan)         Dr akun            / Cr Bank
-- Rekonsiliasi: FIN-AP isi saldo rekening koran per tanggal, sistem hitung selisih
-- dengan saldo jurnal; PJ menyetujui (selisih harus 0 atau diberi penjelasan).
-- =====================================================================

insert into finance.coa (account_code, account_name, account_type, is_postable, notes) values
  ('3-9000', 'Ekuitas Saldo Awal',              'EQUITY',  true, 'Lawan saldo awal saat mulai pakai SmartFin'),
  ('4-9100', 'Pendapatan Bunga Bank / Jasa Giro','REVENUE', true, null),
  ('6-1400', 'Beban Administrasi Bank',          'EXPENSE', true, null),
  ('6-1410', 'Beban Pajak Final Bunga Bank',     'EXPENSE', true, null)
on conflict (account_code) do nothing;

alter table finance.journal drop constraint journal_source_system_check;
alter table finance.journal add constraint journal_source_system_check
  check (source_system in ('SMMS','FUSION4','PETTY_CASH','AP','MANUAL','ASSET','CASH','BANK'));

create table finance.bank_txn (
  txn_id        bigint generated always as identity primary key,
  kind          text not null check (kind in ('OPENING','ADMIN_FEE','INTEREST','INTEREST_TAX','TRANSFER','OTHER_IN','OTHER_OUT')),
  bank_id       bigint not null references finance.bank_account(bank_id),
  to_bank_id    bigint references finance.bank_account(bank_id),
  txn_date      date not null,
  amount        numeric(18,2) not null check (amount > 0),
  account_code  text references finance.coa(account_code),
  project_id    uuid references operational.projects(id),
  description   text not null,
  ref_no        text,
  status        text not null default 'PLANNED' check (status in ('PLANNED','APPROVED','REJECTED')),
  requested_by  text, requested_by_id bigint,
  approved_by   text, approved_at timestamptz, reject_reason text,
  created_at    timestamptz not null default now(),
  check ((kind = 'TRANSFER') = (to_bank_id is not null)),
  check (to_bank_id is distinct from bank_id),
  check (kind not in ('OTHER_IN','OTHER_OUT') or account_code is not null)
);
-- satu saldo awal per rekening
create unique index bank_txn_one_opening on finance.bank_txn (bank_id) where kind = 'OPENING' and status <> 'REJECTED';
create index on finance.bank_txn (bank_id, txn_date);
alter table finance.bank_txn enable row level security;

create table finance.bank_recon (
  recon_id          bigint generated always as identity primary key,
  bank_id           bigint not null references finance.bank_account(bank_id),
  period_end        date not null,
  statement_balance numeric(18,2) not null,
  system_balance    numeric(18,2) not null,
  difference        numeric(18,2) generated always as (statement_balance - system_balance) stored,
  notes             text,
  status            text not null default 'DRAFT' check (status in ('DRAFT','APPROVED')),
  created_by        text, approved_by text, approved_at timestamptz,
  created_at        timestamptz not null default now(),
  unique (bank_id, period_end)
);
alter table finance.bank_recon enable row level security;

-- Saldo rekening menurut jurnal (tidak termasuk VOID) sampai tanggal tertentu
create or replace function finance.bank_balance(p_bank_id bigint, p_as_of date default null)
returns numeric language sql stable security definer set search_path = '' as $$
  select coalesce(sum(l.debit - l.credit), 0)
    from finance.bank_account b
    join finance.journal_line l on l.account_code = b.coa_code
    join finance.journal j on j.journal_id = l.journal_id and j.status <> 'VOID'
   where b.bank_id = p_bank_id and (p_as_of is null or j.journal_date <= p_as_of);
$$;

create or replace function finance.journal_bank_txn(p_txn_id bigint)
returns void language plpgsql security definer set search_path = '' as $$
declare t record; v_dr text; v_cr text; v_lines jsonb := '[]'::jsonb;
begin
  select x.*, b.coa_code as bank_coa, b.account_label, tb.coa_code as to_coa, tb.account_label as to_label
    into t
    from finance.bank_txn x
    join finance.bank_account b on b.bank_id = x.bank_id
    left join finance.bank_account tb on tb.bank_id = x.to_bank_id
   where x.txn_id = p_txn_id;
  if t.txn_id is null then return; end if;
  if t.status = 'APPROVED' then
    select dr, cr into v_dr, v_cr from (values
      ('OPENING',      t.bank_coa, '3-9000'),
      ('ADMIN_FEE',    '6-1400',   t.bank_coa),
      ('INTEREST',     t.bank_coa, '4-9100'),
      ('INTEREST_TAX', '6-1410',   t.bank_coa),
      ('TRANSFER',     t.to_coa,   t.bank_coa),
      ('OTHER_IN',     t.bank_coa, t.account_code),
      ('OTHER_OUT',    t.account_code, t.bank_coa)) m(k, dr, cr) where m.k = t.kind;
    v_lines := jsonb_build_array(
      jsonb_build_object('account', v_dr, 'debit', t.amount, 'project_id', t.project_id, 'memo', coalesce(t.ref_no, t.description)),
      jsonb_build_object('account', v_cr, 'credit', t.amount, 'project_id', t.project_id, 'memo', coalesce(t.ref_no, t.description)));
  end if;
  perform finance.sync_auto_journal('BANK', 'bank_txn', p_txn_id::text, 'APPROVED', t.txn_date, t.project_id,
          t.account_label || ' - ' || t.description || coalesce(' → ' || t.to_label, ''), v_lines);
end; $$;

create or replace function finance.trg_bank_journal()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  begin
    perform finance.journal_bank_txn(new.txn_id);
  exception when others then
    insert into finance.auto_journal_error (source_table, source_id, source_event, error_message)
    values ('bank_txn', new.txn_id::text, tg_op, sqlerrm);
  end;
  return null;
end; $$;
create trigger trg_sfm_bank_txn after insert or update on finance.bank_txn
  for each row execute function finance.trg_bank_journal();

-- ---------------------------------------------------------------------
-- API
-- ---------------------------------------------------------------------
create or replace function public.fin_bank_overview(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform finance.check_session(p_token, array['fin-ap']);
  return jsonb_build_object(
    'banks', (select coalesce(jsonb_agg(jsonb_build_object(
                 'bank_id', b.bank_id, 'label', b.account_label, 'bank_name', b.bank_name, 'last4', b.account_last4,
                 'coa_code', b.coa_code, 'is_active', b.is_active, 'balance', finance.bank_balance(b.bank_id),
                 'opening', (select jsonb_build_object('txn_id', o.txn_id, 'date', o.txn_date, 'amount', o.amount, 'status', o.status)
                               from finance.bank_txn o where o.bank_id = b.bank_id and o.kind = 'OPENING' and o.status <> 'REJECTED'),
                 'last_recon', (select jsonb_build_object('period_end', r.period_end, 'difference', r.difference, 'status', r.status)
                                  from finance.bank_recon r where r.bank_id = b.bank_id order by r.period_end desc limit 1))
               order by b.is_active desc, b.bank_name), '[]'::jsonb) from finance.bank_account b),
    'txns', (select coalesce(jsonb_agg(x order by x.sort_key, x.txn_date desc, x.txn_id desc), '[]'::jsonb) from (
       select t.txn_id, t.kind, t.bank_id, b.account_label as bank_label, t.to_bank_id, tb.account_label as to_bank_label,
              t.txn_date, t.amount, t.account_code, c.account_name, p.code as project_code, t.description, t.ref_no, t.status,
              t.requested_by, t.approved_by, t.approved_at, t.reject_reason,
              case t.status when 'PLANNED' then 1 else 2 end as sort_key
         from finance.bank_txn t
         join finance.bank_account b on b.bank_id = t.bank_id
         left join finance.bank_account tb on tb.bank_id = t.to_bank_id
         left join finance.coa c on c.account_code = t.account_code
         left join operational.projects p on p.id = t.project_id
        where t.status = 'PLANNED' or t.created_at > now() - interval '365 days') x),
    'recons', (select coalesce(jsonb_agg(jsonb_build_object('recon_id', r.recon_id, 'bank_id', r.bank_id, 'bank_label', b.account_label,
                   'period_end', r.period_end, 'statement_balance', r.statement_balance, 'system_balance', r.system_balance,
                   'system_now', finance.bank_balance(r.bank_id, r.period_end), 'difference', r.difference, 'notes', r.notes,
                   'status', r.status, 'created_by', r.created_by, 'approved_by', r.approved_by)
                 order by r.period_end desc, b.account_label), '[]'::jsonb)
                 from finance.bank_recon r join finance.bank_account b on b.bank_id = r.bank_id),
    'accounts', (select coalesce(jsonb_agg(jsonb_build_object('code', account_code, 'name', account_name) order by account_code), '[]'::jsonb)
                   from finance.coa where is_postable and is_active and account_code !~ '^1-1[12][0-9]{2}$'),
    'projects', (select coalesce(jsonb_agg(jsonb_build_object('project_id', id, 'code', code, 'name', name) order by code), '[]'::jsonb)
                   from operational.projects));
end; $$;

create or replace function public.fin_save_bank_txn(
  p_token text, p_kind text, p_bank_id bigint, p_to_bank_id bigint, p_txn_date date, p_amount numeric,
  p_account_code text, p_project_id uuid, p_description text, p_ref_no text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare who bigint; v_id bigint; v_open date;
begin
  who := finance.check_session(p_token, array['fin-ap']);
  if p_kind not in ('OPENING','ADMIN_FEE','INTEREST','INTEREST_TAX','TRANSFER','OTHER_IN','OTHER_OUT') then raise exception 'Jenis mutasi tidak dikenal'; end if;
  if not exists (select 1 from finance.bank_account where bank_id = p_bank_id and is_active) then raise exception 'Pilih rekening bank yang aktif'; end if;
  if coalesce(p_amount,0) <= 0 then raise exception 'Nilai harus lebih dari 0'; end if;
  if p_txn_date is null or p_txn_date > current_date then raise exception 'Tanggal tidak valid'; end if;
  if p_kind = 'OPENING' and exists (select 1 from finance.bank_txn where bank_id = p_bank_id and kind = 'OPENING' and status <> 'REJECTED') then
    raise exception 'Rekening ini sudah punya saldo awal. Tolak dulu yang lama kalau mau diganti.';
  end if;
  if p_kind <> 'OPENING' then
    select txn_date into v_open from finance.bank_txn where bank_id = p_bank_id and kind = 'OPENING' and status <> 'REJECTED';
    if v_open is not null and p_txn_date < v_open then raise exception 'Tanggal mutasi sebelum tanggal saldo awal (%)', v_open; end if;
  end if;
  if p_kind = 'TRANSFER' then
    if p_to_bank_id is null or p_to_bank_id = p_bank_id or not exists (select 1 from finance.bank_account where bank_id = p_to_bank_id and is_active) then
      raise exception 'Pilih rekening tujuan yang aktif dan berbeda';
    end if;
  end if;
  if p_kind in ('OTHER_IN','OTHER_OUT') and not exists (
       select 1 from finance.coa where account_code = p_account_code and is_postable and is_active and account_code !~ '^1-1[12][0-9]{2}$') then
    raise exception 'Pilih akun lawan yang valid (bukan akun kas/bank)';
  end if;
  if coalesce(btrim(p_description),'') = '' then raise exception 'Keterangan wajib diisi'; end if;
  insert into finance.bank_txn (kind, bank_id, to_bank_id, txn_date, amount, account_code, project_id, description, ref_no, requested_by, requested_by_id)
  values (p_kind, p_bank_id, case when p_kind = 'TRANSFER' then p_to_bank_id end, p_txn_date, p_amount,
          case when p_kind in ('OTHER_IN','OTHER_OUT') then p_account_code end, p_project_id, btrim(p_description),
          nullif(btrim(p_ref_no),''), finance.employee_name(who), who)
  returning txn_id into v_id;
  return jsonb_build_object('txn_id', v_id, 'status', 'PLANNED');
end; $$;

create or replace function public.fin_decide_bank_txn(p_token text, p_txn_id bigint, p_approve boolean, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare who bigint; t finance.bank_txn%rowtype; v_j bigint;
begin
  who := finance.check_session(p_token, array['fin-ap','fin-jv'], 'PJ');
  select * into t from finance.bank_txn where txn_id = p_txn_id for update;
  if t.txn_id is null then raise exception 'Mutasi % tidak ditemukan', p_txn_id; end if;
  if t.status <> 'PLANNED' then
    if t.status = 'APPROVED' and not coalesce(p_approve, true) then
      raise exception 'Mutasi yang sudah disetujui tidak bisa ditolak. Buat mutasi koreksi kalau ada kesalahan.';
    end if;
    raise exception 'Mutasi ini sudah diproses (status %)', t.status;
  end if;
  if coalesce(p_approve, false) then
    update finance.bank_txn set status = 'APPROVED', approved_by = finance.employee_name(who), approved_at = now() where txn_id = t.txn_id;
    select journal_id into v_j from finance.journal where source_table = 'bank_txn' and source_id = t.txn_id::text and source_event = 'APPROVED';
    if v_j is null then raise exception 'Jurnal mutasi gagal dibuat, cek log error jurnal'; end if;
    perform finance.post_journal(v_j, finance.employee_name(who));
  else
    if coalesce(btrim(p_reason),'') = '' then raise exception 'Alasan penolakan wajib diisi'; end if;
    update finance.bank_txn set status = 'REJECTED', reject_reason = btrim(p_reason),
           approved_by = finance.employee_name(who), approved_at = now() where txn_id = t.txn_id;
  end if;
  return jsonb_build_object('txn_id', t.txn_id, 'status', case when p_approve then 'APPROVED' else 'REJECTED' end);
end; $$;

create or replace function public.fin_save_recon(p_token text, p_bank_id bigint, p_period_end date, p_statement_balance numeric, p_notes text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare who bigint; v_sys numeric; v_id bigint;
begin
  who := finance.check_session(p_token, array['fin-ap']);
  if not exists (select 1 from finance.bank_account where bank_id = p_bank_id) then raise exception 'Rekening tidak ditemukan'; end if;
  if p_period_end is null or p_period_end > current_date then raise exception 'Tanggal rekonsiliasi tidak valid'; end if;
  if p_statement_balance is null then raise exception 'Saldo rekening koran wajib diisi'; end if;
  if exists (select 1 from finance.bank_recon where bank_id = p_bank_id and period_end = p_period_end and status = 'APPROVED') then
    raise exception 'Rekonsiliasi rekening ini per % sudah disetujui', p_period_end;
  end if;
  v_sys := finance.bank_balance(p_bank_id, p_period_end);
  insert into finance.bank_recon (bank_id, period_end, statement_balance, system_balance, notes, created_by)
  values (p_bank_id, p_period_end, p_statement_balance, v_sys, nullif(btrim(p_notes),''), finance.employee_name(who))
  on conflict (bank_id, period_end) do update
     set statement_balance = excluded.statement_balance, system_balance = excluded.system_balance,
         notes = excluded.notes, created_by = excluded.created_by, created_at = now()
  returning recon_id into v_id;
  return (select jsonb_build_object('recon_id', recon_id, 'system_balance', system_balance, 'difference', difference)
            from finance.bank_recon where recon_id = v_id);
end; $$;

create or replace function public.fin_approve_recon(p_token text, p_recon_id bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare who bigint; r finance.bank_recon%rowtype; v_sys numeric;
begin
  who := finance.check_session(p_token, array['fin-ap','fin-jv'], 'PJ');
  select * into r from finance.bank_recon where recon_id = p_recon_id for update;
  if r.recon_id is null then raise exception 'Rekonsiliasi tidak ditemukan'; end if;
  if r.status = 'APPROVED' then raise exception 'Rekonsiliasi ini sudah disetujui'; end if;
  -- hitung ulang saldo sistem, siapa tahu ada mutasi baru setelah disimpan
  v_sys := finance.bank_balance(r.bank_id, r.period_end);
  update finance.bank_recon set system_balance = v_sys where recon_id = r.recon_id;
  if r.statement_balance <> v_sys and r.notes is null then
    raise exception 'Masih ada selisih Rp %. Lengkapi dulu mutasinya, atau isi penjelasan selisih di rekonsiliasi.', r.statement_balance - v_sys;
  end if;
  update finance.bank_recon set status = 'APPROVED', approved_by = finance.employee_name(who), approved_at = now() where recon_id = r.recon_id;
  return jsonb_build_object('recon_id', r.recon_id, 'status', 'APPROVED', 'difference', r.statement_balance - v_sys);
end; $$;

revoke execute on function finance.bank_balance(bigint, date)  from public, anon, authenticated;
revoke execute on function finance.journal_bank_txn(bigint)    from public, anon, authenticated;
revoke execute on function finance.trg_bank_journal()          from public, anon, authenticated;
revoke execute on function public.fin_bank_overview(text) from public;
revoke execute on function public.fin_save_bank_txn(text, text, bigint, bigint, date, numeric, text, uuid, text, text) from public;
revoke execute on function public.fin_decide_bank_txn(text, bigint, boolean, text) from public;
revoke execute on function public.fin_save_recon(text, bigint, date, numeric, text) from public;
revoke execute on function public.fin_approve_recon(text, bigint) from public;
grant execute on function public.fin_bank_overview(text) to anon, authenticated;
grant execute on function public.fin_save_bank_txn(text, text, bigint, bigint, date, numeric, text, uuid, text, text) to anon, authenticated;
grant execute on function public.fin_decide_bank_txn(text, bigint, boolean, text) to anon, authenticated;
grant execute on function public.fin_save_recon(text, bigint, date, numeric, text) to anon, authenticated;
grant execute on function public.fin_approve_recon(text, bigint) to anon, authenticated;
