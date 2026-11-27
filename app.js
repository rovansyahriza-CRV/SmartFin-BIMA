// =====================================================================
// SmartFin BIMA — frontend
// Semua data lewat fungsi public.fin_* di Supabase. Hak akses (PIC/Author)
// dicek ulang di server setiap panggilan; pengecekan di sini cuma untuk tampilan.
// Hanya publishable key yang boleh ada di file ini.
// =====================================================================
const SUPABASE_URL = 'https://nhmpwjriextmbotmvvbu.supabase.co';
const SUPABASE_KEY = 'sb_publishable_XNqLw7iz873TtrLn9ag8dQ_AkL2rImz';
const SESSION_KEY = 'smartfin_session';
// Drive bridge yang sama dengan SMMS / Fusion4 (Apps Script). Dokumen keuangan masuk kategori "finance";
// bridge menyimpan kategori "finance" di SMMS-BIMA-Files/finance/yyyy-MM, file tidak dibagikan publik.
const DRIVE_BRIDGE_URL = 'https://script.google.com/macros/s/AKfycbwfq5bqNWx0fO9LuEyQasUzkLP91gA8G-rqRKpPOIJ9r7WNN0G_klH8jXxXhY96ArlC/exec';
const DRIVE_BRIDGE_TOKEN = 'bima-2026-x8f2k9';
const DRIVE_CATEGORY = 'finance';
const MAX_UPLOAD_MB = 10;

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
const isSuper = () => session.pic.includes('all') || session.author.includes('all');
const hasAuthor = (code, projectCode) => {
  const c = code.toLowerCase();
  return isSuper() || session.author.includes(c) || (projectCode && session.author.includes(`${c}-${String(projectCode).toLowerCase()}`));
};
const hasAnyAuthor = (code) => { const c = code.toLowerCase(); return isSuper() || session.author.some((a) => a === c || a.startsWith(c + '-')); };

function statusBadge(s) {
  const ok = ['COCOK', 'MATCHED', 'APPROVED', 'POSTED', 'PAID', 'AKTIF', 'LUNAS'];
  const warn = ['SELISIH_HARGA', 'SELISIH_QTY', 'MELEBIHI_PO', 'HOLD', 'PERLU_DILENGKAPI', 'PERLU_DICEK', 'VOID', 'PARTIAL_PAID'];
  const cls = ok.includes(s) ? 'ok' : warn.includes(s) ? 'warn' : '';
  return `<span class="badge ${cls}">${esc(String(s || '-').replace(/_/g, ' '))}</span>`;
}
const emptyRow = (cols, text) => `<tr><td colspan="${cols}" class="empty">${esc(text)}</td></tr>`;

// ---------- login ----------
let accounts = [];
let activeIdx = -1;
const initials = (n) => String(n || '?').trim().split(/\s+/).slice(0, 2).map((w) => w[0]).join('').toUpperCase();

