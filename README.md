# SmartFin BIMA

Smart Financial System BIMA. Sistem ini terintegrasi dengan **SMMS** (material & jasa) dan **Fusion4 SmartGate** (SDM & payroll), dan semuanya ada di satu project Supabase: `nhmpwjriextmbotmvvbu`.

- Alur sistem (whiteboard): https://claude.ai/artifact/AT32YFAykZEzGiNaGHf5Y8
- Dummy page dashboard: https://claude.ai/artifact/BoqyjLuW8tmcnaASCrgLzT

## Struktur database

| Schema | Isi |
|---|---|
| `public` | Tabel SMMS & Fusion4 (sudah ada) |
| `operational` | Proyek, kontrak, BOQ, Work Order (sudah ada) |
| `finance` | **Baru**: COA, budget, jurnal, AP |

## Fase 1: AP + Budget vs Actual

| File | Isi | Status |
|---|---|---|
| `sql/migrations/001_finance_foundation.sql` | Schema finance, COA, budget, jurnal, invoice, jadwal bayar, view 3-way match & Budget vs Actual | ✅ Sudah dijalankan (26 Nov 2026) |
| `sql/migrations/002_auto_journal.sql` | Trigger jurnal otomatis (penerimaan vendor, serah terima, retur, invoice, pembayaran) + backfill | ✅ Sudah dijalankan (26 Nov 2026) |
| `sql/migrations/003_fixed_asset.sql` | Register aset tetap per unit (otomatis dari SMMS) + penyusutan bulanan | ✅ Sudah dijalankan (26 Nov 2026) |
| `sql/migrations/004_auth_api.sql` | Login SmartFin (PIC = menu, Author = approval) + API `fin_*` untuk halaman web | ✅ Sudah dijalankan (26 Nov 2026) |
| `sql/migrations/005_payment.sql` | Rekening bank, termin vendor, jadwal & approval pembayaran (APY), biaya tambahan invoice | ✅ Sudah dijalankan (27 Nov 2026) |
| `sql/migrations/006_documents.sql` | Checklist & upload dokumen invoice (Gate A uang muka, Gate B invoice), invoice HOLD kalau dokumen belum lengkap | ✅ Sudah dijalankan (27 Nov 2026) |
| `sql/migrations/007_payment_doc_hold.sql` | Pembayaran HOLD kalau dokumen belum lengkap, hand over dihitung sebagai bukti terima site | ✅ Sudah dijalankan (27 Nov 2026) |
| `sql/migrations/008_cash.sql` | Petty cash site, pengeluaran langsung tanpa PO, kasbon karyawan, hak akses FIN-PC & APC | ✅ Sudah dijalankan (27 Nov 2026) |
| `sql/migrations/009_bank.sql` | Saldo awal rekening (cut-off manual), mutasi bank lain-lain, rekonsiliasi bulanan | ✅ Sudah dijalankan (27 Nov 2026) |
| `sql/migrations/010_reports.sql` | Menu Laporan (PIC FIN-RPT): neraca saldo, buku besar, laba rugi + per proyek, neraca, arus kas, detail jurnal | ✅ Sudah dijalankan (27 Nov 2026) |
| `sql/migrations/011_ar.sql` | Piutang klien (PIC FIN-AR, approve PJ): invoice dari SMS approved + manual, retensi, PPN/PPh per invoice, penerimaan ke bank | ✅ Sudah dijalankan (27 Nov 2026) |
| `sql/migrations/012_payroll.sql` | Payroll (PIC FIN-PR): jurnal gaji bulanan dari Fusion4 dengan alokasi proyek, pembayaran THP / BPJS / PPh 21 (approve APY) | ✅ Sudah dijalankan (27 Nov 2026) |
| `sql/migrations/013_asset_disposal.sql` | Pelepasan aset tetap (dijual / dihapus): diajukan FIN-AST, disetujui PJ, jurnal laba/rugi | ✅ Sudah dijalankan (27 Nov 2026) |
| `sql/migrations/014_bank_fin_jv.sql` | Menu Bank bisa dibuka FIN-JV (approver PJ tidak perlu FIN-AP); input tetap FIN-AP | ✅ Sudah dijalankan (27 Nov 2026) |
| `sql/migrations/015_tax.sql` | Menu Pajak (PIC FIN-TAX): rekap PPN (masa = tanggal faktur), PPh 21, PPh 23, PPh dipotong klien, tanggal faktur | ✅ Sudah dijalankan (27 Nov 2026) |

