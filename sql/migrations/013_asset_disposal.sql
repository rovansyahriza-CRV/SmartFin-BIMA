-- =====================================================================
-- SmartFin BIMA — Migration 013: Pelepasan Aset Tetap (dijual / dihapus)
-- Status : ✅ Sudah dijalankan (27 Nov 2026)
--
-- PIC FIN-AST mengajukan pelepasan dari menu Aset Tetap, Author PJ (per proyek aset) menyetujui.
-- Saat disetujui jurnal langsung POSTED dan status aset menjadi DIJUAL / DIHAPUS
-- (tidak disusutkan lagi, tidak bisa diedit).
--
-- Syarat: penyusutan sudah dijalankan sampai bulan sebelum tanggal pelepasan
-- (kalau aset masih AKTIF), supaya nilai buku benar.
--
--   SALE      Dr Bank (harga jual + PPN) + Dr 1-2900 Akumulasi Penyusutan
--             Cr 1-2100 Aset Tetap (harga perolehan) + Cr 2-1500 PPN Keluaran (kalau dipungut)
--             selisih harga jual (tanpa PPN) vs nilai buku: Cr 4-9200 Laba / Dr 6-1500 Rugi Pelepasan Aset
--   WRITE_OFF Dr 1-2900 Akumulasi + Dr 6-1500 Rugi (nilai buku) / Cr 1-2100 Aset Tetap
-- =====================================================================

insert into finance.coa (account_code, account_name, account_type, is_postable, notes) values
  ('4-9200', 'Laba Pelepasan Aset Tetap', 'REVENUE', true, 'Harga jual di atas nilai buku'),
  ('6-1500', 'Rugi Pelepasan Aset Tetap', 'EXPENSE', true, 'Harga jual di bawah nilai buku / aset dihapus')
on conflict (account_code) do nothing;

create table finance.asset_disposal (
  disposal_id    bigint generated always as identity primary key,
  asset_id       bigint not null references finance.fixed_asset(asset_id),
  kind           text not null check (kind in ('SALE','WRITE_OFF')),
  disposal_date  date not null,
  proceeds       numeric(18,2) not null default 0 check (proceeds >= 0),   -- harga jual tanpa PPN
  ppn_amount     numeric(18,2) not null default 0 check (ppn_amount >= 0),
  bank_id        bigint references finance.bank_account(bank_id),
  buyer          text,
  reason         text not null,
  cost           numeric(18,2),      -- dicatat saat disetujui
  accumulated    numeric(18,2),
  book_value     numeric(18,2),
  gain_loss      numeric(18,2),      -- + laba / − rugi
  status         text not null default 'PLANNED' check (status in ('PLANNED','APPROVED','REJECTED')),
  requested_by   text, requested_by_id bigint,
  approved_by    text, approved_at timestamptz, reject_reason text,
  created_at     timestamptz not null default now(),
  check (kind = 'SALE' or (proceeds = 0 and ppn_amount = 0)),
  check (kind = 'WRITE_OFF' or bank_id is not null)
);
-- satu pelepasan aktif per aset
create unique index asset_disposal_one on finance.asset_disposal (asset_id) where status <> 'REJECTED';
alter table finance.asset_disposal enable row level security;

create or replace function finance.asset_accumulated(p_asset_id bigint)
returns numeric language sql stable security definer set search_path = '' as $$
  select coalesce(sum(amount), 0) from finance.asset_depreciation where asset_id = p_asset_id;
$$;