async function loadAccounts() {
  $('loginSearch').value = ''; $('loginUser').value = ''; $('loginSearch').classList.remove('picked');
  try {
    accounts = (await rpc('fin_login_accounts')) || [];
    $('loginSearch').placeholder = accounts.length ? 'Ketik untuk mencari nama…' : 'Belum ada akun SmartFin';
    if (!accounts.length) $('loginMsg').textContent = 'Belum ada akun dengan akses SmartFin (PIC FIN / FIN-ALL / ALL).';
  } catch (e) {
    $('loginSearch').placeholder = 'Gagal memuat akun';
    $('loginMsg').textContent = 'Tidak bisa terhubung ke server: ' + e.message;
  }
}
function renderAccountList() {
  const q = $('loginSearch').value.trim().toLowerCase();
  const list = accounts.filter((a) => !q || String(a.nama).toLowerCase().includes(q)).slice(0, 8);
  activeIdx = list.length ? 0 : -1;
  $('loginList').innerHTML = list.length
    ? list.map((a, i) => `<li role="option" id="opt-${esc(a.id)}" data-id="${esc(a.id)}" data-nama="${esc(a.nama)}" aria-selected="${i === 0}"><span class="av">${esc(initials(a.nama))}</span>${esc(a.nama)}</li>`).join('')
    : '<li class="none">Nama tidak ditemukan</li>';
  $('loginList').hidden = false;
  $('loginSearch').setAttribute('aria-expanded', 'true');
}
function closeAccountList() { $('loginList').hidden = true; $('loginSearch').setAttribute('aria-expanded', 'false'); }
function pickAccount(li) {
  if (!li || !li.dataset.id) return;
  $('loginUser').value = li.dataset.id;
  $('loginSearch').value = li.dataset.nama;
  $('loginSearch').classList.add('picked');
  closeAccountList();
  $('loginPass').focus();
}
$('loginSearch').addEventListener('input', () => { $('loginUser').value = ''; $('loginSearch').classList.remove('picked'); renderAccountList(); });
$('loginSearch').addEventListener('focus', renderAccountList);
$('loginSearch').addEventListener('keydown', (ev) => {
  const items = [...$('loginList').querySelectorAll('li[data-id]')];
  if (ev.key === 'ArrowDown' || ev.key === 'ArrowUp') {
    ev.preventDefault();
    if (!items.length) return;
    activeIdx = (activeIdx + (ev.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length;
    items.forEach((li, i) => li.setAttribute('aria-selected', String(i === activeIdx)));
    items[activeIdx].scrollIntoView({ block: 'nearest' });
  } else if (ev.key === 'Enter' && !$('loginList').hidden) {
    ev.preventDefault(); pickAccount(items[activeIdx]);
  } else if (ev.key === 'Escape') closeAccountList();
});
$('loginList').addEventListener('mousedown', (ev) => { ev.preventDefault(); pickAccount(ev.target.closest('li')); });
$('loginSearch').addEventListener('blur', () => setTimeout(closeAccountList, 120));
$('togglePass').addEventListener('click', () => {
  const show = $('loginPass').type === 'password';
  $('loginPass').type = show ? 'text' : 'password';
  $('togglePass').textContent = show ? 'Sembunyikan' : 'Lihat';
  $('togglePass').setAttribute('aria-label', show ? 'Sembunyikan password' : 'Tampilkan password');
});

$('loginForm').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  $('loginMsg').textContent = '';
  if (!$('loginUser').value) { $('loginMsg').textContent = 'Pilih nama dari daftar dulu.'; $('loginSearch').focus(); return; }
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
      kpi('Pembayaran', rpShort(k.siapDibayar || 0), `Siap dibayar · ${k.menungguApproval || 0} menunggu approval APY`, (k.menungguApproval || 0) > 0) +
      kpi('Komitmen PO vs Budget', rpShort(k.komitmenTotal), num(k.budgetTotal) > 0 ? `Budget ${rpShort(k.budgetTotal)}` : 'RAB belum diinput', num(k.budgetTotal) === 0) +
      kpi('Realisasi biaya proyek', rpShort(k.realisasiTotal), 'Material diserahkan ke end user') +
      kpi('Jurnal draft', String(k.jurnalDraft), k.errorJurnal > 0 ? `${k.errorJurnal} error jurnal otomatis` : 'Menunggu posting (PJ)', k.errorJurnal > 0) +
      kpi('Aset perlu dilengkapi', String(k.asetPerluDilengkapi), 'Isi kategori & umur di menu Aset', k.asetPerluDilengkapi > 0);

    $('dashBva').innerHTML = '<tr><th>Proyek</th><th class="num">Budget</th><th class="num">Komitmen</th><th class="num">Realisasi</th><th>Terpakai</th></tr>' +
      (d.budgetVsActual.length ? d.budgetVsActual.map((b) => bvaRow(b)).join('') : emptyRow(5, 'Belum ada data'));

    $('dashDraft').innerHTML = '<tr><th>Tanggal</th><th>Sumber</th><th>Keterangan</th><th class="num">Nilai</th></tr>' +
      (d.draftJournals.length ? d.draftJournals.map((j) => `<tr><td>${tgl(j.journal_date)}</td><td><span class="badge src">${esc(j.source_system)}</span></td><td>${esc(j.description)}</td><td class="num">${rp(j.amount)}</td></tr>`).join('') : emptyRow(4, 'Tidak ada jurnal draft'));

    const up = d.upcomingPayments || [];
    $('dashPay').innerHTML = '<tr><th>Jatuh tempo</th><th>Vendor / PO</th><th class="num">Nilai</th><th>Status</th></tr>' +
      (up.length ? up.map((p) => `<tr><td>${dueCell(p)}</td><td>${esc(p.vendor_name)}<div class="small muted">${esc(p.po_number)}</div></td><td class="num">${rp(p.amount)}</td><td>${payBadge(p.status)}</td></tr>`).join('') : emptyRow(4, 'Tidak ada pembayaran terjadwal'));

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
        const canApprove = i.status === 'MATCHED' && hasAnyAuthor('AI');
        return `<tr><td><b>${esc(i.invoice_no)}</b></td><td>${esc(i.vendor_name)}<br><span class="muted">${esc(i.po_number)}</span></td><td>${tgl(i.invoice_date)}</td><td>${tgl(i.due_date)}</td><td class="num">${rp(i.total_amount)}</td>
          <td>${statusBadge(i.status)}${i.hold_reason ? `<div class="small muted">${esc(i.hold_reason)}</div>` : ''}${i.approved_by ? `<div class="small muted">oleh ${esc(i.approved_by)}</div>` : ''}</td>
          <td><div class="row-gap"><button type="button" class="btn ghost small" data-docs-inv="${esc(i.invoice_id)}" data-title="${esc(i.invoice_no + ' · ' + i.vendor_name + ' · ' + i.po_number)}">Dokumen${i.docs_missing ? ' !' : ' ✓'}</button>
          ${canApprove ? `<button type="button" class="btn primary small" data-approve-inv="${esc(i.invoice_id)}">Approve</button>` : ''}</div></td></tr>`;
      }).join('') : emptyRow(7, 'Belum ada invoice'));

    $('poTable').innerHTML = '<tr><th>PO</th><th>Vendor</th><th>Proyek</th><th>Item</th><th class="num">Qty PO</th><th class="num">Diterima</th><th class="num">Ditagih</th><th class="num">Harga</th><th>Status</th></tr>' +
      (d.poLines.length ? d.poLines.map((l) => `<tr><td>${esc(l.po_number)}</td><td>${esc(l.vendor_name)}</td><td>${esc(l.project_code || '-')}</td><td>${esc(l.item_description)}</td>
        <td class="num">${esc(num(l.po_qty))}</td><td class="num">${esc(num(l.qty_received))}</td><td class="num">${esc(num(l.qty_invoiced))}</td><td class="num">${rp(l.po_unit_price)}</td><td>${statusBadge(l.match_status)}</td></tr>`).join('') : emptyRow(9, 'Belum ada PO'));
  } catch (e) { toast(e.message, true); }
}
$('invTable').addEventListener('click', async (ev) => {
  const dd = ev.target.closest('[data-docs-inv]');
  if (dd) { openDocs('INVOICE', Number(dd.dataset.docsInv), dd.dataset.title); return; }
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
  const terms = (cache.ap && cache.ap.poTerms) || [];
  lines.forEach((l) => {
    const t = terms.find((x) => x.po_id === l.po_id);
    const chargeLeft = t ? num(t.mobilisasi_cost) + num(t.other_service_cost) - num(t.charges_invoiced) : 0;
    if (num(l.qty_received) > num(l.qty_invoiced) || chargeLeft > 0) pos[l.po_id] = `${l.po_number} — ${l.vendor_name}`;
  });
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
  const t = (cache.ap.poTerms || []).find((x) => x.po_id === poId);
  const capMob = t ? num(t.mobilisasi_cost) : 0, capOth = t ? num(t.other_service_cost) : 0;
  $('iChargeBox').hidden = !(capMob + capOth > 0);
  $('iMob').value = '0'; $('iOth').value = '0';
  renderInvoiceDocInputs(poId);
  $('iTermInfo').textContent = t ? `Termin: ${t.term_text || '-'} · Penawaran vendor: mobilisasi ${rp(capMob)}, jasa lain ${rp(capOth)} · sudah ditagih ${rp(t.charges_invoiced)}` : '';
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
function renderInvoiceDocInputs(poId) {
  const line = cache.ap.poLines.find((l) => l.po_id === poId);
  const isSo = line && String(line.doc_type || '').toUpperCase() === 'SO';
  const types = (cache.ap.docTypes || []).filter((d) => d.gate === 'INVOICE' && d.source === 'UPLOAD');
  $('iDocs').innerHTML = types.map((d) => {
    const req = d.rule === 'ALWAYS' || (d.rule === 'IF_SO' && isSo) || d.rule === 'IF_PPN';
    if (d.rule === 'IF_SO' && !isSo) return '';
    const tag = d.rule === 'IF_PPN' ? '<span class="badge">Wajib jika PPN</span>' : req ? '<span class="badge warn">Wajib</span>' : '<span class="badge">Opsional</span>';
    return `<div class="doc-up" data-inv-doc="${esc(d.doc_type)}"><div><div class="row-gap small"><b>${esc(d.doc_name)}</b>${tag}</div>
      <input type="file" accept=".pdf,image/*" aria-label="File ${esc(d.doc_name)}"></div>
      <input type="text" class="ref" placeholder="No. dokumen (opsional)" aria-label="Nomor ${esc(d.doc_name)}"><span></span></div>`;
  }).join('');
}
function chargeLines() {
  const out = [];
  if (parseNum($('iMob').value) > 0) out.push({ charge_type: 'MOBILISASI', amount: parseNum($('iMob').value), description: 'Biaya mobilisasi' });
  if (parseNum($('iOth').value) > 0) out.push({ charge_type: 'OTHER_SERVICE', amount: parseNum($('iOth').value), description: 'Biaya jasa lain' });
  return out;
}
function invoiceSubtotal() {
  return invoiceLines().reduce((s, l) => s + l.qty * l.unit_price, 0) + chargeLines().reduce((s, c) => s + c.amount, 0);
}
function calcInvoice() {
  const sub = invoiceSubtotal();
  const ppn = $('iPpn').checked ? Math.round(sub * 0.11) : 0;
  $('iTotal').textContent = rp(sub + ppn - parseNum($('iPph').value));
}
$('newInvoiceBtn').addEventListener('click', openInvoice);
$('iPo').addEventListener('change', renderInvoiceLines);
$('invForm').addEventListener('input', calcInvoice);
$('invCancel').addEventListener('click', () => $('invDialog').close());
$('invForm').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const lines = invoiceLines().concat(chargeLines());
  if (!lines.length) { $('invMsg').textContent = 'Isi minimal 1 qty invoice atau biaya tambahan.'; return; }
  const sub = invoiceSubtotal();
  try {
    const r = await api('fin_create_invoice', {
      p_po_id: Number($('iPo').value), p_invoice_no: $('iNo').value.trim(), p_invoice_date: $('iDate').value,
      p_due_date: $('iDue').value || null, p_ppn_amount: $('iPpn').checked ? Math.round(sub * 0.11) : 0,
      p_pph23_amount: parseNum($('iPph').value), p_faktur_pajak_no: $('iFaktur').value.trim() || null, p_notes: null, p_lines: lines
    });
    // upload lampiran yang dipilih
    const pending = [...$('iDocs').querySelectorAll('[data-inv-doc]')].filter((row) => row.querySelector('input[type=file]').files[0]);
    let last = r, failed = [];
    for (const row of pending) {
      $('invMsg').textContent = `Mengunggah ${row.dataset.invDoc.replace('INV_', '').toLowerCase()}…`;
      try { last = await attachDocument('INVOICE', r.invoice_id, row.dataset.invDoc, row.querySelector('input[type=file]').files[0], row.querySelector('.ref').value); }
      catch (e) { failed.push(e.message); }
    }
    $('invDialog').close();
    const status = last.invoice_status || r.status;
    if (failed.length) toast('Invoice tersimpan, tapi ada upload gagal: ' + failed.join('; '), true);
    else toast(status === 'MATCHED' ? 'Invoice tersimpan, dokumen lengkap & cocok (siap di-approve)' : 'Invoice tersimpan dengan status HOLD. ' + (last.missing ? 'Kurang: ' + last.missing : (r.hold_reason || '')), status !== 'MATCHED');
    loadAP();
  } catch (e) { $('invMsg').textContent = e.message; }
});



