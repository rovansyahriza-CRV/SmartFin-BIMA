// =====================================================================
// SmartFin BIMA — frontend
// Semua data lewat fungsi public.fin_* di Supabase. Hak akses (PIC/Author)
// dicek ulang di server setiap panggilan; pengecekan di sini cuma untuk tampilan.
// Hanya publishable key yang boleh ada di file ini.
// =====================================================================
const SUPABASE_URL = 'https://nhmpwjriextmbotmvvbu.supabase.co';
const SUPABASE_KEY = 'sb_publishable_XNqLw7iz873TtrLn9ag8dQ_AkL2rImz';
const SESSION_KEY = 'smartfin_session';

let session = null;          // {token, id, name, pic[], author[], expiresAt}
const cache = {};            // data terakhir per halaman

// ---------- util ----------
const $ = (id) => document.getElementById(id);
const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const num = (v) => Number(v || 0);
const rp = (v) => 'Rp ' + num(v).toLocaleString('id-ID', { maximumFractionDigits: 2 });
const rpShort = (v) => {
  const n = num(v), a = Math.abs(n);
  if (a >= 1e9) return 'Rp ' + (n / 1e9).toLocaleString('id-ID', { maximumFractionDigits: 2 }) + ' M';
  if (a >= 1e6) return 'Rp ' + (n / 1e6).toLocaleString('id-ID', { maximumFractionDigits: 2 }) + ' jt';
  return rp(n);
};
const tgl = (v) => v ? new Date(v).toLocaleDateString('id-ID', { day: '2-digit', month: 'short', year: 'numeric' }) : '-';
const parseNum = (s) => Number(String(s || '').replace(/\./g, '').replace(',', '.')) || 0;
const today = () => new Date().toISOString().slice(0, 10);

function toast(msg, isErr) {
  const el = document.createElement('div');
  el.className = 't' + (isErr ? ' err' : '');
  el.textContent = msg;
  $('toast').appendChild(el);
  setTimeout(() => el.remove(), isErr ? 7000 : 4000);
}

async function rpc(fn, params = {}) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: { apikey: SUPABASE_KEY, Authorization: `Bearer ${SUPABASE_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(params)
  });
  const text = await res.text();
  const data = text ? JSON.parse(text) : null;
  if (!res.ok) {
    const err = new Error((data && (data.message || data.hint)) || `Gagal memanggil ${fn}`);
    err.code = data && data.code;
    if (err.code === '28000') { logout(true); }
    throw err;
  }
  return data;
}
const api = (fn, params = {}) => rpc(fn, { p_token: session.token, ...params });

const hasPic = (list) => list.split(',').some((p) => session.pic.includes(p));
const hasAuthor = (code, projectCode) => {
  const c = code.toLowerCase();
  return session.author.includes(c) || (projectCode && session.author.includes(`${c}-${String(projectCode).toLowerCase()}`));
};

function statusBadge(s) {
  const ok = ['COCOK', 'MATCHED', 'APPROVED', 'POSTED', 'PAID', 'AKTIF'];
  const warn = ['SELISIH_HARGA', 'SELISIH_QTY', 'MELEBIHI_PO', 'HOLD', 'PERLU_DILENGKAPI', 'PERLU_DICEK', 'VOID'];
  const cls = ok.includes(s) ? 'ok' : warn.includes(s) ? 'warn' : '';
  return `<span class="badge ${cls}">${esc(String(s || '-').replace(/_/g, ' '))}</span>`;
}
const emptyRow = (cols, text) => `<tr><td colspan="${cols}" class="empty">${esc(text)}</td></tr>`;

// ---------- login ----------
async function loadAccounts() {
  try {
    const rows = await rpc('fin_login_accounts');
    $('loginUser').innerHTML = '<option value="">Pilih nama…</option>' +
      (rows || []).map((r) => `<option value="${esc(r.id)}">${esc(r.nama)}</option>`).join('');
    if (!rows || !rows.length) $('loginMsg').textContent = 'Belum ada akun dengan akses SmartFin (PIC FIN / FIN-ALL / ALL).';
  } catch (e) {
    $('loginUser').innerHTML = '<option value="">Gagal memuat akun</option>';
    $('loginMsg').textContent = 'Tidak bisa terhubung ke server: ' + e.message;
  }
}

$('loginForm').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  $('loginMsg').textContent = '';
  $('loginBtn').disabled = true;
  try {
    const r = await rpc('fin_login', { p_id: Number($('loginUser').value), p_password: $('loginPass').value });
    if (!r || r.error) throw new Error((r && r.error) || 'Login gagal');
    session = r;
    sessionStorage.setItem(SESSION_KEY, JSON.stringify(r));
    $('loginPass').value = '';
    startApp();
  } catch (e) {
    $('loginMsg').textContent = e.message;
  } finally {
    $('loginBtn').disabled = false;
  }
});

function logout(expired) {
  if (session && !expired) rpc('fin_logout', { p_token: session.token }).catch(() => {});
  session = null;
  sessionStorage.removeItem(SESSION_KEY);
  $('appView').hidden = true;
  $('loginView').hidden = false;
  if (expired) $('loginMsg').textContent = 'Sesi berakhir. Silakan login kembali.';
  loadAccounts();
}
$('logoutBtn').addEventListener('click', () => logout(false));

// ---------- navigasi ----------
function startApp() {
  $('loginView').hidden = true;
  $('appView').hidden = false;
  $('userName').textContent = session.name;
  document.querySelectorAll('#nav a').forEach((a) => { a.hidden = !hasPic(a.dataset.pic); });
  $('newInvoiceBtn').hidden = !hasPic('fin-ap');
  go(location.hash.slice(1) || 'dashboard');
}

function go(page) {
  const link = document.querySelector(`#nav a[data-page="${page}"]`);
  if (!link || link.hidden) page = 'dashboard';
  document.querySelectorAll('.page').forEach((s) => { s.hidden = s.id !== 'page-' + page; });
  document.querySelectorAll('#nav a').forEach((a) => a.classList.toggle('active', a.dataset.page === page));
  loaders[page]();
}
window.addEventListener('hashchange', () => session && go(location.hash.slice(1)));
document.addEventListener('click', (ev) => {
  const b = ev.target.closest('[data-refresh]');
  if (b) loaders[b.dataset.refresh]();
});

