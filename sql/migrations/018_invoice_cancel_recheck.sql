-- =====================================================================
-- SmartFin BIMA — Migration 018: Batalkan invoice vendor & cek ulang status
-- Status : ✅ Sudah dijalankan (28 Nov 2026)
--
-- 1. FIN-AP bisa MEMBATALKAN invoice yang belum di-approve (RECEIVED / MATCHED / HOLD), alasan wajib.
--    Invoice batal tidak dihitung di 3-way match, jadi PO-nya bisa diinvoice ulang dengan nomor yang sama.
--    Invoice lain di baris PO yang sama dicek ulang otomatis.
-- 2. FIN-AP bisa CEK ULANG status invoice (mis. setelah sisa barang diterima di SMMS).
-- 3. Otomatis: setiap penerimaan barang di SMMS (vendorReceiving) dibuat / diubah / dihapus,
--    invoice terbuka di baris PO itu dicek ulang. Gagal cek tidak pernah menggagalkan transaksi SMMS.
-- 4. Nomor invoice unik per vendor hanya untuk invoice yang tidak batal; pesan duplikat lebih jelas.
-- Invoice yang belum di-approve belum punya jurnal maupun jadwal pelunasan, jadi pembatalan tidak menyentuh jurnal.
-- =====================================================================

alter table finance.vendor_invoice add column if not exists cancelled_by text;
alter table finance.vendor_invoice add column if not exists cancelled_at timestamptz;
alter table finance.vendor_invoice add column if not exists cancel_reason text;

alter table finance.vendor_invoice drop constraint if exists vendor_invoice_vendor_id_invoice_no_key;
create unique index if not exists vendor_invoice_active_no_uq on finance.vendor_invoice (vendor_id, invoice_no) where status <> 'CANCELLED';

-- Cek ulang semua invoice terbuka yang memakai baris PO tertentu
create or replace function finance.refresh_invoices_for_lines(p_po_detail_ids bigint[])
returns int language plpgsql security definer set search_path = '' as $$
declare r record; n int := 0;
begin
  for r in select distinct i.invoice_id
             from finance.vendor_invoice i join finance.vendor_invoice_line l on l.invoice_id = i.invoice_id
            where l.po_detail_id = any(p_po_detail_ids) and i.status in ('RECEIVED','MATCHED','HOLD')
  loop
    perform finance.refresh_invoice_status(r.invoice_id);
    n := n + 1;
  end loop;
  return n;
end; $$;

create or replace function finance.trg_receiving_recheck()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  begin
    perform finance.refresh_invoices_for_lines(array_remove(array[
      (to_jsonb(new)->>'PODetailID')::bigint, (to_jsonb(old)->>'PODetailID')::bigint], null));
  exception when others then
    insert into finance.auto_journal_error (source_table, source_id, source_event, error_message)
    values ('vendorReceiving', coalesce(to_jsonb(new)->>'PODetailID', to_jsonb(old)->>'PODetailID'), 'RECHECK', sqlerrm);
  end;
  return null;
end; $$;
create trigger trg_sfm_receiving_recheck after insert or update or delete on public."vendorReceiving"
  for each row execute function finance.trg_receiving_recheck();

create or replace function public.fin_cancel_invoice(p_token text, p_invoice_id bigint, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare who bigint; i finance.vendor_invoice%rowtype; v_lines bigint[];
begin
  who := finance.check_session(p_token, array['fin-ap']);
  select * into i from finance.vendor_invoice where invoice_id = p_invoice_id for update;
  if i.invoice_id is null then raise exception 'Invoice tidak ditemukan'; end if;
  if i.status = 'CANCELLED' then raise exception 'Invoice ini sudah dibatalkan'; end if;
  if i.status not in ('RECEIVED','MATCHED','HOLD') then
    raise exception 'Invoice berstatus % tidak bisa dibatalkan (sudah di-approve). Koreksi lewat jurnal penyesuaian.', i.status;
  end if;
  if coalesce(btrim(p_reason),'') = '' then raise exception 'Alasan pembatalan wajib diisi'; end if;
  update finance.vendor_invoice
     set status = 'CANCELLED', cancel_reason = btrim(p_reason), cancelled_by = finance.employee_name(who), cancelled_at = now()
   where invoice_id = i.invoice_id;
  select array_agg(distinct po_detail_id) into v_lines from finance.vendor_invoice_line where invoice_id = i.invoice_id and po_detail_id is not null;
  if v_lines is not null then perform finance.refresh_invoices_for_lines(v_lines); end if;
  return jsonb_build_object('invoice_id', i.invoice_id, 'status', 'CANCELLED');
end; $$;

create or replace function public.fin_recheck_invoice(p_token text, p_invoice_id bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare who bigint; v_lines bigint[];
begin
  who := finance.check_session(p_token, array['fin-ap']);
  if not exists (select 1 from finance.vendor_invoice where invoice_id = p_invoice_id) then raise exception 'Invoice tidak ditemukan'; end if;
  select array_agg(distinct po_detail_id) into v_lines from finance.vendor_invoice_line where invoice_id = p_invoice_id and po_detail_id is not null;
  perform finance.refresh_invoice_status(p_invoice_id);
  if v_lines is not null then perform finance.refresh_invoices_for_lines(v_lines); end if;
  return (select jsonb_build_object('invoice_id', invoice_id, 'status', status, 'hold_reason', hold_reason)
            from finance.vendor_invoice where invoice_id = p_invoice_id);
end; $$;

-- Pesan nomor invoice ganda yang jelas
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
  if coalesce(btrim(p_invoice_no),'') = '' then raise exception 'No. invoice wajib diisi'; end if;
  if exists (select 1 from finance.vendor_invoice where vendor_id = v_vendor and invoice_no = btrim(p_invoice_no) and status <> 'CANCELLED') then
    raise exception 'Invoice nomor % dari vendor ini sudah tercatat. Batalkan dulu yang lama kalau ingin input ulang.', btrim(p_invoice_no);
  end if;
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

-- Daftar invoice ikut mengirim info pembatalan
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
              i.cancelled_by, i.cancelled_at, i.cancel_reason, i.created_by,
              po."DocNumber" as po_number, v."VendorName" as vendor_name,
              finance.doc_missing('INVOICE', i.invoice_id) as docs_missing,
              (select count(*) from finance.document d where d.invoice_id = i.invoice_id) as docs_uploaded
         from finance.vendor_invoice i
         join public."purchaseOrder" po on po."POID" = i.po_id
         join public.vendor v on v."VendorID" = i.vendor_id) x));
end;
$$;

revoke execute on function finance.refresh_invoices_for_lines(bigint[]) from public, anon, authenticated;
revoke execute on function finance.trg_receiving_recheck() from public, anon, authenticated;
revoke execute on function public.fin_cancel_invoice(text, bigint, text) from public;
revoke execute on function public.fin_recheck_invoice(text, bigint) from public;
grant execute on function public.fin_cancel_invoice(text, bigint, text) to anon, authenticated;
grant execute on function public.fin_recheck_invoice(text, bigint) to anon, authenticated;