### Rencana jurnal otomatis (migration 002)

| Event | Debit | Kredit |
|---|---|---|
| Barang diterima dari vendor (`vendorReceiving`) | 1-1600 Persediaan Material di Site | 2-1150 Hutang Belum Ditagih |
| Invoice vendor cocok (3-way match) | 2-1150 Hutang Belum Ditagih + 1-1400 PPN Masukan | 2-1100 Hutang Usaha (dan 2-1410 PPh 23 untuk jasa) |
| Pembayaran vendor | 2-1100 Hutang Usaha | 1-1200 Bank |
| Serah terima ke end user (`endUserReceiving`) | 5-1100 Beban Material Proyek | 1-1600 Persediaan Material di Site |

Semua jurnal otomatis masuk sebagai **DRAFT**. Jurnal baru berstatus POSTED setelah di-approve Finance lewat `finance.post_journal()`, dan fungsi itu menolak jurnal yang tidak balance.

| Retur material dari end user (`materialReturn`) | 1-1600 Persediaan | 5-1100 Beban Material Proyek |
| DP dibayar sebelum invoice | 1-1500 Uang Muka Vendor | 1-1200 Bank |

Klasifikasi saat barang diterima dari vendor:

| Jenis | Penanda | Akun debit |
|---|---|---|
| Material, Consumables, Coating, dll | — | 1-1600 Persediaan |
| Service Order | DocType SO | 5-1200 Beban Jasa / Sewa |
| Tools / Heavy Equipment **sewa** | `Duration` di Request terisi | 5-1200 Beban Jasa / Sewa |
| Tools / Heavy Equipment **beli**, harga/unit ≥ batas kapitalisasi | `Duration` kosong | 1-2100 Aset Tetap |
| Tools / Heavy Equipment **beli**, harga/unit < batas kapitalisasi | `Duration` kosong | 5-1250 Beban Peralatan Kecil |

Batas kapitalisasi disimpan di `finance.setting` (key `capitalization_threshold`), saat ini 0 dan **wajib ditetapkan akuntan**. Register aset & penyusutan bulanan: migration 003.

Kalau data SMMS diedit atau dihapus: jurnal yang masih DRAFT ikut diperbarui atau di-VOID, sedangkan jurnal yang sudah POSTED tidak diubah. Untuk yang POSTED, sistem membuat jurnal penyesuaian sebesar selisihnya. Error di trigger tidak pernah menggagalkan transaksi SMMS; error dicatat di `finance.auto_journal_error`.

### Asumsi yang perlu dikonfirmasi

1. `request.PROJECTID` (14, 15, 901) = `operational.projects.code` ('014', '015', '901'). Kolom `smms_project_id` di projects masih kosong.
2. Nilai komitmen PO memakai subtotal sebelum PPN.
3. Penanda sewa vs beli untuk Tools/Heavy Equipment = kolom `Duration` di Request (dikonfirmasi 26 Nov 2026).
4. Nomor & nama akun COA masih contoh dan **wajib direview akuntan/konsultan pajak**.

### Register aset & penyusutan (migration 003)

