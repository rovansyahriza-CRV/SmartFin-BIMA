-- =====================================================================
-- SmartFin BIMA — Migration 004: Login, Hak Akses & API untuk Web
-- Status : SUDAH DIJALANKAN ke Supabase (26 Nov 2026)
--
-- Pola sama dengan modul Operational (op_login / check_session):
--   * Login pakai akun paswordTbl (public.verify_login), token sesi 8 jam,
--     maksimal 5x salah password per 15 menit.
--   * Kolom PIC (fallback pic)  = MENU   : FIN, FIN-AP, FIN-JV, FIN-BVA, FIN-AST, FIN-ALL
--   * Kolom Author              = APPROVAL: AI (approve invoice), PJ (posting jurnal),
--                                           AB (approve budget), APY (approve pembayaran)
--     Author boleh berakhiran kode proyek: AI-014 = hanya proyek 014; AI = semua proyek.
--   * ALL (di PIC atau Author) = SUPER ADMIN: semua menu + semua approval SmartFin.
--     Saat trial, ALL hanya diberikan ke 1 admin (keputusan user 26 Nov 2026).
--   * Web hanya memanggil fungsi public.fin_* di bawah. Tabel finance tetap
--     tertutup untuk akses langsung (RLS tanpa policy).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Sesi & percobaan login
-- ---------------------------------------------------------------------
create table finance.sessions (
  token_hash      bytea primary key,
  employee_id     bigint not null,
  credential_hash bytea not null,
  expires_at      timestamptz not null,
  created_at      timestamptz not null default now()
);
create table finance.login_attempts (
  employee_id  bigint primary key,
  attempts     integer not null,
  window_start timestamptz not null
);
alter table finance.sessions       enable row level security;
alter table finance.login_attempts enable row level security;

-- Pecah teks "FIN-AP, AI-014" -> {'fin-ap','ai-014'}.
-- FIN-ALL = semua menu SmartFin. ALL = super admin (semua menu + semua approval).
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
           -- ALL = super admin: semua menu SmartFin + semua level approval
           when 'all' = any(v)     then v || array['fin','fin-ap','fin-jv','fin-bva','fin-ast','ai','pj','ab','apy']
           when 'fin-all' = any(v) then v || array['fin','fin-ap','fin-jv','fin-bva','fin-ast']
           else v end
    from parsed;
$$;

-- Validasi sesi + menu (PIC) + approval (Author, opsional per proyek). Return employee_id.
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

-- Nama karyawan untuk jejak approval
create or replace function finance.employee_name(p_id bigint)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(k."NamaPersonnel", p."Nama", p_id::text)
    from public."paswordTbl" p
    left join public."karyawanTbl" k on k."Id" = p."Id"
   where p."Id" = p_id;
$$;

-- ---------------------------------------------------------------------
-- 2. Login / logout
-- ---------------------------------------------------------------------
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

  if not (v_pics && array['fin','fin-ap','fin-jv','fin-bva','fin-ast']) then
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
                where x ~ '^(ai|pj|ab|apy)(-|$)'),
    'expiresAt', now() + interval '8 hours');
end;
$$;

create or replace function public.fin_logout(p_token text)
returns void
language sql
security definer
set search_path = ''
as $$
  delete from finance.sessions where token_hash = sha256(convert_to(coalesce(p_token,''),'UTF8'));
$$;

-- Daftar akun yang punya akses SmartFin (untuk dropdown login)
create or replace function public.fin_login_accounts()
returns table(id bigint, nama text)
language sql
stable
security definer
set search_path = ''
as $$
  select p."Id", coalesce(k."NamaPersonnel", p."Nama")
    from public."paswordTbl" p
    left join public."karyawanTbl" k on k."Id" = p."Id"
   where p."IsActive" = true
     and finance.tokens(coalesce(nullif(btrim(p."PIC"),''), p.pic)) && array['fin','fin-ap','fin-jv','fin-bva','fin-ast']
   order by 2;
$$;