create or replace function finance.journal_asset_disposal(p_disposal_id bigint)
returns void language plpgsql security definer set search_path = '' as $$
declare d record; v_lines jsonb := '[]'::jsonb; v_memo text;
begin
  select x.*, a.asset_code, a.item_description, a.project_id, b.coa_code as bank_coa
    into d
    from finance.asset_disposal x
    join finance.fixed_asset a on a.asset_id = x.asset_id
    left join finance.bank_account b on b.bank_id = x.bank_id
   where x.disposal_id = p_disposal_id;
  if d.disposal_id is null then return; end if;
  v_memo := d.asset_code || case d.kind when 'SALE' then ' dijual' else ' dihapus' end;
  if d.status = 'APPROVED' then
    v_lines := jsonb_build_array(
      jsonb_build_object('account', '1-2900', 'debit', d.accumulated, 'project_id', d.project_id, 'memo', v_memo),
      jsonb_build_object('account', '1-2100', 'credit', d.cost, 'project_id', d.project_id, 'memo', v_memo));
    if d.kind = 'SALE' then
      v_lines := v_lines || jsonb_build_array(
        jsonb_build_object('account', d.bank_coa, 'debit', d.proceeds + d.ppn_amount, 'project_id', d.project_id, 'memo', v_memo || coalesce(' ke ' || d.buyer, '')),
        jsonb_build_object('account', '2-1500', 'credit', d.ppn_amount, 'project_id', d.project_id, 'memo', v_memo || ' PPN'));
    end if;
    if d.gain_loss > 0 then
      v_lines := v_lines || jsonb_build_array(jsonb_build_object('account', '4-9200', 'credit', d.gain_loss, 'project_id', d.project_id, 'memo', v_memo || ' laba'));
    elsif d.gain_loss < 0 then
      v_lines := v_lines || jsonb_build_array(jsonb_build_object('account', '6-1500', 'debit', -d.gain_loss, 'project_id', d.project_id, 'memo', v_memo || ' rugi'));
    end if;
  end if;
  perform finance.sync_auto_journal('ASSET', 'asset_disposal', p_disposal_id::text, 'APPROVED', d.disposal_date, d.project_id,
          'Pelepasan aset ' || d.asset_code || ' - ' || coalesce(d.item_description, '') || ' (' ||
          case d.kind when 'SALE' then 'dijual' else 'dihapus' end || ')', v_lines);
end; $$;

create or replace function finance.trg_asset_disposal_journal()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  begin
    perform finance.journal_asset_disposal(new.disposal_id);
  exception when others then
    insert into finance.auto_journal_error (source_table, source_id, source_event, error_message)
    values ('asset_disposal', new.disposal_id::text, tg_op, sqlerrm);
  end;
  return null;
end; $$;
create trigger trg_sfm_asset_disposal after insert or update on finance.asset_disposal
  for each row execute function finance.trg_asset_disposal_journal();

-- Penyusutan sudah lengkap sampai bulan sebelum tanggal pelepasan?
create or replace function finance.asset_dep_gap(p_asset_id bigint, p_date date)
returns date language sql stable security definer set search_path = '' as $$
  -- bulan pertama yang belum disusutkan (null = sudah lengkap / tidak perlu)
  select m::date
    from finance.fixed_asset a,
         generate_series(a.depreciation_start, (date_trunc('month', p_date) - interval '1 month')::date, interval '1 month') m
   where a.asset_id = p_asset_id and a.status = 'AKTIF' and a.depreciation_start is not null
     and not exists (select 1 from finance.asset_depreciation ad where ad.asset_id = a.asset_id and ad.period = m::date)
   order by m limit 1;
$$;