1. Tools/HE yang **dibeli** dan masuk Aset Tetap: saat diterima di SMMS, SmartFin otomatis membuat **1 kartu aset per unit** dengan status `PERLU_DILENGKAPI`. Datanya ditarik dari SMMS: item, kode item, PO, vendor, tanggal terima, harga, proyek, dan site.
2. Finance mengisi **kategori** (KEL1–KEL4, yang memberi umur default), lalu bisa mengubah umur, nilai sisa, dan metode. Setelah lengkap, status otomatis jadi `AKTIF`.
3. Penyusutan mulai **bulan berikutnya** setelah tanggal terima. Jalankan `finance.run_depreciation('YYYY-MM-01')` tiap akhir bulan; aman dijalankan ulang. Hasilnya jurnal DRAFT: Dr 6-1300 Beban Penyusutan / Cr 1-2900 Akumulasi, per proyek.
4. Kalau qty penerimaan di SMMS dikurangi atau dihapus: unit yang belum disusutkan ikut dihapus, sedangkan unit yang sudah disusutkan ditandai `PERLU_DICEK`.

Umur KEL1–KEL4 (4/8/16/20 tahun) mengacu ke kelompok harta fiskal UU PPh. Penggolongan tiap alat dan umur komersialnya **wajib dicek akuntan**.

### Hak akses SmartFin (migration 004)

Diatur lewat `paswordTbl`, dengan pola yang sama seperti modul Operational:

| Kolom | Kode | Arti |
|---|---|---|
| PIC (menu) | `FIN` | Dashboard |
| | `FIN-AP` | Hutang vendor & invoice, input menu Bank |
| | `FIN-JV` | Jurnal; bisa membuka menu Bank untuk approval PJ (migration 014) |
| | `FIN-BVA` | Budget vs Actual / RAB |
| | `FIN-AST` | Aset tetap |
| | `FIN-AR` | Piutang klien: invoice ke klien & penerimaan uang (migration 011) |
| | `FIN-PR` | Payroll: jurnal gaji dari Fusion4, alokasi proyek, pembayaran gaji/BPJS/PPh 21 (migration 012). Pemegang `FIN-AP` hanya melihat total, tanpa rincian per karyawan |
| | `FIN-TAX` | Rekap pajak per masa + melengkapi nomor/tanggal faktur (migration 015) |
| | `FIN-RPT` | Laporan keuangan: neraca saldo, buku besar, laba rugi, neraca, arus kas (migration 010) |
| | `FIN-PC` | Kas & Kasbon: pemegang kas site input nota, ajukan isi kas / kasbon (migration 008) |
| | `FIN-ALL` | Semua menu SmartFin |
| PIC / Author | `ALL` | **Super admin**: semua menu + semua approval (AI, PJ, AB, APY, APC). Saat trial hanya 1 admin |
| Author (approval) | `AI` / `AI-014` | Approve invoice, untuk semua proyek atau hanya proyek 014 |
| | `PJ` / `PJ-014` | Posting jurnal, approve saldo awal / mutasi bank / rekonsiliasi (migration 009), approve invoice klien & penerimaan per proyek (migration 011), approve pelepasan aset (migration 013) |
| | `AB` | Approve budget/RAB |
| | `APY` | Approve pembayaran vendor, isi kas site, pengeluaran langsung, kasbon, pembayaran gaji/BPJS/PPh 21 (migration 012) |
| | `APC` / `APC-014` | Approve nota petty cash & nota kasbon (migration 008) |

Web hanya memanggil fungsi `public.fin_*`. Setiap fungsi mengecek token sesi (8 jam), PIC, dan Author di server, sedangkan tabel `finance` tetap tertutup untuk akses langsung.

## Halaman web

| File | Isi |
|---|---|
| `index.html` | Login + halaman Dashboard, Hutang Vendor, Jurnal, Budget vs Actual, Aset Tetap |
| `app.js` | Logika halaman. Semua data lewat API `fin_*`, hanya memakai publishable key |
| `style.css` | Tampilan (warna BIMA) |

Menu yang muncul mengikuti PIC akun. Tombol approval (Posting, Approve) hanya muncul untuk pemegang Author yang sesuai, dan tetap dicek ulang di server.

### Pembayaran vendor (migration 005)

