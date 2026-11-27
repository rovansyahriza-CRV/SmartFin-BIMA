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
  if (!link || link.hidden) {
    const first = document.querySelector('#nav a:not([hidden])');
    page = first ? first.dataset.page : 'dashboard';
  }
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
  $('docTitle').textContent = { ADVANCE: 'Dokumen Uang Muka (Gate A)', INVOICE: 'Dokumen Invoice (Gate B)', NOTA: 'Dokumen Nota', DIRECT: 'Dokumen Pengeluaran Langsung' }[gate];
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
$('docClose').addEventListener('click', () => { $('docDialog').close(); if (docCtx) (loaders[location.hash.slice(1)] || loadAP)(); });
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
    loadBank();
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

// ---------- kas & kasbon ----------
const CASH_STATUS = { PLANNED: ['Menunggu APY', 'warn'], APPROVED: ['Disetujui', 'info'], PAID: ['Dibayar', 'ok'], CLOSED: ['Selesai', 'ok'],
  REJECTED: ['Ditolak', ''], CANCELLED: ['Batal', ''], SUBMITTED: ['Menunggu APC', 'warn'] };
const cashBadge = (s, label) => { const [t, c] = CASH_STATUS[s] || [s, '']; return `<span class="badge ${c}">${esc(label || t)}</span>`; };
const KIND_LABEL = { TOPUP: 'Isi kas site', DIRECT: 'Pengeluaran langsung', KASBON: 'Kasbon' };
const canHO = () => hasPic('fin-ap');

