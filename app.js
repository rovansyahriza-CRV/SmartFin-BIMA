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
const ICON = {
  dashboard: 'M3.75 6A2.25 2.25 0 0 1 6 3.75h2.25A2.25 2.25 0 0 1 10.5 6v2.25a2.25 2.25 0 0 1-2.25 2.25H6a2.25 2.25 0 0 1-2.25-2.25V6ZM3.75 15.75A2.25 2.25 0 0 1 6 13.5h2.25a2.25 2.25 0 0 1 2.25 2.25V18a2.25 2.25 0 0 1-2.25 2.25H6A2.25 2.25 0 0 1 3.75 18v-2.25ZM13.5 6a2.25 2.25 0 0 1 2.25-2.25H18A2.25 2.25 0 0 1 20.25 6v2.25A2.25 2.25 0 0 1 18 10.5h-2.25a2.25 2.25 0 0 1-2.25-2.25V6ZM13.5 15.75a2.25 2.25 0 0 1 2.25-2.25H18a2.25 2.25 0 0 1 2.25 2.25V18A2.25 2.25 0 0 1 18 20.25h-2.25A2.25 2.25 0 0 1 13.5 18v-2.25Z',
  ap: 'M19.5 14.25v-2.625a3.375 3.375 0 0 0-3.375-3.375h-1.5A1.125 1.125 0 0 1 13.5 7.125v-1.5a3.375 3.375 0 0 0-3.375-3.375H8.25m0 12.75h7.5m-7.5 3H12M10.5 2.25H5.625c-.621 0-1.125.504-1.125 1.125v17.25c0 .621.504 1.125 1.125 1.125h12.75c.621 0 1.125-.504 1.125-1.125V11.25a9 9 0 0 0-9-9Z',
  bayar: 'M2.25 8.25h19.5M2.25 9h19.5m-16.5 5.25h6m-6 2.25h3m-3.75 3h15a2.25 2.25 0 0 0 2.25-2.25V6.75A2.25 2.25 0 0 0 19.5 4.5h-15a2.25 2.25 0 0 0-2.25 2.25v10.5A2.25 2.25 0 0 0 4.5 19.5Z',
  bank: 'M12 21v-8.25M15.75 21v-8.25M8.25 21v-8.25M3 9l9-6 9 6m-1.5 12V10.332A48.36 48.36 0 0 0 12 9.75c-2.551 0-5.056.2-7.5.582V21M3 21h18M12 6.75h.008v.008H12V6.75Z',
  kas: 'M2.25 18.75a60.07 60.07 0 0 1 15.797 2.101c.727.198 1.453-.342 1.453-1.096V18.75M3.75 4.5v.75A.75.75 0 0 1 3 6h-.75m0 0v-.375c0-.621.504-1.125 1.125-1.125H20.25M2.25 6v9m18-10.5v.75c0 .414.336.75.75.75h.75m-1.5-1.5h.375c.621 0 1.125.504 1.125 1.125v9.75c0 .621-.504 1.125-1.125 1.125h-.375m1.5-1.5H21a.75.75 0 0 0-.75.75v.75m0 0H3.75m0 0h-.375a1.125 1.125 0 0 1-1.125-1.125V15m1.5 1.5v-.75A.75.75 0 0 0 3 15h-.75M15 10.5a3 3 0 1 1-6 0 3 3 0 0 1 6 0Zm3 0h.008v.008H18V10.5Zm-12 0h.008v.008H6V10.5Z',
  jurnal: 'M12 6.042A8.967 8.967 0 0 0 6 3.75c-1.052 0-2.062.18-3 .512v14.25A8.987 8.987 0 0 1 6 18c2.305 0 4.408.867 6 2.292m0-14.25a8.966 8.966 0 0 1 6-2.292c1.052 0 2.062.18 3 .512v14.25A8.987 8.987 0 0 0 18 18a8.967 8.967 0 0 0-6 2.292m0-14.25v14.25',
  budget: 'M10.5 6a7.5 7.5 0 1 0 7.5 7.5h-7.5V6ZM13.5 10.5H21A7.5 7.5 0 0 0 13.5 3v7.5Z',
  aset: 'm21 7.5-9-5.25L3 7.5m18 0-9 5.25m9-5.25v9l-9 5.25M3 7.5l9 5.25M3 7.5v9l9 5.25m0-9v9',
  laporan: 'M19.5 14.25v-2.625a3.375 3.375 0 0 0-3.375-3.375h-1.5A1.125 1.125 0 0 1 13.5 7.125v-1.5a3.375 3.375 0 0 0-3.375-3.375H8.25M9 16.5v.75m3-3v3M15 12v5.25m-4.5-15H5.625c-.621 0-1.125.504-1.125 1.125v17.25c0 .621.504 1.125 1.125 1.125h12.75c.621 0 1.125-.504 1.125-1.125V11.25a9 9 0 0 0-9-9Z',
  ar: 'M9 14.25l6-6m4.5-3.493V21.75l-3.75-1.5-3.75 1.5-3.75-1.5-3.75 1.5V4.757c0-1.108.806-2.057 1.907-2.185a48.507 48.507 0 0 1 11.186 0c1.1.128 1.907 1.077 1.907 2.185ZM9.75 9h.008v.008H9.75V9Zm.375 0a.375.375 0 1 1-.75 0 .375.375 0 0 1 .75 0Zm4.125 4.5h.008v.008h-.008V13.5Zm.375 0a.375.375 0 1 1-.75 0 .375.375 0 0 1 .75 0Z',
  payroll: 'M15 19.128a9.38 9.38 0 0 0 2.625.372 9.337 9.337 0 0 0 4.121-.952 4.125 4.125 0 0 0-7.533-2.493M15 19.128v-.003c0-1.113-.285-2.16-.786-3.07M15 19.128v.106A12.318 12.318 0 0 1 8.624 21c-2.331 0-4.512-.645-6.374-1.766l-.001-.109a6.375 6.375 0 0 1 11.964-3.07M12 6.375a3.375 3.375 0 1 1-6.75 0 3.375 3.375 0 0 1 6.75 0Zm8.25 2.25a2.625 2.625 0 1 1-5.25 0 2.625 2.625 0 0 1 5.25 0Z',
  pajak: 'M15.75 15.75V18m-7.5-6.75h.008v.008H8.25v-.008Zm0 2.25h.008v.008H8.25V13.5Zm0 2.25h.008v.008H8.25v-.008Zm0 2.25h.008v.008H8.25V18Zm2.498-6.75h.007v.008h-.007v-.008Zm0 2.25h.007v.008h-.007V13.5Zm0 2.25h.007v.008h-.007v-.008Zm0 2.25h.007v.008h-.007V18Zm2.504-6.75h.008v.008h-.008v-.008Zm0 2.25h.008v.008h-.008V13.5Zm0 2.25h.008v.008h-.008v-.008Zm0 2.25h.008v.008h-.008V18Zm2.498-6.75h.008v.008h-.008v-.008Zm0 2.25h.008v.008h-.008V13.5ZM8.25 6h7.5v2.25h-7.5V6ZM12 2.25c-1.892 0-3.758.11-5.593.322C5.307 2.7 4.5 3.65 4.5 4.757V19.5a2.25 2.25 0 0 0 2.25 2.25h10.5a2.25 2.25 0 0 0 2.25-2.25V4.757c0-1.108-.806-2.057-1.907-2.185A48.507 48.507 0 0 0 12 2.25Z',
  truck: 'M8.25 18.75a1.5 1.5 0 0 1-3 0m3 0a1.5 1.5 0 0 0-3 0m3 0h6m-9 0H3.375a1.125 1.125 0 0 1-1.125-1.125V14.25m17.25 4.5a1.5 1.5 0 0 1-3 0m3 0a1.5 1.5 0 0 0-3 0m3 0h1.125c.621 0 1.129-.504 1.09-1.124a17.902 17.902 0 0 0-3.213-9.193 2.056 2.056 0 0 0-1.58-.86H14.25M16.5 18.75h-2.25m0-11.177v-.958c0-.568-.422-1.048-.987-1.106a48.554 48.554 0 0 0-10.026 0 1.106 1.106 0 0 0-.987 1.106v7.635m12-6.677v6.677m0 4.5v-4.5m0 0h-12',
  scale: 'M12 3v17.25m0 0c-1.472 0-2.882.265-4.185.75M12 20.25c1.472 0 2.882.265 4.185.75M18.75 4.97A48.416 48.416 0 0 0 12 4.5c-2.291 0-4.545.16-6.75.47m13.5 0c1.01.143 2.01.317 3 .52m-3-.52 2.62 10.726c.122.499-.106 1.028-.589 1.202a5.988 5.988 0 0 1-2.031.352 5.988 5.988 0 0 1-2.031-.352c-.483-.174-.711-.703-.59-1.202L18.75 4.971Zm-16.5.52c.99-.203 1.99-.377 3-.52m0 0 2.62 10.726c.122.499-.106 1.028-.589 1.202a5.989 5.989 0 0 1-2.031.352 5.989 5.989 0 0 1-2.031-.352c-.483-.174-.711-.703-.59-1.202L5.25 4.971Z',
  trend: 'M2.25 18 9 11.25l4.306 4.306a11.95 11.95 0 0 1 5.814-5.518l2.74-1.22m0 0-5.94-2.281m5.94 2.28-2.28 5.941',
  warn: 'M12 9v3.75m-9.303 3.376c-.866 1.5.217 3.374 1.948 3.374h14.71c1.73 0 2.813-1.874 1.948-3.374L13.949 3.378c-.866-1.5-3.032-1.5-3.898 0L2.697 16.126ZM12 15.75h.007v.008H12v-.008Z',
};
const svgIcon = (k) => `<svg fill="none" viewBox="0 0 24 24" stroke-width="1.6" stroke="currentColor" aria-hidden="true"><path stroke-linecap="round" stroke-linejoin="round" d="${ICON[k]}"/></svg>`;
const NAV = [
  { group: 'Ringkasan', items: [
    { page: 'dashboard', label: 'Dashboard', pic: 'fin,fin-ap,fin-jv,fin-bva,fin-ast' }] },
  { group: 'Kas, Hutang & Piutang', items: [
    { page: 'ap', label: 'Hutang Vendor (AP)', pic: 'fin-ap' },
    { page: 'bayar', label: 'Pembayaran', pic: 'fin-ap' },
    { page: 'bank', label: 'Bank', pic: 'fin-ap,fin-jv' },
    { page: 'kas', label: 'Kas & Kasbon', pic: 'fin-ap,fin-pc' },
    { page: 'ar', label: 'Piutang Klien (AR)', pic: 'fin-ar,fin-jv' },
    { page: 'payroll', label: 'Payroll', pic: 'fin-pr,fin-ap' }] },
  { group: 'Pembukuan & Kontrol', items: [
    { page: 'jurnal', label: 'Jurnal', pic: 'fin-jv' },
    { page: 'budget', label: 'Budget vs Actual', pic: 'fin-bva' },
    { page: 'aset', label: 'Aset Tetap', pic: 'fin-ast' },
    { page: 'laporan', label: 'Laporan', pic: 'fin-rpt' },
    { page: 'pajak', label: 'Pajak', pic: 'fin-tax' }] },
];
const navItems = () => NAV.flatMap((g) => g.items.map((i) => ({ ...i, group: g.group })));
const canSee = (page) => { const i = navItems().find((x) => x.page === page); return !!i && hasPic(i.pic); };

function buildNav() {
  $('nav').innerHTML = NAV.map((g) => {
    const items = g.items.filter((i) => hasPic(i.pic));
    if (!items.length) return '';
    return `<div class="nav-group"><div class="nav-label">${esc(g.group)}</div>` +
      items.map((i) => `<a href="#${i.page}" data-page="${i.page}">${svgIcon(i.page)}<span>${esc(i.label)}</span><span class="nav-badge" data-badge="${i.page}" hidden></span></a>`).join('') + '</div>';
  }).join('');
}
function setNavBadge(page, n, alert) {
  const b = document.querySelector(`[data-badge="${page}"]`);
  if (!b) return;
  b.hidden = !(num(n) > 0);
  b.textContent = num(n) > 99 ? '99+' : String(num(n));
  b.classList.toggle('alert', !!alert);
}

function startApp() {
  $('loginView').hidden = true;
  $('appView').hidden = false;
  const role = isSuper() ? 'Admin' : (session.pic.filter((p) => p !== 'fin').map((p) => p.toUpperCase())[0] || 'FIN');
  $('userName').textContent = session.name;
  $('userRole').textContent = '· ' + role;
  $('userAvatar').textContent = initials(session.name);
  $('pmName').textContent = session.name;
  $('pmCodes').innerHTML = [...session.pic.map((p) => p.toUpperCase()), ...session.author.map((a) => a.toUpperCase())]
    .map((c) => `<span class="tag-code">${esc(c)}</span>`).join('') || '<span class="muted small">Tanpa kode akses</span>';
  buildNav();
  $('newInvoiceBtn').hidden = !hasPic('fin-ap');
  go(location.hash.slice(1) || 'dashboard');
}

function go(page) {
  if (!canSee(page)) {
    const first = document.querySelector('#nav a');
    page = first ? first.dataset.page : 'dashboard';
  }
  document.querySelectorAll('.page').forEach((s) => { s.hidden = s.id !== 'page-' + page; });
  document.querySelectorAll('#nav a').forEach((a) => {
    const on = a.dataset.page === page;
    a.classList.toggle('active', on);
    if (on) a.setAttribute('aria-current', 'page'); else a.removeAttribute('aria-current');
  });
  closeSide();
  window.scrollTo(0, 0);
  loaders[page]();
}
window.addEventListener('hashchange', () => session && go(location.hash.slice(1)));
document.addEventListener('click', (ev) => {
  const b = ev.target.closest('[data-refresh]');
  if (b) loaders[b.dataset.refresh]();
});

// sidebar mobile
const closeSide = () => { $('side').classList.remove('open'); $('sideBackdrop').classList.remove('open'); };
$('menuBtn').addEventListener('click', () => { $('side').classList.add('open'); $('sideBackdrop').classList.add('open'); });
$('sideBackdrop').addEventListener('click', closeSide);