| Termin di RFQ | Jadwal otomatis |
|---|---|
| Before Delivery | Uang muka 100% saat PO/SO Approved |
| Partial (DP x%) | Uang muka x% saat PO Approved, sisanya saat invoice approve |
| Net N / N Days | Pelunasan saat invoice approve, jatuh tempo = tanggal invoice + N hari |
| After Received | Pelunasan, jatuh tempo = tanggal invoice |
| Back to Back | Pelunasan tanpa tanggal, ditandai "menunggu klien" |

- Kalau satu vendor mengirim termin lebih dari sekali, yang dipakai adalah kiriman **terakhir**.
- Uang muka yang sudah dibayar otomatis memotong hutang saat invoice di-approve. Uang muka yang belum dibayar dibatalkan dan digabung ke pelunasan.
- Alur bayar: pemegang **APY** menyetujui, lalu PIC FIN-AP menandai **lunas** dengan memilih rekening, tanggal, dan nomor bukti. Approver dan pembayar boleh orang yang sama. Kalau dibayar sebagian, sisanya otomatis jadi jadwal baru.
- Rekening bank dikelola di menu **Bank**. Tiap rekening otomatis mendapat sub-akun COA `1-12xx`.
- Invoice bisa memuat **biaya mobilisasi / jasa lain**. Biaya ini langsung jadi beban 5-1200, dan totalnya tidak boleh melebihi penawaran vendor di RFQ.
- Perbaikan: `ALL` di kolom PIC sekarang juga memberi semua level approval (super admin).

### Dokumen invoice & uang muka (migration 006)

Checklist dokumen dipilih otomatis dari termin dan jenis PO/SO. Dokumen dari SMMS dicentang sendiri, sisanya diupload ke Google Drive lewat bridge Apps Script yang sama dengan SMMS.

**Gate A – sebelum uang muka disetujui (APY)**

| Dokumen | Status |
|---|---|
| PO / SO approved | Otomatis dari SMMS |
| Invoice DP / Proforma vendor | Wajib |
| Jaminan Uang Muka (penerbit, nomor, nilai, berlaku s/d) | Wajib (bisa dimatikan lewat setting `dp_bond_required`) |
| Faktur Pajak DP | Opsional |
| Kwitansi | Opsional |

Serah terima belum diminta di tahap uang muka.

**Gate B – sebelum invoice di-approve (AI)**

| Dokumen | Status |
|---|---|
| PO / SO approved | Otomatis dari SMMS |
| Surat jalan vendor | Otomatis dari SMMS (khusus PO) |
| Bukti terima site | Otomatis dari SMMS (khusus PO) |
| Invoice asli vendor | Wajib |
| Faktur Pajak | Wajib kalau ada PPN |
| Timesheet / Laporan pekerjaan | Wajib untuk SO |
| Kwitansi | Opsional |

- Dokumen wajib belum lengkap: invoice berstatus **HOLD**, dan uang muka tidak bisa disetujui. Begitu lengkap, status pindah sendiri ke MATCHED.
- Dokumen tidak bisa dihapus setelah invoice / uang muka disetujui.
- **Pembayaran ikut HOLD (migration 007):** jadwal pelunasan tidak bisa disetujui APY maupun ditandai lunas selama checklist Gate B invoice-nya belum lengkap (berlaku juga untuk invoice lama). Uang muka memakai Gate A.
- Bukti terima site dianggap ada kalau sudah ada Site Receiving **atau** Hand over di SMMS. Kalau belum, checklist menampilkan no. surat jalan dan site tujuan yang belum dikonfirmasi.
- File maksimal 10 MB. Bridge Drive (Apps Script "BIMA Drive Bridge") menyimpan dokumen di `SMMS-BIMA-Files/finance/yyyy-MM` **tanpa** link publik, jadi hanya akun yang diberi akses ke folder `finance` yang bisa membuka file.

### Kas & Kasbon (migration 008)