-- API -------------------------------------------------------------------
create or replace function public.fin_asset_disposals(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform finance.check_session(p_token, array['fin-ast']);
  return jsonb_build_object(
    'disposals', (select coalesce(jsonb_agg(jsonb_build_object(
                     'disposal_id', x.disposal_id, 'asset_id', x.asset_id, 'asset_code', a.asset_code, 'item', a.item_description,
                     'project_code', p.code, 'kind', x.kind, 'disposal_date', x.disposal_date, 'proceeds', x.proceeds, 'ppn_amount', x.ppn_amount,
                     'bank_label', b.account_label, 'buyer', x.buyer, 'reason', x.reason, 'status', x.status,
                     'cost', coalesce(x.cost, a.acquisition_cost),
                     'accumulated', coalesce(x.accumulated, finance.asset_accumulated(a.asset_id)),
                     'book_value', coalesce(x.book_value, a.acquisition_cost - finance.asset_accumulated(a.asset_id)),
                     'gain_loss', coalesce(x.gain_loss, case when x.kind = 'SALE' then x.proceeds else 0 end - (a.acquisition_cost - finance.asset_accumulated(a.asset_id))),
                     'dep_gap', case when x.status = 'PLANNED' then finance.asset_dep_gap(a.asset_id, x.disposal_date) end,
                     'requested_by', x.requested_by, 'approved_by', x.approved_by, 'reject_reason', x.reject_reason)
                   order by case x.status when 'PLANNED' then 0 else 1 end, x.disposal_date desc, x.disposal_id desc), '[]'::jsonb)
                   from finance.asset_disposal x
                   join finance.fixed_asset a on a.asset_id = x.asset_id
                   left join operational.projects p on p.id = a.project_id
                   left join finance.bank_account b on b.bank_id = x.bank_id),
    'banks', (select coalesce(jsonb_agg(jsonb_build_object('bank_id', bank_id, 'label', account_label) order by bank_name), '[]'::jsonb)
                from finance.bank_account where is_active));
end; $$;

create or replace function public.fin_save_asset_disposal(
  p_token text, p_asset_id bigint, p_kind text, p_disposal_date date, p_proceeds numeric, p_ppn_amount numeric,
  p_bank_id bigint, p_buyer text, p_reason text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare who bigint; a finance.fixed_asset%rowtype; v_gap date; v_id bigint;
begin
  who := finance.check_session(p_token, array['fin-ast']);
  select * into a from finance.fixed_asset where asset_id = p_asset_id for update;
  if a.asset_id is null then raise exception 'Aset tidak ditemukan'; end if;
  if a.status in ('DIJUAL','DIHAPUS') then raise exception 'Aset ini sudah dilepas'; end if;
  if exists (select 1 from finance.asset_disposal where asset_id = p_asset_id and status = 'PLANNED') then
    raise exception 'Aset ini sudah punya pengajuan pelepasan yang menunggu PJ';
  end if;
  if p_kind not in ('SALE','WRITE_OFF') then raise exception 'Jenis pelepasan tidak dikenal'; end if;
  if p_disposal_date is null or p_disposal_date > current_date or p_disposal_date < a.acquisition_date then
    raise exception 'Tanggal pelepasan tidak valid';
  end if;
  if coalesce(btrim(p_reason),'') = '' then raise exception 'Alasan / keterangan wajib diisi'; end if;
  if p_kind = 'SALE' then
    if coalesce(p_proceeds, 0) <= 0 then raise exception 'Isi harga jual'; end if;
    if coalesce(p_ppn_amount, 0) < 0 then raise exception 'PPN tidak valid'; end if;
    if not exists (select 1 from finance.bank_account where bank_id = p_bank_id and is_active) then raise exception 'Pilih rekening penerima uang'; end if;
  end if;
  v_gap := finance.asset_dep_gap(p_asset_id, p_disposal_date);
  if v_gap is not null then
    raise exception 'Penyusutan aset ini belum dijalankan untuk %. Jalankan penyusutan sampai bulan sebelum tanggal pelepasan dulu.', to_char(v_gap, 'MM/YYYY');
  end if;
  insert into finance.asset_disposal (asset_id, kind, disposal_date, proceeds, ppn_amount, bank_id, buyer, reason, requested_by, requested_by_id)
  values (p_asset_id, p_kind, p_disposal_date,
          case when p_kind = 'SALE' then round(p_proceeds, 2) else 0 end,
          case when p_kind = 'SALE' then round(coalesce(p_ppn_amount, 0), 2) else 0 end,
          case when p_kind = 'SALE' then p_bank_id end,
          nullif(btrim(p_buyer),''), btrim(p_reason), finance.employee_name(who), who)
  returning disposal_id into v_id;
  return jsonb_build_object('disposal_id', v_id, 'status', 'PLANNED');
end; $$;

create or replace function public.fin_decide_asset_disposal(p_token text, p_disposal_id bigint, p_approve boolean, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare who bigint; x finance.asset_disposal%rowtype; a finance.fixed_asset%rowtype; v_code text; v_acc numeric; v_gap date; v_j bigint;
begin
  select * into x from finance.asset_disposal where disposal_id = p_disposal_id for update;
  if x.disposal_id is null then raise exception 'Pengajuan pelepasan tidak ditemukan'; end if;
  select * into a from finance.fixed_asset where asset_id = x.asset_id for update;
  select code into v_code from operational.projects where id = a.project_id;
  who := finance.check_session(p_token, array['fin-ast','fin-jv'], 'PJ', v_code);
  if x.status <> 'PLANNED' then raise exception 'Pengajuan ini sudah diproses (status %)', x.status; end if;
  if coalesce(p_approve, false) then
    v_gap := finance.asset_dep_gap(a.asset_id, x.disposal_date);
    if v_gap is not null then
      raise exception 'Penyusutan aset ini belum dijalankan untuk %. Jalankan penyusutan dulu.', to_char(v_gap, 'MM/YYYY');
    end if;
    if exists (select 1 from finance.asset_depreciation where asset_id = a.asset_id and period >= date_trunc('month', x.disposal_date)::date) then
      raise exception 'Sudah ada penyusutan di bulan pelepasan atau sesudahnya. Hubungi admin untuk koreksi penyusutan.';
    end if;
    v_acc := finance.asset_accumulated(a.asset_id);
    update finance.asset_disposal
       set cost = a.acquisition_cost, accumulated = v_acc, book_value = a.acquisition_cost - v_acc,
           gain_loss = proceeds - (a.acquisition_cost - v_acc),
           status = 'APPROVED', approved_by = finance.employee_name(who), approved_at = now()
     where disposal_id = x.disposal_id;
    update finance.fixed_asset
       set status = case x.kind when 'SALE' then 'DIJUAL' else 'DIHAPUS' end,
           notes = concat_ws(' | ', nullif(notes, ''), case x.kind when 'SALE' then 'Dijual ' else 'Dihapus ' end || to_char(x.disposal_date, 'DD/MM/YYYY')),
           updated_by = finance.employee_name(who)
     where asset_id = a.asset_id;
    select journal_id into v_j from finance.journal where source_table = 'asset_disposal' and source_id = x.disposal_id::text and source_event = 'APPROVED';
    if v_j is null then raise exception 'Jurnal pelepasan gagal dibuat, cek log error jurnal'; end if;
    perform finance.post_journal(v_j, finance.employee_name(who));
  else
    if coalesce(btrim(p_reason),'') = '' then raise exception 'Alasan penolakan wajib diisi'; end if;
    update finance.asset_disposal set status = 'REJECTED', reject_reason = btrim(p_reason),
           approved_by = finance.employee_name(who), approved_at = now() where disposal_id = x.disposal_id;
  end if;
  return jsonb_build_object('disposal_id', x.disposal_id, 'status', case when p_approve then 'APPROVED' else 'REJECTED' end);
end; $$;

-- Aset yang sudah dilepas tidak bisa diedit lagi
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
  if exists (select 1 from finance.fixed_asset where asset_id = p_asset_id and status in ('DIJUAL','DIHAPUS')) then
    raise exception 'Aset ini sudah dilepas dan tidak bisa diubah';
  end if;
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

revoke execute on function finance.asset_accumulated(bigint)         from public, anon, authenticated;
revoke execute on function finance.journal_asset_disposal(bigint)    from public, anon, authenticated;
revoke execute on function finance.trg_asset_disposal_journal()      from public, anon, authenticated;
revoke execute on function finance.asset_dep_gap(bigint, date)       from public, anon, authenticated;
revoke execute on function public.fin_asset_disposals(text) from public;
revoke execute on function public.fin_save_asset_disposal(text, bigint, text, date, numeric, numeric, bigint, text, text) from public;
revoke execute on function public.fin_decide_asset_disposal(text, bigint, boolean, text) from public;
grant execute on function public.fin_asset_disposals(text) to anon, authenticated;
grant execute on function public.fin_save_asset_disposal(text, bigint, text, date, numeric, numeric, bigint, text, text) to anon, authenticated;
grant execute on function public.fin_decide_asset_disposal(text, bigint, boolean, text) to anon, authenticated;
