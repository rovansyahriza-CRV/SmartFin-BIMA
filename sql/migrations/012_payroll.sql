-- =====================================================================
-- SmartFin BIMA — Migration 012: Jurnal Payroll dari Fusion4 + pembayaran gaji / BPJS / PPh 21
-- Status : ✅ Sudah dijalankan (27 Nov 2026)
--
-- Sumber: public."payrollBulananTbl" (hasil Proses Payroll Bulanan Fusion4), dibaca apa adanya.
-- PIC FIN-PR membuka menu Payroll, memilih bulan, mengatur alokasi proyek, lalu membuat jurnal
-- (DRAFT) yang diposting PJ di menu Jurnal. Kalau payroll diproses ulang di Fusion4 atau alokasi
-- diubah, tekan "Perbarui jurnal": DRAFT diganti, POSTED dibuatkan jurnal penyesuaian.
--
-- Alokasi: default 100% ke proyek INTERNAL yang divisinya sama dengan Divisi karyawan
-- (901 Direksi, 902 Business Development, 903 HR, 904 Supply Chains, 905 Operation).
-- FIN-PR bisa membagi karyawan ke beberapa proyek (%) per bulan, mis. 60% 014 + 40% 015.
--
-- Jurnal akrual (tanggal = akhir bulan, satu jurnal per bulan, baris diringkas per akun & proyek,
-- tanpa nama karyawan):
--   Proyek CLIENT   : Dr 5-1300 Beban Tenaga Kerja Proyek (bruto + BPJS perusahaan)
--   Proyek INTERNAL : Dr 6-1000 Beban Gaji Overhead (bruto) + Dr 6-1100 Beban BPJS Perusahaan
--   Uang kompensasi PKWT (kalau ada): Dr 6-1200
--   Cr 2-1300 Hutang BPJS (BPJS karyawan + perusahaan) | Cr 2-1400 Hutang PPh 21 | Cr 2-1200 Hutang Gaji (sisanya)
-- Pembayaran (FIN-PR input, Author APY approve, jurnal langsung POSTED):
--   THP   Dr 2-1200 / Cr Bank      BPJS  Dr 2-1300 / Cr Bank      PPH21 Dr 2-1400 / Cr Bank
-- =====================================================================

create or replace function finance.tokens(p_text text)
returns text[] language sql immutable set search_path = '' as $$
  with parsed as (
    select coalesce(array_agg(lower(btrim(x))) filter (where btrim(x) <> ''), array[]::text[]) as v
      from regexp_split_to_table(coalesce(p_text,''), '[,;\n\r]+') x
  )
  select case
           when 'all' = any(v)     then v || array['fin','fin-ap','fin-ar','fin-pr','fin-jv','fin-bva','fin-ast','fin-pc','fin-rpt','ai','pj','ab','apy','apc']
           when 'fin-all' = any(v) then v || array['fin','fin-ap','fin-ar','fin-pr','fin-jv','fin-bva','fin-ast','fin-pc','fin-rpt']
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
  if not (v_pics && array['fin','fin-ap','fin-ar','fin-pr','fin-jv','fin-bva','fin-ast','fin-pc','fin-rpt']) then
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
create table finance.payroll_batch (
  period_year   int not null,
  period_month  int not null check (period_month between 1 and 12),
  journaled_by  text,
  journaled_at  timestamptz,
  primary key (period_year, period_month)
);
alter table finance.payroll_batch enable row level security;

create table finance.payroll_alloc (
  period_year   int not null,
  period_month  int not null check (period_month between 1 and 12),
  karyawan_id   bigint not null,
  project_id    uuid not null references operational.projects(id),
  pct           numeric(5,2) not null check (pct > 0 and pct <= 100),
  updated_by    text,
  updated_at    timestamptz not null default now(),
  primary key (period_year, period_month, karyawan_id, project_id)
);
alter table finance.payroll_alloc enable row level security;