// ---------- dashboard ----------
async function loadDashboard() {
  try {
    const d = await api('fin_dashboard');
    cache.dashboard = d;
    const k = d.kpi;
    $('dashTime').textContent = 'Diperbarui ' + new Date(d.generatedAt).toLocaleString('id-ID');
    const kpi = (label, val, sub, alert) => `<div class="kpi${alert ? ' alert' : ''}"><div class="k-label">${esc(label)}</div><div class="k-val">${esc(val)}</div><div class="k-sub">${esc(sub)}</div></div>`;
    $('kpis').innerHTML =
      kpi('Hutang belum ditagih vendor', rpShort(k.hutangBelumDitagih), 'Barang sudah diterima, invoice belum masuk') +
      kpi('Hutang usaha (invoice approved)', rpShort(k.hutangUsaha), `Jatuh tempo ≤ 7 hari: ${rpShort(k.jatuhTempo7Hari)}`, num(k.jatuhTempo7Hari) > 0) +
      kpi('Komitmen PO vs Budget', rpShort(k.komitmenTotal), num(k.budgetTotal) > 0 ? `Budget ${rpShort(k.budgetTotal)}` : 'RAB belum diinput', num(k.budgetTotal) === 0) +
      kpi('Realisasi biaya proyek', rpShort(k.realisasiTotal), 'Material diserahkan ke end user') +
      kpi('Jurnal draft', String(k.jurnalDraft), k.errorJurnal > 0 ? `${k.errorJurnal} error jurnal otomatis` : 'Menunggu posting (PJ)', k.errorJurnal > 0) +
      kpi('Aset perlu dilengkapi', String(k.asetPerluDilengkapi), 'Isi kategori & umur di menu Aset', k.asetPerluDilengkapi > 0);

    $('dashBva').innerHTML = '<tr><th>Proyek</th><th class="num">Budget</th><th class="num">Komitmen</th><th class="num">Realisasi</th><th>Terpakai</th></tr>' +
      (d.budgetVsActual.length ? d.budgetVsActual.map((b) => bvaRow(b)).join('') : emptyRow(5, 'Belum ada data'));

    $('dashDraft').innerHTML = '<tr><th>Tanggal</th><th>Sumber</th><th>Keterangan</th><th class="num">Nilai</th></tr>' +
      (d.draftJournals.length ? d.draftJournals.map((j) => `<tr><td>${tgl(j.journal_date)}</td><td><span class="badge src">${esc(j.source_system)}</span></td><td>${esc(j.description)}</td><td class="num">${rp(j.amount)}</td></tr>`).join('') : emptyRow(4, 'Tidak ada jurnal draft'));

    const m = d.matchSummary || {};
    $('dashMatch').innerHTML = Object.keys(m).length
      ? Object.entries(m).map(([s, n]) => `${statusBadge(s)} <b>${esc(n)}</b>`).join(' &nbsp; ')
      : '<span class="muted">Belum ada PO</span>';
  } catch (e) { toast(e.message, true); }
}