// menu profil
const setProfile = (open) => { $('profileMenu').hidden = !open; $('profile').classList.toggle('open', open); $('profileBtn').setAttribute('aria-expanded', String(open)); };
$('profileBtn').addEventListener('click', (ev) => { ev.stopPropagation(); setProfile($('profileMenu').hidden); });
document.addEventListener('click', (ev) => { if (!ev.target.closest('#profile')) setProfile(false); });

// command palette (Ctrl/⌘ + K) — lompat antar menu yang boleh diakses
let cmdSel = 0;
function cmdRender() {
  const q = $('cmdInput').value.trim().toLowerCase();
  const list = navItems().filter((i) => hasPic(i.pic) && (!q || (i.label + ' ' + i.group + ' ' + i.page).toLowerCase().includes(q)));
  cmdSel = Math.min(cmdSel, Math.max(list.length - 1, 0));
  $('cmdList').innerHTML = list.length ? list.map((i, n) => `<button type="button" class="cmd-item${n === cmdSel ? ' sel' : ''}" data-go="${i.page}">${svgIcon(i.page)}${esc(i.label)}<small>${esc(i.group)}</small></button>`).join('')
    : '<div class="muted small" style="padding:14px">Menu tidak ditemukan.</div>';
}
function cmdOpen() { if (!session) return; $('cmdInput').value = ''; cmdSel = 0; cmdRender(); $('cmdDialog').showModal(); $('cmdInput').focus(); }
function cmdGo(page) { $('cmdDialog').close(); if (location.hash.slice(1) === page) go(page); else location.hash = page; }
$('cmdBtn').addEventListener('click', cmdOpen);
$('cmdInput').addEventListener('input', () => { cmdSel = 0; cmdRender(); });
$('cmdInput').addEventListener('keydown', (ev) => {
  const items = [...document.querySelectorAll('#cmdList .cmd-item')];
  if (ev.key === 'ArrowDown') { ev.preventDefault(); cmdSel = (cmdSel + 1) % Math.max(items.length, 1); cmdRender(); }
  else if (ev.key === 'ArrowUp') { ev.preventDefault(); cmdSel = (cmdSel - 1 + items.length) % Math.max(items.length, 1); cmdRender(); }
  else if (ev.key === 'Enter' && items[cmdSel]) { ev.preventDefault(); cmdGo(items[cmdSel].dataset.go); }
});
$('cmdList').addEventListener('click', (ev) => { const b = ev.target.closest('[data-go]'); if (b) cmdGo(b.dataset.go); });
$('cmdDialog').addEventListener('click', (ev) => { if (ev.target === $('cmdDialog')) $('cmdDialog').close(); });
document.addEventListener('keydown', (ev) => {
  if ((ev.ctrlKey || ev.metaKey) && ev.key.toLowerCase() === 'k') { ev.preventDefault(); cmdOpen(); }
});

// ---------- dashboard ----------
let bvaUnit = 'jt';
const money = (v) => bvaUnit === 'jt' ? rpShort(v) : rp(v);
async function loadDashboard() {
  try {
    const d = await api('fin_dashboard');
    cache.dashboard = d;
    const k = d.kpi;
    $('dashTime').textContent = 'Data live · diperbarui ' + new Date(d.generatedAt).toLocaleString('id-ID', { dateStyle: 'medium', timeStyle: 'short' });
    const kpi = (icon, label, val, sub, pill) => `<div class="kpi2"><div class="k-top"><div class="k-label">${esc(label)}</div><span class="k-ic">${svgIcon(icon)}</span></div>
      <div class="k-val">${esc(val)}</div><div class="k-sub">${pill || esc(sub)}</div></div>`;
    const pill = (cls, t) => `<span class="pill ${cls}">${esc(t)}</span>`;
    $('kpis').innerHTML =
      kpi('truck', 'Hutang belum ditagih vendor', rpShort(k.hutangBelumDitagih), 'Barang sudah diterima, invoice belum masuk') +
      kpi('scale', 'Hutang usaha (invoice approved)', rpShort(k.hutangUsaha), '',
        num(k.jatuhTempo7Hari) > 0 ? pill('warn', `Jatuh tempo ≤ 7 hari: ${rpShort(k.jatuhTempo7Hari)}`) : pill('ok', 'Tidak ada jatuh tempo ≤ 7 hari')) +
      kpi('bayar', 'Pembayaran siap dibayar', rpShort(k.siapDibayar || 0), '',
        (k.menungguApproval || 0) > 0 ? pill('warn', `${k.menungguApproval} menunggu approval APY`) : pill('ok', 'Tidak ada antrean approval')) +
      kpi('trend', 'Realisasi biaya proyek', rpShort(k.realisasiTotal), 'Material diserahkan ke end user');

    const act = (cls, icon, label, val, linkText, page) => {
      const can = canSee(page);
      const tag = can ? `a href="#${page}"` : 'div';
      return `<${tag} class="act ${cls}"><div><div class="a-label">${esc(label)}</div><div class="a-main"><span class="a-val">${esc(val)}</span>${can ? `<span class="a-link">${esc(linkText)} →</span>` : ''}</div></div><span class="a-ic">${svgIcon(icon)}</span></${can ? 'a' : 'div'}>`;
    };
    const noBudget = num(k.budgetTotal) === 0;
    $('dashActions').innerHTML =
      act(noBudget ? 'amber' : 'calm', 'budget', 'Komitmen PO vs Budget', rpShort(k.komitmenTotal), noBudget ? 'RAB belum diinput' : `dari budget ${rpShort(k.budgetTotal)}`, 'budget') +
      act(k.errorJurnal > 0 ? 'rose' : 'calm', 'jurnal', 'Jurnal draft', `${k.jurnalDraft} jurnal`, k.errorJurnal > 0 ? `${k.errorJurnal} error jurnal otomatis` : 'Review & posting (PJ)', 'jurnal') +
      act(k.asetPerluDilengkapi > 0 ? 'rose' : 'calm', 'aset', 'Aset perlu dilengkapi', `${k.asetPerluDilengkapi} aset`, k.asetPerluDilengkapi > 0 ? 'Isi kategori & umur' : 'Semua lengkap', 'aset');
    setNavBadge('jurnal', k.jurnalDraft, k.errorJurnal > 0);
    setNavBadge('aset', k.asetPerluDilengkapi, true);

    renderDashBva();

    const dj = d.draftJournals || [];
    const srcCls = (s) => String(s || '').toUpperCase().replace(/[^A-Z0-9_]/g, '');
    $('dashDraft').innerHTML = '<tr><th>Tanggal</th><th>Sumber</th><th>Keterangan</th><th class="num">Nilai</th></tr>' +
      (dj.length ? dj.map((j) => `<tr class="jrow" data-dj="${esc(j.journal_id)}" tabindex="0"><td style="white-space:nowrap">${tgl(j.journal_date)}</td><td><span class="src-badge ${srcCls(j.source_system)}">${esc(j.source_system)}</span></td><td>${esc(j.description)}<div class="j-ref">JV-DRAFT #${esc(j.journal_id)}</div></td><td class="num"><b>${rp(j.amount)}</b></td></tr>`).join('') : emptyRow(4, 'Tidak ada jurnal draft'));

    const up = d.upcomingPayments || [];
    $('dashPay').innerHTML = '<tr><th>Jatuh tempo</th><th>Vendor / PO</th><th class="num">Nilai</th><th>Status</th></tr>' +
      (up.length ? up.map((p) => `<tr><td>${dueCell(p)}</td><td>${esc(p.vendor_name)}<div class="j-ref">${esc(p.po_number)}</div></td><td class="num">${rp(p.amount)}</td><td>${payBadge(p.status)}</td></tr>`).join('') : emptyRow(4, 'Tidak ada pembayaran terjadwal'));

    const m = d.matchSummary || {};
    $('dashMatch').innerHTML = Object.keys(m).length
      ? Object.entries(m).map(([s, n]) => `<span class="row-gap" style="gap:6px">${statusBadge(s)} <b>${esc(n)}</b></span>`).join('')
      : '<span class="muted">Belum ada PO</span>';
  } catch (e) { toast(e.message, true); }
}

