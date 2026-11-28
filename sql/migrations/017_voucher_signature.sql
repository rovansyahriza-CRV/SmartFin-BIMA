-- =====================================================================
-- SmartFin BIMA — Migration 017: Bukti Bank Keluar (voucher) + tanda tangan digital QR
-- Status : ⏳ Belum dijalankan
--
-- Setiap transaksi uang keluar yang sudah selesai disetujui bisa dicetak sebagai Bukti Bank Keluar (BBK) PDF:
--   payment_schedule  uang muka & pelunasan vendor (status PAID)
--   cash_request      isi kas site, pengeluaran langsung, kasbon (PAID / CLOSED)
--   payroll_payment   gaji bersih, setoran BPJS, setoran PPh 21 (APPROVED)
--   loan_txn          angsuran & biaya pinjaman (APPROVED)
--   bank_txn          biaya admin, pajak bunga, transfer antar rekening, pengeluaran lain (APPROVED)
--
-- Tanda tangan diambil dari jejak approval yang sudah tersimpan (penginput, approver, pembayar),
-- jadi QR "terbit" dari approval itu sendiri: tidak ada langkah tanda tangan tambahan.
-- Nomor BBK dan kode QR dibuat saat bukti pertama kali dicetak, lalu tetap (cetak ulang = nomor & QR sama).
-- Kode QR acak 16 karakter heksadesimal (64 bit), tidak bisa ditebak.
--
-- Halaman verifikasi publik (verifikasi.html?k=KODE) memanggil public.fin_verify_sign (tanpa login):
-- menampilkan nomor BBK, jenis, tanggal, penerima, nilai, rekening, proyek, dan semua penandatangan.
-- Status "Sah" hanya kalau transaksi sumbernya masih berstatus final; kalau tidak, "Tidak berlaku".
-- =====================================================================

create table finance.voucher (
  voucher_id   bigint generated always as identity primary key,
  voucher_no   text not null unique,
  source_table text not null check (source_table in ('payment_schedule','cash_request','payroll_payment','loan_txn','bank_txn')),
  source_id    bigint not null,
  kind_label   text not null,
  voucher_date date not null,
  payee        text,
  amount       numeric(18,2) not null,
  bank_label   text,
  project_code text,
  description  text,
  ref_no       text,
  issued_by    text,
  issued_at    timestamptz not null default now(),
  unique (source_table, source_id)
);
alter table finance.voucher enable row level security;

create table finance.voucher_sign (
  sign_code   text primary key,
  voucher_id  bigint not null references finance.voucher(voucher_id) on delete cascade,
  seq         int not null,
  role        text not null,
  signer_name text not null,
  signed_at   timestamptz,
  created_at  timestamptz not null default now(),
  unique (voucher_id, seq)
);
alter table finance.voucher_sign enable row level security;