create table finance.payroll_payment (
  payment_id    bigint generated always as identity primary key,
  period_year   int not null,
  period_month  int not null check (period_month between 1 and 12),
  kind          text not null check (kind in ('THP','BPJS','PPH21')),
  bank_id       bigint not null references finance.bank_account(bank_id),
  pay_date      date not null,
  amount        numeric(18,2) not null check (amount > 0),
  ref_no        text,
  status        text not null default 'PLANNED' check (status in ('PLANNED','APPROVED','REJECTED')),
  requested_by  text, requested_by_id bigint,
  approved_by   text, approved_at timestamptz, reject_reason text,
  created_at    timestamptz not null default now()
);
create index on finance.payroll_payment (period_year, period_month);
alter table finance.payroll_payment enable row level security;

-- Helper ----------------------------------------------------------------
-- Proyek default karyawan: proyek INTERNAL dengan divisi yang sama
create or replace function finance.payroll_default_project(p_divisi text)
returns uuid language sql stable security definer set search_path = '' as $$
  select id from operational.projects
   where project_type = 'INTERNAL' and lower(btrim(divisi)) = lower(btrim(p_divisi))
   order by code limit 1;
$$;

-- Porsi biaya tiap karyawan per proyek untuk satu periode
create or replace function finance.payroll_split(p_year int, p_month int)
returns table (karyawan_id bigint, project_id uuid, pct numeric, bruto numeric, bpjs_co numeric, komp numeric)
language sql stable security definer set search_path = '' as $$
  with r as (
    select "KaryawanId" as kid, "Divisi" as divisi, coalesce("PenghasilanBruto",0) as bruto,
           coalesce("TotalBpjsPerusahaan",0) as bpjs_co, coalesce("UangKompensasiPkwt",0) as komp
      from public."payrollBulananTbl" where "Tahun" = p_year and "Bulan" = p_month
  ), al as (
    select a.karyawan_id, a.project_id, a.pct from finance.payroll_alloc a
     where a.period_year = p_year and a.period_month = p_month
  )
  select r.kid, al.project_id, al.pct, r.bruto, r.bpjs_co, r.komp
    from r join al on al.karyawan_id = r.kid
  union all
  select r.kid, finance.payroll_default_project(r.divisi), 100, r.bruto, r.bpjs_co, r.komp
    from r where not exists (select 1 from al where al.karyawan_id = r.kid);
$$;

-- Baris jurnal akrual payroll (ringkas per akun & proyek)
create or replace function finance.payroll_lines(p_year int, p_month int)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_deb jsonb; v_debsum numeric; v_bpjs numeric; v_pph numeric; v_label text;
begin
  select round(coalesce(sum(coalesce("TotalBpjsKaryawan",0) + coalesce("TotalBpjsPerusahaan",0)), 0), 2), round(coalesce(sum(coalesce("Pph21",0)), 0), 2)
    into v_bpjs, v_pph
    from public."payrollBulananTbl" where "Tahun" = p_year and "Bulan" = p_month;
  v_label := 'Payroll ' || to_char(make_date(p_year, p_month, 1), 'MM/YYYY');
  with s as (
    select s.*, coalesce(p.project_type, 'INTERNAL') as ptype
      from finance.payroll_split(p_year, p_month) s left join operational.projects p on p.id = s.project_id
  ), d as (
    select '5-1300' as acc, project_id, sum((bruto + bpjs_co) * pct / 100) as amt from s where ptype = 'CLIENT' group by project_id
    union all select '6-1000', project_id, sum(bruto * pct / 100) from s where ptype <> 'CLIENT' group by project_id
    union all select '6-1100', project_id, sum(bpjs_co * pct / 100) from s where ptype <> 'CLIENT' group by project_id
    union all select '6-1200', project_id, sum(komp * pct / 100) from s group by project_id
  ), dr as (
    select acc, project_id, round(amt, 2) as amt from d where round(amt, 2) > 0
  )
  select coalesce(jsonb_agg(jsonb_build_object('account', acc, 'debit', amt, 'project_id', project_id, 'memo', v_label) order by acc, project_id), '[]'::jsonb),
         coalesce(sum(amt), 0)
    into v_deb, v_debsum from dr;
  if v_debsum = 0 then return '[]'::jsonb; end if;
  return v_deb || jsonb_build_array(
    jsonb_build_object('account', '2-1300', 'credit', v_bpjs, 'memo', v_label || ' BPJS karyawan + perusahaan'),
    jsonb_build_object('account', '2-1400', 'credit', v_pph,  'memo', v_label || ' PPh 21'),
    jsonb_build_object('account', '2-1200', 'credit', v_debsum - v_bpjs - v_pph, 'memo', v_label || ' gaji bersih (THP)'));