function renderDashBva() {
  const d = cache.dashboard;
  if (!d) return;
  const rows = d.budgetVsActual || [];
  const canBudget = canSee('budget');
  $('dashBva').innerHTML = '<tr><th>Proyek</th><th class="num">Budget</th><th class="num">Komitmen</th><th class="num">Realisasi</th><th>Terpakai</th></tr>' +
    (rows.length ? rows.map((b) => {
      const budget = num(b.budget_amount), actual = num(b.actual_amount);
      const pct = budget > 0 ? Math.round(actual / budget * 100) : null;
      const used = pct === null
        ? (canBudget ? '<a href="#budget" class="btn-rab">+ Input RAB</a>' : '<span class="muted small">RAB belum ada</span>')
        : `<div class="row-gap" style="flex-wrap:nowrap"><div class="bar${pct > 85 ? ' over' : ''}" style="flex:1"><div style="width:${Math.min(pct, 100)}%"></div></div><b class="small">${pct}%</b></div>`;
      return `<tr><td><div class="proj-cell"><span class="code-chip">${esc(b.code)}</span><span>${esc(b.name)}</span></div></td><td class="num">${budget ? money(budget) : '<span class="muted">—</span>'}</td><td class="num">${money(b.committed_amount)}</td><td class="num">${money(actual)}</td><td style="min-width:130px">${used}</td></tr>`;
    }).join('') : emptyRow(5, 'Belum ada data'));
  const t = rows.reduce((a, b) => ({ bud: a.bud + num(b.budget_amount), com: a.com + num(b.committed_amount), act: a.act + num(b.actual_amount) }), { bud: 0, com: 0, act: 0 });
  $('dashBvaFoot').textContent = rows.length ? `${rows.length} proyek · Budget ${money(t.bud)} · Komitmen ${money(t.com)} · Realisasi ${money(t.act)}` : '';
}
$('bvaSeg').addEventListener('click', (ev) => {
  const b = ev.target.closest('[data-unit]');
  if (!b) return;
  bvaUnit = b.dataset.unit;
  document.querySelectorAll('#bvaSeg button').forEach((x) => x.classList.toggle('on', x === b));
  renderDashBva();
});
const openDraft = (id) => canSee('laporan') ? openJournalDetail(id) : (location.hash = 'jurnal');
$('dashDraft').addEventListener('click', (ev) => { const r = ev.target.closest('[data-dj]'); if (r) openDraft(Number(r.dataset.dj)); });
$('dashDraft').addEventListener('keydown', (ev) => { const r = ev.target.closest('[data-dj]'); if (r && ev.key === 'Enter') openDraft(Number(r.dataset.dj)); });

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
    const [d, dp] = await Promise.all([api('fin_assets'), api('fin_asset_disposals').catch(() => ({ disposals: [], banks: [] }))]);
    cache.aset = d; cache.disp = dp;
    $('capInfo').textContent = `Batas kapitalisasi: ${rp(d.capitalizationThreshold)} per unit. Kartu aset dibuat otomatis dari penerimaan SMMS.`;
    $('aCat').innerHTML = '<option value="">Pilih kategori…</option>' + d.categories.map((c) => `<option value="${esc(c.category_code)}">${esc(c.category_name)}</option>`).join('');
    $('assetTable').innerHTML = '<tr><th>Kode</th><th>Item</th><th>Lokasi / Proyek</th><th class="num">Perolehan</th><th>Kategori</th><th class="num">Nilai buku</th><th>Status</th><th></th></tr>' +
      (d.assets.length ? d.assets.map((a) => `<tr><td><b>${esc(a.asset_code)}</b></td><td>${esc(a.item_description)}<div class="small muted">${esc(a.vendor_name || '')} · ${esc(a.po_number || '')}</div></td>
        <td>${esc(a.location || '-')}<div class="small muted">Proyek ${esc(a.project_code || '-')}</div></td><td class="num">${rp(a.acquisition_cost)}<div class="small muted">${tgl(a.acquisition_date)}</div></td>
        <td>${a.category_code ? esc(a.category_code) + '<div class="small muted">' + esc(a.useful_life_months) + ' bln</div>' : '<span class="muted">-</span>'}</td>
        <td class="num">${rp(a.book_value)}<div class="small muted">akum. ${rp(a.accumulated_depreciation)}</div></td><td>${statusBadge(a.status)}</td>
        <td style="width:1%"><div class="row-gap asset-acts">${['DIJUAL', 'DIHAPUS'].includes(a.status) ? '' : `<button type="button" class="btn ghost small" data-edit-asset="${esc(a.asset_id)}">${a.status === 'PERLU_DILENGKAPI' ? 'Lengkapi' : 'Edit'}</button>${dp.disposals.some((x) => x.asset_id === a.asset_id && x.status === 'PLANNED') ? '<span class="badge warn">Lepas: menunggu PJ</span>' : `<button type="button" class="btn ghost small" data-dispose-asset="${esc(a.asset_id)}">Lepas</button>`}`}</div></td></tr>`).join('') : emptyRow(8, 'Belum ada aset tetap'));
    renderDisposals();
  } catch (e) { toast(e.message, true); }
}
let editingAsset = null;
$('assetTable').addEventListener('click', (ev) => {
  const ds = ev.target.closest('[data-dispose-asset]');
  if (ds) { disposeForm(cache.aset.assets.find((x) => String(x.asset_id) === ds.dataset.disposeAsset)); return; }
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
  $('cashSubmit').textContent = submitLabel || '';
  $('cashSubmit').hidden = !submitLabel;
  $('cashCancel').textContent = submitLabel ? 'Batal' : 'Tutup';
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
  $('bankForm').hidden = !ho;
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


// ---------- pelepasan aset ----------
function renderDisposals() {
  const d = cache.disp; if (!d) return;
  $('dispTable').innerHTML = '<tr><th>Aset</th><th>Jenis · tanggal</th><th class="num">Nilai buku</th><th class="num">Harga jual</th><th class="num">Laba / (rugi)</th><th>Status</th><th></th></tr>' +
    (d.disposals.length ? d.disposals.map((x) => {
      const pj = hasAuthor('PJ', x.project_code);
      const st = x.status === 'APPROVED' ? `<span class="badge ok">Disetujui</span><div class="small muted">${esc(x.approved_by || '')}</div>`
        : x.status === 'PLANNED' ? `<span class="badge warn">Menunggu PJ</span><div class="small muted">oleh ${esc(x.requested_by || '')}</div>`
        : `<span class="badge">Ditolak</span><div class="small overdue">${esc(x.reject_reason || '')}</div>`;
      const gap = x.dep_gap ? `<div class="small overdue">Penyusutan ${esc(x.dep_gap.slice(5, 7) + '/' + x.dep_gap.slice(0, 4))} belum dijalankan</div>` : '';
      return `<tr><td><b>${esc(x.asset_code)}</b><div class="small muted">${esc(x.item || '')} · proyek ${esc(x.project_code || '-')}</div></td>
        <td>${x.kind === 'SALE' ? 'Dijual' : 'Dihapus'} · ${tgl(x.disposal_date)}<div class="small muted">${esc(x.kind === 'SALE' ? (x.buyer ? 'ke ' + x.buyer + ' · ' : '') + (x.bank_label || '') : x.reason)}</div></td>
        <td class="num">${rp(x.book_value)}<div class="small muted">perolehan ${rp(x.cost)}</div></td>
        <td class="num">${x.kind === 'SALE' ? rp(x.proceeds) + (num(x.ppn_amount) ? `<div class="small muted">+ PPN ${rp(x.ppn_amount)}</div>` : '') : '-'}</td>
        <td class="num ${num(x.gain_loss) < 0 ? 'overdue' : 'rpt-ok'}">${num(x.gain_loss) < 0 ? '(' + rp(-num(x.gain_loss)) + ')' : rp(x.gain_loss)}</td>
        <td>${st}${gap}</td>
        <td><div class="row-gap" style="flex-wrap:nowrap">${x.status === 'PLANNED' && pj ? `<button type="button" class="btn primary small" data-disp-approve="${x.disposal_id}">Setujui</button><button type="button" class="btn ghost small" data-disp-reject="${x.disposal_id}">Tolak</button>` : ''}</div></td></tr>`;
    }).join('') : emptyRow(7, 'Belum ada pelepasan aset'));
}
function disposeForm(a) {
  const banks = cache.disp.banks;
  openCash(`Lepas Aset · ${a.asset_code}`, `${a.item_description} · perolehan ${rp(a.acquisition_cost)} · nilai buku saat ini ${rp(a.book_value)}. Pastikan penyusutan sudah dijalankan sampai bulan sebelum tanggal pelepasan.`, `<div id="dsWrap">
    <div class="row2"><div><label for="dsKind">Jenis</label><select id="dsKind"><option value="SALE">Dijual</option><option value="WRITE_OFF">Dihapus (rusak / hilang)</option></select></div>
      <div><label for="dsDate">Tanggal pelepasan</label><input type="date" id="dsDate" value="${today()}" max="${today()}" min="${a.acquisition_date}" required></div></div>
    <div id="dsSale">
      <div class="row2"><div><label for="dsPrice">Harga jual tanpa PPN (Rp)</label><input id="dsPrice" inputmode="numeric"></div>
        <div><label for="dsPpn">PPN dipungut (Rp, kalau ada)</label><input id="dsPpn" inputmode="numeric" value="0"></div></div>
      <div class="row2"><div><label for="dsBank">Uang masuk ke rekening</label><select id="dsBank">${banks.map((b) => opt(b.bank_id, b.label)).join('') || '<option value="">Belum ada rekening aktif</option>'}</select></div>
        <div><label for="dsBuyer">Pembeli</label><input id="dsBuyer"></div></div>
    </div>
    <label for="dsReason">Alasan / keterangan</label><input id="dsReason" placeholder="mis. tidak terpakai lagi, rusak berat, hilang di site" required>
    <div class="diff-box" id="dsCalc"></div></div>`, 'Ajukan ke PJ', async () => {
    const sale = $('dsKind').value === 'SALE';
    await api('fin_save_asset_disposal', { p_asset_id: a.asset_id, p_kind: $('dsKind').value, p_disposal_date: $('dsDate').value,
      p_proceeds: sale ? parseNum($('dsPrice').value) : 0, p_ppn_amount: sale ? parseNum($('dsPpn').value) : 0,
      p_bank_id: sale ? Number($('dsBank').value) || null : null, p_buyer: sale ? fv('dsBuyer') || null : null, p_reason: fv('dsReason') });
    toast('Pelepasan aset diajukan, menunggu persetujuan PJ');
  });
  const calc = () => {
    const sale = $('dsKind').value === 'SALE';
    $('dsSale').hidden = !sale;
    const price = sale ? parseNum($('dsPrice').value) : 0, gl = price - num(a.book_value);
    $('dsCalc').innerHTML = `Nilai buku: <b>${rp(a.book_value)}</b> (perolehan ${rp(a.acquisition_cost)} − akumulasi ${rp(a.accumulated_depreciation)})`
      + (sale ? `<br>Harga jual: ${rp(price)}` : '')
      + `<br>${gl >= 0 ? 'Laba' : 'Rugi'} pelepasan: <b class="${gl < 0 ? 'overdue' : 'rpt-ok'}">${rp(Math.abs(gl))}</b>`
      + '<br><span class="small muted">Nilai final dihitung ulang saat PJ menyetujui.</span>';
  };
  $('dsWrap').addEventListener('input', calc); $('dsWrap').addEventListener('change', calc); calc();
}
$('dispTable').addEventListener('click', async (ev) => {
  const ap = ev.target.closest('[data-disp-approve]'), rj = ev.target.closest('[data-disp-reject]');
  if (ap) {
    const x = cache.disp.disposals.find((y) => String(y.disposal_id) === ap.dataset.dispApprove);
    if (!confirm(`Setujui pelepasan ${x.asset_code} (${x.kind === 'SALE' ? 'dijual ' + rp(x.proceeds) : 'dihapus'})? Aset berhenti disusutkan dan jurnal langsung terposting.`)) return;
    ap.disabled = true;
    try { await api('fin_decide_asset_disposal', { p_disposal_id: x.disposal_id, p_approve: true, p_reason: null }); toast(`${x.asset_code} dilepas, jurnal terposting`); loadAset(); }
    catch (e) { toast(e.message, true); ap.disabled = false; }
  } else if (rj) {
    const id = Number(rj.dataset.dispReject);
    openCash('Tolak Pelepasan Aset', '', '<label for="cReason">Alasan penolakan</label><input id="cReason" required>', 'Tolak', async () => {
      await api('fin_decide_asset_disposal', { p_disposal_id: id, p_approve: false, p_reason: fv('cReason') }); toast('Pelepasan ditolak');
    });
  }
});

// ---------- piutang klien (AR) ----------
const AR_ST = { DRAFT: ['warn', 'Menunggu PJ'], APPROVED: ['', 'Belum dibayar'], PARTIAL: ['amber', 'Dibayar sebagian'], PAID: ['ok', 'Lunas'], REJECTED: ['', 'Ditolak'] };
const PPN_LABEL = { NONE: 'Tanpa PPN', WAPU: 'PPN dipungut klien (WAPU)', COLLECT: 'PPN dipungut BIMA' };
const PPH_LABEL = { NONE: 'Tanpa PPh', PPH23: 'PPh 23', PPH4_2: 'PPh 4(2) final konstruksi' };
const arLeft = (i) => num(i.receivable_amount) - num(i.settled);
async function loadAR() {
  try { renderAR(await api('fin_ar_overview')); } catch (e) { toast(e.message, true); }
}
function renderAR(d) {
  cache.ar = d;
  if (!d) return;
  const k = d.kpi;
  const kpi = (label, val, sub, alert) => `<div class="kpi${alert ? ' alert' : ''}"><div class="k-label">${esc(label)}</div><div class="k-val">${esc(val)}</div><div class="k-sub">${esc(sub)}</div></div>`;
  $('arKpis').innerHTML =
    kpi('Piutang belum diterima', rpShort(k.piutang), 'Invoice disetujui, belum lunas') +
    kpi('Lewat jatuh tempo', rpShort(k.jatuhTempo), num(k.jatuhTempo) > 0 ? 'Perlu ditagih ulang ke klien' : 'Tidak ada yang lewat', num(k.jatuhTempo) > 0) +
    kpi('Retensi tertahan', rpShort(k.retensi), 'Bisa dicairkan lewat invoice retensi') +
    kpi('SMS belum ditagih', rpShort(k.smsBelumDitagih), `${d.billableSms.length} SMS approved`, d.billableSms.length > 0) +
    kpi('Menunggu PJ', String(k.menunggu), 'Invoice draft + penerimaan', k.menunggu > 0);
  const f = $('arFilter').value;
  const rows = d.invoices.filter((i) => f === 'ALL' || !['PAID', 'REJECTED'].includes(i.status));
  $('arTable').innerHTML = '<tr><th>No. invoice</th><th>Proyek / klien</th><th>Tanggal · jatuh tempo</th><th class="num">Ditagih</th><th class="num">Sisa</th><th>Status</th><th></th></tr>' +
    (rows.length ? rows.map((i) => {
      const [cls, label] = AR_ST[i.status] || ['', i.status];
      const pj = hasAuthor('PJ', i.project_code);
      const late = ['APPROVED', 'PARTIAL'].includes(i.status) && i.due_date < today();
      const acts = [];
      if (i.status === 'DRAFT') {
        if (hasPic('fin-ar')) acts.push(`<button type="button" class="btn ghost small" data-ar-edit="${i.invoice_id}">Ubah</button>`);
        if (pj) acts.push(`<button type="button" class="btn primary small" data-ar-approve="${i.invoice_id}">Setujui</button><button type="button" class="btn ghost small" data-ar-reject="${i.invoice_id}">Tolak</button>`);
      }
      if (['APPROVED', 'PARTIAL'].includes(i.status) && hasPic('fin-ar') && arLeft(i) - num(i.pending) > 0)
        acts.push(`<button type="button" class="btn primary small" data-ar-receive="${i.invoice_id}">Terima uang</button>`);
      const pend = i.receipts.filter((r) => r.status === 'PLANNED');
      const pendTxt = pend.length ? `<div class="small" style="color:var(--amber)">${pend.length} penerimaan menunggu PJ (${rp(i.pending)})</div>` : '';
      return `<tr><td><a href="#ar" data-ar-view="${i.invoice_id}">${esc(i.invoice_no)}</a><div class="small muted">${i.kind === 'RETENTION' ? 'Pencairan retensi' : 'Progress'}${i.faktur_no ? ' · FP ' + esc(i.faktur_no) : ''}</div></td>
        <td><span class="code-chip">${esc(i.project_code)}</span> ${esc(i.client_name || '')}<div class="small muted">${esc(i.description)}</div></td>
        <td>${tgl(i.invoice_date)}<div class="small ${late ? 'overdue' : 'muted'}">${tgl(i.due_date)}${late ? ' · lewat' : ''}</div></td>
        <td class="num">${rp(i.receivable_amount)}</td>
        <td class="num">${['DRAFT', 'REJECTED'].includes(i.status) ? '<span class="muted">—</span>' : rp(arLeft(i))}</td>
        <td><span class="badge ${cls}">${esc(label)}</span>${i.status === 'REJECTED' ? `<div class="small overdue">${esc(i.reject_reason || '')}</div>` : ''}${pendTxt}</td>
        <td><div class="row-gap" style="flex-wrap:nowrap">${acts.join('')}</div></td></tr>`
        + pend.map((r) => `<tr><td></td><td colspan="2" class="small">↳ Penerimaan ${tgl(r.receipt_date)} ke ${esc(r.bank_label)}${r.ref_no ? ' · ' + esc(r.ref_no) : ''} <span class="muted">oleh ${esc(r.requested_by || '')}</span></td>
            <td class="num small">${rp(num(r.cash_amount) + num(r.pph_amount))}${num(r.pph_amount) ? `<div class="muted">PPh ${rp(r.pph_amount)}</div>` : ''}</td><td></td><td><span class="badge warn">Menunggu PJ</span></td>
            <td><div class="row-gap" style="flex-wrap:nowrap">${pj ? `<button type="button" class="btn primary small" data-rc-approve="${r.receipt_id}">Setujui</button><button type="button" class="btn ghost small" data-rc-reject="${r.receipt_id}">Tolak</button>` : ''}</div></td></tr>`).join('');
    }).join('') : emptyRow(7, f === 'OPEN' ? 'Tidak ada invoice yang belum lunas' : 'Belum ada invoice klien'));
  $('arSmsTable').innerHTML = '<tr><th>No. SMS</th><th>Proyek</th><th>Tanggal</th><th class="num">Nilai</th><th></th></tr>' +
    (d.billableSms.length ? d.billableSms.map((s) => `<tr><td><span class="code-chip">${esc(s.number)}</span></td><td>${esc(s.project_code)}</td><td>${tgl(s.document_date)}</td><td class="num">${rp(s.amount)}</td>
      <td>${hasPic('fin-ar') ? `<button type="button" class="btn ghost small" data-ar-sms="${esc(s.sms_id)}">Buat invoice</button>` : ''}</td></tr>`).join('')
      : emptyRow(5, 'Tidak ada SMS approved yang belum ditagih'));
  $('newArBtn').hidden = $('newRetBtn').hidden = !hasPic('fin-ar');
}
$('arFilter').addEventListener('change', () => renderAR(cache.ar));

// Form invoice: kind PROGRESS / RETENTION; inv = invoice draft yang diubah; preSms = SMS yang langsung dicentang
function arForm(kind, inv, preSms) {
  const d = cache.ar;
  const projects = kind === 'RETENTION' ? d.projects.filter((p) => num(p.retention_open) > 0 || (inv && inv.project_id === p.project_id)) : d.projects;
  if (!projects.length) { toast('Belum ada retensi tertahan yang bisa dicairkan.', true); return; }
  const smsOf = (pid) => d.billableSms.filter((s) => s.project_id === pid).concat(inv ? inv.lines.filter((l) => l.sms_id).map((l) => ({ sms_id: l.sms_id, number: l.sms_number, amount: l.amount, project_id: inv.project_id })) : []);
  const preProj = inv ? inv.project_id : preSms ? d.billableSms.find((s) => s.sms_id === preSms).project_id : projects[0].project_id;
  const manual = inv ? inv.lines.filter((l) => !l.sms_id) : [];
  const due = new Date(Date.now() + 30 * 864e5).toISOString().slice(0, 10);
  const manRow = (l = {}) => `<div class="doc-up ar-man" style="grid-template-columns:minmax(0,1.6fr) minmax(0,1fr) auto">
      <input class="am-desc" placeholder="${kind === 'RETENTION' ? 'mis. Retensi termin 1' : 'mis. Mobilisasi, pekerjaan tambah'}" value="${esc(l.description || '')}">
      <input class="am-amt" inputmode="numeric" placeholder="Nilai (Rp)" value="${l.amount ? num(l.amount).toLocaleString('id-ID') : ''}">
      <button type="button" class="btn ghost small am-del" aria-label="Hapus baris">✕</button></div>`;
  openCash(inv ? `Ubah ${inv.invoice_no}` : kind === 'RETENTION' ? 'Invoice Pencairan Retensi' : 'Invoice Klien Baru',
    kind === 'RETENTION' ? 'Mencairkan retensi yang ditahan klien dari invoice progress proyek yang sama.' : 'Centang SMS yang sudah approved klien dan/atau tambah baris manual. Disetujui PJ proyek; jurnal langsung terposting.', `<div id="aWrap">
    <div class="row2"><div><label for="aProj">Proyek</label><select id="aProj" required ${inv ? '' : ''}>${projects.map((p) => opt(p.project_id, `${p.code} · ${p.name}${kind === 'RETENTION' ? ' (sisa retensi ' + rpShort(p.retention_open) + ')' : ''}`, p.project_id === preProj)).join('')}</select></div>
      <div><label for="aNo">No. invoice (kosongkan = otomatis)</label><input id="aNo" value="${esc(inv ? inv.invoice_no : '')}" placeholder="INV/BIMA/yyyy/mm/nnn"></div></div>
    <div class="small muted" id="aClient" style="margin-top:6px"></div>
    <div class="row2"><div><label for="aDate">Tanggal invoice</label><input type="date" id="aDate" value="${inv ? inv.invoice_date : today()}" required></div>
      <div><label for="aDue">Jatuh tempo</label><input type="date" id="aDue" value="${inv ? inv.due_date : due}" required></div></div>
    <label for="aDesc">Keterangan</label><input id="aDesc" value="${esc(inv ? inv.description : '')}" placeholder="${kind === 'RETENTION' ? 'mis. Pencairan retensi 5% termin 1–3' : 'mis. Tagihan termin 1 pekerjaan maintenance'}" required>
    ${kind === 'PROGRESS' ? '<div class="doc-box"><div class="doc-box-head"><b>SMS approved</b><span class="small muted">nilai diambil dari SMMS</span></div><div id="aSms"></div></div>' : ''}
    <div class="doc-box"><div class="doc-box-head"><b>${kind === 'RETENTION' ? 'Nilai pencairan' : 'Baris manual'}</b><button type="button" class="btn ghost small" id="aAddMan">+ Baris</button></div><div id="aMan">${(manual.length ? manual : kind === 'RETENTION' ? [{}] : []).map(manRow).join('')}</div></div>
    <div class="row2">
      ${kind === 'PROGRESS' ? `<div><label for="aRet">Retensi ditahan klien (%)</label><input id="aRet" inputmode="decimal" value="${inv ? num(inv.retention_pct) : 0}"></div>` : '<div></div>'}
      <div><label for="aFaktur">No. faktur pajak (bisa diisi nanti)</label><input id="aFaktur" value="${esc(inv && inv.faktur_no || '')}"></div></div>
    <div class="row2">
      <div><label for="aPpn">PPN</label><select id="aPpn">${Object.entries(PPN_LABEL).map(([v, t]) => opt(v, t, (inv ? inv.ppn_mode : 'WAPU') === v)).join('')}</select></div>
      <div><label for="aPpnRate">Tarif PPN (%)</label><input id="aPpnRate" inputmode="decimal" value="${inv && num(inv.ppn_rate) ? num(inv.ppn_rate) : 11}"></div></div>
    <div class="row2">
      <div><label for="aPph">PPh dipotong klien</label><select id="aPph">${Object.entries(PPH_LABEL).map(([v, t]) => opt(v, t, (inv ? inv.pph_mode : 'NONE') === v)).join('')}</select></div>
      <div><label for="aPphRate">Tarif PPh (%)</label><input id="aPphRate" inputmode="decimal" value="${inv && num(inv.pph_rate) ? num(inv.pph_rate) : 2}"></div></div>
    <div class="diff-box" id="aCalc"></div></div>`, inv ? 'Simpan perubahan' : 'Simpan draft', async () => {
    const lines = [...document.querySelectorAll('#aSms input:checked')].map((c) => ({ sms_id: c.value }))
      .concat([...document.querySelectorAll('#aMan .ar-man')].map((r) => ({ description: r.querySelector('.am-desc').value.trim(), amount: parseNum(r.querySelector('.am-amt').value) }))
        .filter((l) => l.description || l.amount));
    if (!lines.length) throw new Error('Isi minimal satu baris tagihan');
    const r = await api('fin_save_ar_invoice', {
      p_invoice_id: inv ? inv.invoice_id : null, p_kind: kind, p_project_id: $('aProj').value, p_invoice_no: fv('aNo') || null,
      p_invoice_date: $('aDate').value, p_due_date: $('aDue').value, p_description: fv('aDesc'),
      p_retention_pct: kind === 'PROGRESS' ? Number(fv('aRet').replace(',', '.')) || 0 : 0,
      p_ppn_mode: $('aPpn').value, p_ppn_rate: Number(fv('aPpnRate').replace(',', '.')) || 0,
      p_pph_mode: $('aPph').value, p_pph_rate: Number(fv('aPphRate').replace(',', '.')) || 0,
      p_faktur_no: fv('aFaktur') || null, p_lines: lines });
    toast(`${r.invoice_no} tersimpan sebagai draft, menunggu PJ`);
  });
  const renderSms = () => {
    const pid = $('aProj').value, p = d.projects.find((x) => x.project_id === pid);
    $('aClient').textContent = p && p.client ? 'Klien: ' + p.client : 'Klien belum diisi di data proyek';
    if (kind !== 'PROGRESS') return;
    const list = smsOf(pid);
    const picked = inv ? inv.lines.filter((l) => l.sms_id).map((l) => l.sms_id) : preSms ? [preSms] : [];
    $('aSms').innerHTML = list.length ? list.map((s) => `<label class="rpt-check" style="justify-content:space-between;border-top:1px solid var(--line-soft)">
        <span><input type="checkbox" value="${esc(s.sms_id)}" data-amt="${num(s.amount)}" ${picked.includes(s.sms_id) ? 'checked' : ''}> ${esc(s.number)}</span><b class="num">${rp(s.amount)}</b></label>`).join('')
      : '<p class="small muted">Tidak ada SMS approved yang belum ditagih untuk proyek ini.</p>';
    calc();
  };
  const calc = () => {
    const dpp = [...document.querySelectorAll('#aSms input:checked')].reduce((t, c) => t + num(c.dataset.amt), 0)
      + [...document.querySelectorAll('#aMan .am-amt')].reduce((t, x) => t + parseNum(x.value), 0);
    const retPct = kind === 'PROGRESS' ? Number(fv('aRet').replace(',', '.')) || 0 : 0;
    const ret = Math.round(dpp * retPct / 100), base = dpp - ret;
    const ppnM = $('aPpn').value, pphM = $('aPph').value;
    const ppn = ppnM === 'NONE' ? 0 : Math.floor(base * (Number(fv('aPpnRate').replace(',', '.')) || 0) / 100);
    const pph = pphM === 'NONE' ? 0 : Math.floor(base * (Number(fv('aPphRate').replace(',', '.')) || 0) / 100);
    const recv = base + (ppnM === 'COLLECT' ? ppn : 0);
    $('aPpnRate').disabled = ppnM === 'NONE'; $('aPphRate').disabled = pphM === 'NONE';
    $('aCalc').innerHTML = `${kind === 'RETENTION' ? 'Nilai pencairan' : 'DPP (nilai pekerjaan)'}: <b>${rp(dpp)}</b>`
      + (ret ? `<br>Retensi ditahan ${retPct}%: − ${rp(ret)} <span class="muted">(masuk Piutang Retensi)</span>` : '')
      + (ppnM !== 'NONE' ? `<br>PPN: ${ppnM === 'COLLECT' ? '+ ' : ''}${rp(ppn)} <span class="muted">${ppnM === 'WAPU' ? '(dipungut & disetor klien, tidak ditagih)' : ''}</span>` : '')
      + `<br>Total piutang ditagih: <b>${rp(recv)}</b>`
      + (pph ? `<br>PPh dipotong klien: − ${rp(pph)}` : '')
      + `<br>Perkiraan uang masuk: <b>${rp(recv - pph)}</b>`;
  };
  $('aProj').addEventListener('change', renderSms);
  $('aWrap').addEventListener('input', calc);
  $('aWrap').addEventListener('change', calc);
  $('aAddMan').addEventListener('click', () => { $('aMan').insertAdjacentHTML('beforeend', manRow()); });
  $('aMan').addEventListener('click', (ev) => { const b = ev.target.closest('.am-del'); if (b) { b.closest('.ar-man').remove(); calc(); } });
  $('aWrap').addEventListener('focusout', (ev) => { if (ev.target.classList.contains('am-amt') && parseNum(ev.target.value)) ev.target.value = parseNum(ev.target.value).toLocaleString('id-ID'); });
  renderSms(); calc();
}

function arReceiveForm(i) {
  const banks = cache.ar.banks;
  if (!banks.length) { toast('Belum ada rekening bank aktif. Tambahkan di menu Bank.', true); return; }
  const left = arLeft(i) - num(i.pending);
  const pphLeft = Math.max(0, num(i.pph_amount) - i.receipts.filter((r) => r.status !== 'REJECTED').reduce((t, r) => t + num(r.pph_amount), 0));
  openCash(`Terima Uang · ${i.invoice_no}`, `${i.client_name || ''} · sisa piutang ${rp(left)}. Disetujui PJ, lalu jurnal bank terposting.`, `<div id="rWrap">
    <div class="row2"><div><label for="rBank">Masuk ke rekening</label><select id="rBank">${banks.map((b) => opt(b.bank_id, b.label)).join('')}</select></div>
      <div><label for="rDate">Tanggal uang masuk</label><input type="date" id="rDate" value="${today()}" max="${today()}" min="${i.invoice_date}" required></div></div>
    <div class="row2"><div><label for="rCash">Uang diterima di rekening (Rp)</label><input id="rCash" inputmode="numeric" value="${(left - pphLeft).toLocaleString('id-ID')}" required></div>
      <div><label for="rPph">PPh dipotong klien (Rp)</label><input id="rPph" inputmode="numeric" value="${pphLeft.toLocaleString('id-ID')}" ${i.pph_mode === 'NONE' ? 'disabled' : ''}></div></div>
    <label for="rRef">No. referensi transfer / bukti potong</label><input id="rRef" placeholder="mis. TRF-PHM-0012 / BP 23 no. ...">
    <label for="rNotes">Catatan</label><input id="rNotes">
    <div class="diff-box" id="rCalc"></div></div>`, 'Kirim ke PJ', async () => {
    await api('fin_save_ar_receipt', { p_invoice_id: i.invoice_id, p_bank_id: Number($('rBank').value), p_receipt_date: $('rDate').value,
      p_cash_amount: parseNum($('rCash').value), p_pph_amount: i.pph_mode === 'NONE' ? 0 : parseNum($('rPph').value), p_ref_no: fv('rRef') || null, p_notes: fv('rNotes') || null });
    toast('Penerimaan tersimpan, menunggu persetujuan PJ');
  });
  const calc = () => {
    const t = parseNum($('rCash').value) + (i.pph_mode === 'NONE' ? 0 : parseNum($('rPph').value));
    $('rCalc').innerHTML = `Mengurangi piutang: <b>${rp(t)}</b> dari sisa ${rp(left)}<br>Sisa setelah ini: <b class="${t > left ? 'overdue' : ''}">${rp(left - t)}</b>`;
  };
  $('rWrap').addEventListener('input', calc); calc();
}

function arView(i) {
  const lines = i.lines.map((l) => `<tr><td>${l.sms_number ? `<span class="code-chip">${esc(l.sms_number)}</span> ` : ''}${esc(l.description)}</td><td class="num">${rp(l.amount)}</td></tr>`).join('');
  const base = num(i.dpp) - num(i.retention_amount);
  const rc = i.receipts.length ? i.receipts.map((r) => `<tr><td>${tgl(r.receipt_date)} · ${esc(r.bank_label)}${r.ref_no ? `<div class="small muted">${esc(r.ref_no)}</div>` : ''}</td>
      <td class="num">${rp(r.cash_amount)}${num(r.pph_amount) ? `<div class="small muted">+ PPh ${rp(r.pph_amount)}</div>` : ''}</td>
      <td>${r.status === 'APPROVED' ? `<span class="badge ok">Disetujui</span><div class="small muted">${esc(r.approved_by || '')}</div>` : r.status === 'PLANNED' ? '<span class="badge warn">Menunggu PJ</span>' : `<span class="badge">Ditolak</span><div class="small overdue">${esc(r.reject_reason || '')}</div>`}</td></tr>`).join('')
    : '<tr><td colspan="3" class="empty">Belum ada penerimaan</td></tr>';
  openCash(i.invoice_no, `${i.project_code} · ${i.client_name || ''} · ${tgl(i.invoice_date)} s/d ${tgl(i.due_date)} · ${(AR_ST[i.status] || [, i.status])[1]}`, `
    <p>${esc(i.description)}</p>
    <div class="scroll"><table class="rpt"><tr><th>Uraian</th><th class="num">Nilai</th></tr>${lines}
      <tr class="sub"><td>${i.kind === 'RETENTION' ? 'Nilai pencairan retensi' : 'DPP'}</td><td class="num">${rp(i.dpp)}</td></tr>
      ${num(i.retention_amount) ? `<tr><td class="ind">Retensi ditahan ${num(i.retention_pct)}%</td><td class="num">(${rp(i.retention_amount)})</td></tr>` : ''}
      ${i.ppn_mode !== 'NONE' ? `<tr><td class="ind">PPN ${num(i.ppn_rate)}% · ${esc(PPN_LABEL[i.ppn_mode])}</td><td class="num">${i.ppn_mode === 'COLLECT' ? '' : '('}${rp(i.ppn_amount)}${i.ppn_mode === 'COLLECT' ? '' : ')'}</td></tr>` : ''}
      <tr class="total"><td>Total piutang</td><td class="num">${rp(i.receivable_amount)}</td></tr>
      ${num(i.pph_amount) ? `<tr><td class="ind">${esc(PPH_LABEL[i.pph_mode])} ${num(i.pph_rate)}% (dipotong klien)</td><td class="num">(${rp(i.pph_amount)})</td></tr>` : ''}
      <tr><td>Perkiraan uang masuk</td><td class="num">${rp(i.expected_cash)}</td></tr></table></div>
    ${i.ppn_mode === 'WAPU' ? '<p class="small muted">PPN dipungut dan disetor langsung oleh klien (WAPU), jadi tidak ikut ditagih dan tidak dijurnal. Dasar PPN = ' + rp(base) + '.</p>' : ''}
    <div class="row2"><div><label for="vFaktur">No. faktur pajak</label><input id="vFaktur" value="${esc(i.faktur_no || '')}" ${hasPic('fin-ar') && i.status !== 'REJECTED' ? '' : 'disabled'}></div><div></div></div>
    <h3 style="margin-top:16px">Penerimaan</h3>
    <div class="scroll"><table class="rpt"><tr><th>Tanggal · rekening</th><th class="num">Diterima</th><th>Status</th></tr>${rc}</table></div>
    <p class="small muted">Dibuat ${esc(i.created_by || '')}${i.approved_by ? ` · ${i.status === 'REJECTED' ? 'ditolak' : 'disetujui'} ${esc(i.approved_by)}` : ''}</p>`,
  hasPic('fin-ar') && i.status !== 'REJECTED' ? 'Simpan no. faktur' : null, async () => {
    await api('fin_set_ar_faktur', { p_invoice_id: i.invoice_id, p_faktur_no: fv('vFaktur') || null }); toast('No. faktur tersimpan');
  });
}

$('newArBtn').addEventListener('click', () => cache.ar && arForm('PROGRESS'));
$('newRetBtn').addEventListener('click', () => cache.ar && arForm('RETENTION'));
$('page-ar').addEventListener('click', async (ev) => {
  const d = cache.ar; if (!d) return;
  const t = (attr) => ev.target.closest(`[${attr}]`);
  const inv = (id) => d.invoices.find((x) => String(x.invoice_id) === String(id));
  let el;
  if ((el = t('data-ar-view'))) { ev.preventDefault(); arView(inv(el.dataset.arView)); }
  else if ((el = t('data-ar-edit'))) { const i = inv(el.dataset.arEdit); arForm(i.kind, i); }
  else if ((el = t('data-ar-sms'))) arForm('PROGRESS', null, el.dataset.arSms);
  else if ((el = t('data-ar-receive'))) arReceiveForm(inv(el.dataset.arReceive));
  else if ((el = t('data-ar-approve'))) {
    const i = inv(el.dataset.arApprove);
    if (!confirm(`Setujui ${i.invoice_no} senilai ${rp(i.receivable_amount)} ke ${i.client_name || i.project_code}? Jurnal pendapatan & piutang langsung terposting.`)) return;
    el.disabled = true;
    try { await api('fin_decide_ar_invoice', { p_invoice_id: i.invoice_id, p_approve: true, p_reason: null }); toast(`${i.invoice_no} disetujui dan terposting`); loadAR(); }
    catch (e) { toast(e.message, true); el.disabled = false; }
  } else if ((el = t('data-ar-reject'))) {
    const id = Number(el.dataset.arReject);
    openCash('Tolak Invoice Klien', 'SMS di invoice ini akan dilepas dan bisa ditagih ulang.', '<label for="cReason">Alasan penolakan</label><input id="cReason" required>', 'Tolak', async () => {
      await api('fin_decide_ar_invoice', { p_invoice_id: id, p_approve: false, p_reason: fv('cReason') }); toast('Invoice ditolak');
    });
  } else if ((el = t('data-rc-approve'))) {
    el.disabled = true;
    try { await api('fin_decide_ar_receipt', { p_receipt_id: Number(el.dataset.rcApprove), p_approve: true, p_reason: null }); toast('Penerimaan disetujui dan terposting'); loadAR(); }
    catch (e) { toast(e.message, true); el.disabled = false; }
  } else if ((el = t('data-rc-reject'))) {
    const id = Number(el.dataset.rcReject);
    openCash('Tolak Penerimaan', '', '<label for="cReason">Alasan penolakan</label><input id="cReason" required>', 'Tolak', async () => {
      await api('fin_decide_ar_receipt', { p_receipt_id: id, p_approve: false, p_reason: fv('cReason') }); toast('Penerimaan ditolak');
    });
  }
});

// ---------- payroll (Fusion4) ----------
const PR_KIND = { THP: 'Gaji bersih (THP)', BPJS: 'Setoran BPJS', PPH21: 'Setoran PPh 21' };
const BULAN = ['Januari', 'Februari', 'Maret', 'April', 'Mei', 'Juni', 'Juli', 'Agustus', 'September', 'Oktober', 'November', 'Desember'];
let prSel = null;
async function loadPayroll() {
  try {
    const [y, m] = prSel ? prSel.split('-').map(Number) : [null, null];
    renderPayroll(await api('fin_payroll_overview', { p_year: y, p_month: m }));
  } catch (e) { toast(e.message, true); }
}
function renderPayroll(d) {
  cache.payroll = d;
  if (!d || !d.year) {
    $('prPeriod').innerHTML = ''; $('prKpis').innerHTML = '';
    $('prJournalCard').innerHTML = '<p class="muted">Belum ada payroll yang diproses di Fusion4.</p>';
    return;
  }
  prSel = `${d.year}-${d.month}`;
  const jst = { POSTED: ['ok', 'Terposting'], DRAFT: ['warn', 'Draft, menunggu PJ'], VOID: ['', 'Void'] };
  $('prPeriod').innerHTML = d.periods.map((p) => opt(`${p.year}-${p.month}`, `${BULAN[p.month - 1]} ${p.year} · ${p.employees} karyawan${p.journal_status ? ' · ' + (jst[p.journal_status] || ['', p.journal_status])[1] : ''}`, `${p.year}-${p.month}` === prSel)).join('');
  const t = d.totals;
  const kpi = (label, val, sub, alert) => `<div class="kpi${alert ? ' alert' : ''}"><div class="k-label">${esc(label)}</div><div class="k-val">${esc(val)}</div><div class="k-sub">${esc(sub)}</div></div>`;
  $('prKpis').innerHTML =
    kpi('Gaji bruto', rpShort(t.bruto), `${t.employees} karyawan`) +
    kpi('BPJS perusahaan', rpShort(t.bpjs_perusahaan), 'Beban perusahaan, di luar bruto') +
    kpi('PPh 21', rpShort(t.pph21), 'Dipotong dari gaji') +
    kpi('Gaji bersih (THP)', rpShort(t.thp), t.processed_at ? 'Diproses ' + tgl(t.processed_at) : '') +
    kpi('Total biaya perusahaan', rpShort(num(t.bruto) + num(t.bpjs_perusahaan) + num(t.kompensasi)), num(t.kompensasi) ? `termasuk kompensasi PKWT ${rpShort(t.kompensasi)}` : 'bruto + BPJS perusahaan');
  const j = d.journal, canPr = hasPic('fin-pr');
  const [jc, jl] = j ? jst[j.status] || ['', j.status] : ['', 'Belum dibuat'];
  const btn = canPr ? `<button type="button" class="btn ${j ? 'ghost' : 'primary'}" id="prJournalBtn">${j ? 'Perbarui jurnal' : 'Buat jurnal'}</button>` : '';
  $('prJournalCard').innerHTML = `<div class="card-head"><div><h2>Jurnal ${BULAN[d.month - 1]} ${d.year}</h2>
      <p>${j ? `${esc(j.journal_no || 'JV draft #' + j.journal_id)} · dibuat/diperbarui ${esc(j.journaled_by || '')} ${j.journaled_at ? tgl(j.journaled_at) : ''}` : 'Cek alokasi proyek di bawah, lalu buat jurnal. PJ memposting di menu Jurnal.'}</p></div>
      <div class="row-gap"><span class="badge ${jc}">${esc(jl)}</span>${btn}</div></div>
    ${j && j.adjust_draft ? '<div class="rpt-note">Ada jurnal penyesuaian (DRAFT) karena payroll atau alokasi berubah setelah jurnal diposting. Minta PJ memposting penyesuaiannya di menu Jurnal.</div>' : ''}
    ${num(t.other_deduction) ? `<div class="rpt-note">Ada potongan gaji di luar BPJS & PPh 21 (${rp(t.other_deduction)}). Jurnal belum bisa dibuat untuk periode ini.</div>` : ''}
    <p class="small muted">Payroll diproses ulang di Fusion4 atau alokasi diubah? Tekan "Perbarui jurnal": jurnal DRAFT diganti, jurnal yang sudah POSTED dibuatkan penyesuaian sebesar selisihnya.</p>`;
  $('prProjTable').innerHTML = '<tr><th>Proyek</th><th>Jenis</th><th class="num">Karyawan</th><th class="num">Biaya</th></tr>' +
    (d.byProject.length ? d.byProject.map((p) => `<tr><td><span class="code-chip">${esc(p.code || '-')}</span> ${esc(p.name || 'Tanpa proyek')}</td><td>${p.type === 'CLIENT' ? '<span class="badge info">Klien · 5-1300</span>' : '<span class="badge">Internal · 6-1000</span>'}</td><td class="num">${esc(p.employees)}</td><td class="num">${rp(p.cost)}</td></tr>`).join('') : emptyRow(4, 'Tidak ada data'));
  const td = d.lines.reduce((a, l) => a + num(l.debit), 0), tc = d.lines.reduce((a, l) => a + num(l.credit), 0);
  $('prLines').innerHTML = '<tr><th>Akun</th><th>Proyek</th><th class="num">Debit</th><th class="num">Kredit</th></tr>' +
    d.lines.map((l) => `<tr><td>${esc(l.account)} · ${esc(l.account_name || '')}</td><td>${esc(l.project_code || '-')}</td><td class="num">${num(l.debit) ? rp(l.debit) : ''}</td><td class="num">${num(l.credit) ? rp(l.credit) : ''}</td></tr>`).join('') +
    `<tr class="total"><td colspan="2"><b>Total</b></td><td class="num"><b>${rp(td)}</b></td><td class="num"><b>${rp(tc)}</b></td></tr>`;
  const posted = j && j.status === 'POSTED';
  $('prOwed').innerHTML = '<tr><th>Kewajiban</th><th class="num">Hutang</th><th class="num">Sudah dibayar</th><th class="num">Menunggu APY</th><th class="num">Sisa</th><th></th></tr>' +
    Object.keys(PR_KIND).map((k) => {
      const o = d.owed[k] || {}, left = num(o.owed) - num(o.paid) - num(o.pending);
      return `<tr><td>${esc(PR_KIND[k])}</td><td class="num">${rp(o.owed)}</td><td class="num">${rp(o.paid)}</td><td class="num">${num(o.pending) ? rp(o.pending) : '-'}</td>
        <td class="num ${left > 0 ? '' : 'muted'}">${rp(left)}</td>
        <td>${canPr && posted && left > 0.004 ? `<button type="button" class="btn primary small" data-pr-pay="${k}">Bayar</button>` : ''}</td></tr>`;
    }).join('');
  const apy = hasAuthor('APY');
  $('prPayTable').innerHTML = d.payments.length ? '<tr><th>Tanggal</th><th>Jenis</th><th>Rekening</th><th class="num">Nilai</th><th>Status</th><th></th></tr>' +
    d.payments.map((p) => `<tr><td>${tgl(p.pay_date)}</td><td>${esc(PR_KIND[p.kind])}${p.ref_no ? `<div class="small muted">${esc(p.ref_no)}</div>` : ''}</td><td>${esc(p.bank_label)}</td><td class="num">${rp(p.amount)}</td>
      <td>${p.status === 'APPROVED' ? `<span class="badge ok">Disetujui</span><div class="small muted">${esc(p.approved_by || '')}</div>` : p.status === 'PLANNED' ? `<span class="badge warn">Menunggu APY</span><div class="small muted">oleh ${esc(p.requested_by || '')}</div>` : `<span class="badge">Ditolak</span><div class="small overdue">${esc(p.reject_reason || '')}</div>`}</td>
      <td><div class="row-gap" style="flex-wrap:nowrap">${p.status === 'PLANNED' && apy ? `<button type="button" class="btn primary small" data-prp-approve="${p.payment_id}">Setujui</button><button type="button" class="btn ghost small" data-prp-reject="${p.payment_id}">Tolak</button>` : ''}</div></td></tr>`).join('') : '';
  $('prEmpCard').hidden = !d.detail;
  renderPrEmp();
}
function renderPrEmp() {
  const d = cache.payroll; if (!d || !d.detail) return;
  const q = $('prSearch').value.trim().toLowerCase();
  const rows = d.employees.filter((e) => !q || `${e.nama} ${e.divisi} ${e.departemen}`.toLowerCase().includes(q));
  $('prEmpTable').innerHTML = '<tr><th>Karyawan</th><th>Divisi / departemen</th><th class="num">Bruto</th><th class="num">BPJS perusahaan</th><th>Alokasi proyek</th><th></th></tr>' +
    (rows.length ? rows.map((e) => `<tr><td><b>${esc(e.nama)}</b><div class="small muted">${esc(e.kontrak || '')}</div></td><td>${esc(e.divisi)}<div class="small muted">${esc(e.departemen || '')}</div></td>
      <td class="num">${rp(e.bruto)}</td><td class="num">${rp(e.bpjs_perusahaan)}</td>
      <td>${e.alloc.length ? e.alloc.map((a) => `<span class="code-chip">${esc(a.code)}</span> ${num(a.pct)}%`).join(' · ') : `<span class="code-chip">${esc(e.default_project || '—')}</span> <span class="small muted">100% default</span>`}</td>
      <td>${hasPic('fin-pr') ? `<button type="button" class="btn ghost small" data-pr-alloc="${e.karyawan_id}">Atur</button>` : ''}</td></tr>`).join('') : emptyRow(6, 'Tidak ada karyawan'));
}
$('prSearch').addEventListener('input', renderPrEmp);
$('prPeriod').addEventListener('change', () => { prSel = $('prPeriod').value; loadPayroll(); });

function prAllocForm(e) {
  const d = cache.payroll;
  const projOpts = (sel) => d.projects.map((p) => opt(p.project_id, `${p.code} · ${p.name}${p.type === 'CLIENT' ? ' (klien)' : ''}`, p.project_id === sel)).join('');
  const row = (a = {}) => `<div class="doc-up pr-al" style="grid-template-columns:minmax(0,2fr) 110px auto"><select class="pa-proj">${projOpts(a.project_id)}</select>
    <input class="pa-pct" inputmode="decimal" placeholder="%" value="${a.pct ? num(a.pct) : ''}"><button type="button" class="btn ghost small pa-del" aria-label="Hapus">✕</button></div>`;
  openCash(`Alokasi · ${e.nama}`, `${e.divisi} · bruto ${rp(e.bruto)}. Default: 100% ke proyek ${e.default_project || '-'}. Total harus 100%.`, `<div id="paWrap">
    <div id="paRows">${(e.alloc.length ? e.alloc : [{}]).map(row).join('')}</div>
    <div class="row-gap" style="margin-top:8px"><button type="button" class="btn ghost small" id="paAdd">+ Proyek</button><button type="button" class="btn ghost small" id="paReset">Kembali ke default divisi</button></div>
    <div class="diff-box" id="paSum"></div></div>`, 'Simpan alokasi', async () => {
    const allocs = [...document.querySelectorAll('#paRows .pr-al')].map((r) => ({ project_id: r.querySelector('.pa-proj').value, pct: Number(r.querySelector('.pa-pct').value.replace(',', '.')) || 0 }));
    await api('fin_save_payroll_alloc', { p_year: d.year, p_month: d.month, p_karyawan_id: e.karyawan_id, p_allocs: allocs });
    toast(`Alokasi ${e.nama} tersimpan. Tekan "${d.journal ? 'Perbarui' : 'Buat'} jurnal" supaya jurnalnya ikut berubah.`);
  });
  const sum = () => {
    const s = [...document.querySelectorAll('#paRows .pa-pct')].reduce((a, x) => a + (Number(x.value.replace(',', '.')) || 0), 0);
    $('paSum').innerHTML = `Total alokasi: <b class="${Math.abs(s - 100) > 0.001 ? 'overdue' : 'rpt-ok'}">${s.toLocaleString('id-ID')}%</b>`;
  };
  $('paWrap').addEventListener('input', sum);
  $('paAdd').addEventListener('click', () => { $('paRows').insertAdjacentHTML('beforeend', row()); sum(); });
  $('paRows').addEventListener('click', (ev) => { const b = ev.target.closest('.pa-del'); if (b) { b.closest('.pr-al').remove(); sum(); } });
  $('paReset').addEventListener('click', async () => {
    try { await api('fin_save_payroll_alloc', { p_year: d.year, p_month: d.month, p_karyawan_id: e.karyawan_id, p_allocs: [] }); $('cashDialog').close(); toast('Alokasi kembali ke default divisi'); loadPayroll(); }
    catch (err) { $('cashMsg').textContent = err.message; }
  });
  sum();
}

function prPayForm(kind) {
  const d = cache.payroll, o = d.owed[kind];
  if (!d.banks.length) { toast('Belum ada rekening bank aktif. Tambahkan di menu Bank.', true); return; }
  const left = Math.round((num(o.owed) - num(o.paid) - num(o.pending)) * 100) / 100;
  openCash(`${PR_KIND[kind]} · ${BULAN[d.month - 1]} ${d.year}`, `Sisa ${rp(left)}. Disetujui APY, lalu jurnal bank terposting.`, `
    <div class="row2"><div><label for="ppBank">Dari rekening</label><select id="ppBank">${d.banks.map((b) => opt(b.bank_id, b.label)).join('')}</select></div>
      <div><label for="ppDate">Tanggal bayar</label><input type="date" id="ppDate" value="${today()}" max="${today()}" required></div></div>
    <label for="ppAmt">Nilai (Rp)</label><input id="ppAmt" inputmode="decimal" value="${left.toLocaleString('id-ID')}" required>
    <label for="ppRef">No. referensi (transfer / NTPN / kode billing)</label><input id="ppRef">`, 'Kirim ke APY', async () => {
    await api('fin_save_payroll_payment', { p_year: d.year, p_month: d.month, p_kind: kind, p_bank_id: Number($('ppBank').value), p_pay_date: $('ppDate').value, p_amount: parseNum($('ppAmt').value), p_ref_no: fv('ppRef') || null });
    toast('Pembayaran tersimpan, menunggu persetujuan APY');
  });
}

$('page-payroll').addEventListener('click', async (ev) => {
  const d = cache.payroll; if (!d) return;
  const t = (attr) => ev.target.closest(`[${attr}]`);
  let el;
  if (ev.target.closest('#prJournalBtn')) {
    const b = $('prJournalBtn'); b.disabled = true;
    try {
      const r = await api('fin_payroll_journal', { p_year: d.year, p_month: d.month });
      toast(r.status === 'POSTED' ? (r.adjust_draft ? 'Jurnal sudah POSTED; jurnal penyesuaian dibuat, minta PJ memposting.' : 'Jurnal sudah POSTED dan tidak ada perubahan.') : 'Jurnal payroll (DRAFT) siap diposting PJ di menu Jurnal');
      loadPayroll();
    } catch (e) { toast(e.message, true); b.disabled = false; }
  } else if ((el = t('data-pr-alloc'))) prAllocForm(d.employees.find((e) => String(e.karyawan_id) === el.dataset.prAlloc));
  else if ((el = t('data-pr-pay'))) prPayForm(el.dataset.prPay);
  else if ((el = t('data-prp-approve'))) {
    const p = d.payments.find((x) => String(x.payment_id) === el.dataset.prpApprove);
    if (!confirm(`Setujui ${PR_KIND[p.kind].toLowerCase()} ${rp(p.amount)} dari ${p.bank_label}? Jurnal langsung terposting.`)) return;
    el.disabled = true;
    try { await api('fin_decide_payroll_payment', { p_payment_id: p.payment_id, p_approve: true, p_reason: null }); toast('Pembayaran disetujui dan terposting'); loadPayroll(); }
    catch (e) { toast(e.message, true); el.disabled = false; }
  } else if ((el = t('data-prp-reject'))) {
    const id = Number(el.dataset.prpReject);
    openCash('Tolak Pembayaran', '', '<label for="cReason">Alasan penolakan</label><input id="cReason" required>', 'Tolak', async () => {
      await api('fin_decide_payroll_payment', { p_payment_id: id, p_approve: false, p_reason: fv('cReason') }); toast('Pembayaran ditolak');
    });
  }
});

// ---------- rekap pajak ----------
const TAX_SRC = { AR_INVOICE: 'Invoice klien', ASSET_DISPOSAL: 'Jual aset', VENDOR_INVOICE: 'Invoice vendor', CASH_EXPENSE: 'Nota kas', CASH_DIRECT: 'Pengeluaran langsung' };
async function loadPajak() {
  if (!$('taxPeriod').value) { const d = new Date(); d.setMonth(d.getMonth() - 1); $('taxPeriod').value = d.toISOString().slice(0, 7); }
  const [y, m] = $('taxPeriod').value.split('-').map(Number);
  try { renderPajak(await api('fin_tax_report', { p_year: y, p_month: m })); } catch (e) { toast(e.message, true); }
}
function renderPajak(d) {
  cache.pajak = d;
  const sum = (arr, k) => arr.reduce((t, x) => t + num(x[k]), 0);
  const out = d.ppn.filter((x) => x.direction === 'OUT'), inn = d.ppn.filter((x) => x.direction === 'IN'), wapu = d.ppn.filter((x) => x.direction === 'WAPU');
  const ppnOut = sum(out, 'ppn'), ppnIn = sum(inn, 'ppn'), diff = ppnOut - ppnIn;
  const noFaktur = d.ppn.filter((x) => !x.faktur_date || !x.faktur_no).length;
  const pph23 = sum(d.pph23_withheld, 'pph'), p21 = d.pph21;
  const kpi = (label, val, sub, alert) => `<div class="kpi${alert ? ' alert' : ''}"><div class="k-label">${esc(label)}</div><div class="k-val">${esc(val)}</div><div class="k-sub">${esc(sub)}</div></div>`;
  $('taxKpis').innerHTML =
    kpi('PPN Keluaran', rpShort(ppnOut), `${out.length} faktur`) +
    kpi('PPN Masukan', rpShort(ppnIn), `${inn.length} faktur`) +
    kpi(diff >= 0 ? 'PPN kurang bayar' : 'PPN lebih bayar', rpShort(Math.abs(diff)), diff >= 0 ? 'Keluaran − Masukan, perlu disetor' : 'Bisa dikompensasi ke masa berikutnya', diff > 0) +
    kpi('PPh 21', rpShort(p21.amount), p21.payroll_exists ? `${rpShort(p21.paid)} sudah disetor` : 'Belum ada payroll', p21.payroll_exists && num(p21.amount) - num(p21.paid) > 0.004) +
    kpi('PPh 23 dipotong BIMA', rpShort(pph23), `${d.pph23_withheld.length} transaksi`);
  $('taxNote').innerHTML = noFaktur ? `<div class="rpt-note">${noFaktur} dokumen PPN belum lengkap nomor / tanggal fakturnya. Masanya sementara dihitung dari tanggal transaksi; klik <b>Isi faktur</b> untuk melengkapi.</div>` : '';
  const ppnTable = (rows, showProj) => '<tr><th>Tanggal faktur</th><th>No. faktur</th><th>Dokumen</th><th>Lawan transaksi</th><th class="num">DPP</th><th class="num">PPN</th><th></th></tr>' +
    (rows.length ? rows.map((x) => `<tr><td>${x.faktur_date ? tgl(x.faktur_date) : `<span class="overdue small">belum diisi</span><div class="small muted">trx ${tgl(x.trx_date)}</div>`}</td>
      <td>${x.faktur_no ? `<span class="code-chip">${esc(x.faktur_no)}</span>` : '<span class="overdue small">belum diisi</span>'}</td>
      <td>${esc(x.doc_no)}<div class="small muted">${esc(TAX_SRC[x.source] || x.source)}${showProj && x.project_code ? ' · ' + esc(x.project_code) : ''}</div></td>
      <td>${esc(x.counterparty || '-')}${x.npwp ? `<div class="small muted">NPWP ${esc(x.npwp)}</div>` : ''}</td>
      <td class="num">${rp(x.dpp)}</td><td class="num"><b>${rp(x.ppn)}</b></td>
      <td><button type="button" class="btn ghost small" data-tax-faktur="${esc(x.source)}:${esc(x.ref_id)}">${x.faktur_no && x.faktur_date ? 'Ubah' : 'Isi faktur'}</button></td></tr>`).join('')
      + `<tr class="total"><td colspan="4"><b>Total</b></td><td class="num"><b>${rp(sum(rows, 'dpp'))}</b></td><td class="num"><b>${rp(sum(rows, 'ppn'))}</b></td><td></td></tr>`
      : emptyRow(7, 'Tidak ada faktur di masa ini'));
  $('taxOut').innerHTML = ppnTable(out, true);
  $('taxIn').innerHTML = ppnTable(inn, true);
  $('taxWapu').innerHTML = ppnTable(wapu, true);
  $('taxPph21').innerHTML = p21.payroll_exists
    ? `<div class="diff-box" style="margin:0">Payroll ${p21.employees} karyawan · bruto ${rp(p21.bruto)}<br>PPh 21 masa ini: <b>${rp(p21.amount)}</b>
        <br>Sudah disetor (disetujui APY): <b>${rp(p21.paid)}</b>${num(p21.pending) ? ` · menunggu APY ${rp(p21.pending)}` : ''}
        <br>Sisa belum disetor: <b class="${num(p21.amount) - num(p21.paid) > 0.004 ? 'overdue' : 'rpt-ok'}">${rp(num(p21.amount) - num(p21.paid))}</b>
        <br><span class="small muted">Jurnal payroll: ${esc(p21.journal_status || 'belum dibuat')}. Setoran dicatat di menu Payroll → Bayar (PPh 21).</span></div>`
    : '<p class="muted">Belum ada payroll Fusion4 untuk masa ini.</p>';
  const bal = d.balances || {};
  $('taxBal').innerHTML = '<tr><th>Akun</th><th class="num">Saldo</th><th>Artinya</th></tr>' +
    [['2-1500', 'PPN Keluaran yang belum dikompensasi / disetor'], ['1-1400', 'PPN Masukan yang belum dikreditkan'], ['2-1400', 'PPh 21 belum disetor'], ['2-1410', 'PPh 23 dipotong belum disetor'], ['1-1450', 'PPh 23 dibayar dimuka (kredit pajak)']]
      .filter(([c]) => bal[c]).map(([c, t]) => { const b = num(bal[c].balance), v = c.startsWith('2-') ? -b : b; return `<tr><td>${esc(c)} · ${esc(bal[c].name)}</td><td class="num">${rp(v)}</td><td class="small muted">${esc(t)}</td></tr>`; }).join('');
  $('taxPph23').innerHTML = '<tr><th>Tanggal</th><th>Dokumen</th><th>Vendor</th><th class="num">DPP</th><th class="num">PPh 23</th></tr>' +
    (d.pph23_withheld.length ? d.pph23_withheld.map((x) => `<tr><td>${tgl(x.trx_date)}</td><td>${esc(x.doc_no)}<div class="small muted">${esc(TAX_SRC[x.source] || x.source)}</div></td><td>${esc(x.counterparty || '-')}${x.npwp ? `<div class="small muted">NPWP ${esc(x.npwp)}</div>` : ''}</td><td class="num">${rp(x.dpp)}</td><td class="num"><b>${rp(x.pph)}</b></td></tr>`).join('')
      + `<tr class="total"><td colspan="3"><b>Total</b></td><td class="num"><b>${rp(sum(d.pph23_withheld, 'dpp'))}</b></td><td class="num"><b>${rp(pph23)}</b></td></tr>` : emptyRow(5, 'Tidak ada PPh 23 dipotong di masa ini'));
  $('taxClient').innerHTML = '<tr><th>Tanggal terima</th><th>Invoice</th><th>Klien</th><th>Jenis</th><th class="num">Dasar</th><th class="num">PPh</th></tr>' +
    (d.pph_by_client.length ? d.pph_by_client.map((x) => `<tr><td>${tgl(x.receipt_date)}</td><td>${esc(x.invoice_no)}<div class="small muted">${esc(x.ref_no || '')}</div></td><td>${esc(x.client || '-')} <span class="code-chip">${esc(x.project_code || '')}</span></td>
      <td>${x.pph_mode === 'PPH4_2' ? 'PPh 4(2) final' : 'PPh 23'} ${num(x.pph_rate)}%</td><td class="num">${rp(x.base)}</td><td class="num"><b>${rp(x.pph)}</b></td></tr>`).join('')
      : emptyRow(6, 'Tidak ada PPh dipotong klien di masa ini'));
  $('taxBankCard').hidden = !d.bank_interest_tax.length;
  $('taxBank').innerHTML = '<tr><th>Tanggal</th><th>Rekening</th><th>Referensi</th><th class="num">PPh final</th></tr>' +
    d.bank_interest_tax.map((x) => `<tr><td>${tgl(x.txn_date)}</td><td>${esc(x.bank)}</td><td>${esc(x.ref_no || '-')}</td><td class="num">${rp(x.amount)}</td></tr>`).join('');
}
$('taxPeriod').addEventListener('change', loadPajak);
$('page-pajak').addEventListener('click', (ev) => {
  const b = ev.target.closest('[data-tax-faktur]'); if (!b) return;
  const [src, id] = b.dataset.taxFaktur.split(':');
  const x = cache.pajak.ppn.find((r) => r.source === src && String(r.ref_id) === id);
  openCash(`Faktur Pajak · ${x.doc_no}`, `${TAX_SRC[src]} · ${x.counterparty || ''} · PPN ${rp(x.ppn)}. Masa PPN mengikuti tanggal faktur.`, `
    <div class="row2"><div><label for="fkNo">No. faktur pajak</label><input id="fkNo" value="${esc(x.faktur_no || '')}" placeholder="mis. 010.000-26.12345678"></div>
      <div><label for="fkDate">Tanggal faktur</label><input type="date" id="fkDate" value="${esc(x.faktur_date || '')}"></div></div>`, 'Simpan faktur', async () => {
    await api('fin_set_faktur', { p_source: src, p_ref_id: Number(id), p_faktur_no: fv('fkNo') || null, p_faktur_date: $('fkDate').value || null });
    toast('Faktur tersimpan');
  });
});
$('taxExport').addEventListener('click', async () => {
  const d = cache.pajak; if (!d) { toast('Tampilkan rekap dulu.', true); return; }
  try {
    const XLSX = await loadXlsx();
    const wb = XLSX.utils.book_new();
    const masa = `${String(d.month).padStart(2, '0')}/${d.year}`;
    const add = (name, header, rows) => {
      const ws = XLSX.utils.aoa_to_sheet([[`SmartFin · ${name} · Masa ${masa}`], [], header, ...rows]);
      ws['!cols'] = header.map((h) => ({ wch: Math.max(12, h.length + 4) }));
      const range = XLSX.utils.decode_range(ws['!ref']);
      for (let R = range.s.r; R <= range.e.r; ++R) for (let C = range.s.c; C <= range.e.c; ++C) {
        const cell = ws[XLSX.utils.encode_cell({ r: R, c: C })]; if (cell && cell.t === 'n') cell.z = '#,##0';
      }
      XLSX.utils.book_append_sheet(wb, ws, name.slice(0, 31));
    };
    const ppnRows = (dir) => d.ppn.filter((x) => x.direction === dir).map((x) => [x.faktur_date || '', x.faktur_no || '', x.doc_no, TAX_SRC[x.source] || x.source, x.counterparty || '', x.npwp || '', x.project_code || '', num(x.dpp), num(x.ppn), x.trx_date]);
    const ppnHead = ['Tanggal faktur', 'No. faktur', 'Dokumen', 'Sumber', 'Lawan transaksi', 'NPWP', 'Proyek', 'DPP', 'PPN', 'Tanggal transaksi'];
    const sum = (dir) => d.ppn.filter((x) => x.direction === dir).reduce((t, x) => t + num(x.ppn), 0);
    add('Ringkasan', ['Pos', 'Nilai'], [['PPN Keluaran', sum('OUT')], ['PPN Masukan', sum('IN')], ['PPN kurang (lebih) bayar', sum('OUT') - sum('IN')], ['PPN dipungut klien (WAPU)', sum('WAPU')],
      ['PPh 21', num(d.pph21.amount)], ['PPh 21 sudah disetor', num(d.pph21.paid)], ['PPh 23 dipotong BIMA', d.pph23_withheld.reduce((t, x) => t + num(x.pph), 0)],
      ['PPh 23 dipotong klien', d.pph_by_client.filter((x) => x.pph_mode !== 'PPH4_2').reduce((t, x) => t + num(x.pph), 0)],
      ['PPh 4(2) dipotong klien', d.pph_by_client.filter((x) => x.pph_mode === 'PPH4_2').reduce((t, x) => t + num(x.pph), 0)]]);
    add('PPN Keluaran', ppnHead, ppnRows('OUT'));
    add('PPN Masukan', ppnHead, ppnRows('IN'));
    add('PPN WAPU', ppnHead, ppnRows('WAPU'));
    add('PPh 23 dipotong BIMA', ['Tanggal', 'Dokumen', 'Sumber', 'Vendor', 'NPWP', 'DPP', 'PPh 23'], d.pph23_withheld.map((x) => [x.trx_date, x.doc_no, TAX_SRC[x.source] || x.source, x.counterparty || '', x.npwp || '', num(x.dpp), num(x.pph)]));
    add('PPh dipotong klien', ['Tanggal terima', 'Invoice', 'Klien', 'Proyek', 'Jenis', 'Tarif %', 'Dasar', 'PPh', 'Referensi'], d.pph_by_client.map((x) => [x.receipt_date, x.invoice_no, x.client || '', x.project_code || '', x.pph_mode === 'PPH4_2' ? 'PPh 4(2) final' : 'PPh 23', num(x.pph_rate), num(x.base), num(x.pph), x.ref_no || '']));
    XLSX.writeFile(wb, `SmartFin_Rekap_Pajak_${d.year}-${String(d.month).padStart(2, '0')}.xlsx`);
  } catch (e) { toast(e.message, true); }
});

// ---------- laporan keuangan ----------
const RPT_TITLE = { TB: 'Neraca Saldo', GL: 'Buku Besar', PL: 'Laba Rugi', BS: 'Neraca', CF: 'Arus Kas' };
let rptKind = 'TB', rptExportRows = null, rptMeta = null;
const rpN = (v) => { const n = num(v); return n < 0 ? `(${rp(-n)})` : rp(n); };
const dk = (v) => { const n = num(v); return n === 0 ? rp(0) : `${rp(Math.abs(n))} ${n > 0 ? 'D' : 'K'}`; };
function rptInitDates() {
  if ($('rptFrom').value) return;
  const t = today();
  $('rptFrom').value = t.slice(0, 8) + '01';
  $('rptTo').value = t;
}
async function loadLaporan() { rptInitDates(); runReport(); }
function setRptTab(k) {
  rptKind = k;
  document.querySelectorAll('[data-rpt]').forEach((b) => b.classList.toggle('active', b.dataset.rpt === k));
  $('rptAccWrap').hidden = k !== 'GL';
  $('rptFrom').disabled = k === 'BS';
}
document.querySelectorAll('[data-rpt]').forEach((b) => b.addEventListener('click', () => { setRptTab(b.dataset.rpt); runReport(); }));
$('rptRun').addEventListener('click', () => runReport());
async function runReport(account) {
  if (account) $('rptAccount').value = account;
  if (rptKind === 'GL' && !$('rptAccount').value) {
    if (rptMeta && rptMeta.accounts.length) {
      $('rptBody').innerHTML = '<p class="muted">Pilih akun, lalu klik Tampilkan. Atau klik akun di Neraca Saldo / Laba Rugi.</p>';
      rptExportRows = null; return;
    }
  }
  $('rptBody').innerHTML = '<p class="muted">Menghitung…</p>';
  try {
    const r = await api('fin_report', { p_report: rptKind, p_from: $('rptFrom').value || null, p_to: $('rptTo').value || null,
      p_project_id: $('rptProject').value || null, p_account: rptKind === 'GL' ? ($('rptAccount').value || null) : null,
      p_include_draft: $('rptDraft').checked, p_journal_id: null });
    if (r.meta && !rptMeta) {
      rptMeta = r.meta;
      $('rptProject').innerHTML = '<option value="">Semua proyek</option>' + r.meta.projects.map((p) => `<option value="${esc(p.project_id)}">${esc(p.code)} · ${esc(p.name)}</option>`).join('');
      $('rptAccount').innerHTML = '<option value="">— pilih akun —</option>' + r.meta.accounts.map((a) => `<option value="${esc(a.code)}">${esc(a.code)} · ${esc(a.name)}</option>`).join('');
      if (account) $('rptAccount').value = account;
    }
    renderReport(r);
  } catch (e) { $('rptBody').innerHTML = `<p class="error-text">${esc(e.message)}</p>`; rptExportRows = null; }
}
function rptHeader(r) {
  const period = r.report === 'BS' ? `Per ${tgl(r.to)}` : `${tgl(r.from)} s/d ${tgl(r.to)}`;
  const proj = r.project ? ` · Proyek ${esc(r.project.code)}` : ' · Semua proyek';
  const note = r.includeDraft && num(r.draftCount) > 0 ? `<div class="rpt-note">Termasuk ${r.draftCount} jurnal DRAFT yang belum diposting PJ. Matikan "Termasuk jurnal DRAFT" untuk angka final.</div>` : '';
  return `<div class="rpt-head"><h2>${RPT_TITLE[r.report]}</h2><span class="small muted">${period}${proj}</span></div>${note}`;
}
function renderReport(r) {
  const d = r.data; let html = rptHeader(r); const X = [[RPT_TITLE[r.report]], [r.report === 'BS' ? `Per ${r.to}` : `${r.from} s/d ${r.to}`, r.project ? 'Proyek ' + r.project.code : 'Semua proyek'], []];
  if (r.report === 'TB') {
    const t = d.reduce((a, x) => ({ o: a.o + num(x.opening), d: a.d + num(x.debit), c: a.c + num(x.credit), z: a.z + num(x.closing) }), { o: 0, d: 0, c: 0, z: 0 });
    html += '<div class="scroll"><table class="rpt"><tr><th>Akun</th><th>Nama akun</th><th class="num">Saldo awal</th><th class="num">Debit</th><th class="num">Kredit</th><th class="num">Saldo akhir</th></tr>' +
      (d.length ? d.map((x) => `<tr class="link" data-gl="${esc(x.account_code)}"><td>${esc(x.account_code)}</td><td>${esc(x.account_name)}</td><td class="num">${dk(x.opening)}</td><td class="num">${rp(x.debit)}</td><td class="num">${rp(x.credit)}</td><td class="num">${dk(x.closing)}</td></tr>`).join('') : emptyRow(6, 'Belum ada jurnal'))
      + `<tr class="total"><td colspan="2">Total</td><td class="num">${dk(t.o)}</td><td class="num">${rp(t.d)}</td><td class="num">${rp(t.c)}</td><td class="num">${dk(t.z)}</td></tr></table></div>`
      + `<p class="small ${Math.round(t.d - t.c) === 0 ? 'rpt-ok' : 'rpt-bad'}">${Math.round(t.d - t.c) === 0 ? 'Seimbang: total debit = total kredit.' : 'Tidak seimbang: selisih ' + rp(t.d - t.c)}</p>`;
    X.push(['Akun', 'Nama akun', 'Saldo awal (D+/K-)', 'Debit', 'Kredit', 'Saldo akhir (D+/K-)']);
    d.forEach((x) => X.push([x.account_code, x.account_name, num(x.opening), num(x.debit), num(x.credit), num(x.closing)]));
    X.push(['Total', '', t.o, t.d, t.c, t.z]);
  } else if (r.report === 'GL') {
    let bal = num(d.opening);
    html += `<p><b>${esc(d.account ? d.account.code + ' · ' + d.account.name : '')}</b></p><div class="scroll"><table class="rpt"><tr><th>Tanggal</th><th>No. jurnal</th><th>Keterangan</th><th>Proyek</th><th class="num">Debit</th><th class="num">Kredit</th><th class="num">Saldo</th></tr>`
      + `<tr class="sub"><td colspan="6">Saldo awal</td><td class="num">${dk(bal)}</td></tr>`;
    X.push(['Akun', d.account ? d.account.code + ' ' + d.account.name : '']); X.push(['Tanggal', 'No. jurnal', 'Keterangan', 'Proyek', 'Debit', 'Kredit', 'Saldo (D+/K-)']); X.push(['', '', 'Saldo awal', '', '', '', bal]);
    d.lines.forEach((x) => {
      bal += num(x.debit) - num(x.credit);
      html += `<tr class="link" data-jrn="${esc(x.journal_id)}"><td>${tgl(x.journal_date)}</td><td>${esc(x.journal_no || 'DRAFT #' + x.journal_id)}${x.status === 'DRAFT' ? ' <span class="badge warn">Draft</span>' : ''}</td><td>${esc(x.description)}${x.memo ? `<div class="small muted">${esc(x.memo)}</div>` : ''}</td><td>${esc(x.project_code || '-')}</td><td class="num">${num(x.debit) ? rp(x.debit) : ''}</td><td class="num">${num(x.credit) ? rp(x.credit) : ''}</td><td class="num">${dk(bal)}</td></tr>`;
      X.push([x.journal_date, x.journal_no || 'DRAFT #' + x.journal_id, x.description, x.project_code || '', num(x.debit), num(x.credit), bal]);
    });
    html += (d.lines.length ? '' : emptyRow(7, 'Tidak ada mutasi di periode ini')) + `<tr class="total"><td colspan="6">Saldo akhir</td><td class="num">${dk(bal)}</td></tr></table></div>`;
  } else if (r.report === 'PL') {
    const rev = d.accounts.filter((a) => a.account_type === 'REVENUE');
    const cogs = d.accounts.filter((a) => a.account_type === 'EXPENSE' && a.account_code.startsWith('5-'));
    const opex = d.accounts.filter((a) => a.account_type === 'EXPENSE' && !a.account_code.startsWith('5-'));
    const sum = (arr) => arr.reduce((t, a) => t + num(a.amount), 0);
    const R = sum(rev), C = sum(cogs), O = sum(opex);
    const rows = (arr) => arr.map((a) => `<tr class="link" data-gl="${esc(a.account_code)}"><td class="ind">${esc(a.account_code)} · ${esc(a.account_name)}</td><td class="num">${rpN(a.amount)}</td></tr>`).join('') || '<tr><td class="ind muted">-</td><td></td></tr>';
    html += `<div class="scroll"><table class="rpt"><tr><th>Keterangan</th><th class="num">Nilai</th></tr>
      <tr class="sec"><td colspan="2">Pendapatan</td></tr>${rows(rev)}<tr class="sub"><td>Total pendapatan</td><td class="num">${rpN(R)}</td></tr>
      <tr class="sec"><td colspan="2">Beban pokok proyek</td></tr>${rows(cogs)}<tr class="sub"><td>Total beban pokok proyek</td><td class="num">${rpN(C)}</td></tr>
      <tr class="sub"><td>Laba kotor</td><td class="num">${rpN(R - C)}</td></tr>
      <tr class="sec"><td colspan="2">Beban usaha</td></tr>${rows(opex)}<tr class="sub"><td>Total beban usaha</td><td class="num">${rpN(O)}</td></tr>
      <tr class="total"><td>Laba (rugi) bersih</td><td class="num">${rpN(R - C - O)}</td></tr></table></div>`;
    html += '<h3 style="margin:18px 0 6px">Per proyek</h3><div class="scroll"><table class="rpt"><tr><th>Proyek</th><th class="num">Pendapatan</th><th class="num">Beban</th><th class="num">Margin</th><th class="num">Margin %</th></tr>'
      + (d.projects.length ? d.projects.map((p) => { const m = num(p.revenue) - num(p.expense); return `<tr><td>${p.code ? esc(p.code) + ' · ' : ''}${esc(p.name)}</td><td class="num">${rpN(p.revenue)}</td><td class="num">${rpN(p.expense)}</td><td class="num">${rpN(m)}</td><td class="num">${num(p.revenue) ? (m / num(p.revenue) * 100).toFixed(1) + '%' : '-'}</td></tr>`; }).join('') : emptyRow(5, 'Belum ada pendapatan / beban'))
      + '</table></div>';
    X.push(['Keterangan', 'Nilai']); X.push(['PENDAPATAN']); rev.forEach((a) => X.push([a.account_code + ' ' + a.account_name, num(a.amount)])); X.push(['Total pendapatan', R]);
    X.push(['BEBAN POKOK PROYEK']); cogs.forEach((a) => X.push([a.account_code + ' ' + a.account_name, num(a.amount)])); X.push(['Total beban pokok proyek', C]); X.push(['Laba kotor', R - C]);
    X.push(['BEBAN USAHA']); opex.forEach((a) => X.push([a.account_code + ' ' + a.account_name, num(a.amount)])); X.push(['Total beban usaha', O]); X.push(['Laba (rugi) bersih', R - C - O]);
    X.push([]); X.push(['Proyek', 'Pendapatan', 'Beban', 'Margin']); d.projects.forEach((p) => X.push([(p.code ? p.code + ' ' : '') + p.name, num(p.revenue), num(p.expense), num(p.revenue) - num(p.expense)]));
  } else if (r.report === 'BS') {
    const by = (t) => d.accounts.filter((a) => a.account_type === t);
    const sum = (arr) => arr.reduce((t, a) => t + num(a.amount), 0);
    const A = by('ASSET'), L = by('LIABILITY'), E = by('EQUITY');
    const sa = sum(A), sl = sum(L), se = sum(E) + num(d.priorEarnings) + num(d.currentEarnings);
    const rows = (arr) => arr.map((a) => `<tr class="link" data-gl="${esc(a.account_code)}"><td class="ind">${esc(a.account_code)} · ${esc(a.account_name)}</td><td class="num">${rpN(a.amount)}</td></tr>`).join('') || '<tr><td class="ind muted">-</td><td></td></tr>';
    const ok = Math.round(sa - sl - se) === 0;
    html += `<div class="scroll"><table class="rpt"><tr><th>Keterangan</th><th class="num">Nilai</th></tr>
      <tr class="sec"><td colspan="2">Aset</td></tr>${rows(A)}<tr class="total"><td>Total aset</td><td class="num">${rpN(sa)}</td></tr>
      <tr class="sec"><td colspan="2">Liabilitas</td></tr>${rows(L)}<tr class="sub"><td>Total liabilitas</td><td class="num">${rpN(sl)}</td></tr>
      <tr class="sec"><td colspan="2">Ekuitas</td></tr>${rows(E)}
      <tr><td class="ind">Laba ditahan (sebelum ${tgl(d.fiscalYearStart)})</td><td class="num">${rpN(d.priorEarnings)}</td></tr>
      <tr><td class="ind">Laba tahun berjalan</td><td class="num">${rpN(d.currentEarnings)}</td></tr>
      <tr class="sub"><td>Total ekuitas</td><td class="num">${rpN(se)}</td></tr>
      <tr class="total"><td>Total liabilitas + ekuitas</td><td class="num">${rpN(sl + se)}</td></tr></table></div>
      <p class="small ${ok ? 'rpt-ok' : 'rpt-bad'}">${ok ? 'Seimbang: total aset = liabilitas + ekuitas.' : 'Tidak seimbang: selisih ' + rp(sa - sl - se) + (r.project ? ' (wajar kalau difilter per proyek)' : '')}</p>`;
    X.push(['Keterangan', 'Nilai']); X.push(['ASET']); A.forEach((a) => X.push([a.account_code + ' ' + a.account_name, num(a.amount)])); X.push(['Total aset', sa]);
    X.push(['LIABILITAS']); L.forEach((a) => X.push([a.account_code + ' ' + a.account_name, num(a.amount)])); X.push(['Total liabilitas', sl]);
    X.push(['EKUITAS']); E.forEach((a) => X.push([a.account_code + ' ' + a.account_name, num(a.amount)])); X.push(['Laba ditahan', num(d.priorEarnings)]); X.push(['Laba tahun berjalan', num(d.currentEarnings)]); X.push(['Total ekuitas', se]); X.push(['Total liabilitas + ekuitas', sl + se]);
  } else if (r.report === 'CF') {
    const c = d.categories || {};
    const lines = [['OPERASI', 'Arus kas dari operasi'], ['INVESTASI', 'Arus kas dari investasi (aset tetap)'], ['PENDANAAN', 'Arus kas dari pendanaan (modal)'], ['SALDO_AWAL', 'Setoran saldo awal rekening']];
    const net = lines.reduce((t, [k]) => t + num(c[k]), 0);
    html += `<div class="scroll"><table class="rpt"><tr><th>Keterangan</th><th class="num">Nilai</th></tr>
      <tr class="sub"><td>Saldo kas &amp; bank awal periode</td><td class="num">${rpN(d.opening)}</td></tr>
      ${lines.map(([k, t]) => `<tr><td class="ind">${t}</td><td class="num">${rpN(c[k] || 0)}</td></tr>`).join('')}
      <tr class="sub"><td>Kenaikan (penurunan) kas</td><td class="num">${rpN(net)}</td></tr>
      <tr class="total"><td>Saldo kas &amp; bank akhir periode</td><td class="num">${rpN(d.closing)}</td></tr></table></div>
      <p class="small muted">Kas &amp; bank = semua akun kas kecil (1-11xx) dan bank (1-12xx). Transfer antar rekening sendiri tidak dihitung.</p>
      <h3 style="margin:18px 0 6px">Rincian</h3><div class="scroll"><table class="rpt"><tr><th>Tanggal</th><th>No. jurnal</th><th>Keterangan</th><th>Kelompok</th><th class="num">Kas masuk / (keluar)</th></tr>`
      + (d.detail.length ? d.detail.map((x) => `<tr class="link" data-jrn="${esc(x.journal_id)}"><td>${tgl(x.journal_date)}</td><td>${esc(x.journal_no || 'DRAFT #' + x.journal_id)}</td><td>${esc(x.description)}</td><td class="small">${esc((lines.find((l) => l[0] === x.category) || [, x.category])[1])}</td><td class="num">${rpN(x.cash_delta)}</td></tr>`).join('') : emptyRow(5, 'Tidak ada arus kas di periode ini')) + '</table></div>';
    X.push(['Keterangan', 'Nilai']); X.push(['Saldo kas & bank awal', num(d.opening)]); lines.forEach(([k, t]) => X.push([t, num(c[k] || 0)])); X.push(['Kenaikan (penurunan) kas', net]); X.push(['Saldo kas & bank akhir', num(d.closing)]);
    X.push([]); X.push(['Tanggal', 'No. jurnal', 'Keterangan', 'Kelompok', 'Kas masuk/(keluar)']); d.detail.forEach((x) => X.push([x.journal_date, x.journal_no || '', x.description, x.category, num(x.cash_delta)]));
  }
  $('rptBody').innerHTML = html;
  rptExportRows = X;
}
$('rptBody').addEventListener('click', async (ev) => {
  const g = ev.target.closest('[data-gl]');
  if (g) { setRptTab('GL'); runReport(g.dataset.gl); return; }
  const j = ev.target.closest('[data-jrn]');
  if (j) openJournalDetail(Number(j.dataset.jrn));
});
async function openJournalDetail(id) {
  try {
    const r = await api('fin_report', { p_report: 'JOURNAL', p_from: null, p_to: null, p_project_id: null, p_account: null, p_include_draft: true, p_journal_id: id });
    const x = r.data;
    const td = x.lines.reduce((t, l) => t + num(l.debit), 0), tc = x.lines.reduce((t, l) => t + num(l.credit), 0);
    openCash(x.journal_no || 'Jurnal DRAFT #' + x.journal_id, `${tgl(x.journal_date)} · ${x.source_system} · ${x.status === 'POSTED' ? 'diposting ' + (x.posted_by || '') : 'DRAFT, belum diposting'}`,
      `<p>${esc(x.description)}</p><div class="scroll"><table class="rpt"><tr><th>Akun</th><th>Proyek</th><th class="num">Debit</th><th class="num">Kredit</th></tr>`
      + x.lines.map((l) => `<tr><td>${esc(l.account_code)} · ${esc(l.account_name || '')}${l.memo ? `<div class="small muted">${esc(l.memo)}</div>` : ''}</td><td>${esc(l.project_code || '-')}</td><td class="num">${num(l.debit) ? rp(l.debit) : ''}</td><td class="num">${num(l.credit) ? rp(l.credit) : ''}</td></tr>`).join('')
      + `<tr class="total"><td colspan="2">Total</td><td class="num">${rp(td)}</td><td class="num">${rp(tc)}</td></tr></table></div>`, null, null);
  } catch (e) { toast(e.message, true); }
}
let xlsxLoading = null;
const loadXlsx = () => xlsxLoading || (xlsxLoading = new Promise((res, rej) => {
  const s = document.createElement('script');
  s.src = 'https://cdn.sheetjs.com/xlsx-0.20.3/package/dist/xlsx.full.min.js';
  s.onload = () => res(window.XLSX); s.onerror = () => { xlsxLoading = null; rej(new Error('Gagal memuat modul Excel. Cek koneksi internet.')); };
  document.head.appendChild(s);
}));
$('rptExport').addEventListener('click', async () => {
  if (!rptExportRows) { toast('Tampilkan laporan dulu.', true); return; }
  try {
    const XLSX = await loadXlsx();
    const ws = XLSX.utils.aoa_to_sheet(rptExportRows);
    ws['!cols'] = [{ wch: 14 }, { wch: 40 }, { wch: 18 }, { wch: 18 }, { wch: 18 }, { wch: 18 }, { wch: 18 }];
    const range = XLSX.utils.decode_range(ws['!ref']);
    for (let R = range.s.r; R <= range.e.r; ++R) for (let C = range.s.c; C <= range.e.c; ++C) {
      const cell = ws[XLSX.utils.encode_cell({ r: R, c: C })];
      if (cell && cell.t === 'n') cell.z = '#,##0;(#,##0)';
    }
    const wb = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(wb, ws, RPT_TITLE[rptKind].slice(0, 31));
    XLSX.writeFile(wb, `SmartFin_${RPT_TITLE[rptKind].replace(/\s+/g, '_')}_${$('rptTo').value || today()}.xlsx`);
  } catch (e) { toast(e.message, true); }
});

const loaders = { pajak: loadPajak, payroll: loadPayroll, ar: loadAR, laporan: loadLaporan, dashboard: loadDashboard, ap: loadAP, bayar: loadBayar, bank: loadBank, kas: loadKas, jurnal: loadJurnal, budget: loadBudget, aset: loadAset };

// ---------- start ----------
(function init() {
  const d = new Date(); d.setMonth(d.getMonth() - 1);
  $('depPeriod').value = d.toISOString().slice(0, 7);
  try { session = JSON.parse(sessionStorage.getItem(SESSION_KEY)); } catch (e) { session = null; }
  if (session && session.token && new Date(session.expiresAt) > new Date()) startApp();
  else { session = null; loadAccounts(); }
})();
