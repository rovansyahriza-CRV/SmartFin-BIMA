-- =====================================================================
-- SmartFin BIMA — Migration 015: Rekap Pajak (menu Pajak, PIC FIN-TAX)
-- Status : ✅ Sudah dijalankan (27 Nov 2026)
--
-- Rekap internal per masa pajak (bulan), bahan lapor SPT — belum file impor Coretax/e-Faktur/e-Bupot.
--   PPN Keluaran : invoice klien PPN dipungut BIMA + penjualan aset ber-PPN
--   PPN WAPU     : invoice klien yang PPN-nya dipungut klien (informasi, tidak disetor BIMA)
--   PPN Masukan  : invoice vendor, nota kas, pengeluaran langsung yang ada PPN
--   Masa PPN     = bulan TANGGAL FAKTUR PAJAK; kalau tanggal faktur belum diisi dipakai tanggal
--                  transaksi dan barisnya ditandai "tanggal faktur belum diisi".
--   PPh 21       : dari jurnal payroll Fusion4 (masa = bulan payroll) + setoran yang sudah disetujui
--   PPh 23 dipotong BIMA : invoice vendor jasa & pengeluaran langsung (per vendor, per transaksi)
--   PPh 23 / 4(2) dipotong klien : penerimaan invoice klien (kredit pajak / PPh final)
--   PPh final bunga bank : mutasi bank INTEREST_TAX
--   Saldo akun pajak per akhir masa (jurnal POSTED) untuk cek setoran.
-- Nomor & tanggal faktur bisa dilengkapi dari menu Pajak (FIN-TAX) atau oleh PIC modulnya.
-- =====================================================================

-- PIC FIN-TAX ------------------------------------------------------------
create or replace function finance.tokens(p_text text)
returns text[] language sql immutable set search_path = '' as $$
  with parsed as (
    select coalesce(array_agg(lower(btrim(x))) filter (where btrim(x) <> ''), array[]::text[]) as v
      from regexp_split_to_table(coalesce(p_text,''), '[,;\n\r]+') x
  )
  select case
           when 'all' = any(v)     then v || array['fin','fin-ap','fin-ar','fin-pr','fin-tax','fin-jv','fin-bva','fin-ast','fin-pc','fin-rpt','ai','pj','ab','apy','apc']
           when 'fin-all' = any(v) then v || array['fin','fin-ap','fin-ar','fin-pr','fin-tax','fin-jv','fin-bva','fin-ast','fin-pc','fin-rpt']
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
  if not (v_pics && array['fin','fin-ap','fin-ar','fin-pr','fin-tax','fin-jv','fin-bva','fin-ast','fin-pc','fin-rpt']) then
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

-- Kolom faktur -------------------------------------------------------------
alter table finance.vendor_invoice add column faktur_date date;
alter table finance.ar_invoice     add column faktur_date date;
alter table finance.cash_expense   add column faktur_no text, add column faktur_date date;
alter table finance.cash_request   add column faktur_no text, add column faktur_date date;
alter table finance.asset_disposal add column faktur_no text, add column faktur_date date;

-- Rincian faktur PPN per masa (satu baris = satu dokumen)
create or replace function finance.tax_ppn_rows(p_year int, p_month int)
returns table (direction text, source text, ref_id bigint, doc_no text, trx_date date, faktur_no text, faktur_date date,
               counterparty text, npwp text, dpp numeric, ppn numeric, project_code text)
language sql stable security definer set search_path = '' as $$
  with m as (select make_date(p_year, p_month, 1) as d)
  select * from (
    -- PPN Keluaran: invoice klien dipungut BIMA
    select 'OUT', 'AR_INVOICE', i.invoice_id, i.invoice_no, i.invoice_date, i.faktur_no, i.faktur_date,
           i.client_name, null::text, i.dpp - i.retention_amount, i.ppn_amount, p.code
      from finance.ar_invoice i left join operational.projects p on p.id = i.project_id
     where i.ppn_mode = 'COLLECT' and i.ppn_amount > 0 and i.status in ('APPROVED','PARTIAL','PAID')
    union all
    -- PPN dipungut klien (WAPU) — informasi
    select 'WAPU', 'AR_INVOICE', i.invoice_id, i.invoice_no, i.invoice_date, i.faktur_no, i.faktur_date,
           i.client_name, null, i.dpp - i.retention_amount, i.ppn_amount, p.code
      from finance.ar_invoice i left join operational.projects p on p.id = i.project_id
     where i.ppn_mode = 'WAPU' and i.ppn_amount > 0 and i.status in ('APPROVED','PARTIAL','PAID')
    union all
    -- PPN Keluaran: penjualan aset
    select 'OUT', 'ASSET_DISPOSAL', x.disposal_id, a.asset_code, x.disposal_date, x.faktur_no, x.faktur_date,
           x.buyer, null, x.proceeds, x.ppn_amount, p.code
      from finance.asset_disposal x join finance.fixed_asset a on a.asset_id = x.asset_id
      left join operational.projects p on p.id = a.project_id
     where x.status = 'APPROVED' and x.ppn_amount > 0
    union all
    -- PPN Masukan: invoice vendor
    select 'IN', 'VENDOR_INVOICE', vi.invoice_id, vi.invoice_no, vi.invoice_date, vi.faktur_pajak_no, vi.faktur_date,
           v."VendorName", v."NPWP", vi.subtotal, vi.ppn_amount, null
      from finance.vendor_invoice vi left join public.vendor v on v."VendorID" = vi.vendor_id
     where vi.ppn_amount > 0 and vi.status in ('APPROVED','PARTIAL_PAID','PAID')
    union all
    -- PPN Masukan: nota kas site / kasbon
    select 'IN', 'CASH_EXPENSE', e.expense_id, 'NOTA-' || e.expense_id, e.expense_date, e.faktur_no, e.faktur_date,
           e.description, null, e.amount - e.ppn_amount, e.ppn_amount, p.code
      from finance.cash_expense e left join operational.projects p on p.id = e.project_id
     where e.ppn_amount > 0 and e.status = 'APPROVED'
    union all
    -- PPN Masukan: pengeluaran langsung tanpa PO
    select 'IN', 'CASH_DIRECT', r.request_id, 'DIRECT-' || r.request_id, coalesce(r.paid_at, r.created_at::date), r.faktur_no, r.faktur_date,
           r.payee, null, r.amount - r.ppn_amount, r.ppn_amount, p.code
      from finance.cash_request r left join operational.projects p on p.id = r.project_id
     where r.kind = 'DIRECT' and r.ppn_amount > 0 and r.status in ('PAID','CLOSED')
  ) x (direction, source, ref_id, doc_no, trx_date, faktur_no, faktur_date, counterparty, npwp, dpp, ppn, project_code)
  where date_trunc('month', coalesce(x.faktur_date, x.trx_date))::date = (select d from m);