end; $$;

-- Hutang payroll per jenis untuk satu periode (dari jurnal akrual yang dihitung saat ini)
create or replace function finance.payroll_owed(p_year int, p_month int, p_kind text)
returns numeric language sql stable security definer set search_path = '' as $$
  select coalesce(sum((l->>'credit')::numeric), 0)
    from jsonb_array_elements(finance.payroll_lines(p_year, p_month)) l
   where l->>'account' = case p_kind when 'THP' then '2-1200' when 'BPJS' then '2-1300' else '2-1400' end;
$$;

create or replace function finance.payroll_paid(p_year int, p_month int, p_kind text, p_include_planned boolean default false)
returns numeric language sql stable security definer set search_path = '' as $$
  select coalesce(sum(amount), 0) from finance.payroll_payment
   where period_year = p_year and period_month = p_month and kind = p_kind
     and (status = 'APPROVED' or (p_include_planned and status = 'PLANNED'));
$$;

create or replace function finance.journal_payroll_payment(p_payment_id bigint)
returns void language plpgsql security definer set search_path = '' as $$
declare r record; v_lines jsonb := '[]'::jsonb; v_acc text; v_label text;
begin
  select x.*, b.coa_code as bank_coa, b.account_label into r
    from finance.payroll_payment x join finance.bank_account b on b.bank_id = x.bank_id
   where x.payment_id = p_payment_id;
  if r.payment_id is null then return; end if;
  v_acc := case r.kind when 'THP' then '2-1200' when 'BPJS' then '2-1300' else '2-1400' end;
  v_label := case r.kind when 'THP' then 'Pembayaran gaji (THP)' when 'BPJS' then 'Setoran BPJS' else 'Setoran PPh 21' end
             || ' ' || to_char(make_date(r.period_year, r.period_month, 1), 'MM/YYYY');
  if r.status = 'APPROVED' then
    v_lines := jsonb_build_array(
      jsonb_build_object('account', v_acc, 'debit', r.amount, 'memo', coalesce(r.ref_no, v_label)),
      jsonb_build_object('account', r.bank_coa, 'credit', r.amount, 'memo', coalesce(r.ref_no, v_label)));
  end if;
  perform finance.sync_auto_journal('BANK', 'payroll_payment', p_payment_id::text, 'APPROVED', r.pay_date, null,
          v_label || ' dari ' || r.account_label, v_lines);
end; $$;

create or replace function finance.trg_payroll_payment_journal()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  begin
    perform finance.journal_payroll_payment(new.payment_id);
  exception when others then
    insert into finance.auto_journal_error (source_table, source_id, source_event, error_message)
    values ('payroll_payment', new.payment_id::text, tg_op, sqlerrm);
  end;
  return null;
end; $$;
create trigger trg_sfm_payroll_payment after insert or update on finance.payroll_payment
  for each row execute function finance.trg_payroll_payment_journal();

