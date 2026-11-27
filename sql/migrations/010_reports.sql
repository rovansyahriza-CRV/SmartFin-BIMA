-- =====================================================================
-- SmartFin BIMA — Migration 010: Laporan Keuangan (menu Laporan, PIC FIN-RPT)
-- Status : ✅ Sudah dijalankan (27 Nov 2026)
--
-- Satu API public.fin_report(token, report, from, to, project, account, include_draft, journal_id):
--   TB      Neraca saldo: saldo awal, debit, kredit, saldo akhir per akun
--   GL      Buku besar satu akun dengan saldo berjalan
--   PL      Laba rugi per akun + ringkasan per proyek (pendapatan, beban, margin)
--   BS      Neraca per tanggal akhir, termasuk laba berjalan
--   CF      Arus kas: saldo kas+bank awal, kas dari operasi / investasi / pendanaan / saldo awal, saldo akhir
--   JOURNAL Detail satu jurnal (drill-down)
-- Jurnal VOID tidak pernah dihitung. Jurnal DRAFT ikut dihitung kalau include_draft = true.
-- Filter proyek memakai journal_line.project_id.
-- =====================================================================

create or replace function finance.tokens(p_text text)
returns text[] language sql immutable set search_path = '' as $$
  with parsed as (
    select coalesce(array_agg(lower(btrim(x))) filter (where btrim(x) <> ''), array[]::text[]) as v
      from regexp_split_to_table(coalesce(p_text,''), '[,;\n\r]+') x
  )
  select case
           when 'all' = any(v)     then v || array['fin','fin-ap','fin-jv','fin-bva','fin-ast','fin-pc','fin-rpt','ai','pj','ab','apy','apc']
           when 'fin-all' = any(v) then v || array['fin','fin-ap','fin-jv','fin-bva','fin-ast','fin-pc','fin-rpt']
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
  if not (v_pics && array['fin','fin-ap','fin-jv','fin-bva','fin-ast','fin-pc','fin-rpt']) then
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

-- Baris jurnal yang dihitung laporan (tanpa VOID; DRAFT opsional; filter proyek opsional)
create or replace function finance.report_lines(p_include_draft boolean, p_project_id uuid)
returns table (journal_id bigint, journal_no text, journal_date date, status text, source_system text, description text,
               account_code text, debit numeric, credit numeric, project_id uuid, memo text)
language sql stable security definer set search_path = '' as $$
  select j.journal_id, j.journal_no, j.journal_date, j.status, j.source_system, j.description,
         l.account_code, l.debit, l.credit, l.project_id, l.memo
    from finance.journal j
    join finance.journal_line l on l.journal_id = j.journal_id
   where (j.status = 'POSTED' or (p_include_draft and j.status = 'DRAFT'))
     and (p_project_id is null or l.project_id = p_project_id)
$$;

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

revoke execute on function finance.report_lines(boolean, uuid) from public, anon, authenticated;
revoke execute on function public.fin_report(text, text, date, date, uuid, text, boolean, bigint) from public;
grant execute on function public.fin_report(text, text, date, date, uuid, text, boolean, bigint) to anon, authenticated;