// ---------- upload dokumen ----------
function fileToBase64(file) {
  return new Promise((resolve, reject) => {
    const r = new FileReader();
    r.onload = () => resolve(String(r.result).split(',')[1]);
    r.onerror = reject;
    r.readAsDataURL(file);
  });
}
async function uploadToDrive(file, prefix) {
  if (file.size > MAX_UPLOAD_MB * 1024 * 1024) throw new Error(`File ${file.name} melebihi ${MAX_UPLOAD_MB} MB`);
  const base64Data = await fileToBase64(file);
  const safeName = `${prefix}_${Date.now()}_${file.name}`.replace(/[^A-Za-z0-9._-]+/g, '_');
  const send = async (category) => {
    const res = await fetch(DRIVE_BRIDGE_URL, { method: 'POST', body: JSON.stringify({
      token: DRIVE_BRIDGE_TOKEN, action: 'upload', category, fileName: safeName, mimeType: file.type || 'application/octet-stream', base64Data }) });
    return res.json();
  };
  let data = await send(DRIVE_CATEGORY);
  if (!data || data.error) throw new Error('Upload gagal: ' + ((data && data.error) || 'tidak ada respons'));
  return { url: data.viewUrl || data.directUrl, fileId: data.fileId, fileName: file.name };
}
async function attachDocument(gate, refId, docType, file, refNo, bond) {
  const up = await uploadToDrive(file, docType);
  return api('fin_add_document', { p_gate: gate, p_ref_id: refId, p_doc_type: docType, p_file_url: up.url, p_file_id: up.fileId,
    p_file_name: up.fileName, p_ref_no: refNo || null, p_bond_issuer: bond ? bond.issuer : null,
    p_bond_amount: bond ? bond.amount : null, p_bond_expiry: bond ? bond.expiry : null, p_notes: null });
}

