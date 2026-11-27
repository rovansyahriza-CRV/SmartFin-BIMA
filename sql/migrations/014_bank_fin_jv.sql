-- =====================================================================
-- SmartFin BIMA — Migration 014: Menu Bank juga untuk FIN-JV (approver PJ)
-- Status : ⏳ Belum dijalankan
--
-- Sebelumnya menu Bank hanya untuk FIN-AP, jadi approver PJ harus punya FIN-AP juga.
-- Sekarang pemegang FIN-JV bisa membuka menu Bank (lihat saldo, mutasi, rekonsiliasi) dan,
-- kalau punya Author PJ, menyetujui saldo awal / mutasi / rekonsiliasi.
-- Input rekening, saldo awal, mutasi, dan rekonsiliasi tetap hanya FIN-AP.
-- (fin_decide_bank_txn dan fin_approve_recon sudah menerima FIN-JV sejak migration 009.)
-- =====================================================================

create or replace function public.fin_bank_overview(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform finance.check_session(p_token, array['fin-ap','fin-jv']);
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

revoke execute on function public.fin_bank_overview(text) from public;
grant execute on function public.fin_bank_overview(text) to anon, authenticated;