| Alur | Siapa | Jurnal otomatis |
|---|---|---|
| Kas site baru (plafon & batas per nota diisi manual) | FIN-AP | Sub-akun `1-11xx` dibuat otomatis |
| Isi kas site dari bank HO | Diajukan pemegang kas / FIN-AP → **APY** → FIN-AP tandai dibayar | Dr Kas Site / Cr Bank |
| Nota kas site + foto nota | Pemegang kas (FIN-PC) → **APC** | Dr Beban (+PPN Masukan) / Cr Kas Site |
| Pengeluaran langsung tanpa PO (listrik, sewa, BPJS, reimburse) | FIN-AP + nota/tagihan → **APY** → dibayar | Dr Beban (+PPN) / Cr Bank (+Hutang PPh 23) |
| Kasbon karyawan | Karyawan / pemegang kas / FIN-AP → **APY** → dibayar | Dr Uang Muka Karyawan `1-1700` / Cr Bank |
| Nota kasbon + foto nota | Penerima kasbon → **APC** | Dr Beban / Cr Uang Muka Karyawan |
| Tutup kasbon | FIN-AP | Sisa dikembalikan: Dr Bank / Cr 1-1700 · kekurangan dibayar: Dr 1-1700 / Cr Bank |

- Nota di atas **batas per nota** ditolak (harus lewat PO di SMMS). Nota juga ditolak kalau saldo kas tidak cukup.
- Isi kas tidak boleh membuat saldo melebihi **plafon**; form isi kas otomatis menyarankan nilai sampai plafon.
- Foto nota wajib (faktur pajak wajib kalau ada PPN). Tanpa dokumen, nota tidak bisa disetujui APC dan pengeluaran langsung HOLD.
- Pemegang kas (hanya FIN-PC) cuma melihat kas, nota, dan kasbon miliknya. FIN-AP, APC, dan APY melihat semuanya.
- Nota yang disetujui dan pengeluaran langsung yang dibayar masuk ke **komitmen & realisasi Budget vs Actual** proyeknya.

### Saldo awal, mutasi & rekonsiliasi bank (migration 009)

Ada di menu **Bank** (PIC FIN-AP). Semua diinput **FIN-AP** dan disetujui **PJ**; begitu disetujui, jurnalnya langsung POSTED.

| Jenis | Jurnal |
|---|---|
| Saldo awal (tanggal cut-off diisi manual, 1x per rekening) | Dr Bank / Cr 3-9000 Ekuitas Saldo Awal |
| Biaya admin bank | Dr 6-1400 / Cr Bank |
| Bunga / jasa giro | Dr Bank / Cr 4-9100 |
| Pajak bunga (PPh final dipotong bank) | Dr 6-1410 / Cr Bank |
| Transfer antar rekening sendiri | Dr Bank tujuan / Cr Bank asal |
| Uang masuk / keluar lain | Bank vs akun lawan yang dipilih (bukan akun kas/bank) |

- Mutasi bertanggal sebelum tanggal saldo awal ditolak. Mutasi yang sudah disetujui tidak bisa ditolak; koreksi dengan mutasi baru.
- **Rekonsiliasi**: FIN-AP isi saldo akhir rekening koran per tanggal, SmartFin menghitung selisih dengan saldo jurnal sampai tanggal itu. PJ menyetujui kalau selisih 0, atau kalau selisihnya sudah diberi penjelasan.

### Laporan keuangan (migration 010)

Satu menu **Laporan** (PIC `FIN-RPT`; `ALL` dan `FIN-ALL` otomatis termasuk) dengan tab, filter periode, filter proyek, dan tombol **Ekspor Excel** (.xlsx).

| Tab | Isi |
|---|---|
| Neraca Saldo | Saldo awal, debit, kredit, saldo akhir per akun + cek seimbang |
| Buku Besar | Mutasi satu akun dengan saldo berjalan; klik baris untuk melihat jurnalnya |
| Laba Rugi | Pendapatan, beban pokok proyek (5-xxxx), laba kotor, beban usaha (6-xxxx), laba bersih + ringkasan margin per proyek |
| Neraca | Aset, liabilitas, ekuitas per tanggal akhir, termasuk laba ditahan dan laba tahun berjalan + cek seimbang |
| Arus Kas | Saldo kas & bank awal, arus kas operasi / investasi / pendanaan / setoran saldo awal, saldo akhir + rincian |