// ---------- dialog checklist dokumen ----------
let docCtx = null;
async function openDocs(gate, refId, title) {
  docCtx = { gate, refId, title };
  $('docTitle').textContent = gate === 'ADVANCE' ? 'Dokumen Uang Muka (Gate A)' : 'Dokumen Invoice (Gate B)';
  $('docInfo').textContent = title;
  $('docMsg').textContent = '';
  $('docList').innerHTML = '<p class="muted">Memuat…</p>';
  if (!$('docDialog').open) $('docDialog').showModal();
  try {
    const d = await api('fin_doc_checklist', { p_gate: gate, p_ref_id: refId });
    $('docList').innerHTML = d.items.map((it) => {
      const ic = it.ok ? '<span class="doc-ic ok">✓</span>' : it.required ? '<span class="doc-ic no">!</span>' : '<span class="doc-ic opt">–</span>';
      const chips = (it.items || []).map((x) => {
        const label = esc(x.label) + (x.bond_expiry ? ` · s/d ${tgl(x.bond_expiry)}` : '') + (x.bond_amount ? ` · ${rp(x.bond_amount)}` : '');
        const link = x.url ? `<a href="${esc(x.url)}" target="_blank" rel="noopener">${label}</a>` : label;
        const del = x.doc_id && !d.locked ? `<button type="button" data-del-doc="${esc(x.doc_id)}" aria-label="Hapus dokumen">hapus</button>` : '';
        return `<span class="doc-chip">${link}${del}</span>`;
      }).join('');
      const tag = it.required ? '<span class="badge warn">Wajib</span>' : '<span class="badge">Opsional</span>';
      const up = it.source === 'UPLOAD' ? `<div class="doc-up" data-up="${esc(it.doc_type)}">
          <input type="file" accept=".pdf,image/*" aria-label="Pilih file ${esc(it.doc_name)}">
          <input type="text" class="ref" placeholder="${it.doc_type === 'ADV_BOND' ? 'No. jaminan' : 'No. dokumen (opsional)'}" aria-label="Nomor dokumen">
          <button type="button" class="btn primary small" data-upload="${esc(it.doc_type)}">Upload</button></div>
          ${it.doc_type === 'ADV_BOND' ? `<div class="doc-bond" data-bond="1">
            <input type="text" class="b-issuer" placeholder="Penerbit (bank/asuransi)" aria-label="Penerbit jaminan">
            <input type="text" class="b-amount" inputmode="numeric" placeholder="Nilai jaminan (Rp)" aria-label="Nilai jaminan">
            <input type="date" class="b-expiry" aria-label="Berlaku sampai"></div>` : ''}` : '<div class="small muted">Otomatis dari SMMS</div>';
      return `<div class="doc-row">${ic}<div><div class="row-gap"><span class="doc-name">${esc(it.doc_name)}</span>${tag}</div>
        <div class="doc-items">${chips || (it.source === 'SMMS' ? `<span class="small ${it.required ? 'overdue' : 'muted'}">${esc(it.note || 'Belum ada di SMMS')}</span>` : '')}</div>${up}</div></div>`;
    }).join('') + `<p class="small ${d.missing ? 'overdue' : 'muted'}">${d.missing ? 'Belum lengkap: ' + esc(d.missing) : 'Semua dokumen wajib sudah lengkap ✓'}</p>`;
  } catch (e) { $('docList').innerHTML = ''; $('docMsg').textContent = e.message; }
}
$('docClose').addEventListener('click', () => { $('docDialog').close(); if (docCtx) ((location.hash.slice(1) === 'bayar') ? loadBayar : loadAP)(); });
$('docList').addEventListener('click', async (ev) => {
  const ub = ev.target.closest('[data-upload]');
  if (ub) {
    const row = ub.closest('.doc-up');
    const file = row.querySelector('input[type=file]').files[0];
    if (!file) { $('docMsg').textContent = 'Pilih file dulu.'; return; }
    let bond = null;
    if (ub.dataset.upload === 'ADV_BOND') {
      const b = row.parentElement.querySelector('[data-bond]');
      bond = { issuer: b.querySelector('.b-issuer').value.trim() || null, amount: parseNum(b.querySelector('.b-amount').value) || null, expiry: b.querySelector('.b-expiry').value || null };
    }
    ub.disabled = true; ub.textContent = 'Mengunggah…'; $('docMsg').textContent = '';
    try {
      const r = await attachDocument(docCtx.gate, docCtx.refId, ub.dataset.upload, file, row.querySelector('.ref').value, bond);
      toast(r.missing ? 'Dokumen tersimpan. Masih kurang: ' + r.missing : 'Dokumen tersimpan. Semua dokumen wajib lengkap ✓');
      openDocs(docCtx.gate, docCtx.refId, docCtx.title);
    } catch (e) { $('docMsg').textContent = e.message; ub.disabled = false; ub.textContent = 'Upload'; }
    return;
  }
  const db = ev.target.closest('[data-del-doc]');
  if (db) {
    if (!confirm('Hapus dokumen ini dari daftar? (File di Drive tidak ikut terhapus)')) return;
    try { await api('fin_remove_document', { p_doc_id: Number(db.dataset.delDoc) }); openDocs(docCtx.gate, docCtx.refId, docCtx.title); }
    catch (e) { $('docMsg').textContent = e.message; }
  }
});