async function loadKas() {
  try {
    const d = await api('fin_cash_overview');
    cache.kas = d;
    $('newDirectBtn').hidden = !d.isHO;
    $('newFundBtn').hidden = !d.isHO;
    const sum = (arr, f) => arr.reduce((t, x) => t + num(f(x)), 0);
    const pendingNotes = d.expenses.filter((e) => e.status === 'SUBMITTED');
    const pendingReq = d.requests.filter((r) => r.status === 'PLANNED');
    const kasbonOpen = d.requests.filter((r) => r.kind === 'KASBON' && r.status === 'PAID');
    const kpi = (label, val, sub, alert) => `<div class="kpi${alert ? ' alert' : ''}"><div class="k-label">${esc(label)}</div><div class="k-val">${esc(val)}</div><div class="k-sub">${esc(sub)}</div></div>`;
    $('kasKpis').innerHTML =
      kpi('Saldo kas site', rpShort(sum(d.funds, (f) => f.balance)), `${d.funds.filter((f) => f.is_active).length} kas aktif`) +
      kpi('Nota menunggu APC', rpShort(sum(pendingNotes, (e) => e.amount)), `${pendingNotes.length} nota`, pendingNotes.length > 0) +
      kpi('Pengajuan menunggu APY', rpShort(sum(pendingReq, (r) => r.amount)), `${pendingReq.length} pengajuan`, pendingReq.length > 0) +
      kpi('Kasbon belum selesai', rpShort(sum(kasbonOpen, (r) => num(r.paid_amount) - num(r.settled))), `${kasbonOpen.length} kasbon`);

    // kas site
    $('fundTable').innerHTML = '<tr><th>Kas</th><th>Pemegang</th><th>Saldo / plafon</th><th class="num">Batas per nota</th><th>Menunggu</th><th></th></tr>' +
      (d.funds.length ? d.funds.map((f) => {
        const pct = Math.max(0, Math.min(100, num(f.balance) / num(f.ceiling) * 100));
        const own = f.custodian_id === d.me || d.isHO;
        const topup = Math.max(0, num(f.ceiling) - num(f.balance) - num(f.pending_topup));
        const acts = [
          own && f.is_active ? `<button type="button" class="btn primary small" data-nota-fund="${esc(f.fund_id)}">+ Nota</button>` : '',
          own && f.is_active && topup > 0 ? `<button type="button" class="btn ghost small" data-topup="${esc(f.fund_id)}">Isi kas</button>` : '',
          d.isHO ? `<button type="button" class="btn ghost small" data-edit-fund="${esc(f.fund_id)}">Ubah</button>` : ''].join('');
        return `<tr><td><b>${esc(f.fund_name)}</b><div class="small muted">${f.project_code ? 'Proyek ' + esc(f.project_code) + ' · ' : ''}${esc(f.coa_code)}${f.is_active ? '' : ' · nonaktif'}</div></td>
          <td>${esc(f.custodian_name)}</td>
          <td><div class="fund-bal${pct < 25 ? ' low' : ''}"><span>${rp(f.balance)} <span class="small muted">/ ${rpShort(f.ceiling)}</span></span><div class="bar"><div style="width:${pct.toFixed(0)}%"></div></div></div></td>
          <td class="num">${rp(f.max_per_note)}</td>
          <td class="small">${num(f.pending_notes) ? 'Nota ' + rp(f.pending_notes) + '<br>' : ''}${num(f.pending_topup) ? 'Isi kas ' + rp(f.pending_topup) : ''}${!num(f.pending_notes) && !num(f.pending_topup) ? '<span class="muted">-</span>' : ''}</td>
          <td><div class="row-gap">${acts}</div></td></tr>`;
      }).join('') : emptyRow(6, d.isHO ? 'Belum ada kas site. Klik "+ Kas site" untuk membuat.' : 'Belum ada kas site atas nama Anda.'));

    // nota
    const nf = $('notaFilter').value;
    const notes = d.expenses.filter((e) => nf === 'ALL' || e.status === 'SUBMITTED');
    $('notaTable').innerHTML = '<tr><th>Tanggal</th><th>Sumber</th><th>Keterangan</th><th>Kategori</th><th class="num">Nilai</th><th>Status</th><th></th></tr>' +
      (notes.length ? notes.map((e) => {
        const src = e.source === 'PETTY_CASH' ? esc(e.fund_name) : 'Kasbon ' + esc(e.kasbon_employee);
        const docBtn = `<button type="button" class="btn ghost small" data-docs-nota="${esc(e.expense_id)}" data-title="${esc(e.description + ' · ' + rp(e.amount))}">Dokumen${e.docs_missing ? ' !' : ' ✓'}</button>`;
        let act = '';
        if (e.status === 'SUBMITTED' && hasAuthor('APC', e.project_code)) {
          act = e.docs_missing ? '<span class="small overdue">Lengkapi dokumen dulu</span>'
            : `<button type="button" class="btn primary small" data-approve-nota="${esc(e.expense_id)}">Setujui</button><button type="button" class="btn ghost small" data-reject-nota="${esc(e.expense_id)}">Tolak</button>`;
        }
        const who = e.status === 'REJECTED' ? `<div class="small overdue">${esc(e.reject_reason || '')}</div>` : e.approved_by ? `<div class="small muted">${esc(e.approved_by)}</div>` : `<div class="small muted">oleh ${esc(e.submitted_by || '')}</div>`;
        return `<tr><td>${tgl(e.expense_date)}</td><td>${src}${e.project_code ? `<div class="small muted">Proyek ${esc(e.project_code)}</div>` : ''}</td>
          <td>${esc(e.description)}</td><td class="small">${esc(e.account_code)} ${esc(e.account_name || '')}</td>
          <td class="num">${rp(e.amount)}${num(e.ppn_amount) ? `<div class="small muted">PPN ${rp(e.ppn_amount)}</div>` : ''}</td>
          <td>${cashBadge(e.status)}${who}</td><td><div class="row-gap">${docBtn}${act}</div></td></tr>`;
      }).join('') : emptyRow(7, nf === 'OPEN' ? 'Tidak ada nota yang menunggu approval' : 'Belum ada nota'));

    // pengajuan
    const rf = $('reqFilter').value;
    const reqs = d.requests.filter((r) => rf === 'ALL' || ['PLANNED', 'APPROVED', 'PAID'].includes(r.status) && !(r.kind !== 'KASBON' && r.status === 'PAID'));
    $('reqTable').innerHTML = '<tr><th>Jenis</th><th>Untuk</th><th>Keterangan</th><th class="num">Nilai</th><th>Status</th><th></th></tr>' +
      (reqs.length ? reqs.map((r) => {
        const target = r.kind === 'TOPUP' ? esc(r.fund_name) : r.kind === 'KASBON' ? esc(r.employee_name) : esc(r.payee) + `<div class="small muted">${esc(r.account_code)} ${esc(r.account_name || '')}</div>`;
        const acts = [];
        if (r.kind === 'DIRECT') acts.push(`<button type="button" class="btn ghost small" data-docs-direct="${esc(r.request_id)}" data-title="${esc(r.payee + ' · ' + r.description)}">Dokumen${r.status === 'PLANNED' ? (r.docs_missing ? ' !' : ' ✓') : ''}</button>`);
        if (r.status === 'PLANNED' && hasAuthor('APY', r.project_code)) {
          if (r.docs_missing) acts.push('<span class="small overdue">Lengkapi dokumen dulu</span>');
          else acts.push(`<button type="button" class="btn primary small" data-approve-req="${esc(r.request_id)}">Setujui</button>`);
          acts.push(`<button type="button" class="btn ghost small" data-reject-req="${esc(r.request_id)}">Tolak</button>`);
        }
        if (r.status === 'APPROVED' && d.isHO) acts.push(`<button type="button" class="btn primary small" data-pay-req="${esc(r.request_id)}">Tandai Dibayar</button>`);
        if (r.kind === 'KASBON' && r.status === 'PAID') {
          if (d.isHO || r.employee_id === d.me) acts.push(`<button type="button" class="btn primary small" data-nota-kasbon="${esc(r.request_id)}">+ Nota</button>`);
          if (d.isHO) acts.push(`<button type="button" class="btn ghost small" data-close-kasbon="${esc(r.request_id)}">Tutup kasbon</button>`);
        }
        let info = '';
        if (r.kind === 'KASBON' && ['PAID', 'CLOSED'].includes(r.status)) info = `<div class="small muted">Nota disetujui ${rp(r.settled)}${num(r.pending_notes) ? ' · menunggu ' + rp(r.pending_notes) : ''}</div>`;
        if (r.status === 'REJECTED') info = `<div class="small overdue">${esc(r.reject_reason || '')}</div>`;
        else if (r.paid_at) info += `<div class="small muted">${tgl(r.paid_at)} · ${esc(r.bank_label || '')}${r.payment_ref ? ' · ' + esc(r.payment_ref) : ''}</div>`;
        else if (r.approved_by) info += `<div class="small muted">disetujui ${esc(r.approved_by)}</div>`;
        const label = r.kind === 'KASBON' && r.status === 'PAID' ? 'Berjalan' : null;
        return `<tr><td><span class="kind">${KIND_LABEL[r.kind]}</span>${r.project_code ? `<div class="small muted">Proyek ${esc(r.project_code)}</div>` : ''}</td>
          <td>${target}</td><td>${esc(r.description)}<div class="small muted">diajukan ${esc(r.requested_by || '')}</div></td>
          <td class="num">${rp(r.amount)}${num(r.pph23_amount) ? `<div class="small muted">dibayar ${rp(num(r.amount) - num(r.pph23_amount))}</div>` : ''}</td>
          <td>${cashBadge(r.status, label)}${info}</td><td><div class="row-gap">${acts.join('')}</div></td></tr>`;
      }).join('') : emptyRow(6, 'Tidak ada pengajuan'));
  } catch (e) { toast(e.message, true); }
}
['notaFilter', 'reqFilter'].forEach((id) => $(id).addEventListener('change', loadKas));