-- API -------------------------------------------------------------------
create or replace function public.fin_payroll_overview(p_token text, p_year int, p_month int)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare who bigint; v_detail boolean; v_y int := p_year; v_m int := p_month; v_key text; v_j record;
begin
  who := finance.check_session(p_token, array['fin-pr','fin-ap']);
  v_detail := finance.emp_has(who, 'fin-pr', null);
  if v_y is null or v_m is null then
    select "Tahun", "Bulan" into v_y, v_m from public."payrollBulananTbl" order by "Tahun" desc, "Bulan" desc limit 1;
  end if;
  v_key := v_y || '-' || lpad(v_m::text, 2, '0');
  select journal_id, status, journal_no into v_j from finance.journal
   where source_table = 'payroll_batch' and source_id = v_key and source_event = 'ACCRUAL';
  return jsonb_build_object(
    'year', v_y, 'month', v_m, 'detail', v_detail,
    'periods', (select coalesce(jsonb_agg(jsonb_build_object('year', x."Tahun", 'month', x."Bulan", 'employees', x.n, 'bruto', x.bruto,
                   'journal_status', (select status from finance.journal where source_table = 'payroll_batch'
                                        and source_id = x."Tahun" || '-' || lpad(x."Bulan"::text, 2, '0') and source_event = 'ACCRUAL'))
                   order by x."Tahun" desc, x."Bulan" desc), '[]'::jsonb)
                  from (select "Tahun", "Bulan", count(*) n, sum("PenghasilanBruto") bruto from public."payrollBulananTbl" group by 1, 2) x),
    'totals', (select jsonb_build_object('employees', count(*), 'bruto', coalesce(sum("PenghasilanBruto"),0),
                  'bpjs_karyawan', coalesce(sum("TotalBpjsKaryawan"),0), 'bpjs_perusahaan', coalesce(sum("TotalBpjsPerusahaan"),0),
                  'pph21', coalesce(sum("Pph21"),0), 'thp', coalesce(sum("TakeHomePay"),0), 'kompensasi', coalesce(sum("UangKompensasiPkwt"),0),
                  'other_deduction', coalesce(sum("TotalPotongan" - coalesce("TotalBpjsKaryawan",0) - coalesce("Pph21",0)),0),
                  'processed_at', max("ProcessedAt"))
                 from public."payrollBulananTbl" where "Tahun" = v_y and "Bulan" = v_m),
    'byProject', (select coalesce(jsonb_agg(jsonb_build_object('project_id', s.project_id, 'code', p.code, 'name', p.name, 'type', p.project_type,
                     'cost', s.cost, 'employees', s.n) order by p.code), '[]'::jsonb)
                   from (select project_id, sum((bruto + bpjs_co + komp) * pct / 100) cost, count(distinct karyawan_id) n
                           from finance.payroll_split(v_y, v_m) group by project_id) s
                   left join operational.projects p on p.id = s.project_id),
    'employees', case when v_detail then (select coalesce(jsonb_agg(jsonb_build_object(
                     'karyawan_id', r."KaryawanId", 'nama', r."NamaKaryawan", 'divisi', r."Divisi", 'departemen', r."Departemen",
                     'kontrak', r."JenisKontrak", 'bruto', r."PenghasilanBruto", 'bpjs_perusahaan', r."TotalBpjsPerusahaan",
                     'komp', r."UangKompensasiPkwt", 'thp', r."TakeHomePay",
                     'default_project', (select code from operational.projects where id = finance.payroll_default_project(r."Divisi")),
                     'alloc', (select coalesce(jsonb_agg(jsonb_build_object('project_id', a.project_id, 'code', p.code, 'pct', a.pct) order by p.code), '[]'::jsonb)
                                 from finance.payroll_alloc a join operational.projects p on p.id = a.project_id
                                where a.period_year = v_y and a.period_month = v_m and a.karyawan_id = r."KaryawanId"))
                   order by r."Divisi", r."NamaKaryawan"), '[]'::jsonb)
                   from public."payrollBulananTbl" r where r."Tahun" = v_y and r."Bulan" = v_m) else '[]'::jsonb end,
    'lines', (select coalesce(jsonb_agg(jsonb_build_object('account', l->>'account', 'account_name', c.account_name,
                  'project_code', p.code, 'debit', coalesce((l->>'debit')::numeric, 0), 'credit', coalesce((l->>'credit')::numeric, 0))), '[]'::jsonb)
                from jsonb_array_elements(finance.payroll_lines(v_y, v_m)) l
                left join finance.coa c on c.account_code = l->>'account'
                left join operational.projects p on p.id = nullif(l->>'project_id','')::uuid),
    'journal', case when v_j.journal_id is null then null else jsonb_build_object('journal_id', v_j.journal_id, 'status', v_j.status, 'journal_no', v_j.journal_no,
                  'adjust_draft', exists (select 1 from finance.journal where source_table = 'payroll_batch' and source_id = v_key
                                            and source_event like 'ACCRUAL-ADJ-%' and status = 'DRAFT'),
                  'journaled_by', (select journaled_by from finance.payroll_batch where period_year = v_y and period_month = v_m),
                  'journaled_at', (select journaled_at from finance.payroll_batch where period_year = v_y and period_month = v_m)) end,
    'owed', (select jsonb_object_agg(k, jsonb_build_object('owed', finance.payroll_owed(v_y, v_m, k),
                  'paid', finance.payroll_paid(v_y, v_m, k), 'pending', finance.payroll_paid(v_y, v_m, k, true) - finance.payroll_paid(v_y, v_m, k)))
               from unnest(array['THP','BPJS','PPH21']) k),
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('payment_id', x.payment_id, 'kind', x.kind, 'bank_label', b.account_label,
                    'pay_date', x.pay_date, 'amount', x.amount, 'ref_no', x.ref_no, 'status', x.status, 'requested_by', x.requested_by,
                    'approved_by', x.approved_by, 'reject_reason', x.reject_reason) order by x.pay_date, x.payment_id), '[]'::jsonb)
                   from finance.payroll_payment x join finance.bank_account b on b.bank_id = x.bank_id
                  where x.period_year = v_y and x.period_month = v_m),
    'projects', (select coalesce(jsonb_agg(jsonb_build_object('project_id', id, 'code', code, 'name', name, 'type', project_type) order by code), '[]'::jsonb)
                   from operational.projects),
    'banks', (select coalesce(jsonb_agg(jsonb_build_object('bank_id', bank_id, 'label', account_label) order by bank_name), '[]'::jsonb)
                from finance.bank_account where is_active));