- Jurnal VOID tidak pernah dihitung. Jurnal DRAFT ikut dihitung kalau "Termasuk jurnal DRAFT" dicentang; matikan untuk angka final (hanya POSTED).
- Klik akun di Neraca Saldo, Laba Rugi, atau Neraca untuk membuka Buku Besar akun itu.
- Filter proyek memakai proyek di baris jurnal; neraca per proyek wajar tidak seimbang.


### Piutang klien (migration 011)

Menu **Piutang Klien (AR)**: diinput PIC `FIN-AR`, disetujui Author `PJ` (atau `PJ-<kode proyek>`). Pemegang `FIN-JV` + PJ juga bisa membuka menu untuk approve. Begitu disetujui, jurnal langsung POSTED.

- **Dasar tagihan**: SMS berstatus APPROVED di SMMS operational (nilai diambil dari item SMS, tidak bisa diketik ulang) ditambah baris manual. Satu SMS hanya bisa masuk satu invoice; kalau invoice ditolak, SMS-nya dilepas dan bisa ditagih lagi.
- **Nomor invoice** otomatis `INV/BIMA/yyyy/mm/nnn` kalau dikosongkan.
- **Retensi** (% per invoice progress) dicatat di 1-1310 Piutang Retensi, lalu dicairkan lewat invoice jenis *Pencairan retensi* (tidak boleh melebihi sisa retensi proyek).
- **Pajak dipilih per invoice**, dasar = nilai yang jatuh tagih (DPP − retensi):

| Pilihan | Perlakuan |
|---|---|
| PPN WAPU | Dicatat untuk faktur, tidak ditagih dan tidak dijurnal (klien yang setor) |
| PPN dipungut BIMA | Ikut ditagih, Cr 2-1500 PPN Keluaran |
| PPh 23 | Dipotong klien saat bayar → Dr 1-1450 PPh 23 Dibayar Dimuka |
| PPh 4(2) | Dipotong klien saat bayar → Dr 6-1420 Beban PPh Final Jasa Konstruksi |

- **Jurnal invoice**: Dr 1-1300 Piutang Usaha + Dr 1-1310 Piutang Retensi / Cr 4-1000 Pendapatan Kontrak + Cr 2-1500 (PPN dipungut BIMA). Pencairan retensi: Dr 1-1300 / Cr 1-1310.
- **Penerimaan**: FIN-AR isi uang masuk ke rekening + PPh yang dipotong klien; PJ menyetujui → Dr Bank + Dr PPh / Cr 1-1300. Status invoice otomatis *Dibayar sebagian* / *Lunas*. Penerimaan tidak boleh melebihi sisa piutang (termasuk yang masih menunggu PJ).
- No. faktur pajak bisa dilengkapi setelah invoice disetujui (buka detail invoice).

### Payroll dari Fusion4 (migration 012)

Menu **Payroll** (PIC `FIN-PR`) membaca hasil *Proses Payroll Bulanan* Fusion4 (`payrollBulananTbl`) per bulan.

1. **Alokasi proyek**: default 100% ke proyek internal sesuai Divisi karyawan (901 Direksi, 902 Business Development, 903 HR, 904 Supply Chains, 905 Operation). Klik **Atur** untuk membagi karyawan ke beberapa proyek, misalnya 60% 014 + 40% 015. Total harus 100%.
2. **Buat jurnal**: satu jurnal per bulan (tanggal akhir bulan), diringkas per akun & proyek tanpa nama karyawan, masuk DRAFT, lalu diposting PJ di menu Jurnal.

| Baris | Akun |
|---|---|
| Karyawan di proyek klien | Dr 5-1300 Beban Tenaga Kerja Proyek (bruto + BPJS perusahaan) |
| Karyawan di proyek internal | Dr 6-1000 Beban Gaji Overhead (bruto) + Dr 6-1100 Beban BPJS Perusahaan |
| Uang kompensasi PKWT | Dr 6-1200 |
| Kewajiban | Cr 2-1300 Hutang BPJS (karyawan + perusahaan), Cr 2-1400 Hutang PPh 21, Cr 2-1200 Hutang Gaji (THP) |