function bvaRow(b) {
  const budget = num(b.budget_amount), actual = num(b.actual_amount);
  const pct = budget > 0 ? Math.round(actual / budget * 100) : null;
  const bar = pct === null ? '<span class="muted small">RAB belum ada</span>'
    : `<div class="row-gap"><div class="bar${pct > 85 ? ' over' : ''}" style="flex:1"><div style="width:${Math.min(pct, 100)}%"></div></div><b class="small">${pct}%</b></div>`;
  return `<tr><td><b>${esc(b.code)}</b> ${esc(b.name)}</td><td class="num">${rpShort(budget)}</td><td class="num">${rpShort(b.committed_amount)}</td><td class="num">${rpShort(actual)}</td><td>${bar}</td></tr>`;
}

// ---------- jurnal ----------
async function loadJurnal() {
  try {
    const rows = await api('fin_journals', { p_status: $('jvStatus').value, p_limit: 200 });
    $('jvList').innerHTML = rows.length ? rows.map((j) => {
      const canPost = j.status === 'DRAFT' && hasAuthor('PJ', j.project_code);
      const lines = (j.lines || []).map((l) => `<tr><td>${esc(l.account)} ${esc(l.accountName)}</td><td>${esc(l.memo)}</td><td class="num">${num(l.debit) ? rp(l.debit) : ''}</td><td class="num">${num(l.credit) ? rp(l.credit) : ''}</td></tr>`).join('');
      return `<div class="jv">
        <div class="jv-head">
          <div><div class="jv-title">${esc(j.description)}</div>
          <div class="jv-meta">${tgl(j.journal_date)} · <span class="badge src">${esc(j.source_system)}</span> ${j.project_code ? '· Proyek ' + esc(j.project_code) : ''} ${j.journal_no ? '· ' + esc(j.journal_no) : ''} ${j.posted_by ? '· diposting ' + esc(j.posted_by) : ''}</div></div>
          <div class="row-gap">${statusBadge(j.status)}${canPost ? `<button type="button" class="btn primary small" data-post="${esc(j.journal_id)}">Posting</button>` : ''}</div>
        </div>
        <div class="scroll"><table><tr><th>Akun</th><th>Memo</th><th class="num">Debit</th><th class="num">Kredit</th></tr>${lines}</table></div>
      </div>`;
    }).join('') : '<div class="card empty">Tidak ada jurnal untuk filter ini.</div>';
  } catch (e) { toast(e.message, true); }
}
$('jvStatus').addEventListener('change', loadJurnal);
$('jvList').addEventListener('click', async (ev) => {
  const b = ev.target.closest('[data-post]');
  if (!b) return;
  if (!confirm('Posting jurnal ini? Jurnal yang sudah POSTED tidak bisa diubah, koreksi lewat jurnal penyesuaian.')) return;
  b.disabled = true;
  try {
    const r = await api('fin_post_journal', { p_journal_id: Number(b.dataset.post) });
    toast(`Jurnal ${r.journal_no} berhasil diposting`);
    loadJurnal();
  } catch (e) { toast(e.message, true); b.disabled = false; }
});