end; $$;

-- Alokasi karyawan ke proyek; p_allocs kosong = kembali ke default divisi
create or replace function public.fin_save_payroll_alloc(p_token text, p_year int, p_month int, p_karyawan_id bigint, p_allocs jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare who bigint; v_sum numeric; v_n int;
begin
  who := finance.check_session(p_token, array['fin-pr']);
  if not exists (select 1 from public."payrollBulananTbl" where "Tahun" = p_year and "Bulan" = p_month and "KaryawanId" = p_karyawan_id) then
    raise exception 'Karyawan tidak ada di payroll periode ini';
  end if;
  if jsonb_typeof(coalesce(p_allocs, '[]'::jsonb)) <> 'array' then raise exception 'Format alokasi tidak valid'; end if;
  select count(*), coalesce(sum((a->>'pct')::numeric), 0) into v_n, v_sum from jsonb_array_elements(coalesce(p_allocs, '[]'::jsonb)) a;
  if v_n > 0 then
    if exists (select 1 from jsonb_array_elements(p_allocs) a
                where coalesce((a->>'pct')::numeric, 0) <= 0
                   or not exists (select 1 from operational.projects p where p.id = nullif(a->>'project_id','')::uuid)) then
      raise exception 'Setiap baris alokasi harus punya proyek dan persen > 0';
    end if;
    if (select count(distinct a->>'project_id') from jsonb_array_elements(p_allocs) a) <> v_n then raise exception 'Proyek dobel di alokasi'; end if;
    if round(v_sum, 2) <> 100 then raise exception 'Total alokasi harus 100%% (sekarang % persen)', round(v_sum, 2); end if;
  end if;
  delete from finance.payroll_alloc where period_year = p_year and period_month = p_month and karyawan_id = p_karyawan_id;
  insert into finance.payroll_alloc (period_year, period_month, karyawan_id, project_id, pct, updated_by)
  select p_year, p_month, p_karyawan_id, (a->>'project_id')::uuid, (a->>'pct')::numeric, finance.employee_name(who)
    from jsonb_array_elements(coalesce(p_allocs, '[]'::jsonb)) a;
  return jsonb_build_object('karyawan_id', p_karyawan_id, 'rows', v_n);
end; $$;

-- Buat / perbarui jurnal akrual payroll satu bulan (DRAFT; kalau sudah POSTED → jurnal penyesuaian)
create or replace function public.fin_payroll_journal(p_token text, p_year int, p_month int)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare who bigint; v_lines jsonb; v_key text; v_n int; v_other numeric; v_j record;
begin
  who := finance.check_session(p_token, array['fin-pr']);
  select count(*), coalesce(sum("TotalPotongan" - coalesce("TotalBpjsKaryawan",0) - coalesce("Pph21",0)), 0)
    into v_n, v_other from public."payrollBulananTbl" where "Tahun" = p_year and "Bulan" = p_month;
  if v_n = 0 then raise exception 'Belum ada payroll Fusion4 untuk periode ini'; end if;
  if abs(v_other) > 1 then
    raise exception 'Ada potongan gaji di luar BPJS & PPh 21 (Rp %). Jurnalnya belum didukung, hubungi admin SmartFin.', v_other;
  end if;
  if exists (select 1 from finance.payroll_split(p_year, p_month) where project_id is null) then
    raise exception 'Ada karyawan yang divisinya tidak punya proyek internal. Atur alokasinya dulu.';
  end if;
  v_key := p_year || '-' || lpad(p_month::text, 2, '0');
  perform pg_advisory_xact_lock(hashtextextended('smartfin-payroll:' || v_key, 0));
  v_lines := finance.payroll_lines(p_year, p_month);
  perform finance.sync_auto_journal('FUSION4', 'payroll_batch', v_key, 'ACCRUAL',
          (make_date(p_year, p_month, 1) + interval '1 month - 1 day')::date, null,
          'Payroll ' || to_char(make_date(p_year, p_month, 1), 'MM/YYYY') || ' (' || v_n || ' karyawan) dari Fusion4', v_lines);
  insert into finance.payroll_batch (period_year, period_month, journaled_by, journaled_at)
  values (p_year, p_month, finance.employee_name(who), now())
  on conflict (period_year, period_month) do update set journaled_by = excluded.journaled_by, journaled_at = excluded.journaled_at;
  select journal_id, status into v_j from finance.journal where source_table = 'payroll_batch' and source_id = v_key and source_event = 'ACCRUAL';
  return jsonb_build_object('journal_id', v_j.journal_id, 'status', v_j.status,
    'adjust_draft', exists (select 1 from finance.journal where source_table = 'payroll_batch' and source_id = v_key
                              and source_event like 'ACCRUAL-ADJ-%' and status = 'DRAFT'));
end; $$;

create or replace function public.fin_save_payroll_payment(
  p_token text, p_year int, p_month int, p_kind text, p_bank_id bigint, p_pay_date date, p_amount numeric, p_ref_no text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare who bigint; v_key text; v_left numeric; v_id bigint;
begin
  who := finance.check_session(p_token, array['fin-pr']);
  if p_kind not in ('THP','BPJS','PPH21') then raise exception 'Jenis pembayaran tidak dikenal'; end if;
  v_key := p_year || '-' || lpad(p_month::text, 2, '0');
  if not exists (select 1 from finance.journal where source_table = 'payroll_batch' and source_id = v_key and source_event = 'ACCRUAL' and status = 'POSTED') then
    raise exception 'Jurnal payroll periode ini belum diposting PJ. Buat jurnal dan minta PJ posting dulu.';
  end if;
  if not exists (select 1 from finance.bank_account where bank_id = p_bank_id and is_active) then raise exception 'Pilih rekening bank yang aktif'; end if;
  if p_pay_date is null or p_pay_date > current_date then raise exception 'Tanggal bayar tidak valid'; end if;
  if coalesce(p_amount, 0) <= 0 then raise exception 'Nilai harus lebih dari 0'; end if;
  perform pg_advisory_xact_lock(hashtextextended('smartfin-payroll-pay:' || v_key || p_kind, 0));
  v_left := finance.payroll_owed(p_year, p_month, p_kind) - finance.payroll_paid(p_year, p_month, p_kind, true);
  if p_amount > v_left then raise exception 'Melebihi sisa hutang (Rp %, termasuk yang menunggu approval)', v_left; end if;
  insert into finance.payroll_payment (period_year, period_month, kind, bank_id, pay_date, amount, ref_no, requested_by, requested_by_id)
  values (p_year, p_month, p_kind, p_bank_id, p_pay_date, p_amount, nullif(btrim(p_ref_no),''), finance.employee_name(who), who)
  returning payment_id into v_id;
  return jsonb_build_object('payment_id', v_id, 'status', 'PLANNED');
end; $$;

create or replace function public.fin_decide_payroll_payment(p_token text, p_payment_id bigint, p_approve boolean, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare who bigint; x finance.payroll_payment%rowtype; v_j bigint;
begin
  who := finance.check_session(p_token, array['fin-pr','fin-ap'], 'APY');
  select * into x from finance.payroll_payment where payment_id = p_payment_id for update;
  if x.payment_id is null then raise exception 'Pembayaran tidak ditemukan'; end if;
  if x.status <> 'PLANNED' then raise exception 'Pembayaran ini sudah diproses (status %)', x.status; end if;
  if coalesce(p_approve, false) then
    update finance.payroll_payment set status = 'APPROVED', approved_by = finance.employee_name(who), approved_at = now() where payment_id = x.payment_id;
    select journal_id into v_j from finance.journal where source_table = 'payroll_payment' and source_id = x.payment_id::text and source_event = 'APPROVED';
    if v_j is null then raise exception 'Jurnal pembayaran gagal dibuat, cek log error jurnal'; end if;
    perform finance.post_journal(v_j, finance.employee_name(who));
  else
    if coalesce(btrim(p_reason),'') = '' then raise exception 'Alasan penolakan wajib diisi'; end if;
    update finance.payroll_payment set status = 'REJECTED', reject_reason = btrim(p_reason),
           approved_by = finance.employee_name(who), approved_at = now() where payment_id = x.payment_id;
  end if;
  return jsonb_build_object('payment_id', x.payment_id, 'status', case when p_approve then 'APPROVED' else 'REJECTED' end);
end; $$;

-- Hak eksekusi ------------------------------------------------------------
revoke execute on function finance.payroll_default_project(text)            from public, anon, authenticated;
revoke execute on function finance.payroll_split(int, int)                  from public, anon, authenticated;
revoke execute on function finance.payroll_lines(int, int)                  from public, anon, authenticated;
revoke execute on function finance.payroll_owed(int, int, text)             from public, anon, authenticated;
revoke execute on function finance.payroll_paid(int, int, text, boolean)    from public, anon, authenticated;
revoke execute on function finance.journal_payroll_payment(bigint)          from public, anon, authenticated;
revoke execute on function finance.trg_payroll_payment_journal()            from public, anon, authenticated;
revoke execute on function public.fin_payroll_overview(text, int, int) from public;
revoke execute on function public.fin_save_payroll_alloc(text, int, int, bigint, jsonb) from public;
revoke execute on function public.fin_payroll_journal(text, int, int) from public;
revoke execute on function public.fin_save_payroll_payment(text, int, int, text, bigint, date, numeric, text) from public;
revoke execute on function public.fin_decide_payroll_payment(text, bigint, boolean, text) from public;
grant execute on function public.fin_payroll_overview(text, int, int) to anon, authenticated;
grant execute on function public.fin_save_payroll_alloc(text, int, int, bigint, jsonb) to anon, authenticated;
grant execute on function public.fin_payroll_journal(text, int, int) to anon, authenticated;
grant execute on function public.fin_save_payroll_payment(text, int, int, text, bigint, date, numeric, text) to anon, authenticated;
grant execute on function public.fin_decide_payroll_payment(text, bigint, boolean, text) to anon, authenticated;