3. Payroll diproses ulang di Fusion4 atau alokasi diubah → **Perbarui jurnal**. Jurnal DRAFT diganti; jurnal yang sudah POSTED dibuatkan jurnal penyesuaian sebesar selisihnya.
4. **Pembayaran** (setelah jurnal POSTED): FIN-PR klik **Bayar** untuk THP, BPJS, atau PPh 21; APY menyetujui → Dr Hutang Gaji/BPJS/PPh 21 / Cr Bank, langsung POSTED. Tidak boleh melebihi sisa hutang periode itu.

Jurnal ditolak kalau ada potongan gaji di luar BPJS & PPh 21 (belum didukung) atau ada divisi yang tidak punya proyek internal (atur alokasinya dulu).

### Pelepasan aset tetap (migration 013)

Di menu **Aset Tetap**, tombol **Lepas** di tiap aset (PIC `FIN-AST`) untuk aset yang **dijual** atau **dihapus** (rusak / hilang). Author `PJ` / `PJ-<proyek>` menyetujui di tabel *Pelepasan Aset*.

- Syarat: penyusutan sudah dijalankan sampai bulan sebelum tanggal pelepasan (kalau aset masih AKTIF), supaya nilai buku benar.
- Saat disetujui: nilai buku dihitung ulang, status aset jadi DIJUAL / DIHAPUS (tidak disusutkan lagi, tidak bisa diedit), jurnal langsung POSTED.

| Jenis | Jurnal |
|---|---|
| Dijual | Dr Bank (harga + PPN) + Dr 1-2900 Akumulasi / Cr 1-2100 Aset Tetap + Cr 2-1500 PPN Keluaran; selisih harga jual vs nilai buku → Cr 4-9200 Laba atau Dr 6-1500 Rugi Pelepasan Aset |
| Dihapus | Dr 1-2900 Akumulasi + Dr 6-1500 Rugi (nilai buku) / Cr 1-2100 Aset Tetap |

### Rekap pajak (migration 015)

Menu **Pajak** (PIC `FIN-TAX`) menampilkan rekap per masa (bulan) dari transaksi SmartFin, plus **Ekspor Excel** (sheet Ringkasan, PPN Keluaran, PPN Masukan, PPN WAPU, PPh 23 dipotong BIMA, PPh dipotong klien). Ini bahan lapor SPT, belum file impor Coretax / e-Faktur / e-Bupot.

| Bagian | Sumber | Masa |
|---|---|---|
| PPN Keluaran | Invoice klien PPN dipungut BIMA, penjualan aset ber-PPN | Tanggal faktur pajak |
| PPN Masukan | Invoice vendor, nota kas, pengeluaran langsung ber-PPN | Tanggal faktur pajak |
| PPN WAPU | Invoice klien yang PPN-nya dipungut klien (informasi) | Tanggal faktur pajak |
| PPh 21 | Payroll Fusion4 + setoran PPh 21 di menu Payroll | Bulan payroll |
| PPh 23 dipotong BIMA | Invoice vendor jasa, pengeluaran langsung | Tanggal invoice / bayar |
| PPh 23 / 4(2) dipotong klien | Penerimaan invoice klien | Tanggal terima |
| PPh final bunga | Mutasi bank pajak bunga | Tanggal mutasi |

- Kalau tanggal faktur belum diisi, masa sementara memakai tanggal transaksi dan barisnya ditandai **belum diisi**. Klik **Isi faktur** untuk melengkapi nomor & tanggal faktur (FIN-TAX untuk semua dokumen; FIN-AP / FIN-AR / FIN-AST untuk dokumen modulnya sendiri).
- Tabel **Saldo Akun Pajak** menunjukkan saldo PPN Keluaran, PPN Masukan, Hutang PPh 21, Hutang PPh 23, dan PPh 23 Dibayar Dimuka per akhir masa (jurnal POSTED) untuk cek setoran.