// ---------- AP ----------
async function loadAP() {
  try {
    const d = await api('fin_ap_overview');
    cache.ap = d;
    $('invTable').innerHTML = '<tr><th>No. Invoice</th><th>Vendor / PO</th><th>Tanggal</th><th>Jatuh tempo</th><th class="num">Total</th><th>Status</th><th></th></tr>' +
      (d.invoices.length ? d.invoices.map((i) => {
        const canApprove = i.status === 'MATCHED' && session.author.some((a) => a === 'ai' || a.startsWith('ai-'));
        return `<tr><td><b>${esc(i.invoice_no)}</b></td><td>${esc(i.vendor_name)}<br><span class="muted">${esc(i.po_number)}</span></td><td>${tgl(i.invoice_date)}</td><td>${tgl(i.due_date)}</td><td class="num">${rp(i.total_amount)}</td>
          <td>${statusBadge(i.status)}${i.hold_reason ? `<div class="small muted">${esc(i.hold_reason)}</div>` : ''}${i.approved_by ? `<div class="small muted">oleh ${esc(i.approved_by)}</div>` : ''}</td>
          <td>${canApprove ? `<button type="button" class="btn primary small" data-approve-inv="${esc(i.invoice_id)}">Approve</button>` : ''}</td></tr>`;
      }).join('') : emptyRow(7, 'Belum ada invoice'));

    $('poTable').innerHTML = '<tr><th>PO</th><th>Vendor</th><th>Proyek</th><th>Item</th><th class="num">Qty PO</th><th class="num">Diterima</th><th class="num">Ditagih</th><th class="num">Harga</th><th>Status</th></tr>' +
      (d.poLines.length ? d.poLines.map((l) => `<tr><td>${esc(l.po_number)}</td><td>${esc(l.vendor_name)}</td><td>${esc(l.project_code || '-')}</td><td>${esc(l.item_description)}</td>
        <td class="num">${esc(num(l.po_qty))}</td><td class="num">${esc(num(l.qty_received))}</td><td class="num">${esc(num(l.qty_invoiced))}</td><td class="num">${rp(l.po_unit_price)}</td><td>${statusBadge(l.match_status)}</td></tr>`).join('') : emptyRow(9, 'Belum ada PO'));
  } catch (e) { toast(e.message, true); }
}
$('invTable').addEventListener('click', async (ev) => {
  const b = ev.target.closest('[data-approve-inv]');
  if (!b) return;
  if (!confirm('Approve invoice ini? Hutang usaha akan diakui dan jurnalnya dibuat otomatis.')) return;
  b.disabled = true;
  try {
    await api('fin_approve_invoice', { p_invoice_id: Number(b.dataset.approveInv) });
    toast('Invoice di-approve');
    loadAP();
  } catch (e) { toast(e.message, true); b.disabled = false; }
});

// form invoice
function openInvoice() {
  const lines = (cache.ap && cache.ap.poLines) || [];
  const pos = {};
  lines.forEach((l) => { if (num(l.qty_received) > num(l.qty_invoiced)) pos[l.po_id] = `${l.po_number} — ${l.vendor_name}`; });
  if (!Object.keys(pos).length) { toast('Tidak ada PO dengan barang diterima yang belum ditagih.', true); return; }
  $('iPo').innerHTML = Object.entries(pos).map(([id, label]) => `<option value="${esc(id)}">${esc(label)}</option>`).join('');
  $('invForm').reset();
  $('iDate').value = today();
  $('invMsg').textContent = '';
  renderInvoiceLines();
  $('invDialog').showModal();
}
function renderInvoiceLines() {
  const poId = Number($('iPo').value);
  const lines = cache.ap.poLines.filter((l) => l.po_id === poId);
  $('iLines').innerHTML = '<tr><th>Item</th><th class="num">Diterima</th><th class="num">Sudah ditagih</th><th>Qty invoice</th><th>Harga satuan</th></tr>' +
    lines.map((l) => {
      const open = Math.max(num(l.qty_received) - num(l.qty_invoiced), 0);
      return `<tr data-line="${esc(l.po_detail_id)}"><td>${esc(l.item_description)}<div class="small muted">Harga PO ${rp(l.po_unit_price)}</div></td><td class="num">${esc(num(l.qty_received))}</td><td class="num">${esc(num(l.qty_invoiced))}</td>
        <td><input class="iq" inputmode="decimal" value="${esc(open)}" aria-label="Qty invoice"></td><td><input class="ip" inputmode="numeric" value="${esc(num(l.po_unit_price))}" aria-label="Harga satuan"></td></tr>`;
    }).join('');
  calcInvoice();
}
function invoiceLines() {
  return [...$('iLines').querySelectorAll('tr[data-line]')].map((tr) => ({
    po_detail_id: Number(tr.dataset.line),
    qty: parseNum(tr.querySelector('.iq').value),
    unit_price: parseNum(tr.querySelector('.ip').value)
  })).filter((l) => l.qty > 0);
}
function calcInvoice() {
  const sub = invoiceLines().reduce((s, l) => s + l.qty * l.unit_price, 0);
  const ppn = $('iPpn').checked ? Math.round(sub * 0.11) : 0;
  $('iTotal').textContent = rp(sub + ppn - parseNum($('iPph').value));
}
$('newInvoiceBtn').addEventListener('click', openInvoice);
$('iPo').addEventListener('change', renderInvoiceLines);
$('invForm').addEventListener('input', calcInvoice);
$('invCancel').addEventListener('click', () => $('invDialog').close());
$('invForm').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const lines = invoiceLines();
  if (!lines.length) { $('invMsg').textContent = 'Isi minimal 1 qty invoice.'; return; }
  const sub = lines.reduce((s, l) => s + l.qty * l.unit_price, 0);
  try {
    const r = await api('fin_create_invoice', {
      p_po_id: Number($('iPo').value), p_invoice_no: $('iNo').value.trim(), p_invoice_date: $('iDate').value,
      p_due_date: $('iDue').value || null, p_ppn_amount: $('iPpn').checked ? Math.round(sub * 0.11) : 0,
      p_pph23_amount: parseNum($('iPph').value), p_faktur_pajak_no: $('iFaktur').value.trim() || null, p_notes: null, p_lines: lines
    });
    $('invDialog').close();
    toast(r.status === 'MATCHED' ? 'Invoice tersimpan: cocok dengan PO & penerimaan (siap di-approve)' : 'Invoice tersimpan dengan status HOLD: ' + (r.hold_reason || 'ada selisih'), r.status !== 'MATCHED');
    loadAP();
  } catch (e) { $('invMsg').textContent = e.message; }
});

