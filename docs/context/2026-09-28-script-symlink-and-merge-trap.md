# Dua salinan script, lalu symlink, lalu file terpotong

Tanggal: 2026-09-28 · Repo: `survey-agents` (root) · Commit: `2b5c5b8`, `5a9c498`

Ringkas: script management server pernah ada di dua tempat yang bisa berbeda
tanpa terdeteksi. Setelah diperbaiki jadi symlink, muncul jebakan baru di
langkah merge yang justru merusak file itu.

---

## Insiden 1 — Dua salinan, melenceng dua arah

`surveyku-server.sh` ada di dua tempat:

- `Survey/surveyku-server.sh` — di dalam repo, di-commit
- `/home/whyrtch/surveyku-server.sh` — jalur operasional, yang dipakai orang

Tidak ada mekanisme yang menjaga keduanya sama. PR #1–#3 hanya mengubah
yang di repo; jalur operasional tetap versi 2026-09-24.

Arah divergensinya dua arah, bukan satu:

| | runtime punya | repo punya |
|---|---|---|
| | `ADMIN_NOTIFY_EMAILS`, `ADMIN_URL`, `MIN_SURVEYORS_TO_COMPLETE` | deteksi image drift, mount Firebase, credential MinIO |

Dampaknya nyata. `apply_backend_env` versi repo me-recreate container
**tanpa** ketiga env admin itu, dan `ensure_backend_env` versi lama tidak
mengembalikannya karena SMTP/PayPal sudah terkonfigurasi. Container produksi
kehilangan ketiganya.

Blast radius ternyata kecil: backend punya default sendiri
(`internal/config/config.go`), dan dua dari tiga nilainya sama dengan
default script. Hanya `ADMIN_URL` yang berbeda — default backend
`http://localhost:3000/...` tidak bisa dibuka penerima email.

Pelajaran: saat menambah baris `-e` di `apply_backend_env`, cek dulu apakah
versi runtime punya env yang belum ada di versi repo. Dua arah divergensi
sangat mudah terlewat karena yang terlihat hanya satu.

---

## Insiden 2 — Dua versi AGENTS.md

`AGENTS.md` yang dipakai sebagai instruksi sesi memuat catatan bahwa
`/home/whyrtch/surveyku-server.sh` adalah symlink ke file di repo. Catatan
itu **tidak pernah ada** di file repo — dicek dengan
`git show HEAD:AGENTS.md`.

Artinya ada versi AGENTS.md yang tidak sinkron dengan file di disk. Sesi
berikutnya yang membaca file disk akan kehilangan instruksi penting.

Sekarang catatan itu ada di `AGENTS.md` maupun `README.md`, dan sekarang
sesuai dengan kenyataan: jalurnya memang symlink.

---

## Perbaikan — sumber tunggal lewat symlink

```
/home/whyrtch/surveyku-server.sh -> /home/whyrtch/Project/Survey/surveyku-server.sh
```

Berbeda mustahil terjadi.

Symlink aman dipakai di sini karena:

- `$0` hanya dipakai di pesan usage
- tidak ada `cd` relatif — semuanya path absolut (`$WEB_DIR`)
- tidak ada systemd unit yang mereferensikan script
- kalau repo dipindah, semuanya sudah rusak, jadi symlink tidak menambah
  fragilitas baru

`verify_script_source()` memperingatkan kalau symlink diganti salinan,
dipanggil dari `do_start` dan `do_status`.

Sengaja **hanya peringatan**, tidak memperbaiki sendiri. Bash membaca file
script bertahap per byte offset; menulis ulang file yang sedang dieksekusi
bisa membuat shell membaca offset lama dari file baru.

---

## Insiden 3 — Merge memotong file jadi 0 byte

`gh pr merge --squash --delete-branch` menghasilkan:

```
/home/whyrtch/surveyku-server.sh: Text file busy
```

Setelah itu `surveyku-server.sh` di working tree **0 byte** — dan karena
path operasional adalah symlink ke file itu, script management server ikut
mati.

Penyebab yang paling mungkin: squash-merge membuat branch lokal diverge dari
`main`, lalu `--delete-branch` menjalankan operasi checkout dalam kondisi
itu.

Sudah diuji di clone terisolasi bahwa `git checkout` antar branch dengan
file termodifikasi **tidak** memotong file — jadi bukan routine git biasa,
melebihi itu. Akar masalahnya belum dipastikan sepenuhnya; yang pasti
triggernya adalah kombinasi squash-merge + branch deletion otomatis.

Pemulihan:

```bash
git restore surveyku-server.sh   # isi baik ada di HEAD / origin/main
git branch -d <branch>
git checkout main && git pull --ff-only origin main
```

---

## Trade-off yang diterima

Symlink menutup risiko *divergensi*, tapi membuka risiko *kor*: file target
sekarang hidup di dalam git working tree, jadi operasi git yang menyentuh
file itu ikut menggerakkan script operasional.

Sesi berikutnya **wajib** menghindari `--delete-branch`. Prosedurnya ada di
`AGENTS.md` (durable, ter-commit) dan di `.kiro/github-pr.md` (lokal saja,
karena `.kiro/` gitignored di `surveyku-backend`).

Alternatif yang belum diambil: simpan script di luar repo dan guard
berbasis perbandingan isi, bukan tipe symlink. Itu lebih tahan terhadap
operasi git, tapi kembali ke deteksi konten.

---

## Verifikasi setelah semua perbaikan

- `status` / `start` idempoten lewat symlink, container ID tidak berubah
- Image drift dipaksa rebuild: container `295fbc0c` → `6d611368`, log
  `recreate container...`, mount Firebase terpasang ulang
- Start kedua: 0 baris recreate
- Guard diam saat symlink sehat; memperingatkan saat disimulasikan diganti
  salinan, lalu dipulihkan
- Health backend/minio/web 200
- `ADMIN_URL` benar, `FIREBASE_BUCKET` kosong
- E2E baca file: HTTP 200, 19251 bytes, `Microsoft Excel 2007+`
- Ketiga repo di `main`, working tree bersih