-- ---------------------------------------------------------------------
-- 3. Dashboard
-- ---------------------------------------------------------------------
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
                              where status in ('PLANNED','DUE') and due_date <= current_date + 7),
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
                          order by j.journal_date desc, j.journal_id desc limit 8) x)
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Jurnal: daftar & posting
-- ---------------------------------------------------------------------
create or replace function public.fin_journals(p_token text, p_status text default 'DRAFT', p_limit integer default 100)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform finance.check_session(p_token, array['fin-jv']);
  return (select coalesce(jsonb_agg(x order by x.journal_date desc, x.journal_id desc), '[]'::jsonb) from (
    select j.journal_id, j.journal_no, j.journal_date, j.source_system, j.source_table, j.source_event,
           j.description, j.status, j.posted_by, j.posted_at, p.code as project_code,
           (select jsonb_agg(jsonb_build_object('account', l.account_code, 'accountName', c.account_name,
                                                'debit', l.debit, 'credit', l.credit, 'memo', l.memo)
                             order by l.debit desc, l.line_id)
              from finance.journal_line l join finance.coa c using (account_code)
             where l.journal_id = j.journal_id) as lines
      from finance.journal j
      left join operational.projects p on p.id = j.project_id
     where p_status is null or p_status = 'ALL' or j.status = p_status
     order by j.journal_date desc, j.journal_id desc
     limit greatest(least(coalesce(p_limit,100), 500), 1)) x);
end;
$$;