-- ---------------------------------------------------------------------
-- Data satu transaksi uang keluar (dipakai cetak & verifikasi)
-- ---------------------------------------------------------------------
create or replace function finance.voucher_source(p_source text, p_id bigint)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r record; v jsonb; v_event text;
begin
  if p_source = 'payment_schedule' then
    select ps.*, po."DocNumber" as po_number, ven."VendorName" as vendor_name, b.account_label as bank_label,
           i.invoice_no, i.created_by as inv_by, i.created_at as inv_at, i.approved_by as inv_appr, i.approved_at as inv_appr_at,
           (select pr.code from finance.v_po_detail_project d join operational.projects pr on pr.id = d.project_id where d.po_id = ps.po_id limit 1) as project_code
      into r
      from finance.payment_schedule ps
      join public."purchaseOrder" po on po."POID" = ps.po_id
      left join public.vendor ven on ven."VendorID" = po."VendorID"
      left join finance.vendor_invoice i on i.invoice_id = ps.invoice_id
      left join finance.bank_account b on b.bank_id = ps.bank_id
     where ps.schedule_id = p_id;
    if not found then return null; end if;
    v := jsonb_build_object(
      'valid', r.status = 'PAID',
      'pics', jsonb_build_array('fin-ap'),
      'kind_label', case when r.schedule_type = 'ADVANCE' then 'Uang muka vendor' else 'Pelunasan vendor' end,
      'date', (r.paid_at at time zone 'Asia/Makassar')::date,
      'payee', r.vendor_name,
      'amount', coalesce(r.paid_amount, r.amount),
      'bank_label', r.bank_label, 'project_code', r.project_code,
      'description', concat_ws(' · ', 'PO ' || r.po_number, 'Invoice ' || r.invoice_no, r.description),
      'ref_no', r.payment_ref,
      'lines', jsonb_build_array(jsonb_build_object('label', case when r.schedule_type = 'ADVANCE' then 'Uang muka' else 'Pembayaran invoice' end, 'amount', coalesce(r.paid_amount, r.amount))),
      'signers', (select coalesce(jsonb_agg(s order by s.ord), '[]'::jsonb) from (values
          (1, 'Invoice diinput (FIN-AP)', r.inv_by, r.inv_at),
          (2, 'Invoice disetujui (AI)', r.inv_appr, r.inv_appr_at),
          (3, 'Pembayaran disetujui (APY)', r.approved_by, r.approved_at),
          (4, 'Dibayar (FIN-AP)', r.paid_by, r.paid_at)) s(ord, role, name, at) where s.name is not null));
    v_event := 'PAID';

  elsif p_source = 'cash_request' then
    select cr.*, f.fund_name, b.account_label as bank_label, p.code as project_code,
           finance.employee_name(cr.employee_id) as employee_name
      into r
      from finance.cash_request cr
      left join finance.cash_fund f on f.fund_id = cr.fund_id
      left join finance.bank_account b on b.bank_id = cr.bank_id
      left join operational.projects p on p.id = coalesce(cr.project_id, f.project_id)
     where cr.request_id = p_id;
    if not found then return null; end if;
    v := jsonb_build_object(
      'valid', r.status in ('PAID','CLOSED'),
      'pics', jsonb_build_array('fin-ap','fin-pc'),
      'owners', jsonb_build_array(r.requested_by_id, r.employee_id, (select custodian_id from finance.cash_fund where fund_id = r.fund_id)),
      'kind_label', case r.kind when 'TOPUP' then 'Isi kas site' when 'DIRECT' then 'Pengeluaran langsung' else 'Kasbon karyawan' end,
      'date', r.paid_at,
      'payee', case r.kind when 'TOPUP' then 'Kas site ' || r.fund_name when 'KASBON' then r.employee_name else r.payee end,
      'amount', coalesce(r.paid_amount, r.amount - r.pph23_amount),
      'bank_label', r.bank_label, 'project_code', r.project_code,
      'description', r.description, 'ref_no', r.payment_ref,
      'lines', case when r.kind = 'DIRECT' then
                 (select jsonb_agg(x) from (values (1, jsonb_build_object('label', 'Nilai tagihan (termasuk PPN)', 'amount', r.amount)),
                                                   (2, jsonb_build_object('label', 'PPN masukan', 'amount', r.ppn_amount)),
                                                   (3, jsonb_build_object('label', 'Dipotong PPh 23', 'amount', -r.pph23_amount))) t(o, x)
                   where (x->>'amount')::numeric <> 0 or o = 1)
               else jsonb_build_array(jsonb_build_object('label', case r.kind when 'TOPUP' then 'Pengisian kas' else 'Kasbon dibayarkan' end, 'amount', coalesce(r.paid_amount, r.amount))) end,
      'signers', (select coalesce(jsonb_agg(s order by s.ord), '[]'::jsonb) from (values
          (1, 'Diajukan', r.requested_by, r.created_at),
          (2, 'Disetujui (APY)', r.approved_by, r.approved_at),
          (3, 'Dibayar (FIN-AP)', r.paid_by, (r.paid_at::timestamp at time zone 'Asia/Makassar'))) s(ord, role, name, at) where s.name is not null));
    v_event := 'PAID';

  elsif p_source = 'payroll_payment' then
    select pp.*, b.account_label as bank_label into r
      from finance.payroll_payment pp left join finance.bank_account b on b.bank_id = pp.bank_id
     where pp.payment_id = p_id;
    if not found then return null; end if;
    v := jsonb_build_object(
      'valid', r.status = 'APPROVED',
      'pics', jsonb_build_array('fin-pr','fin-ap'),
      'kind_label', case r.kind when 'THP' then 'Pembayaran gaji bersih (THP)' when 'BPJS' then 'Setoran BPJS' else 'Setoran PPh 21' end,
      'date', r.pay_date,
      'payee', case r.kind when 'THP' then 'Karyawan (payroll)' when 'BPJS' then 'BPJS Kesehatan & Ketenagakerjaan' else 'Kas Negara (PPh 21)' end,
      'amount', r.amount, 'bank_label', r.bank_label, 'project_code', null,
      'description', 'Payroll periode ' || r.period_year || '-' || lpad(r.period_month::text, 2, '0'),
      'ref_no', r.ref_no,
      'lines', jsonb_build_array(jsonb_build_object('label', case r.kind when 'THP' then 'Gaji bersih' when 'BPJS' then 'Iuran BPJS' else 'PPh 21' end, 'amount', r.amount)),
      'signers', (select coalesce(jsonb_agg(s order by s.ord), '[]'::jsonb) from (values
          (1, 'Diajukan (FIN-PR)', r.requested_by, r.created_at),
          (2, 'Disetujui (APY)', r.approved_by, r.approved_at)) s(ord, role, name, at) where s.name is not null));
    v_event := 'APPROVED';

  elsif p_source = 'loan_txn' then
    select t.*, l.loan_no, l.lender_name, b.account_label as bank_label, p.code as project_code into r
      from finance.loan_txn t join finance.loan l on l.loan_id = t.loan_id
      left join finance.bank_account b on b.bank_id = t.bank_id
      join operational.projects p on p.id = l.project_id
     where t.txn_id = p_id and t.kind in ('INSTALLMENT','FEE');
    if not found then return null; end if;
    v := jsonb_build_object(
      'valid', r.status = 'APPROVED',
      'pics', jsonb_build_array('fin-ap','fin-jv'),
      'kind_label', case when r.kind = 'INSTALLMENT' then 'Angsuran pinjaman' else 'Biaya pinjaman' end,
      'date', r.txn_date, 'payee', r.lender_name,
      'amount', r.principal_amount + r.interest_amount + r.fee_amount - r.pph23_amount,
      'bank_label', r.bank_label, 'project_code', r.project_code,
      'description', concat_ws(' · ', 'Pinjaman ' || r.loan_no, case when r.schedule_seq is not null then 'angsuran ke-' || r.schedule_seq end, r.notes),
      'ref_no', r.ref_no,
      'lines', (select coalesce(jsonb_agg(x order by o), '[]'::jsonb) from (values
          (1, jsonb_build_object('label', 'Pokok', 'amount', r.principal_amount)),
          (2, jsonb_build_object('label', 'Bunga', 'amount', r.interest_amount)),
          (3, jsonb_build_object('label', 'Biaya / provisi / admin', 'amount', r.fee_amount)),
          (4, jsonb_build_object('label', 'Dipotong PPh 23 atas bunga', 'amount', -r.pph23_amount))) t(o, x) where (x->>'amount')::numeric <> 0),
      'signers', (select coalesce(jsonb_agg(s order by s.ord), '[]'::jsonb) from (values
          (1, 'Diajukan (FIN-AP)', r.requested_by, r.created_at),
          (2, 'Disetujui (APY)', r.approved_by, r.approved_at)) s(ord, role, name, at) where s.name is not null));
    v_event := 'APPROVED';

  elsif p_source = 'bank_txn' then
    select t.*, b.account_label as bank_label, tb.account_label as to_label, p.code as project_code, c.account_name into r
      from finance.bank_txn t join finance.bank_account b on b.bank_id = t.bank_id
      left join finance.bank_account tb on tb.bank_id = t.to_bank_id
      left join operational.projects p on p.id = t.project_id
      left join finance.coa c on c.account_code = t.account_code
     where t.txn_id = p_id and t.kind in ('ADMIN_FEE','INTEREST_TAX','TRANSFER','OTHER_OUT');
    if not found then return null; end if;
    v := jsonb_build_object(
      'valid', r.status = 'APPROVED',
      'pics', jsonb_build_array('fin-ap','fin-jv'),
      'kind_label', case r.kind when 'ADMIN_FEE' then 'Biaya admin bank' when 'INTEREST_TAX' then 'Pajak bunga bank'
                                when 'TRANSFER' then 'Transfer antar rekening' else 'Pengeluaran bank lain' end,
      'date', r.txn_date,
      'payee', case r.kind when 'TRANSFER' then 'Rekening ' || r.to_label when 'OTHER_OUT' then coalesce(r.account_name, r.description) else r.bank_label end,
      'amount', r.amount, 'bank_label', r.bank_label, 'project_code', r.project_code,
      'description', r.description, 'ref_no', r.ref_no,
      'lines', jsonb_build_array(jsonb_build_object('label', coalesce(r.description, 'Nilai'), 'amount', r.amount)),
      'signers', (select coalesce(jsonb_agg(s order by s.ord), '[]'::jsonb) from (values
          (1, 'Diajukan (FIN-AP)', r.requested_by, r.created_at),
          (2, 'Disetujui (PJ)', r.approved_by, r.approved_at)) s(ord, role, name, at) where s.name is not null));
    v_event := 'APPROVED';
  else
    raise exception 'Jenis bukti tidak dikenal';
  end if;

  -- baris jurnal (net per akun, termasuk jurnal penyesuaian kalau ada)
  return v || jsonb_build_object('journal', (
    select coalesce(jsonb_agg(jsonb_build_object('account', x.account_code, 'name', x.account_name,
             'debit', greatest(x.net, 0), 'credit', greatest(-x.net, 0)) order by (x.net < 0), x.account_code), '[]'::jsonb)
      from (select l.account_code, c.account_name, sum(l.debit - l.credit) net
              from finance.journal j join finance.journal_line l on l.journal_id = j.journal_id
              left join finance.coa c on c.account_code = l.account_code
             where j.source_table = p_source and j.source_id = p_id::text and j.source_event = v_event and j.status <> 'VOID'
             group by l.account_code, c.account_name having sum(l.debit - l.credit) <> 0) x),
    'journal_no', (select string_agg(j.journal_no, ', ' order by j.journal_id) from finance.journal j
                    where j.source_table = p_source and j.source_id = p_id::text and j.source_event = v_event and j.status <> 'VOID'));