// --- form dialog generik ---
let cashSubmit = null;
const opt = (v, t, sel) => `<option value="${esc(v)}"${sel ? ' selected' : ''}>${esc(t)}</option>`;
const projectOptions = (sel, blank = '— tanpa proyek / overhead —') => opt('', blank) + cache.kas.projects.map((p) => opt(p.project_id, `${p.code} · ${p.name}`, p.project_id === sel)).join('');
const accountOptions = (sel) => cache.kas.accounts.map((a) => opt(a.code, `${a.code} · ${a.name}`, a.code === sel)).join('');
const bankOptions = () => cache.kas.banks.map((b) => opt(b.bank_id, `${b.label} (${b.bank_name})`)).join('');
const fileRows = (gate) => {
  const types = cache.kas.docTypes.filter((t) => t.gate === gate);
  return `<div class="cash-files"><div class="small"><b>Lampiran</b> · foto/PDF maks ${MAX_UPLOAD_MB} MB</div>${types.map((t) => `<div class="f-row" data-cash-doc="${esc(t.doc_type)}" data-rule="${esc(t.rule)}">
    <span class="small">${esc(t.doc_name)} ${t.rule === 'ALWAYS' ? '<span class="badge warn">Wajib</span>' : t.rule === 'IF_PPN' ? '<span class="badge">Jika PPN</span>' : '<span class="badge">Opsional</span>'}</span>
    <input type="file" accept=".pdf,image/*" capture="environment" aria-label="${esc(t.doc_name)}"></div>`).join('')}</div>`;
};
function openCash(title, info, html, submitLabel, onSubmit) {
  $('cashTitle').textContent = title;
  $('cashInfo').textContent = info || '';
  $('cashFields').innerHTML = html;
  $('cashMsg').textContent = '';
  $('cashSubmit').textContent = submitLabel;
  $('cashSubmit').disabled = false;
  cashSubmit = onSubmit;
  $('cashDialog').showModal();
}
$('cashCancel').addEventListener('click', () => $('cashDialog').close());
$('cashForm').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  if (!cashSubmit) return;
  $('cashSubmit').disabled = true; $('cashMsg').textContent = '';
  try { await cashSubmit(); $('cashDialog').close(); (loaders[location.hash.slice(1)] || loadKas)(); }
  catch (e) { $('cashMsg').textContent = e.message; $('cashSubmit').disabled = false; }
});
const fv = (id) => $(id).value.trim();
async function uploadCashFiles(gate, refId) {
  const failed = []; let last = null;
  for (const row of document.querySelectorAll('#cashFields [data-cash-doc]')) {
    const file = row.querySelector('input[type=file]').files[0];
    if (!file) continue;
    try { last = await attachDocument(gate, refId, row.dataset.cashDoc, file, ''); } catch (e) { failed.push(e.message); }
  }
  if (failed.length) toast('Tersimpan, tapi ada upload gagal: ' + failed.join('; '), true);
  return last;
}

function notaForm(source, refId, title, info, projectId) {
  openCash(title, info, `
    <div class="row2"><div><label for="cDate">Tanggal nota</label><input type="date" id="cDate" value="${today()}" max="${today()}" required></div>
      <div><label for="cAcc">Kategori biaya</label><select id="cAcc" required>${accountOptions('5-1400')}</select></div></div>
    <label for="cDesc">Keterangan</label><input id="cDesc" placeholder="mis. BBM genset, ATK, konsumsi rapat" required>
    <div class="row2"><div><label for="cAmt">Total nota (Rp)</label><input id="cAmt" inputmode="numeric" required></div>
      <div><label for="cPpn">PPN di nota (Rp, kalau ada)</label><input id="cPpn" inputmode="numeric" value="0"></div></div>
    <label for="cProj">Dibebankan ke proyek</label><select id="cProj">${projectOptions(projectId)}</select>
    ${fileRows('NOTA')}`, 'Kirim nota', async () => {
    const amt = parseNum(fv('cAmt')), ppn = parseNum(fv('cPpn'));
    const needDocs = [...document.querySelectorAll('#cashFields [data-cash-doc]')].filter((r) => (r.dataset.rule === 'ALWAYS' || (r.dataset.rule === 'IF_PPN' && ppn > 0)) && !r.querySelector('input').files[0]);
    if (needDocs.length) throw new Error('Lampirkan dulu: ' + needDocs.map((r) => r.querySelector('span').textContent.replace(/(Wajib|Jika PPN)/, '').trim()).join(', '));
    const r = await api('fin_create_expense', { p_source: source, p_ref_id: refId, p_expense_date: fv('cDate'), p_project_id: fv('cProj') || null,
      p_account_code: fv('cAcc'), p_description: fv('cDesc'), p_amount: amt, p_ppn_amount: ppn });
    const last = await uploadCashFiles('NOTA', r.expense_id);
    const missing = last ? last.missing : r.docs_missing;
    toast(missing ? 'Nota tersimpan. Masih kurang: ' + missing : 'Nota terkirim, menunggu approval APC', !!missing);
  });
}