// ---------- budget ----------
async function loadBudget() {
  try {
    const d = await api('fin_budget');
    cache.budget = d;
    const projName = Object.fromEntries(d.projects.map((p) => [p.project_id, `${p.code} ${p.name}`]));
    const projCode = Object.fromEntries(d.projects.map((p) => [p.project_id, p.code]));
    $('bProject').innerHTML = d.projects.map((p) => `<option value="${esc(p.project_id)}">${esc(p.code)} — ${esc(p.name)}</option>`).join('');
    $('bvaTable').innerHTML = '<tr><th>Proyek</th><th class="num">Budget</th><th class="num">Komitmen</th><th class="num">Realisasi</th><th>Terpakai</th></tr>' +
      d.summary.map((b) => bvaRow(b)).join('');
    $('budgetTable').innerHTML = '<tr><th>Proyek</th><th>Kategori</th><th>Rev</th><th class="num">Nilai</th><th>Approval</th></tr>' +
      (d.budgets.length ? d.budgets.map((b) => {
        const canApprove = !b.approved_at && hasAuthor('AB', projCode[b.project_id]);
        return `<tr><td>${esc(projName[b.project_id] || '-')}</td><td>${esc(b.cost_category)}</td><td>${esc(b.revision)}</td><td class="num">${rp(b.amount)}</td>
          <td>${b.approved_at ? `<span class="badge ok">Approved</span><div class="small muted">${esc(b.approved_by)}</div>` : canApprove ? `<button type="button" class="btn primary small" data-approve-bud="${esc(b.budget_id)}">Approve</button>` : '<span class="badge">Menunggu</span>'}</td></tr>`;
      }).join('') : emptyRow(5, 'RAB belum diinput'));
  } catch (e) { toast(e.message, true); }
}
$('budgetForm').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  try {
    await api('fin_save_budget', { p_project_id: $('bProject').value, p_cost_category: $('bCat').value, p_amount: parseNum($('bAmount').value), p_revision: $('bRev').value, p_notes: $('bNotes').value || null });
    toast('RAB tersimpan');
    $('bAmount').value = ''; $('bNotes').value = '';
    loadBudget();
  } catch (e) { toast(e.message, true); }
});
$('budgetTable').addEventListener('click', async (ev) => {
  const b = ev.target.closest('[data-approve-bud]');
  if (!b) return;
  b.disabled = true;
  try { await api('fin_approve_budget', { p_budget_id: Number(b.dataset.approveBud) }); toast('RAB di-approve'); loadBudget(); }
  catch (e) { toast(e.message, true); b.disabled = false; }
});

