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
| | `FIN-AP` | Hutang vendor & invoice |
| | `FIN-JV` | Jurnal |
| | `FIN-BVA` | Budget vs Actual / RAB |
| | `FIN-AST` | Aset tetap |
| | `FIN-PC` | Kas & Kasbon: pemegang kas site input nota, ajukan isi kas / kasbon (migration 008) |
| | `FIN-ALL` | Semua menu SmartFin |
| PIC / Author | `ALL` | **Super admin**: semua menu + semua approval (AI, PJ, AB, APY, APC). Saat trial hanya 1 admin |
| Author (approval) | `AI` / `AI-014` | Approve invoice, untuk semua proyek atau hanya proyek 014 |
| | `PJ` | Posting jurnal, approve saldo awal / mutasi bank / rekonsiliasi (migration 009) |
| | `AB` | Approve budget/RAB |
| | `APY` | Approve pembayaran, isi kas site, pengeluaran langsung, kasbon |
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
- Rekening bank dikelola di halaman Pembayaran. Tiap rekening otomatis mendapat sub-akun COA `1-12xx`.
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

Ada di halaman **Pembayaran**, di bawah Rekening Bank. Semua diinput **FIN-AP** dan disetujui **PJ**; begitu disetujui, jurnalnya langsung POSTED.

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

