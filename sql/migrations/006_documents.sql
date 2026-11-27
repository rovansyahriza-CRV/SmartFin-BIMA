-- =====================================================================
-- SmartFin BIMA — Migration 006: Checklist & Lampiran Dokumen (Gate A / Gate B)
-- Status : DRAFT
--
-- Gate A (ADVANCE)  : dicek saat jadwal UANG MUKA mau disetujui (APY)
--                     PO/SO approved (otomatis SMMS), Invoice DP/Proforma, Jaminan Uang Muka,
--                     Faktur Pajak DP & Kwitansi (opsional)
-- Gate B (INVOICE)  : dicek saat invoice vendor dibuat / mau di-approve (AI)
--                     PO/SO (otomatis), Surat Jalan & Bukti Terima Site (otomatis, khusus PO),
--                     Invoice asli, Faktur Pajak (kalau ada PPN), Laporan Pekerjaan (khusus SO),
--                     Kwitansi (opsional)
-- Dokumen wajib belum lengkap:
--   * invoice -> status HOLD (tidak bisa di-approve), otomatis MATCHED begitu lengkap
--   * jadwal uang muka -> tombol Setujui ditolak server
-- File disimpan di Google Drive (bridge SMMS); database hanya menyimpan link & metadata.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Master jenis dokumen
-- ---------------------------------------------------------------------
create table finance.document_type (
  doc_type    text primary key,
  gate        text not null check (gate in ('ADVANCE','INVOICE')),
  doc_name    text not null,
  source      text not null check (source in ('SMMS','UPLOAD')),
  rule        text not null check (rule in ('ALWAYS','IF_PO','IF_SO','IF_PPN','OPTIONAL','SETTING')),
  setting_key text,                         -- dipakai kalau rule = SETTING
  sort_order  integer not null default 0,
  is_active   boolean not null default true
);
alter table finance.document_type enable row level security;

insert into finance.document_type (doc_type, gate, doc_name, source, rule, setting_key, sort_order) values
  ('ADV_PO',          'ADVANCE', 'PO / SO approved',               'SMMS',   'ALWAYS',  null, 10),
  ('ADV_INVOICE',     'ADVANCE', 'Invoice DP / Proforma vendor',   'UPLOAD', 'ALWAYS',  null, 20),
  ('ADV_BOND',        'ADVANCE', 'Jaminan Uang Muka',              'UPLOAD', 'SETTING', 'dp_bond_required', 30),
  ('ADV_TAX',         'ADVANCE', 'Faktur Pajak DP',                'UPLOAD', 'OPTIONAL',null, 40),
  ('ADV_RECEIPT',     'ADVANCE', 'Kwitansi',                       'UPLOAD', 'OPTIONAL',null, 50),
  ('INV_PO',          'INVOICE', 'PO / SO',                        'SMMS',   'ALWAYS',  null, 10),
  ('INV_DELIVERY',    'INVOICE', 'Surat Jalan / DO vendor',        'SMMS',   'IF_PO',   null, 20),
  ('INV_SITE_RECEIPT','INVOICE', 'Bukti terima di site',           'SMMS',   'IF_PO',   null, 30),
  ('INV_INVOICE',     'INVOICE', 'Invoice asli vendor',            'UPLOAD', 'ALWAYS',  null, 40),
  ('INV_TAX',         'INVOICE', 'Faktur Pajak',                   'UPLOAD', 'IF_PPN',  null, 50),
  ('INV_WORK_REPORT', 'INVOICE', 'Timesheet / Laporan pekerjaan',  'UPLOAD', 'IF_SO',   null, 60),
  ('INV_RECEIPT',     'INVOICE', 'Kwitansi',                       'UPLOAD', 'OPTIONAL',null, 70);

insert into finance.setting (key, value, notes) values
  ('dp_bond_required', 'true', 'Jaminan Uang Muka wajib di Gate A (true/false).');