$$;

-- Saldo akun per tanggal (jurnal POSTED; positif = saldo normal debit)
create or replace function finance.account_balance(p_account text, p_as_of date)
returns numeric language sql stable security definer set search_path = '' as $$
  select coalesce(sum(l.debit - l.credit), 0)
    from finance.journal_line l join finance.journal j on j.journal_id = l.journal_id
   where l.account_code = p_account and j.status = 'POSTED' and j.journal_date <= p_as_of;
$$;

-- API -------------------------------------------------------------------
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
         where r.kind = 'DIRECT' and r.pph23_amount > 0 and r.status in ('PAID','CLOSED') and coalesce(r.paid_at, r.created_at::date) between v_from and v_to) x),
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

-- Lengkapi nomor & tanggal faktur. FIN-TAX boleh semua sumber; PIC modul boleh sumbernya sendiri.
create or replace function public.fin_set_faktur(p_token text, p_source text, p_ref_id bigint, p_faktur_no text, p_faktur_date date)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare who bigint; v_pic text; v_no text := nullif(btrim(p_faktur_no), '');
begin
  v_pic := case p_source when 'VENDOR_INVOICE' then 'fin-ap' when 'CASH_EXPENSE' then 'fin-ap' when 'CASH_DIRECT' then 'fin-ap'
                         when 'AR_INVOICE' then 'fin-ar' when 'ASSET_DISPOSAL' then 'fin-ast' end;
  if v_pic is null then raise exception 'Sumber dokumen tidak dikenal'; end if;
  who := finance.check_session(p_token, array['fin-tax', v_pic]);
  if p_faktur_date is not null and (p_faktur_date > current_date + 31 or p_faktur_date < date '2020-01-01') then
    raise exception 'Tanggal faktur tidak valid';
  end if;
  if p_source = 'VENDOR_INVOICE' then
    update finance.vendor_invoice set faktur_pajak_no = coalesce(v_no, faktur_pajak_no), faktur_date = p_faktur_date where invoice_id = p_ref_id;
  elsif p_source = 'AR_INVOICE' then
    update finance.ar_invoice set faktur_no = coalesce(v_no, faktur_no), faktur_date = p_faktur_date where invoice_id = p_ref_id and status <> 'REJECTED';
  elsif p_source = 'CASH_EXPENSE' then
    update finance.cash_expense set faktur_no = v_no, faktur_date = p_faktur_date where expense_id = p_ref_id;
  elsif p_source = 'CASH_DIRECT' then
    update finance.cash_request set faktur_no = v_no, faktur_date = p_faktur_date where request_id = p_ref_id and kind = 'DIRECT';
  else
    update finance.asset_disposal set faktur_no = v_no, faktur_date = p_faktur_date where disposal_id = p_ref_id;
  end if;
  if not found then raise exception 'Dokumen tidak ditemukan'; end if;
  return jsonb_build_object('source', p_source, 'ref_id', p_ref_id, 'faktur_no', v_no, 'faktur_date', p_faktur_date);
end; $$;

revoke execute on function finance.tax_ppn_rows(int, int)          from public, anon, authenticated;
revoke execute on function finance.account_balance(text, date)     from public, anon, authenticated;
revoke execute on function public.fin_tax_report(text, int, int) from public;
revoke execute on function public.fin_set_faktur(text, text, bigint, text, date) from public;
grant execute on function public.fin_tax_report(text, int, int) to anon, authenticated;
grant execute on function public.fin_set_faktur(text, text, bigint, text, date) to anon, authenticated;