end; $$;

-- ---------------------------------------------------------------------
-- Cetak: terbitkan nomor BBK & kode QR (sekali), kembalikan data lengkap untuk PDF
-- ---------------------------------------------------------------------
create or replace function public.fin_voucher(p_token text, p_source text, p_id bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare who bigint; s jsonb; v finance.voucher%rowtype; v_pics text[]; v_prefix text; v_seq int; x jsonb; i int := 0;
begin
  if p_source not in ('payment_schedule','cash_request','payroll_payment','loan_txn','bank_txn') then raise exception 'Jenis bukti tidak dikenal'; end if;
  s := finance.voucher_source(p_source, p_id);
  if s is null then raise exception 'Transaksi tidak ditemukan atau bukan transaksi uang keluar'; end if;
  select array_agg(e) into v_pics from jsonb_array_elements_text(s->'pics') e;
  who := finance.check_session(p_token, v_pics);
  if p_source = 'cash_request' and not finance.emp_has(who, 'fin-ap')
     and not exists (select 1 from jsonb_array_elements_text(s->'owners') o where o = who::text) then
    raise exception 'Bukti ini hanya bisa dicetak oleh pengaju, penerima, pemegang kas, atau finance HO';
  end if;
  if not (s->>'valid')::boolean then raise exception 'Bukti hanya bisa dicetak setelah transaksi selesai disetujui / dibayar'; end if;

  select * into v from finance.voucher where source_table = p_source and source_id = p_id;
  if v.voucher_id is null then
    lock table finance.voucher in share row exclusive mode;
    v_prefix := 'BBK/' || to_char(coalesce((s->>'date')::date, current_date), 'YYYY/MM') || '/';
    select coalesce(max(substr(voucher_no, length(v_prefix) + 1)::int), 0) + 1 into v_seq
      from finance.voucher where voucher_no like v_prefix || '%';
    insert into finance.voucher (voucher_no, source_table, source_id, kind_label, voucher_date, payee, amount, bank_label,
                                 project_code, description, ref_no, issued_by)
    values (v_prefix || lpad(v_seq::text, 4, '0'), p_source, p_id, s->>'kind_label', coalesce((s->>'date')::date, current_date),
            s->>'payee', (s->>'amount')::numeric, s->>'bank_label', s->>'project_code', s->>'description', s->>'ref_no',
            finance.employee_name(who))
    returning * into v;
  end if;

  for x in select * from jsonb_array_elements(s->'signers') loop
    i := i + 1;
    insert into finance.voucher_sign (sign_code, voucher_id, seq, role, signer_name, signed_at)
    values ('SF-' || upper(encode(extensions.gen_random_bytes(8), 'hex')), v.voucher_id, i, x->>'role', x->>'name', (x->>'at')::timestamptz)
    on conflict (voucher_id, seq) do nothing;
  end loop;

  return jsonb_build_object(
    'voucher_no', v.voucher_no, 'kind_label', v.kind_label, 'date', v.voucher_date, 'payee', v.payee, 'amount', v.amount,
    'bank_label', v.bank_label, 'project_code', v.project_code, 'description', v.description, 'ref_no', v.ref_no,
    'issued_by', v.issued_by, 'issued_at', v.issued_at, 'printed_by', finance.employee_name(who),
    'lines', s->'lines', 'journal', s->'journal', 'journal_no', s->>'journal_no',
    'signs', (select coalesce(jsonb_agg(jsonb_build_object('code', sign_code, 'role', role, 'name', signer_name, 'at', signed_at) order by seq), '[]'::jsonb)
                from finance.voucher_sign where voucher_id = v.voucher_id));
end; $$;

-- ---------------------------------------------------------------------
-- Verifikasi publik dari QR (tanpa login)
-- ---------------------------------------------------------------------
create or replace function public.fin_verify_sign(p_code text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare g finance.voucher_sign%rowtype; v finance.voucher%rowtype; s jsonb;
begin
  if p_code is null or p_code !~ '^SF-[0-9A-F]{16}$' then return jsonb_build_object('found', false); end if;
  select * into g from finance.voucher_sign where sign_code = upper(p_code);
  if g.sign_code is null then return jsonb_build_object('found', false); end if;
  select * into v from finance.voucher where voucher_id = g.voucher_id;
  s := finance.voucher_source(v.source_table, v.source_id);
  return jsonb_build_object(
    'found', true,
    'valid', coalesce((s->>'valid')::boolean, false),
    'code', g.sign_code, 'role', g.role, 'name', g.signer_name, 'signed_at', g.signed_at,
    'voucher_no', v.voucher_no, 'kind_label', v.kind_label, 'date', v.voucher_date, 'payee', v.payee, 'amount', v.amount,
    'bank_label', v.bank_label, 'project_code', v.project_code, 'issued_at', v.issued_at,
    'signs', (select jsonb_agg(jsonb_build_object('role', role, 'name', signer_name, 'at', signed_at, 'me', sign_code = g.sign_code) order by seq)
                from finance.voucher_sign where voucher_id = v.voucher_id));
end; $$;

revoke execute on function finance.voucher_source(text, bigint) from public, anon, authenticated;
revoke execute on function public.fin_voucher(text, text, bigint) from public;
revoke execute on function public.fin_verify_sign(text) from public;
grant execute on function public.fin_voucher(text, text, bigint) to anon, authenticated;
grant execute on function public.fin_verify_sign(text) to anon, authenticated;