-- ---------------------------------------------------------------------
-- 2. Lampiran dokumen
-- ---------------------------------------------------------------------
create table finance.document (
  doc_id        bigint generated always as identity primary key,
  doc_type      text not null references finance.document_type(doc_type),
  invoice_id    bigint references finance.vendor_invoice(invoice_id) on delete cascade,
  schedule_id   bigint references finance.payment_schedule(schedule_id) on delete cascade,
  file_url      text not null,
  file_id       text,
  file_name     text,
  ref_no        text,                 -- no. invoice / no. faktur / no. jaminan
  bond_issuer   text,                 -- khusus Jaminan Uang Muka
  bond_amount   numeric(18,2),
  bond_expiry   date,
  notes         text,
  uploaded_by   text,
  uploaded_at   timestamptz not null default now(),
  check ((invoice_id is null) <> (schedule_id is null)),
  check (file_url ~* '^https://')
);
create index on finance.document (invoice_id);
create index on finance.document (schedule_id);
alter table finance.document enable row level security;

-- ---------------------------------------------------------------------
-- 3. Checklist: hitung dokumen wajib/tersedia untuk satu invoice atau satu jadwal DP
-- ---------------------------------------------------------------------
create or replace function finance.doc_checklist(p_gate text, p_ref_id bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_po_id   bigint;
  v_is_so   boolean;
  v_has_ppn boolean := false;
  v_lines   bigint[];
  v_out     jsonb := '[]'::jsonb;
  t         record;
  v_req     boolean;
  v_links   jsonb;
begin
  if p_gate = 'INVOICE' then
    select i.po_id, i.ppn_amount > 0 into v_po_id, v_has_ppn from finance.vendor_invoice i where i.invoice_id = p_ref_id;
    select array_agg(po_detail_id) into v_lines from finance.vendor_invoice_line where invoice_id = p_ref_id and po_detail_id is not null;
  else
    select s.po_id into v_po_id from finance.payment_schedule s where s.schedule_id = p_ref_id;
  end if;
  if v_po_id is null then return '[]'::jsonb; end if;

  select upper(coalesce("DocType",'PO')) = 'SO' into v_is_so from public."purchaseOrder" where "POID" = v_po_id;
  -- baris PO yang dicek untuk dokumen terima: baris di invoice, atau semua baris PO kalau invoice hanya biaya tambahan
  if v_lines is null then
    select array_agg("PODetailID") into v_lines from public."purchaseOrderDetail" where "POID" = v_po_id;
  end if;

  for t in select * from finance.document_type where gate = p_gate and is_active order by sort_order loop
    v_req := case t.rule
               when 'ALWAYS'   then true
               when 'IF_PO'    then not v_is_so
               when 'IF_SO'    then v_is_so
               when 'IF_PPN'   then v_has_ppn
               when 'SETTING'  then coalesce((select lower(value) in ('true','1','ya','yes') from finance.setting where key = t.setting_key), true)
               else false
             end;

    if t.source = 'SMMS' then
      v_links := case t.doc_type
        when 'ADV_PO' then (select coalesce(jsonb_agg(jsonb_build_object('label', "DocNumber", 'url', "ReportURL")), '[]'::jsonb)
                              from public."purchaseOrder" where "POID" = v_po_id and "ReportURL" is not null)
        when 'INV_PO' then (select coalesce(jsonb_agg(jsonb_build_object('label', "DocNumber", 'url', "ReportURL")), '[]'::jsonb)
                              from public."purchaseOrder" where "POID" = v_po_id and "ReportURL" is not null)
        when 'INV_DELIVERY' then (select coalesce(jsonb_agg(distinct jsonb_build_object('label', 'SJ ' || "VendorDocNumber", 'url', null)), '[]'::jsonb)
                              from public."vendorReceiving" where "PODetailID" = any(v_lines) and nullif(btrim("VendorDocNumber"),'') is not null)
        when 'INV_SITE_RECEIPT' then (select coalesce(jsonb_agg(distinct jsonb_build_object('label', coalesce(sr."NoTransaksi", 'Terima site'), 'url', sr."ReportURL")), '[]'::jsonb)
                              from public."siteReceiving" sr join public.delivery d on d."DeliveryID" = sr."DeliveryID"
                             where d."PODetailID" = any(v_lines) and sr."ReportURL" is not null)
        else '[]'::jsonb end;
    else
      select coalesce(jsonb_agg(jsonb_build_object('doc_id', doc_id, 'label', coalesce(ref_no, file_name, 'Dokumen'),
                                                   'url', file_url, 'uploaded_by', uploaded_by, 'uploaded_at', uploaded_at,
                                                   'bond_issuer', bond_issuer, 'bond_amount', bond_amount, 'bond_expiry', bond_expiry)
                                order by uploaded_at), '[]'::jsonb)
        into v_links
        from finance.document
       where doc_type = t.doc_type
         and ((p_gate = 'INVOICE' and invoice_id = p_ref_id) or (p_gate = 'ADVANCE' and schedule_id = p_ref_id));
    end if;

    v_out := v_out || jsonb_build_object('doc_type', t.doc_type, 'doc_name', t.doc_name, 'source', t.source,
                                         'required', v_req, 'ok', jsonb_array_length(v_links) > 0, 'items', v_links);
  end loop;
  return v_out;
end;
$$;

-- Daftar nama dokumen wajib yang belum ada (null = lengkap)
create or replace function finance.doc_missing(p_gate text, p_ref_id bigint)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select string_agg(x->>'doc_name', ', ')
    from jsonb_array_elements(finance.doc_checklist(p_gate, p_ref_id)) x
   where (x->>'required')::boolean and not (x->>'ok')::boolean;
$$;

-- ---------------------------------------------------------------------
-- 4. Status invoice: 3-way match + biaya tambahan + dokumen
-- ---------------------------------------------------------------------
create or replace function finance.refresh_invoice_status(p_invoice_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_po bigint; v_hold text; v_charge numeric; v_cap numeric; v_docs text;
begin
  select po_id into v_po from finance.vendor_invoice
   where invoice_id = p_invoice_id and status in ('RECEIVED','MATCHED','HOLD');
  if v_po is null then return; end if;

  select string_agg(distinct m.item_description || ': ' || m.match_status, '; ') into v_hold
    from finance.vendor_invoice_line l
    join finance.v_three_way_match m on m.po_detail_id = l.po_detail_id
   where l.invoice_id = p_invoice_id and m.match_status <> 'COCOK';

  select coalesce(sum(l.subtotal),0) into v_charge
    from finance.vendor_invoice_line l join finance.vendor_invoice i on i.invoice_id = l.invoice_id
   where i.po_id = v_po and l.charge_type is not null and i.status <> 'CANCELLED';
  select mobilisasi_cost + other_service_cost into v_cap from finance.v_po_term where po_id = v_po;
  if v_charge > coalesce(v_cap,0) then
    v_hold := concat_ws('; ', v_hold, 'Biaya tambahan Rp ' || v_charge || ' melebihi penawaran RFQ Rp ' || coalesce(v_cap,0));
  end if;

  v_docs := finance.doc_missing('INVOICE', p_invoice_id);
  if v_docs is not null then
    v_hold := concat_ws('; ', v_hold, 'Dokumen belum lengkap: ' || v_docs);
  end if;

  update finance.vendor_invoice
     set status = case when v_hold is null then 'MATCHED' else 'HOLD' end, hold_reason = v_hold
   where invoice_id = p_invoice_id;
end;
$$;

-- Validasi approve invoice: tambah syarat dokumen lengkap
create or replace function finance.trg_vendor_invoice_validate()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare v_charge numeric; v_cap numeric; v_docs text;
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
    v_docs := finance.doc_missing('INVOICE', new.invoice_id);
    if v_docs is not null then
      raise exception 'Invoice % belum bisa di-approve. Dokumen belum lengkap: %', new.invoice_no, v_docs;
    end if;
    new.approved_at := coalesce(new.approved_at, now());
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- 5. API
-- ---------------------------------------------------------------------
create or replace function public.fin_doc_checklist(p_token text, p_gate text, p_ref_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform finance.check_session(p_token, array['fin-ap']);
  if p_gate not in ('ADVANCE','INVOICE') then raise exception 'Gate tidak dikenal'; end if;
  return jsonb_build_object('gate', p_gate, 'ref_id', p_ref_id, 'items', finance.doc_checklist(p_gate, p_ref_id),
                            'missing', finance.doc_missing(p_gate, p_ref_id));
end;
$$;

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
  who := finance.check_session(p_token, array['fin-ap']);
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

  insert into finance.document (doc_type, invoice_id, schedule_id, file_url, file_id, file_name, ref_no,
                                bond_issuer, bond_amount, bond_expiry, notes, uploaded_by)
  values (p_doc_type,
          case when p_gate = 'INVOICE' then p_ref_id end,
          case when p_gate = 'ADVANCE' then p_ref_id end,
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
declare who bigint; d finance.document%rowtype;
begin
  who := finance.check_session(p_token, array['fin-ap']);
  select * into d from finance.document where doc_id = p_doc_id;
  if d.doc_id is null then raise exception 'Dokumen tidak ditemukan'; end if;
  if d.invoice_id is not null and exists (select 1 from finance.vendor_invoice where invoice_id = d.invoice_id
                                           and status in ('APPROVED','PARTIAL_PAID','PAID')) then
    raise exception 'Dokumen invoice yang sudah di-approve tidak bisa dihapus';
  end if;
  if d.schedule_id is not null and exists (select 1 from finance.payment_schedule where schedule_id = d.schedule_id
                                            and status in ('APPROVED','PAID')) then
    raise exception 'Dokumen uang muka yang sudah disetujui tidak bisa dihapus';
  end if;
  delete from finance.document where doc_id = p_doc_id;
  if d.invoice_id is not null then perform finance.refresh_invoice_status(d.invoice_id); end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- Approve pembayaran: Gate A untuk uang muka
create or replace function public.fin_approve_payment(p_token text, p_schedule_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare who bigint; v_code text; v_type text; v_docs text;
begin
  select pr.code into v_code
    from finance.payment_schedule ps
    join finance.v_po_detail_project d on d.po_id = ps.po_id
    join operational.projects pr on pr.id = d.project_id
   where ps.schedule_id = p_schedule_id limit 1;
  who := finance.check_session(p_token, array['fin-ap'], 'APY', v_code);
  select schedule_type into v_type from finance.payment_schedule where schedule_id = p_schedule_id;
  if v_type = 'ADVANCE' then
    v_docs := finance.doc_missing('ADVANCE', p_schedule_id);
    if v_docs is not null then
      raise exception 'Uang muka belum bisa disetujui. Dokumen belum lengkap: %', v_docs;
    end if;
  end if;
  update finance.payment_schedule
     set status = 'APPROVED', approved_by = finance.employee_name(who), approved_at = now()
   where schedule_id = p_schedule_id and status in ('PLANNED','DUE');
  if not found then raise exception 'Jadwal % tidak bisa disetujui (status bukan Rencana)', p_schedule_id; end if;
  return jsonb_build_object('schedule_id', p_schedule_id, 'status', 'APPROVED');
end;
$$;

-- fin_create_invoice: status akhir lewat refresh_invoice_status (dokumen ikut dicek)
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
  perform finance.refresh_invoice_status(v_id);
  return (select jsonb_build_object('invoice_id', invoice_id, 'status', status, 'hold_reason', hold_reason,
                                    'total_amount', total_amount)
            from finance.vendor_invoice where invoice_id = v_id);
end;
$$;

-- fin_payments & fin_ap_overview: tambah info kelengkapan dokumen
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
              case when ps.schedule_type = 'ADVANCE' then finance.doc_missing('ADVANCE', ps.schedule_id) end as docs_missing,
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
       select m.*, po."DocNumber" as po_number, po."DocType" as doc_type, v."VendorName" as vendor_name, p.code as project_code
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
    'docTypes', (select coalesce(jsonb_agg(to_jsonb(d) order by d.gate, d.sort_order), '[]'::jsonb) from finance.document_type d where d.is_active),
    'invoices', (select coalesce(jsonb_agg(x order by x.invoice_id desc), '[]'::jsonb) from (
       select i.invoice_id, i.invoice_no, i.invoice_date, i.due_date, i.status, i.subtotal, i.ppn_amount,
              i.pph23_amount, i.total_amount, i.hold_reason, i.approved_by, i.approved_at,
              po."DocNumber" as po_number, v."VendorName" as vendor_name,
              finance.doc_missing('INVOICE', i.invoice_id) as docs_missing,
              (select count(*) from finance.document d where d.invoice_id = i.invoice_id) as docs_uploaded
         from finance.vendor_invoice i
         join public."purchaseOrder" po on po."POID" = i.po_id
         join public.vendor v on v."VendorID" = i.vendor_id) x));
end;
$$;


-- Approve invoice: pesan error menyebut alasan HOLD
create or replace function public.fin_approve_invoice(p_token text, p_invoice_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare who bigint; v_code text; v_status text; v_reason text;
begin
  select p.code into v_code
    from finance.vendor_invoice_line l
    join finance.v_po_detail_project d on d.po_detail_id = l.po_detail_id
    left join operational.projects p on p.id = d.project_id
   where l.invoice_id = p_invoice_id limit 1;
  if v_code is null then
    select p.code into v_code from finance.vendor_invoice i
      join finance.v_po_detail_project d on d.po_id = i.po_id
      left join operational.projects p on p.id = d.project_id
     where i.invoice_id = p_invoice_id limit 1;
  end if;
  who := finance.check_session(p_token, array['fin-ap'], 'AI', v_code);
  perform finance.refresh_invoice_status(p_invoice_id);
  select status, hold_reason into v_status, v_reason from finance.vendor_invoice where invoice_id = p_invoice_id;
  if v_status is distinct from 'MATCHED' then
    raise exception 'Invoice belum bisa di-approve (status %): %', coalesce(v_status,'-'), coalesce(v_reason, 'cek data invoice');
  end if;
  update finance.vendor_invoice
     set status = 'APPROVED', approved_by = finance.employee_name(who), approved_at = now()
   where invoice_id = p_invoice_id;
  return jsonb_build_object('invoice_id', p_invoice_id, 'status', 'APPROVED');
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Hak eksekusi
-- ---------------------------------------------------------------------
revoke execute on function finance.doc_checklist(text, bigint)          from public, anon, authenticated;
revoke execute on function finance.doc_missing(text, bigint)            from public, anon, authenticated;
revoke execute on function finance.refresh_invoice_status(bigint)       from public, anon, authenticated;
revoke execute on function finance.trg_vendor_invoice_validate()        from public, anon, authenticated;
revoke execute on function public.fin_doc_checklist(text, text, bigint) from public;
revoke execute on function public.fin_add_document(text, text, bigint, text, text, text, text, text, text, numeric, date, text) from public;
revoke execute on function public.fin_remove_document(text, bigint)     from public;
grant execute on function public.fin_doc_checklist(text, text, bigint)  to anon, authenticated;
grant execute on function public.fin_add_document(text, text, bigint, text, text, text, text, text, text, numeric, date, text) to anon, authenticated;
grant execute on function public.fin_remove_document(text, bigint)      to anon, authenticated;

-- Backfill: invoice yang belum di-approve ikut dicek ulang dokumennya
select finance.refresh_invoice_status(invoice_id) from finance.vendor_invoice where status in ('RECEIVED','MATCHED','HOLD');
