# AGENTS.md — SurveyKu

> **WAJIB BACA PERTAMA: `README.md` di folder ini.**
> README.md adalah satu-satunya referensi utama (arsitektur, business flow,
> API contract, data model, rules, deployment, troubleshooting).
> Jangan mengubah kode apa pun sebelum membaca README.md sampai selesai.

---

## 1. Apa ini?

**SurveyKu** = platform pengumpulan data survei end-to-end.
3 peran: **client** (memesan survei), **surveyor** (mengerjakan survei via
mobile, dapat reward), **admin** (back-office: verifikasi, audit, payout).

## 2. Struktur (4 folder)

| Folder | Isi | Stack |
|---|---|---|
| `surveyku-backend/` | REST API | Go (Echo, DDD + Clean Architecture) |
| `surveyku-web/` | Web client/admin | Next.js App Router + TypeScript |
| `surveyor-app/` | App mobile surveyor | React Native / Expo + Firebase |
| `surveyku-minio/` | **Data mentah MinIO** | ⚠️ BUKAN kode — jangan diubah/di-commit |

## 3. Alur kerja AI (ikuti urutan ini)

1. **Baca `README.md`** (wajib, sebelum apa pun).
2. Tentukan folder yang relevan dengan tugas:
   - Backend → `surveyku-backend/` (baca `README.md`-nya juga)
   - Web → `surveyku-web/` (baca `AGENTS.md`-nya — Next.js versi ini beda)
   - Mobile → `surveyor-app/` (baca `AGENTS.md`-nya — Expo SDK 56 beda)
3. Ikuti pola kode yang SUDAH ADA di folder tersebut. Jangan buat pola baru.
4. Verifikasi sebelum selesai: build + test + lint (lihat README.md bagian
   "Verifikasi Sebelum Commit").

## 4. Aturan penting (jangan dilanggar)

- **Jangan sentuh `surveyku-minio/`** — itu data runtime MinIO, bukan kode.
- **Jangan edit migration SQL yang sudah jalan** — buat migration baru.
- **Jangan panggil repo langsung dari handler** — lewat service layer.
- **Jangan commit/push/merge tanpa persetujuan eksplisit user.**
- **Jangan taruh secret di kode/commit.**
- **Jangan "perbaiki" konstanta `StatusApprovedPaid`** (nilai string
  `"APPROVED_UNPAID"` itu disengaja).
- **Jangan tambah upload UI hasil** — file hasil selalu di-generate backend.

## 5. Dokumen kunci (baca sesuai kebutuhan)

- `README.md` — referensi utama (WAJIB)
- `surveyku-backend/docs/business-flow/` — flow bisnis backend
- `surveyku-web/docs/business-flow/` — flow bisnis web
- `surveyor-app/MOBILE_API_FLOW.md` — kontrak API mobile ↔ backend
- `surveyor-app/ARCHITECTURE.md` — arsitektur mobile
- `docs/context/` di tiap subproject — konteks keputusan & insiden

## 6. Deployment

### Komponen & port

| Komponen | Jenis | Nama | Port |
|---|---|---|---|
| PostgreSQL | Container | `immich-postgres` | 5432 (internal) |
| Redis | Container | `surveyku-redis` | 6379 |
| MinIO | Container | `surveyku-minio` | 9000 (API), 9001 (console) |
| Backend | Container | `surveyku-backend` | 8080 |
| Web (Next.js) | Proses bare (`setsid`) | — | 3000 |
| Tunnel | Cloudflared (systemd user) | — | `survey.whyrtch.online` (backend), `admin-survey.whyrtch.online` (web) |

### Script utama

```bash
/home/whyrtch/surveyku-server.sh {start|stop|restart|status|fix-loops|setup-smtp|setup-paypal}
```

- `start` — nyalakan semua service (PostgreSQL → Redis → MinIO → Backend → Web → Tunnel) + verifikasi endpoint
- `stop` — matikan Web, Backend, MinIO, Redis (PostgreSQL & Tunnel dibiarkan jalan)
- `restart` — stop lalu start
- `status` — cek semua komponen + deteksi NoOp storage + restart loop
- `setup-smtp` / `setup-paypal` — isi konfigurasi lalu recreate container backend

### Deploy perubahan backend (Go)

```bash
cd /home/whyrtch/Project/Survey/surveyku-backend
# 1. Pastikan kode di commit final (bukan state branch fitur)
# 2. Build image
docker build -t surveyku-backend:latest .
# 3. Recreate container
/home/whyrtch/surveyku-server.sh restart
# 4. Verifikasi
/home/whyrtch/surveyku-server.sh status
curl http://localhost:8080/api/v1/health
```

> ⚠️ **PELAJARAN INSIDEN (2026-09-17):** selalu rebuild image dari **commit
> final** sebelum deploy. Image dari state branch fitur menyebabkan order
> selesai tanpa file hasil. Detail: `surveyku-backend/docs/context/2026-09-17-order-complete-with-result.md`.

### Deploy perubahan web (Next.js)

```bash
cd /home/whyrtch/Project/Survey/surveyku-web
# Web jalan sebagai proses bare (dev mode), bukan container
/home/whyrtch/surveyku-server.sh restart   # atau start_web via script
tail -f web.log                            # cek log
```

### Env files (rahasia, jangan di-commit)

| File | Isi |
|---|---|
| `/home/whyrtch/Project/.smtp.env` | SMTP_HOST, SMTP_USER, SMTP_PASSWORD, VERIFY_URL |
| `/home/whyrtch/Project/.backend.env` | PAYPAL_CLIENT_ID, PAYPAL_SECRET, MINIO_* |
| `/home/whyrtch/Project/.web.env` | PAYPAL_CLIENT_ID (web), dll |

### Troubleshooting deploy

| Gejala | Solusi |
|---|---|
| Upload file gagal `INTERNAL_ERROR` | Backend pakai NoOp storage → `./surveyku-server.sh restart` |
| Order COMPLETED tanpa file hasil | Admin klik "Generate Hasil Akhir" (self-heal) |
| Endpoint baru tidak ada | Image stale → rebuild dari commit final + restart |
| Cloudflared restart loop | `sudo ./surveyku-server.sh fix-loops` |

## 7. Jika bingung

Baca ulang `README.md`. Semua jawaban ada di sana (glossary, arsitektur,
flow, API, data model, deployment, troubleshooting, pitfalls).