// ---------- pembayaran ----------
const PAY_LABEL = { PLANNED: 'Rencana', DUE: 'Rencana', APPROVED: 'Disetujui', PAID: 'Lunas', CANCELLED: 'Batal' };
function payBadge(s) {
  const cls = s === 'PAID' ? 'ok' : s === 'APPROVED' ? 'info' : s === 'CANCELLED' ? '' : 'warn';
  return `<span class="badge ${cls}">${esc(PAY_LABEL[s] || s)}</span>`;
}
function dueCell(p) {
  if (p.waiting_client) return '<span class="badge">Menunggu klien</span>';
  if (!p.due_date) return '-';
  const overdue = p.status !== 'PAID' && new Date(p.due_date) < new Date(today());
  return `<span class="${overdue ? 'overdue' : ''}">${tgl(p.due_date)}${overdue ? ' · lewat' : ''}</span>`;
}
let payingSchedule = null;
async function loadBayar() {
  try {
    const d = await api('fin_payments');
    cache.bayar = d;
    const s = d.schedules.filter((x) => x.status !== 'CANCELLED');
    const open = s.filter((x) => x.status !== 'PAID');
    const sum = (arr) => arr.reduce((t, x) => t + num(x.amount), 0);
    const week = open.filter((x) => x.due_date && new Date(x.due_date) <= new Date(Date.now() + 7 * 864e5));
    const kpi = (label, val, sub, alert) => `<div class="kpi${alert ? ' alert' : ''}"><div class="k-label">${esc(label)}</div><div class="k-val">${esc(val)}</div><div class="k-sub">${esc(sub)}</div></div>`;
    $('payKpis').innerHTML =
      kpi('Menunggu approval APY', rpShort(sum(open.filter((x) => x.status !== 'APPROVED'))), `${open.filter((x) => x.status !== 'APPROVED').length} jadwal`) +
      kpi('Siap dibayar', rpShort(sum(open.filter((x) => x.status === 'APPROVED' && !x.docs_missing))), `${open.filter((x) => x.status === 'APPROVED' && !x.docs_missing).length} jadwal · ${open.filter((x) => x.docs_missing).length} HOLD dokumen`, open.some((x) => x.docs_missing)) +
      kpi('Jatuh tempo ≤ 7 hari', rpShort(sum(week)), `${week.length} jadwal`, week.length > 0) +
      kpi('Sudah dibayar', rpShort(s.filter((x) => x.status === 'PAID').reduce((t, x) => t + num(x.paid_amount || x.amount), 0)), 'Total tercatat');

    const f = $('payFilter').value;
    const rows = d.schedules.filter((x) => f === 'ALL' || (f === 'PAID' ? x.status === 'PAID' : !['PAID', 'CANCELLED'].includes(x.status)));
    $('payTable').innerHTML = '<tr><th>Jatuh tempo</th><th>Vendor / PO</th><th>Keterangan</th><th>Termin</th><th class="num">Nilai</th><th>Status</th><th></th></tr>' +
      (rows.length ? rows.map((p) => {
        let action = '';
        const docTitle = esc(p.vendor_name + ' · ' + p.po_number + ' · ' + (p.invoice_no ? 'Inv ' + p.invoice_no : p.description));
        const docMark = p.docs_missing ? ' !' : ' ✓';
        const docBtn = p.schedule_type === 'ADVANCE'
          ? `<button type="button" class="btn ghost small" data-docs-adv="${esc(p.schedule_id)}" data-title="${docTitle}">Dokumen${docMark}</button>`
          : p.invoice_id ? `<button type="button" class="btn ghost small" data-docs-inv="${esc(p.invoice_id)}" data-title="${docTitle}">Dokumen${p.status === 'PAID' ? '' : docMark}</button>` : '';
        const holdMsg = `<span class="small overdue">Lengkapi dokumen dulu</span>`;
        if (['PLANNED', 'DUE'].includes(p.status) && hasAuthor('APY', p.project_code)) {
          action = p.docs_missing ? holdMsg : `<button type="button" class="btn primary small" data-approve-pay="${esc(p.schedule_id)}">Setujui</button>`;
        }
        if (p.status === 'APPROVED') action = p.docs_missing ? holdMsg : `<button type="button" class="btn primary small" data-pay="${esc(p.schedule_id)}">Tandai Lunas</button>`;
        action = `<div class="row-gap">${docBtn}${action}</div>`;
        const who = p.status === 'PAID' ? `<div class="small muted">${tgl(p.paid_at)} · ${esc(p.bank_label || '')} ${p.payment_ref ? '· ' + esc(p.payment_ref) : ''}</div>`
          : p.approved_by ? `<div class="small muted">disetujui ${esc(p.approved_by)}</div>` : '';
        return `<tr><td>${dueCell(p)}</td><td>${esc(p.vendor_name)}<div class="small muted">${esc(p.po_number)}${p.invoice_no ? ' · Inv ' + esc(p.invoice_no) : ''}${p.project_code ? ' · Proyek ' + esc(p.project_code) : ''}</div></td>
          <td>${esc(p.description)}${p.schedule_type === 'ADVANCE' ? ' <span class="badge info">Uang muka</span>' : ''}</td><td>${esc(p.term_type || '-')}</td>
          <td class="num">${rp(p.status === 'PAID' ? (p.paid_amount || p.amount) : p.amount)}</td><td>${payBadge(p.status)}${p.docs_missing ? ' <span class="badge warn" title="Dokumen belum lengkap: ' + esc(p.docs_missing) + '">HOLD</span>' : ''}${who}</td><td>${action}</td></tr>`;
      }).join('') : emptyRow(7, 'Tidak ada jadwal untuk filter ini'));

    const bal = d.bankBalances || {};
    $('bankTable').innerHTML = '<tr><th>Rekening</th><th>Akun COA</th><th class="num">Saldo (dari jurnal)</th><th>Status</th></tr>' +
      (d.banks.length ? d.banks.map((b) => `<tr><td><b>${esc(b.account_label)}</b><div class="small muted">${esc(b.bank_name)}${b.account_last4 ? ' · ****' + esc(b.account_last4) : ''}</div></td>
        <td>${esc(b.coa_code)}</td><td class="num">${rp(bal[b.bank_id])}</td><td>${b.is_active ? '<span class="badge ok">Aktif</span>' : '<span class="badge">Nonaktif</span>'}</td></tr>`).join('')
        : emptyRow(4, 'Belum ada rekening. Tambahkan dulu sebelum menandai pembayaran lunas.'));
  } catch (e) { toast(e.message, true); }
}
$('payFilter').addEventListener('change', loadBayar);
$('payTable').addEventListener('click', async (ev) => {
  const dd = ev.target.closest('[data-docs-adv]');
  if (dd) { openDocs('ADVANCE', Number(dd.dataset.docsAdv), dd.dataset.title); return; }
  const di = ev.target.closest('[data-docs-inv]');
  if (di) { openDocs('INVOICE', Number(di.dataset.docsInv), di.dataset.title); return; }
  const a = ev.target.closest('[data-approve-pay]');
  if (a) {
    if (!confirm('Setujui pembayaran ini?')) return;
    a.disabled = true;
    try { await api('fin_approve_payment', { p_schedule_id: Number(a.dataset.approvePay) }); toast('Pembayaran disetujui'); loadBayar(); }
    catch (e) { toast(e.message, true); a.disabled = false; }
    return;
  }
  const p = ev.target.closest('[data-pay]');
  if (!p) return;
  const s = cache.bayar.schedules.find((x) => String(x.schedule_id) === p.dataset.pay);
  const banks = cache.bayar.banks.filter((b) => b.is_active);
  if (!banks.length) { toast('Tambahkan rekening bank dulu di bagian Rekening Bank.', true); return; }
  payingSchedule = s.schedule_id;
  $('payInfo').textContent = `${s.vendor_name} · ${s.po_number} · ${s.description} · ${rp(s.amount)}`;
  $('pBank').innerHTML = banks.map((b) => `<option value="${esc(b.bank_id)}">${esc(b.account_label)} (${esc(b.bank_name)})</option>`).join('');
  $('pDate').value = today();
  $('pAmount').value = num(s.amount).toLocaleString('id-ID');
  $('pRef').value = '';
  $('payMsg').textContent = '';
  $('payDialog').showModal();
});
$('payCancel').addEventListener('click', () => $('payDialog').close());
$('payForm').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  try {
    const r = await api('fin_mark_paid', { p_schedule_id: payingSchedule, p_bank_id: Number($('pBank').value), p_paid_date: $('pDate').value,
      p_paid_amount: parseNum($('pAmount').value), p_payment_ref: $('pRef').value || null });
    $('payDialog').close();
    toast(`Pembayaran ${rp(r.paid_amount)} tercatat lunas, jurnal bank dibuat`);
    loadBayar();
  } catch (e) { $('payMsg').textContent = e.message; }
});
$('bankForm').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  try {
    const r = await api('fin_save_bank', { p_bank_id: null, p_bank_name: $('bkName').value, p_account_label: $('bkLabel').value,
      p_account_last4: $('bkLast4').value || null, p_is_active: true });
    toast(`Rekening tersimpan (akun ${r.coa_code})`);
    $('bankForm').reset();
    loadBayar();
  } catch (e) { toast(e.message, true); }
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

const loaders = { dashboard: loadDashboard, ap: loadAP, bayar: loadBayar, jurnal: loadJurnal, budget: loadBudget, aset: loadAset };

// ---------- start ----------
(function init() {
  const d = new Date(); d.setMonth(d.getMonth() - 1);
  $('depPeriod').value = d.toISOString().slice(0, 7);
  try { session = JSON.parse(sessionStorage.getItem(SESSION_KEY)); } catch (e) { session = null; }
  if (session && session.token && new Date(session.expiresAt) > new Date()) startApp();
  else { session = null; loadAccounts(); }
})();