create or replace function public.fin_post_journal(p_token text, p_journal_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare who bigint; v_code text;
begin
  select p.code into v_code from finance.journal j
    left join operational.projects p on p.id = j.project_id where j.journal_id = p_journal_id;
  who := finance.check_session(p_token, array['fin-jv'], 'PJ', v_code);
  perform finance.post_journal(p_journal_id, finance.employee_name(who));
  return (select jsonb_build_object('journal_id', journal_id, 'journal_no', journal_no, 'status', status)
            from finance.journal where journal_id = p_journal_id);
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Aset tetap
-- ---------------------------------------------------------------------
create or replace function public.fin_assets(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform finance.check_session(p_token, array['fin-ast']);
  return jsonb_build_object(
    'assets',     (select coalesce(jsonb_agg(to_jsonb(a) order by a.asset_id), '[]'::jsonb) from finance.v_asset_register a),
    'categories', (select coalesce(jsonb_agg(to_jsonb(c) order by c.category_code), '[]'::jsonb) from finance.asset_category c),
    'capitalizationThreshold', (select value from finance.setting where key = 'capitalization_threshold'));
end;
$$;

create or replace function public.fin_update_asset(
  p_token text, p_asset_id bigint, p_category text, p_useful_life_months integer,
  p_residual_value numeric, p_method text, p_location text, p_condition text, p_notes text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare who bigint;
begin
  who := finance.check_session(p_token, array['fin-ast']);
  update finance.fixed_asset
     set category_code      = coalesce(p_category, category_code),
         useful_life_months = coalesce(p_useful_life_months, useful_life_months),
         residual_value     = coalesce(p_residual_value, residual_value),
         method             = coalesce(p_method, method),
         location           = coalesce(p_location, location),
         condition          = coalesce(p_condition, condition),
         notes              = coalesce(p_notes, notes),
         updated_by         = finance.employee_name(who)
   where asset_id = p_asset_id;
  if not found then raise exception 'Aset % tidak ditemukan', p_asset_id; end if;
  return (select to_jsonb(a) from finance.v_asset_register a where a.asset_id = p_asset_id);
end;
$$;

create or replace function public.fin_run_depreciation(p_token text, p_period date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare who bigint; n integer;
begin
  who := finance.check_session(p_token, array['fin-ast']);
  n := finance.run_depreciation(p_period, finance.employee_name(who));
  return jsonb_build_object('period', date_trunc('month', p_period)::date, 'assetsDepreciated', n);
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Hutang vendor: PO terbuka, invoice, approve
-- ---------------------------------------------------------------------
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
    'invoices', (select coalesce(jsonb_agg(x order by x.invoice_id desc), '[]'::jsonb) from (
       select i.invoice_id, i.invoice_no, i.invoice_date, i.due_date, i.status, i.subtotal, i.ppn_amount,
              i.pph23_amount, i.total_amount, i.hold_reason, i.approved_by, i.approved_at,
              po."DocNumber" as po_number, v."VendorName" as vendor_name
         from finance.vendor_invoice i
         join public."purchaseOrder" po on po."POID" = i.po_id
         join public.vendor v on v."VendorID" = i.vendor_id) x));
end;
$$;

-- p_lines: [{"po_detail_id":17,"qty":2,"unit_price":1250000}, ...]
create or replace function public.fin_create_invoice(
  p_token text, p_po_id bigint, p_invoice_no text, p_invoice_date date, p_due_date date,
  p_ppn_amount numeric, p_pph23_amount numeric, p_faktur_pajak_no text, p_notes text, p_lines jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare who bigint; v_id bigint; v_vendor bigint; v_sub numeric;
begin
  who := finance.check_session(p_token, array['fin-ap']);
  select "VendorID" into v_vendor from public."purchaseOrder" where "POID" = p_po_id;
  if v_vendor is null then raise exception 'PO % tidak ditemukan', p_po_id; end if;
  if p_lines is null or jsonb_array_length(p_lines) = 0 then raise exception 'Invoice harus punya minimal 1 baris item'; end if;
  if exists (select 1 from jsonb_array_elements(p_lines) l
              left join public."purchaseOrderDetail" d on d."PODetailID" = (l->>'po_detail_id')::bigint
             where d."POID" is distinct from p_po_id) then
    raise exception 'Ada baris item yang bukan milik PO ini';
  end if;

  select sum(round((l->>'qty')::numeric * (l->>'unit_price')::numeric, 2)) into v_sub
    from jsonb_array_elements(p_lines) l;

  insert into finance.vendor_invoice (invoice_no, vendor_id, po_id, invoice_date, due_date, subtotal,
                                      ppn_amount, pph23_amount, faktur_pajak_no, notes, created_by)
  values (btrim(p_invoice_no), v_vendor, p_po_id, p_invoice_date, p_due_date, v_sub,
          coalesce(p_ppn_amount,0), coalesce(p_pph23_amount,0), p_faktur_pajak_no, p_notes, finance.employee_name(who))
  returning invoice_id into v_id;

  insert into finance.vendor_invoice_line (invoice_id, po_detail_id, qty, unit_price)
  select v_id, (l->>'po_detail_id')::bigint, (l->>'qty')::numeric, (l->>'unit_price')::numeric
    from jsonb_array_elements(p_lines) l;

  -- status MATCHED kalau semua baris cocok, HOLD kalau ada selisih
  update finance.vendor_invoice i
     set status = case when exists (select 1 from finance.vendor_invoice_line l
                                      join finance.v_three_way_match m on m.po_detail_id = l.po_detail_id
                                     where l.invoice_id = v_id and m.match_status <> 'COCOK')
                       then 'HOLD' else 'MATCHED' end,
         hold_reason = (select string_agg(distinct m.item_description || ': ' || m.match_status, '; ')
                          from finance.vendor_invoice_line l
                          join finance.v_three_way_match m on m.po_detail_id = l.po_detail_id
                         where l.invoice_id = v_id and m.match_status <> 'COCOK')
   where i.invoice_id = v_id;

  return (select jsonb_build_object('invoice_id', invoice_id, 'status', status, 'hold_reason', hold_reason,
                                    'total_amount', total_amount)
            from finance.vendor_invoice where invoice_id = v_id);
end;
$$;

create or replace function public.fin_approve_invoice(p_token text, p_invoice_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare who bigint; v_code text;
begin
  select p.code into v_code
    from finance.vendor_invoice_line l
    join finance.v_po_detail_project d on d.po_detail_id = l.po_detail_id
    left join operational.projects p on p.id = d.project_id
   where l.invoice_id = p_invoice_id limit 1;
  who := finance.check_session(p_token, array['fin-ap'], 'AI', v_code);
  update finance.vendor_invoice
     set status = 'APPROVED', approved_by = finance.employee_name(who), approved_at = now()
   where invoice_id = p_invoice_id and status in ('MATCHED','RECEIVED');
  if not found then raise exception 'Invoice % tidak bisa di-approve (status bukan MATCHED)', p_invoice_id; end if;
  return (select jsonb_build_object('invoice_id', invoice_id, 'status', status) from finance.vendor_invoice where invoice_id = p_invoice_id);
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Budget (RAB) per proyek
-- ---------------------------------------------------------------------
create or replace function public.fin_budget(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform finance.check_session(p_token, array['fin-bva']);
  return jsonb_build_object(
    'projects', (select coalesce(jsonb_agg(jsonb_build_object('project_id', id, 'code', code, 'name', name) order by code), '[]'::jsonb)
                   from operational.projects),
    'budgets',  (select coalesce(jsonb_agg(to_jsonb(b) order by b.project_id, b.cost_category, b.created_at), '[]'::jsonb)
                   from finance.project_budget b),
    'summary',  (select coalesce(jsonb_agg(to_jsonb(v) order by v.code), '[]'::jsonb) from finance.v_budget_vs_actual v));
end;
$$;

create or replace function public.fin_save_budget(
  p_token text, p_project_id uuid, p_cost_category text, p_amount numeric, p_revision text, p_notes text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare who bigint;
begin
  who := finance.check_session(p_token, array['fin-bva']);
  insert into finance.project_budget (project_id, cost_category, amount, revision, notes)
  values (p_project_id, upper(p_cost_category), p_amount, coalesce(nullif(btrim(p_revision),''),'R0'), p_notes)
  on conflict (project_id, cost_category, revision)
  do update set amount = excluded.amount, notes = excluded.notes, approved_by = null, approved_at = null;
  return jsonb_build_object('ok', true, 'savedBy', finance.employee_name(who));
end;
$$;

create or replace function public.fin_approve_budget(p_token text, p_budget_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare who bigint; v_code text;
begin
  select p.code into v_code from finance.project_budget b
    join operational.projects p on p.id = b.project_id where b.budget_id = p_budget_id;
  who := finance.check_session(p_token, array['fin-bva'], 'AB', v_code);
  update finance.project_budget set approved_by = finance.employee_name(who), approved_at = now()
   where budget_id = p_budget_id;
  return jsonb_build_object('ok', found);
end;
$$;

-- ---------------------------------------------------------------------
-- 8. Hak eksekusi: web (anon) hanya boleh fungsi public.fin_*
-- ---------------------------------------------------------------------
revoke execute on function finance.tokens(text)                         from public, anon, authenticated;
revoke execute on function finance.check_session(text, text[], text, text) from public, anon, authenticated;
revoke execute on function finance.employee_name(bigint)                from public, anon, authenticated;

revoke execute on function public.fin_login(bigint, text)               from public;
revoke execute on function public.fin_logout(text)                      from public;
revoke execute on function public.fin_login_accounts()                  from public;
revoke execute on function public.fin_dashboard(text)                   from public;
revoke execute on function public.fin_journals(text, text, integer)     from public;
revoke execute on function public.fin_post_journal(text, bigint)        from public;
revoke execute on function public.fin_assets(text)                      from public;
revoke execute on function public.fin_update_asset(text, bigint, text, integer, numeric, text, text, text, text) from public;
revoke execute on function public.fin_run_depreciation(text, date)      from public;
revoke execute on function public.fin_ap_overview(text)                 from public;
revoke execute on function public.fin_create_invoice(text, bigint, text, date, date, numeric, numeric, text, text, jsonb) from public;
revoke execute on function public.fin_approve_invoice(text, bigint)     from public;
revoke execute on function public.fin_budget(text)                      from public;
revoke execute on function public.fin_save_budget(text, uuid, text, numeric, text, text) from public;
revoke execute on function public.fin_approve_budget(text, bigint)      from public;

grant execute on function public.fin_login(bigint, text)               to anon, authenticated;
grant execute on function public.fin_logout(text)                      to anon, authenticated;
grant execute on function public.fin_login_accounts()                  to anon, authenticated;
grant execute on function public.fin_dashboard(text)                   to anon, authenticated;
grant execute on function public.fin_journals(text, text, integer)     to anon, authenticated;
grant execute on function public.fin_post_journal(text, bigint)        to anon, authenticated;
grant execute on function public.fin_assets(text)                      to anon, authenticated;
grant execute on function public.fin_update_asset(text, bigint, text, integer, numeric, text, text, text, text) to anon, authenticated;
grant execute on function public.fin_run_depreciation(text, date)      to anon, authenticated;
grant execute on function public.fin_ap_overview(text)                 to anon, authenticated;
grant execute on function public.fin_create_invoice(text, bigint, text, date, date, numeric, numeric, text, text, jsonb) to anon, authenticated;
grant execute on function public.fin_approve_invoice(text, bigint)     to anon, authenticated;
grant execute on function public.fin_budget(text)                      to anon, authenticated;
grant execute on function public.fin_save_budget(text, uuid, text, numeric, text, text) to anon, authenticated;
grant execute on function public.fin_approve_budget(text, bigint)      to anon, authenticated;