$('newKasbonBtn').addEventListener('click', () => {
  const d = cache.kas; if (!d) return;
  const isCustodian = d.funds.some((f) => f.custodian_id === d.me);
  const emps = d.isHO || isCustodian ? d.employees : d.employees.filter((e) => e.id === d.me);
  openCash('Ajukan Kasbon', 'Uang muka karyawan, dipertanggungjawabkan dengan nota. Disetujui APY lalu dibayar finance HO.', `
    <label for="cEmp">Karyawan penerima</label><select id="cEmp" required>${emps.map((e) => opt(e.id, e.name, e.id === d.me)).join('')}</select>
    <div class="row2"><div><label for="cAmt">Nilai kasbon (Rp)</label><input id="cAmt" inputmode="numeric" required></div>
      <div><label for="cDue">Target pertanggungjawaban</label><input type="date" id="cDue"></div></div>
    <label for="cProj">Proyek</label><select id="cProj">${projectOptions(null)}</select>
    <label for="cDesc">Keperluan</label><input id="cDesc" placeholder="mis. Perjalanan dinas ke site 014" required>`, 'Ajukan', async () => {
    await api('fin_request_cash', { p_kind: 'KASBON', p_fund_id: null, p_employee_id: Number(fv('cEmp')), p_project_id: fv('cProj') || null, p_payee: null,
      p_account_code: null, p_amount: parseNum(fv('cAmt')), p_ppn_amount: 0, p_pph23_amount: 0, p_due_date: fv('cDue') || null, p_description: fv('cDesc') });
    toast('Kasbon diajukan, menunggu approval APY');
  });
});

$('newDirectBtn').addEventListener('click', () => {
  openCash('Pengeluaran Langsung', 'Tagihan tanpa PO yang dibayar dari bank HO (listrik, sewa, BPJS, notaris, reimburse). Disetujui APY setelah dokumen lengkap.', `
    <div class="row2"><div><label for="cPayee">Penerima</label><input id="cPayee" required></div>
      <div><label for="cAcc">Akun beban</label><select id="cAcc" required>${accountOptions('5-1200')}</select></div></div>
    <label for="cDesc">Keterangan</label><input id="cDesc" required>
    <div class="row2"><div><label for="cAmt">Total tagihan termasuk PPN (Rp)</label><input id="cAmt" inputmode="numeric" required></div>
      <div><label for="cPpn">PPN (Rp)</label><input id="cPpn" inputmode="numeric" value="0"></div></div>
    <div class="row2"><div><label for="cPph">PPh 23 dipotong (Rp)</label><input id="cPph" inputmode="numeric" value="0"></div>
      <div><label for="cDue">Jatuh tempo</label><input type="date" id="cDue"></div></div>
    <label for="cProj">Dibebankan ke proyek</label><select id="cProj">${projectOptions(null)}</select>
    ${fileRows('DIRECT')}`, 'Simpan', async () => {
    const r = await api('fin_request_cash', { p_kind: 'DIRECT', p_fund_id: null, p_employee_id: null, p_project_id: fv('cProj') || null, p_payee: fv('cPayee'),
      p_account_code: fv('cAcc'), p_amount: parseNum(fv('cAmt')), p_ppn_amount: parseNum(fv('cPpn')), p_pph23_amount: parseNum(fv('cPph')),
      p_due_date: fv('cDue') || null, p_description: fv('cDesc') });
    const last = await uploadCashFiles('DIRECT', r.request_id);
    const missing = last ? last.missing : r.docs_missing;
    toast(missing ? 'Tersimpan dengan status HOLD. Kurang: ' + missing : 'Tersimpan, menunggu approval APY', !!missing);
  });
});

function fundForm(f) {
  const d = cache.kas;
  openCash(f ? 'Ubah Kas Site' : 'Kas Site Baru', f ? `Akun ${f.coa_code}` : 'Sub-akun kas (1-11xx) dibuat otomatis.', `
    <label for="cName">Nama kas</label><input id="cName" value="${esc(f ? f.fund_name : '')}" placeholder="mis. Kas Site 014 Handil" required>
    <div class="row2"><div><label for="cProj">Proyek / site</label><select id="cProj">${projectOptions(f && f.project_id, '— kantor / HO —')}</select></div>
      <div><label for="cCust">Pemegang kas</label><select id="cCust" required>${d.employees.map((e) => opt(e.id, e.name, f && e.id === f.custodian_id)).join('')}</select></div></div>
    <div class="row2"><div><label for="cCeil">Plafon kas (Rp)</label><input id="cCeil" inputmode="numeric" value="${f ? num(f.ceiling).toLocaleString('id-ID') : ''}" required></div>
      <div><label for="cMax">Batas per nota (Rp)</label><input id="cMax" inputmode="numeric" value="${f ? num(f.max_per_note).toLocaleString('id-ID') : ''}" required></div></div>
    ${f ? `<label class="row-gap"><input type="checkbox" id="cActive"${f.is_active ? ' checked' : ''}> Kas aktif</label>` : ''}
    <p class="small muted">Pemegang kas butuh PIC <b>FIN-PC</b> di akunnya. Nota di atas batas per nota ditolak dan harus lewat PO di SMMS.</p>`, 'Simpan', async () => {
    await api('fin_save_fund', { p_fund_id: f ? f.fund_id : null, p_fund_name: fv('cName'), p_project_id: fv('cProj') || null, p_custodian_id: Number(fv('cCust')),
      p_ceiling: parseNum(fv('cCeil')), p_max_per_note: parseNum(fv('cMax')), p_is_active: f ? $('cActive').checked : true });
    toast('Kas site tersimpan');
  });
}
$('newFundBtn').addEventListener('click', () => fundForm(null));

function rejectForm(kind, id, label) {
  openCash('Tolak ' + label, '', `<label for="cReason">Alasan penolakan</label><input id="cReason" required>`, 'Tolak', async () => {
    if (kind === 'nota') await api('fin_decide_expense', { p_expense_id: id, p_approve: false, p_reason: fv('cReason') });
    else await api('fin_decide_cash', { p_request_id: id, p_approve: false, p_reason: fv('cReason') });
    toast(label + ' ditolak');
  });
}

