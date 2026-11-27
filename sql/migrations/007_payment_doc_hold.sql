-- =====================================================================
-- SmartFin BIMA — Migration 007: Pembayaran HOLD kalau dokumen belum lengkap
-- Status : ✅ Sudah dijalankan (27 Nov 2026)
--
-- 1. Jadwal pembayaran (uang muka maupun pelunasan) tidak bisa disetujui APY
--    dan tidak bisa ditandai lunas selama dokumen wajibnya belum lengkap.
--    Pelunasan memakai checklist Gate B invoice-nya, uang muka memakai Gate A.
--    Berlaku juga untuk invoice yang sudah di-approve sebelum migration 006.
-- 2. "Bukti terima di site" juga dianggap ada kalau barang sudah di-hand over
--    ke end user (endUserReceiving), karena hand over pasti setelah terima di site.
-- 3. Kalau bukti terima belum ada, checklist menampilkan pengiriman yang belum
--    dikonfirmasi (no. surat jalan + site tujuan) supaya finance tahu harus tanya siapa.
-- 4. fin_doc_checklist mengembalikan "locked" (dokumen tidak bisa dihapus lagi).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Checklist: hand over dihitung + catatan pengiriman yang belum diterima
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
  v_note    text;
begin
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
          into v_note
          from public.delivery d
         where d."PODetailID" = any(v_lines)
           and not exists (select 1 from public."siteReceiving" sr where sr."DeliveryID" = d."DeliveryID");
        v_note := coalesce(v_note || ', belum dikonfirmasi terima di SMMS', 'Belum dikirim ke site di SMMS');
      end if;
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
                                         'required', v_req, 'ok', jsonb_array_length(v_links) > 0, 'items', v_links,
                                         'note', v_note);
  end loop;
  return v_out;
end;
$$;

-- ---------------------------------------------------------------------
-- 2. Dokumen kurang untuk satu jadwal pembayaran
--    ADVANCE -> Gate A jadwal itu; pelunasan dengan invoice -> Gate B invoice-nya
-- ---------------------------------------------------------------------
create or replace function finance.schedule_docs_missing(p_schedule_id bigint)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
           when s.schedule_type = 'ADVANCE' then finance.doc_missing('ADVANCE', s.schedule_id)
           when s.invoice_id is not null    then finance.doc_missing('INVOICE', s.invoice_id)
         end
    from finance.payment_schedule s
   where s.schedule_id = p_schedule_id;
$$;

-- ---------------------------------------------------------------------
-- 3. API
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
                            'missing', finance.doc_missing(p_gate, p_ref_id),
                            'locked', case when p_gate = 'INVOICE'
                                           then exists (select 1 from finance.vendor_invoice where invoice_id = p_ref_id
                                                          and status in ('APPROVED','PARTIAL_PAID','PAID'))
                                           else exists (select 1 from finance.payment_schedule where schedule_id = p_ref_id
                                                          and status in ('APPROVED','PAID')) end);
end;
$$;

create or replace function public.fin_approve_payment(p_token text, p_schedule_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare who bigint; v_code text; v_docs text;
begin
  select pr.code into v_code
    from finance.payment_schedule ps
    join finance.v_po_detail_project d on d.po_id = ps.po_id
    join operational.projects pr on pr.id = d.project_id
   where ps.schedule_id = p_schedule_id limit 1;
  who := finance.check_session(p_token, array['fin-ap'], 'APY', v_code);
  v_docs := finance.schedule_docs_missing(p_schedule_id);
  if v_docs is not null then
    raise exception 'Pembayaran ditahan (HOLD). Dokumen belum lengkap: %', v_docs;
  end if;
  update finance.payment_schedule
     set status = 'APPROVED', approved_by = finance.employee_name(who), approved_at = now()
   where schedule_id = p_schedule_id and status in ('PLANNED','DUE');
  if not found then raise exception 'Jadwal % tidak bisa disetujui (status bukan Rencana)', p_schedule_id; end if;
  return jsonb_build_object('schedule_id', p_schedule_id, 'status', 'APPROVED');
end;
$$;

create or replace function public.fin_mark_paid(p_token text, p_schedule_id bigint, p_bank_id bigint, p_paid_date date, p_paid_amount numeric, p_payment_ref text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare who bigint; s finance.payment_schedule%rowtype; b finance.bank_account%rowtype; v_amt numeric; v_docs text;
begin
  who := finance.check_session(p_token, array['fin-ap']);
  select * into s from finance.payment_schedule where schedule_id = p_schedule_id for update;
  if s.schedule_id is null then raise exception 'Jadwal % tidak ditemukan', p_schedule_id; end if;
  if s.status <> 'APPROVED' then raise exception 'Pembayaran harus disetujui (APY) dulu sebelum ditandai lunas'; end if;
  v_docs := finance.schedule_docs_missing(p_schedule_id);
  if v_docs is not null then
    raise exception 'Pembayaran ditahan (HOLD). Dokumen belum lengkap: %', v_docs;
  end if;
  select * into b from finance.bank_account where bank_id = p_bank_id and is_active;
  if b.bank_id is null then raise exception 'Pilih rekening bank yang aktif'; end if;
  v_amt := coalesce(p_paid_amount, s.amount);
  if v_amt <= 0 or v_amt > s.amount then
    raise exception 'Nilai bayar harus lebih dari 0 dan tidak melebihi Rp %', s.amount;
  end if;
  if v_amt < s.amount then
    insert into finance.payment_schedule (po_id, invoice_id, schedule_type, term_type, description, due_date,
                                          amount, status, waiting_client, parent_schedule_id)
    values (s.po_id, s.invoice_id, s.schedule_type, s.term_type, 'Sisa: ' || coalesce(s.description,''),
            s.due_date, s.amount - v_amt, 'PLANNED', s.waiting_client, s.schedule_id);
    update finance.payment_schedule set amount = v_amt where schedule_id = s.schedule_id;
  end if;
  update finance.payment_schedule
     set status = 'PAID', bank_id = b.bank_id, paid_from_account = b.coa_code, paid_amount = v_amt,
         paid_at = coalesce(p_paid_date, current_date)::timestamptz, payment_ref = nullif(btrim(p_payment_ref),''),
         paid_by = finance.employee_name(who)
   where schedule_id = s.schedule_id;
  if s.invoice_id is not null then
    update finance.vendor_invoice i
       set status = case when not exists (select 1 from finance.payment_schedule
                                           where invoice_id = i.invoice_id and status not in ('PAID','CANCELLED'))
                         then 'PAID' else 'PARTIAL_PAID' end
     where i.invoice_id = s.invoice_id and i.status in ('APPROVED','PARTIAL_PAID');
  end if;
  return jsonb_build_object('schedule_id', s.schedule_id, 'status', 'PAID', 'paid_amount', v_amt);
end;
$$;

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
              ps.applied_invoice_id, ps.po_id, ps.invoice_id, po."DocNumber" as po_number, v."VendorName" as vendor_name,
              i.invoice_no, b.account_label as bank_label, p.code as project_code,
              case when ps.status in ('PLANNED','DUE','APPROVED') then finance.schedule_docs_missing(ps.schedule_id) end as docs_missing,
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

-- ---------------------------------------------------------------------
-- 4. Hak eksekusi
-- ---------------------------------------------------------------------
revoke execute on function finance.doc_checklist(text, bigint)        from public, anon, authenticated;
revoke execute on function finance.schedule_docs_missing(bigint)      from public, anon, authenticated;
