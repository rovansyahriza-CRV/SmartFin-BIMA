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
| `sql/migrations/003_fixed_asset.sql` | Register aset tetap per unit (otomatis dari SMMS) + penyusutan bulanan | Draft, sudah diuji (rollback), belum dijalankan |

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