$('page-kas').addEventListener('click', async (ev) => {
  const d = cache.kas; if (!d) return;
  const t = (attr) => ev.target.closest(`[${attr}]`);
  const fundOf = (id) => d.funds.find((f) => String(f.fund_id) === String(id));
  const reqOf = (id) => d.requests.find((r) => String(r.request_id) === String(id));
  let b;
  if ((b = t('data-nota-fund'))) {
    const f = fundOf(b.dataset.notaFund);
    const avail = num(f.balance) - num(f.pending_notes);
    notaForm('PETTY_CASH', f.fund_id, 'Nota Kas Site', `${f.fund_name} · tersedia ${rp(avail)} · batas per nota ${rp(f.max_per_note)}`, f.project_id);
  } else if ((b = t('data-nota-kasbon'))) {
    const r = reqOf(b.dataset.notaKasbon);
    notaForm('KASBON', r.request_id, 'Nota Kasbon', `${r.employee_name} · kasbon ${rp(r.paid_amount)} · sudah dipertanggungjawabkan ${rp(num(r.settled) + num(r.pending_notes))}`, r.project_id);
  } else if ((b = t('data-topup'))) {
    const f = fundOf(b.dataset.topup);
    const max = Math.max(0, num(f.ceiling) - num(f.balance) - num(f.pending_topup));
    openCash('Ajukan Isi Kas', `${f.fund_name} · saldo ${rp(f.balance)} · plafon ${rp(f.ceiling)}`, `
      <label for="cAmt">Nilai isi kas (Rp)</label><input id="cAmt" inputmode="numeric" value="${max.toLocaleString('id-ID')}" required>
      <p class="small muted">Disarankan mengisi sampai plafon (${rp(max)}). Ditransfer dari bank HO setelah disetujui APY.</p>
      <label for="cDesc">Keterangan</label><input id="cDesc" value="Isi ulang kas ${esc(f.fund_name)}" required>`, 'Ajukan', async () => {
      await api('fin_request_cash', { p_kind: 'TOPUP', p_fund_id: f.fund_id, p_employee_id: null, p_project_id: null, p_payee: null, p_account_code: null,
        p_amount: parseNum(fv('cAmt')), p_ppn_amount: 0, p_pph23_amount: 0, p_due_date: null, p_description: fv('cDesc') });
      toast('Pengajuan isi kas terkirim, menunggu approval APY');
    });
  } else if ((b = t('data-edit-fund'))) fundForm(fundOf(b.dataset.editFund));
  else if ((b = t('data-docs-nota'))) openDocs('NOTA', Number(b.dataset.docsNota), b.dataset.title);
  else if ((b = t('data-docs-direct'))) openDocs('DIRECT', Number(b.dataset.docsDirect), b.dataset.title);
  else if ((b = t('data-approve-nota'))) {
    b.disabled = true;
    try { await api('fin_decide_expense', { p_expense_id: Number(b.dataset.approveNota), p_approve: true, p_reason: null }); toast('Nota disetujui'); loadKas(); }
    catch (e) { toast(e.message, true); b.disabled = false; }
  } else if ((b = t('data-reject-nota'))) rejectForm('nota', Number(b.dataset.rejectNota), 'nota');
  else if ((b = t('data-approve-req'))) {
    const r = reqOf(b.dataset.approveReq);
    if (!confirm(`Setujui ${KIND_LABEL[r.kind].toLowerCase()} ${rp(r.amount)}?`)) return;
    b.disabled = true;
    try { await api('fin_decide_cash', { p_request_id: r.request_id, p_approve: true, p_reason: null }); toast('Pengajuan disetujui'); loadKas(); }
    catch (e) { toast(e.message, true); b.disabled = false; }
  } else if ((b = t('data-reject-req'))) rejectForm('req', Number(b.dataset.rejectReq), 'pengajuan');
  else if ((b = t('data-pay-req'))) {
    const r = reqOf(b.dataset.payReq);
    if (!d.banks.length) { toast('Tambahkan rekening bank dulu di menu Bank.', true); return; }
    const pay = r.kind === 'DIRECT' ? num(r.amount) - num(r.pph23_amount) : num(r.amount);
    openCash('Tandai Dibayar', `${KIND_LABEL[r.kind]} · ${r.kind === 'TOPUP' ? r.fund_name : r.kind === 'KASBON' ? r.employee_name : r.payee} · ${rp(pay)}`, `
      <label for="cBank">Dibayar dari rekening</label><select id="cBank" required>${bankOptions()}</select>
      <div class="row2"><div><label for="cDate">Tanggal bayar</label><input type="date" id="cDate" value="${today()}" required></div>
        <div><label for="cRef">No. bukti transfer</label><input id="cRef"></div></div>`, 'Simpan', async () => {
      await api('fin_pay_cash', { p_request_id: r.request_id, p_bank_id: Number(fv('cBank')), p_paid_date: fv('cDate'), p_payment_ref: fv('cRef') });
      toast('Pembayaran tercatat');
    });
  } else if ((b = t('data-close-kasbon'))) {
    const r = reqOf(b.dataset.closeKasbon);
    if (num(r.pending_notes)) { toast('Masih ada nota kasbon yang menunggu approval APC.', true); return; }
    const diff = num(r.paid_amount) - num(r.settled);
    const line = diff > 0 ? `Sisa <b>${rp(diff)}</b> dikembalikan karyawan ke rekening perusahaan.` : diff < 0 ? `Kekurangan <b>${rp(-diff)}</b> dibayarkan ke karyawan.` : 'Nota sama dengan kasbon, tidak ada selisih.';
    openCash('Tutup Kasbon', `${r.employee_name} · ${r.description}`, `
      <div class="diff-box">Kasbon ${rp(r.paid_amount)}<br>Nota disetujui ${rp(r.settled)}<br>${line}</div>
      ${diff !== 0 ? `<label for="cBank">${diff > 0 ? 'Diterima di rekening' : 'Dibayar dari rekening'}</label><select id="cBank" required>${bankOptions()}</select>` : ''}
      <div class="row2"><div><label for="cDate">Tanggal</label><input type="date" id="cDate" value="${today()}" required></div>
        <div><label for="cRef">No. bukti</label><input id="cRef"></div></div>`, 'Tutup kasbon', async () => {
      await api('fin_close_kasbon', { p_request_id: r.request_id, p_bank_id: diff !== 0 ? Number(fv('cBank')) : null, p_close_date: fv('cDate'), p_ref: fv('cRef') });
      toast('Kasbon ditutup');
    });
  }
});