// ---------- aset ----------
async function loadAset() {
  try {
    const d = await api('fin_assets');
    cache.aset = d;
    $('capInfo').textContent = `Batas kapitalisasi: ${rp(d.capitalizationThreshold)} per unit. Kartu aset dibuat otomatis dari penerimaan SMMS.`;
    $('aCat').innerHTML = '<option value="">Pilih kategori…</option>' + d.categories.map((c) => `<option value="${esc(c.category_code)}">${esc(c.category_name)}</option>`).join('');
    $('assetTable').innerHTML = '<tr><th>Kode</th><th>Item</th><th>Lokasi / Proyek</th><th>Tgl perolehan</th><th class="num">Harga</th><th>Kategori / Umur</th><th class="num">Akumulasi</th><th class="num">Nilai buku</th><th>Status</th><th></th></tr>' +
      (d.assets.length ? d.assets.map((a) => `<tr><td><b>${esc(a.asset_code)}</b></td><td>${esc(a.item_description)}<div class="small muted">${esc(a.vendor_name || '')} · ${esc(a.po_number || '')}</div></td>
        <td>${esc(a.location || '-')}<div class="small muted">Proyek ${esc(a.project_code || '-')}</div></td><td>${tgl(a.acquisition_date)}</td><td class="num">${rp(a.acquisition_cost)}</td>
        <td>${a.category_code ? esc(a.category_code) + ' · ' + esc(a.useful_life_months) + ' bln' : '<span class="muted">-</span>'}</td>
        <td class="num">${rp(a.accumulated_depreciation)}</td><td class="num">${rp(a.book_value)}</td><td>${statusBadge(a.status)}</td>
        <td><button type="button" class="btn ghost small" data-edit-asset="${esc(a.asset_id)}">${a.status === 'PERLU_DILENGKAPI' ? 'Lengkapi' : 'Edit'}</button></td></tr>`).join('') : emptyRow(10, 'Belum ada aset tetap'));
  } catch (e) { toast(e.message, true); }
}
let editingAsset = null;
$('assetTable').addEventListener('click', (ev) => {
  const b = ev.target.closest('[data-edit-asset]');
  if (!b) return;
  const a = cache.aset.assets.find((x) => String(x.asset_id) === b.dataset.editAsset);
  editingAsset = a.asset_id;
  $('aTitle').textContent = `${a.asset_code} — ${a.status === 'PERLU_DILENGKAPI' ? 'Lengkapi' : 'Edit'} aset`;
  $('aInfo').textContent = `${a.item_description} · ${rp(a.acquisition_cost)} · diterima ${tgl(a.acquisition_date)}`;
  $('aCat').value = a.category_code || '';
  $('aLife').value = a.useful_life_months || '';
  $('aResidual').value = num(a.residual_value) || '';
  $('aMethod').value = a.method || '';
  $('aCond').value = a.condition || '';
  $('aLoc').value = a.location || '';
  $('assetMsg').textContent = '';
  $('assetDialog').showModal();
});
$('aCat').addEventListener('change', () => {
  const c = cache.aset.categories.find((x) => x.category_code === $('aCat').value);
  if (c && !$('aLife').value) $('aLife').value = c.useful_life_months;
});
$('assetCancel').addEventListener('click', () => $('assetDialog').close());
$('assetForm').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  try {
    await api('fin_update_asset', {
      p_asset_id: editingAsset, p_category: $('aCat').value || null, p_useful_life_months: Number($('aLife').value) || null,
      p_residual_value: $('aResidual').value === '' ? null : parseNum($('aResidual').value), p_method: $('aMethod').value || null,
      p_location: $('aLoc').value || null, p_condition: $('aCond').value || null, p_notes: null
    });
    $('assetDialog').close();
    toast('Aset tersimpan');
    loadAset();
  } catch (e) { $('assetMsg').textContent = e.message; }
});
$('runDepBtn').addEventListener('click', async () => {
  const p = $('depPeriod').value;
  if (!p) { toast('Pilih periode bulan dulu.', true); return; }
  if (!confirm(`Jalankan penyusutan periode ${p}? Jurnal DRAFT akan dibuat (aman dijalankan ulang).`)) return;
  try {
    const r = await api('fin_run_depreciation', { p_period: p + '-01' });
    toast(`Penyusutan ${p}: ${r.assetsDepreciated} aset disusutkan`);
    loadAset();
  } catch (e) { toast(e.message, true); }
});

const loaders = { dashboard: loadDashboard, ap: loadAP, jurnal: loadJurnal, budget: loadBudget, aset: loadAset };

// ---------- start ----------
(function init() {
  const d = new Date(); d.setMonth(d.getMonth() - 1);
  $('depPeriod').value = d.toISOString().slice(0, 7);
  try { session = JSON.parse(sessionStorage.getItem(SESSION_KEY)); } catch (e) { session = null; }
  if (session && session.token && new Date(session.expiresAt) > new Date()) startApp();
  else { session = null; loadAccounts(); }
})();