// ---------- saldo awal, mutasi & rekonsiliasi bank ----------
const BTX_LABEL = { OPENING: 'Saldo awal', ADMIN_FEE: 'Biaya admin bank', INTEREST: 'Bunga / jasa giro', INTEREST_TAX: 'Pajak bunga',
  TRANSFER: 'Transfer antar rekening', OTHER_IN: 'Uang masuk lain', OTHER_OUT: 'Uang keluar lain' };
const BTX_IN = ['OPENING', 'INTEREST', 'OTHER_IN'];
async function loadBank() {
  try { renderBank(await api('fin_bank_overview')); } catch (e) { toast(e.message, true); }
}
function renderBank(b) {
  cache.bank = b;
  if (!b) return;
  const act = b.banks.filter((x) => x.is_active);
  const pend = b.txns.filter((t) => t.status === 'PLANNED');
  const noOpen = act.filter((x) => !x.opening || x.opening.status !== 'APPROVED');
  const kpi = (label, val, sub, alert) => `<div class="kpi${alert ? ' alert' : ''}"><div class="k-label">${esc(label)}</div><div class="k-val">${esc(val)}</div><div class="k-sub">${esc(sub)}</div></div>`;
  $('bankKpis').innerHTML =
    kpi('Total saldo bank', rpShort(act.reduce((t, x) => t + num(x.balance), 0)), `${act.length} rekening aktif`) +
    kpi('Mutasi menunggu PJ', String(pend.length), pend.length ? rpShort(pend.reduce((t, x) => t + num(x.amount), 0)) : 'tidak ada', pend.length > 0) +
    kpi('Belum ada saldo awal', String(noOpen.length), noOpen.length ? noOpen.map((x) => x.label).join(', ') : 'semua rekening lengkap', noOpen.length > 0);
  $('bankTable').innerHTML = '<tr><th>Rekening</th><th>Akun COA</th><th class="num">Saldo (dari jurnal)</th><th>Saldo awal</th><th>Rekonsiliasi terakhir</th></tr>' +
    (b.banks.length ? b.banks.map((x) => {
      const o = x.opening, r = x.last_recon;
      const op = !o ? '<span class="small overdue">Belum diisi</span>' : `${tgl(o.date)} · ${rpShort(o.amount)}${o.status === 'PLANNED' ? ' <span class="badge warn">Menunggu PJ</span>' : ''}`;
      const rc = !r ? '<span class="small muted">-</span>' : `${tgl(r.period_end)} ${r.status === 'APPROVED' ? '<span class="badge ok">OK</span>' : '<span class="badge warn">Menunggu PJ</span>'}${num(r.difference) ? `<div class="small overdue">selisih ${rp(r.difference)}</div>` : ''}`;
      return `<tr><td><b>${esc(x.label)}</b><div class="small muted">${esc(x.bank_name)}${x.last4 ? ' · ****' + esc(x.last4) : ''}${x.is_active ? '' : ' · nonaktif'}</div></td>
        <td>${esc(x.coa_code)}</td><td class="num">${rp(x.balance)}</td><td class="small">${op}</td><td class="small">${rc}</td></tr>`;
    }).join('') : emptyRow(5, 'Belum ada rekening. Tambahkan lewat form di samping.'));
  const f = $('btxFilter').value;
  const rows = b.txns.filter((t) => f === 'ALL' || t.status === 'PLANNED');
  const canPJ = hasAuthor('PJ');
  $('btxTable').innerHTML = '<tr><th>Tanggal</th><th>Jenis</th><th>Rekening</th><th>Keterangan</th><th class="num">Nilai</th><th>Status</th><th></th></tr>' +
    (rows.length ? rows.map((t) => {
      const sign = t.kind === 'TRANSFER' ? '' : BTX_IN.includes(t.kind) ? '+' : '−';
      const acts = t.status === 'PLANNED' && canPJ
        ? `<button type="button" class="btn primary small" data-approve-btx="${esc(t.txn_id)}">Setujui</button><button type="button" class="btn ghost small" data-reject-btx="${esc(t.txn_id)}">Tolak</button>` : '';
      const st = t.status === 'PLANNED' ? '<span class="badge warn">Menunggu PJ</span>' : t.status === 'APPROVED' ? '<span class="badge ok">Disetujui</span>' : '<span class="badge">Ditolak</span>';
      const who = t.status === 'REJECTED' ? `<div class="small overdue">${esc(t.reject_reason || '')}</div>` : t.approved_by ? `<div class="small muted">${esc(t.approved_by)}</div>` : `<div class="small muted">oleh ${esc(t.requested_by || '')}</div>`;
      return `<tr><td>${tgl(t.txn_date)}</td><td>${esc(BTX_LABEL[t.kind])}${t.account_code ? `<div class="small muted">${esc(t.account_code)} ${esc(t.account_name || '')}</div>` : ''}</td>
        <td>${esc(t.bank_label)}${t.to_bank_label ? ' → ' + esc(t.to_bank_label) : ''}</td>
        <td>${esc(t.description)}${t.ref_no ? `<div class="small muted">${esc(t.ref_no)}</div>` : ''}</td>
        <td class="num">${sign} ${rp(t.amount)}</td><td>${st}${who}</td><td><div class="row-gap">${acts}</div></td></tr>`;
    }).join('') : emptyRow(7, f === 'OPEN' ? 'Tidak ada mutasi yang menunggu persetujuan' : 'Belum ada mutasi'));
  $('reconTable').innerHTML = '<tr><th>Per tanggal</th><th>Rekening</th><th class="num">Rekening koran</th><th class="num">SmartFin</th><th class="num">Selisih</th><th>Status</th><th></th></tr>' +
    (b.recons.length ? b.recons.map((r) => {
      const diff = num(r.statement_balance) - num(r.system_now);
      const acts = r.status === 'DRAFT' ? [
        hasPic('fin-ap') ? `<button type="button" class="btn ghost small" data-edit-recon="${esc(r.recon_id)}">Ubah</button>` : '',
        canPJ ? `<button type="button" class="btn primary small" data-approve-recon="${esc(r.recon_id)}">Setujui</button>` : ''].join('') : '';
      return `<tr><td>${tgl(r.period_end)}</td><td>${esc(r.bank_label)}</td><td class="num">${rp(r.statement_balance)}</td>
        <td class="num">${rp(r.status === 'APPROVED' ? r.system_balance : r.system_now)}</td>
        <td class="num ${Math.abs(r.status === 'APPROVED' ? num(r.difference) : diff) > 0 ? 'overdue' : ''}">${rp(r.status === 'APPROVED' ? r.difference : diff)}${r.notes ? `<div class="small muted">${esc(r.notes)}</div>` : ''}</td>
        <td>${r.status === 'APPROVED' ? `<span class="badge ok">Disetujui</span><div class="small muted">${esc(r.approved_by || '')}</div>` : '<span class="badge warn">Menunggu PJ</span>'}</td>
        <td><div class="row-gap">${acts}</div></td></tr>`;
    }).join('') : emptyRow(7, 'Belum ada rekonsiliasi'));
  const ho = hasPic('fin-ap');
  ['newOpeningBtn', 'newBankTxnBtn', 'newReconBtn'].forEach((id) => { $(id).hidden = !ho; });
}
$('btxFilter').addEventListener('change', () => renderBank(cache.bank));
const activeBanks = () => (cache.bank ? cache.bank.banks.filter((b) => b.is_active) : []);
const bankOpts = (list, sel) => list.map((b) => opt(b.bank_id, `${b.label} (${b.bank_name})`, String(b.bank_id) === String(sel))).join('');
$('newOpeningBtn').addEventListener('click', () => {
  const list = activeBanks().filter((b) => !b.opening);
  if (!list.length) { toast(activeBanks().length ? 'Semua rekening sudah punya saldo awal.' : 'Tambahkan rekening bank dulu.', true); return; }
  openCash('Saldo Awal Rekening', 'Isi sesuai saldo rekening koran pada tanggal cut-off (mulai pakai SmartFin). Satu kali per rekening.', `
    <label for="cBank">Rekening</label><select id="cBank" required>${bankOpts(list)}</select>
    <div class="row2"><div><label for="cDate">Tanggal cut-off</label><input type="date" id="cDate" max="${today()}" required></div>
      <div><label for="cAmt">Saldo per tanggal cut-off (Rp)</label><input id="cAmt" inputmode="numeric" required></div></div>
    <label for="cRef">No. / periode rekening koran</label><input id="cRef" placeholder="mis. RK Okt 2026">
    <p class="small muted">Mutasi sebelum tanggal cut-off tidak bisa diinput. Jurnal: Bank / Ekuitas Saldo Awal (3-9000).</p>`, 'Ajukan ke PJ', async () => {
    await api('fin_save_bank_txn', { p_kind: 'OPENING', p_bank_id: Number(fv('cBank')), p_to_bank_id: null, p_txn_date: fv('cDate'),
      p_amount: parseNum(fv('cAmt')), p_account_code: null, p_project_id: null, p_description: 'Saldo awal per ' + fv('cDate'), p_ref_no: fv('cRef') });
    toast('Saldo awal diajukan, menunggu persetujuan PJ');
  });
});
$('newBankTxnBtn').addEventListener('click', () => {
  const list = activeBanks();
  if (!list.length) { toast('Tambahkan rekening bank dulu.', true); return; }
  const accs = cache.bank.accounts.map((a) => opt(a.code, `${a.code} · ${a.name}`)).join('');
  const projs = opt('', '— tanpa proyek —') + cache.bank.projects.map((p) => opt(p.project_id, `${p.code} · ${p.name}`)).join('');
  openCash('Mutasi Bank', 'Transaksi bank yang tidak lewat modul lain.', `
    <div class="row2"><div><label for="cKind">Jenis</label><select id="cKind">${['ADMIN_FEE', 'INTEREST', 'INTEREST_TAX', 'TRANSFER', 'OTHER_IN', 'OTHER_OUT'].map((k) => opt(k, BTX_LABEL[k])).join('')}</select></div>
      <div><label for="cBank">Rekening</label><select id="cBank" required>${bankOpts(list)}</select></div></div>
    <div id="cToWrap" hidden><label for="cTo">Ke rekening</label><select id="cTo">${bankOpts(list)}</select></div>
    <div id="cAccWrap" hidden><div class="row2"><div><label for="cAcc">Akun lawan</label><select id="cAcc">${accs}</select></div>
      <div><label for="cProj">Proyek</label><select id="cProj">${projs}</select></div></div></div>
    <div class="row2"><div><label for="cDate">Tanggal</label><input type="date" id="cDate" value="${today()}" max="${today()}" required></div>
      <div><label for="cAmt">Nilai (Rp)</label><input id="cAmt" inputmode="numeric" required></div></div>
    <div class="row2"><div><label for="cDesc">Keterangan</label><input id="cDesc" required></div>
      <div><label for="cRef">No. referensi</label><input id="cRef"></div></div>`, 'Ajukan ke PJ', async () => {
    const k = fv('cKind');
    await api('fin_save_bank_txn', { p_kind: k, p_bank_id: Number(fv('cBank')), p_to_bank_id: k === 'TRANSFER' ? Number(fv('cTo')) : null,
      p_txn_date: fv('cDate'), p_amount: parseNum(fv('cAmt')), p_account_code: ['OTHER_IN', 'OTHER_OUT'].includes(k) ? fv('cAcc') : null,
      p_project_id: ['OTHER_IN', 'OTHER_OUT'].includes(k) ? (fv('cProj') || null) : null, p_description: fv('cDesc'), p_ref_no: fv('cRef') });
    toast('Mutasi diajukan, menunggu persetujuan PJ');
  });
  const sync = () => {
    const k = $('cKind').value;
    $('cToWrap').hidden = k !== 'TRANSFER';
    $('cAccWrap').hidden = !['OTHER_IN', 'OTHER_OUT'].includes(k);
    if (!$('cDesc').dataset.touched) $('cDesc').value = BTX_LABEL[k];
  };
  $('cKind').addEventListener('change', sync);
  $('cDesc').addEventListener('input', () => { $('cDesc').dataset.touched = '1'; });
  sync();
});
function reconForm(r) {
  const list = cache.bank.banks;
  if (!list.length) { toast('Tambahkan rekening bank dulu.', true); return; }
  openCash(r ? 'Ubah Rekonsiliasi' : 'Rekonsiliasi Bank', 'Saldo SmartFin dihitung dari jurnal sampai tanggal yang dipilih.', `
    <div class="row2"><div><label for="cBank">Rekening</label><select id="cBank" required ${r ? 'disabled' : ''}>${bankOpts(list, r && r.bank_id)}</select></div>
      <div><label for="cDate">Per tanggal</label><input type="date" id="cDate" value="${r ? r.period_end : today()}" max="${today()}" required ${r ? 'disabled' : ''}></div></div>
    <label for="cAmt">Saldo akhir rekening koran (Rp)</label><input id="cAmt" inputmode="numeric" value="${r ? num(r.statement_balance).toLocaleString('id-ID') : ''}" required>
    <label for="cNotes">Penjelasan selisih (wajib kalau masih ada selisih)</label><input id="cNotes" value="${esc(r ? r.notes || '' : '')}">`, 'Simpan', async () => {
    const res = await api('fin_save_recon', { p_bank_id: Number(fv('cBank')), p_period_end: fv('cDate'), p_statement_balance: parseNum(fv('cAmt')), p_notes: fv('cNotes') });
    toast(num(res.difference) === 0 ? 'Rekonsiliasi cocok, menunggu persetujuan PJ' : `Tersimpan. Selisih ${rp(res.difference)}`, num(res.difference) !== 0);
  });
}
$('newReconBtn').addEventListener('click', () => reconForm(null));
$('page-bank').addEventListener('click', async (ev) => {
  const b = cache.bank; if (!b) return;
  const t = (attr) => ev.target.closest(`[${attr}]`);
  let el;
  if ((el = t('data-approve-btx'))) {
    const x = b.txns.find((y) => String(y.txn_id) === el.dataset.approveBtx);
    if (!confirm(`Setujui ${BTX_LABEL[x.kind].toLowerCase()} ${rp(x.amount)} (${x.bank_label})? Jurnal langsung terposting.`)) return;
    el.disabled = true;
    try { await api('fin_decide_bank_txn', { p_txn_id: x.txn_id, p_approve: true, p_reason: null }); toast('Mutasi disetujui dan terposting'); loadBank(); }
    catch (e) { toast(e.message, true); el.disabled = false; }
  } else if ((el = t('data-reject-btx'))) {
    const id = Number(el.dataset.rejectBtx);
    openCash('Tolak Mutasi', '', '<label for="cReason">Alasan penolakan</label><input id="cReason" required>', 'Tolak', async () => {
      await api('fin_decide_bank_txn', { p_txn_id: id, p_approve: false, p_reason: fv('cReason') }); toast('Mutasi ditolak');
    });
  } else if ((el = t('data-edit-recon'))) reconForm(b.recons.find((r) => String(r.recon_id) === el.dataset.editRecon));
  else if ((el = t('data-approve-recon'))) {
    el.disabled = true;
    try { const r = await api('fin_approve_recon', { p_recon_id: Number(el.dataset.approveRecon) }); toast(num(r.difference) === 0 ? 'Rekonsiliasi disetujui' : `Rekonsiliasi disetujui dengan selisih ${rp(r.difference)}`); loadBank(); }
    catch (e) { toast(e.message, true); el.disabled = false; }
  }
});

const loaders = { dashboard: loadDashboard, ap: loadAP, bayar: loadBayar, bank: loadBank, kas: loadKas, jurnal: loadJurnal, budget: loadBudget, aset: loadAset };

// ---------- start ----------
(function init() {
  const d = new Date(); d.setMonth(d.getMonth() - 1);
  $('depPeriod').value = d.toISOString().slice(0, 7);
  try { session = JSON.parse(sessionStorage.getItem(SESSION_KEY)); } catch (e) { session = null; }
  if (session && session.token && new Date(session.expiresAt) > new Date()) startApp();
  else { session = null; loadAccounts(); }
})();
