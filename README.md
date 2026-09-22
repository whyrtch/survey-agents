# SurveyKu — Survey Data Collection Platform

SurveyKu adalah platform pengumpulan data survei end-to-end. **Client** memesan
survei dan menerima data responden yang sudah tervalidasi, **surveyor**
mengerjakan tugas survei lewat aplikasi mobile dan mendapat reward, **admin**
menjalankan operasional back-office (verifikasi pembayaran, audit jawaban,
payout, dll).

> **Tujuan dokumen ini:** menjadi satu-satunya referensi yang cukup untuk
> memahami arsitektur, flow, rules, dan konvensi proyek. Baca dokumen ini
> sebelum mengubah kode apa pun.

---

## 📁 Struktur Direktori

```
/home/whyrtch/Project/Survey/
├── README.md            # Dokumen ini
├── surveyku-backend/    # REST API (Go, DDD + Clean Architecture)
├── surveyku-web/        # Frontend client/admin (Next.js App Router + TypeScript)
├── surveyor-app/        # Aplikasi mobile surveyor (React Native / Expo + Firebase)
└── surveyku-minio/      # Data MinIO (bucket surveyku: ktp, questionnaire, redemption_proof, result)
```

**PENTING — jangan tertukar:**
- Database aktif memakai container `immich-postgres` (dipakai bersama aplikasi
  Immich), mount `/DATA/AppData/immich/pgdata`.
- MinIO aktif me-mount `/home/whyrtch/Project/Survey/surveyku-minio` (container
  `surveyku-minio`, port 9000/9001).

---

## 📖 Glossary (definisi istilah)

| Istilah | Definisi |
|---|---|
| **Order** | Pesanan survei dari client. Punya target responden, kriteria demografi, dan status. |
| **Survey** | Form survei milik sebuah order (relasi 1 order → 1 survey). Berisi `form_schema` (JSONB), `quota`, `quota_filled`. |
| **Task** | Satu pengerjaan survei oleh satu surveyor. Berisi jawaban (JSONB) dan status. |
| **Quota** | Jumlah responden target. `quota_filled` = jumlah task yang sudah terkumpul. |
| **Approved task** | Task berstatus `APPROVED_UNPAID` atau `COMPLETED_PAID` — jawabannya dipakai untuk generate file hasil. |
| **Result file** | File `.xlsx` hasil survei, di-generate otomatis backend dari jawaban approved, di-upload ke MinIO. |
| **Client** | Pengguna yang memesan survei (role `client`). |
| **Surveyor** | Pengguna yang mengerjakan survei (role `surveyor`). |
| **Admin** | Pengguna back-office (role `admin`). |

---

## 🏗️ Arsitektur

### Backend (`surveyku-backend/`) — Go, DDD + Clean Architecture

```
surveyku-backend/
├── cmd/
│   ├── server/          # Entry point aplikasi (main.go)
│   ├── seed/            # Database seeder
│   └── hashgen/         # Utility: generator password hash
├── internal/
│   ├── domain/          # Entitas bisnis + interface (TIDAK boleh depend ke infra)
│   │   ├── order/       #   Order entity + status transitions
│   │   ├── task/        #   Task entity + status transitions
│   │   └── survey/      #   Survey entity + ErrNotFound sentinel
│   ├── application/     # Use case & business logic (service layer)
│   │   ├── admin_service.go    # Admin + client complete order, generate xlsx
│   │   ├── order_service.go    # Order CRUD, progress, upload-result
│   │   ├── task_service.go     # Task assignment, submit, audit
│   │   ├── auth_service.go     # Register, login, OTP, JWT
│   │   ├── finance_service.go  # Payout, redemptions
│   │   └── settings_service.go # App settings (min_withdrawal)
│   ├── infrastructure/  # Implementasi eksternal
│   │   ├── persistence/postgres/  # Repository (pgx)
│   │   ├── auth/                  # JWT manager
│   │   ├── storage/               # MinIO / NoOp storage
│   │   └── ...                    # Redis, SMTP, PayPal
│   └── interfaces/      # HTTP layer
│       ├── http/handler/  # Echo handlers (admin, order, task, auth, ...)
│       ├── http/dto/      # Request/response DTO + Response envelope
│       ├── http/middleware/ # Auth, role, CORS
│       └── http/router/   # Route registration
├── migrations/          # SQL migration (001_init ... 022_income_range)
├── docs/                # Swagger + business-flow + context documentation
└── Dockerfile           # Multi-stage build (golang:1.23 → alpine)
```

**Lapisan & aturan dependensi (Clean Architecture):**
- `domain` ← `application` ← `infrastructure` + `interfaces`
- `domain` TIDAK boleh mengimpor `infrastructure` atau `interfaces`.
- `application` mendefinisikan interface repository; `infrastructure` yang
  mengimplementasikannya.
- Handler hanya memanggil service (application layer), tidak langsung ke repo.

**Dependensi utama:** Echo v4 (web framework), pgx v5 (PostgreSQL), Redis
(cache & OTP), MinIO (object storage), JWT (auth), Swaggo (Swagger).

### Frontend (`surveyku-web/`) — Next.js App Router + TypeScript

```
surveyku-web/
├── src/
│   ├── app/
│   │   ├── (auth)/          # Login & register
│   │   ├── admin/           # Back-office admin (dark/amber theme)
│   │   │   └── orders/[id]/ #   AdminOrderDetail.tsx (complete, export, generate)
│   │   ├── dashboard/       # Portal client (light/teal theme)
│   │   ├── my-orders/       # Daftar & detail order client
│   │   │   └── [id]/        #   OrderDetail.tsx (progress, complete, download)
│   │   ├── order/           # Wizard pembuatan order (7 langkah)
│   │   └── profile/
│   ├── components/
│   │   ├── layout/          # AdminLayout, DashboardLayout, Footer
│   │   ├── order/           # Komponen wizard order
│   │   └── ui/              # Button, Icon, KebabMenu, TableSkeleton
│   ├── hooks/               # useAuth, useOrders, useAdmin, useUser
│   ├── services/            # admin.service, order.service, auth.service, ...
│   ├── stores/              # Zustand (auth store)
│   └── lib/                 # Axios client (auto token refresh), helpers
├── e2e/                     # Playwright end-to-end tests
└── restart-dev.sh           # Reset cache .next + restart dev server
```

**Dependensi utama:** Next.js (App Router), React 19, TanStack Query + Axios
(token refresh otomatis), Zustand (auth store), react-hook-form + zod,
Tailwind CSS, Material Symbols, sonner (notifikasi).

### Mobile Surveyor (`surveyor-app/`) — React Native / Expo + Firebase

Aplikasi mobile untuk **surveyor** (mengerjakan survei & klaim reward).
Dua sumber data: **Firebase** (Auth, Firestore, Storage) untuk profil &
notifikasi realtime, dan **SurveyKu API** (`EXPO_PUBLIC_API_URL`) untuk
auth OTP, daftar survei, task, dan wallet.

```
surveyor-app/
├── src/
│   ├── app/                 # Expo Router (file-based routing)
│   │   ├── (auth)/          #   welcome, login (phone), otp
│   │   ├── (onboarding)/    #   6-step profil (personal→location→demographic→economic→review→success)
│   │   ├── (app)/(tabs)/    #   home, surveys, rewards, notifications, profile
│   │   └── (survey)/[id]/   #   Survey engine: intro→question→review→complete
│   ├── features/            # home, surveys, survey-engine, rewards, submissions,
│   │                        #   notifications, onboarding, profile, shared
│   ├── components/          # ui/, layout/, feedback/, animation/
│   ├── lib/                 # query (TanStack), firestore (converters, realtime)
│   ├── store/               # Zustand: auth, onboarding, app, notification, submission, session
│   ├── repositories/        # Typed Firestore access
│   ├── services/            # Feature services (mock → real Firebase switch)
│   ├── theme/               # Design tokens (palette, colorTokens light/dark, spacing, typography)
│   └── utils/               # format (Rupiah), phone, profile completion, error, cn
├── firestore.rules          # Firestore security rules
├── storage.rules            # Firebase Storage rules
├── firestore.indexes.json   # Composite indexes
├── app.json / eas.json      # Expo + EAS build config
└── docs/                    # Flow UI, master data, API flow
```

**Dependensi utama:** Expo SDK 56, Expo Router, React Native 0.85, TypeScript,
Firebase v10 (Auth + Firestore + Storage), Zustand v5, TanStack Query v5,
NativeWind v5 + Tailwind v4, Reanimated 4, react-hook-form + zod, SecureStore
(draft persistence), Vitest (unit test).

**Mock → Real Firebase:** semua service memakai
`const USE_MOCK = !process.env['EXPO_PUBLIC_FIREBASE_PROJECT_ID']`.
Tanpa Firebase terkonfigurasi → mock data (dev tanpa backend). Set
`EXPO_PUBLIC_FIREBASE_PROJECT_ID` di `.env.local` → real Firestore.

**Route protection:** `(auth)` redirect ke app jika sudah login; `(app)`
redirect ke welcome jika belum; `(onboarding)` redirect ke home jika selesai;
`(survey)` full-screen tanpa tab bar.

---

## 🔄 Business Flow

### Siklus Order

```
PENDING_PAYMENT → PAID_PREPARATION → ACTIVE_COLLECTION → COMPLETED
```

Transisi hanya bisa maju (domain-enforced di `internal/domain/order/entity.go`):

| Dari | Ke | Pemicu |
|---|---|---|
| `PENDING_PAYMENT` | `PAID_PREPARATION` | Pembayaran PayPal berhasil (otomatis) |
| `PAID_PREPARATION` | `ACTIVE_COLLECTION` | Admin membuat survei / order diproses |
| `ACTIVE_COLLECTION` | `COMPLETED` | Client atau admin complete order |

### Siklus Task (Surveyor)

```
ON_PROGRESS → UNDER_REVIEW → APPROVED_UNPAID → COMPLETED_PAID
                    │
                    ├──→ REJECTED_FRAUD
                    └──→ SCREENED_OUT
```

| Status | Arti |
|---|---|
| `ON_PROGRESS` | Surveyor mulai mengerjakan |
| `UNDER_REVIEW` | Jawaban disubmit, menunggu audit admin |
| `APPROVED_UNPAID` | Disetujui, menunggu pembayaran reward |
| `COMPLETED_PAID` | Reward sudah dibayar |
| `REJECTED_FRAUD` | Ditolak (fraud) — terminal |
| `SCREENED_OUT` | Keluar karena aturan screening (`end_survey`) — terminal |

> **PERHATIAN:** konstanta `StatusApprovedPaid` bernilai string
> `"APPROVED_UNPAID"` (nama konstanta ≠ nilai string). Jangan "perbaiki"
> nilainya — itu disengaja.

### Siklus Surveyor di Mobile App

Detail lengkap: `surveyor-app/MOBILE_API_FLOW.md`.

1. **Auth** — `POST /auth/register/surveyor` (atau `/auth/login/surveyor`)
   → OTP dikirim → `POST /auth/verify-otp` → `{user, access_token, refresh_token}`.
   Dev bypass: OTP `123456` selalu valid di non-production.
2. **Onboarding** — `PUT /users/me/profile` (6 langkah). Profil ≥ 80% membuka
   akses survei; 100% → badge terverifikasi.
3. **Browse** — `GET /surveys/available` → `GET /surveys/{id}/detail`.
4. **Kerjakan** — `POST /tasks/{survey_id}/start` (claim slot) → jawab
   pertanyaan → `POST /tasks/{task_id}/answers/page` (per halaman, idempoten)
   → `POST /tasks/{task_id}/submit` (final).
5. **Screening** — jika jawaban memicu logic `end_survey`, server balas
   `status: "SCREENED_OUT"` (terminal, tanpa reward). Server mengevaluasi ulang
   seluruh answers saat final submit.
6. **Reward** — task `UNDER_REVIEW` → admin audit → `APPROVED_UNPAID` →
   payout → `COMPLETED_PAID`. Wallet: `GET /wallet`, `POST /wallet/redeem`.

**Aturan penting (mobile):**
- `POST /tasks/{id}/answers/page` WAJIB dipanggil setiap transisi antar
  halaman; halaman yang sudah disubmit boleh dikirim ulang (idempoten).
- Validasi server per-page: semua question `required` di halaman tsb harus
  terisi. Server TIDAK memahami logic `show` — question tersembunyi yang
  `required:true` akan gagal 422 → app harus menampilkan pesan ramah.
- Limit payload: ≤ 500 key, scalar ≤ 16 KiB, array ≤ 256 elemen, kedalaman ≤ 3,
  body ≤ 1 MiB, max 100 halaman.
- Error yang mungkin: `409 TASK_CONFLICT/TASK_INVALID_TRANSITION`,
  `422 INVALID_PAGE/UNKNOWN_QUESTION/REQUIRED_QUESTION_MISSING/ANSWERS_TOO_LARGE`,
  `403 FORBIDDEN`.

### Order Creation (Client)

Wizard 7 langkah di `/order` (detail: `surveyku-web/docs/business-flow/order-creation.md`):

1. Pilih paket → 2. Konfigurasi demografi (usia, gender, domisili, pekerjaan)
→ 3. Upload kuesioner → 4. Jumlah responden → 5. Ringkasan → 6. Pembayaran
(PayPal) → 7. Selesai.

- `/order` **wajib login** (client). Guest checkout sudah dihapus.
- Kuesioner di-upload ke `/api/v1/files/upload` (category `questionnaire`)
  SEBELUM order dibuat.
- Demografi "Semua Pekerjaan" dikirim sebagai `"all"` — backend
  memperlakukan `"all"` / `"semua"` / `"semua pekerjaan"` sebagai "any".

### Order Completion (tanpa upload) — FLOW KUNCI

Detail lengkap: `surveyku-backend/docs/business-flow/order-completion-flow.md`.

**Alur client:**
1. Client buka `/my-orders/[id]` → lihat progress ring (collected vs target).
2. Kuota penuh → tombol **"Selesaikan Survey"** aktif.
3. Klik → `POST /orders/{id}/complete` → backend validasi kepemilikan (403)
   + kuota (409 `ORDER_QUOTA_NOT_MET`) → generate xlsx → status COMPLETED.
4. Client lihat **Download Hasil** dan unduh `result_file_url`.

**Alur admin:**
1. Admin buka `/admin/orders/[id]` → **"Selesaikan Order"** (tanpa constraint
   kuota) → `POST /admin/orders/{id}/complete`.
2. Order COMPLETED → **"Lihat Hasil Akhir"** (link download).
3. Jika file hilang → **"Generate Hasil Akhir"** → panggil ulang endpoint
   complete → self-heal: file di-generate ulang dari DB.

**Aturan penting:**
- File `.xlsx` di-generate dari jawaban task **approved** (`APPROVED_UNPAID` +
  `COMPLETED_PAID`), dipaginasi (per 1000) agar tidak terpotong.
- File dibuat **SEBELUM** transisi status di-commit (gagal generate → order
  tetap ACTIVE_COLLECTION, bisa retry).
- **TIDAK ADA upload manual** — xlsx hasil generate adalah dokumen hasil
  akhir. Endpoint `upload-result` lama masih ada untuk backward compatibility
  tapi tidak dipakai frontend.
- Update status memakai `UpdateStatusIfCurrent` (column-narrow) agar tidak
  menimpa perubahan konkuren.

---

## 🔌 API Contract

### Response Envelope (SEMUA endpoint)

```json
{
  "success": true,
  "data": { ... },
  "meta": { "page": 1, "per_page": 10, "total": 100 },
  "error": "ERROR_CODE",
  "message": "human readable message",
  "details": { ... }
}
```

- Sukses: `success: true` + `data` (dan `meta` untuk list).
- Error: `success: false` + `error` (kode) + `message`.
- Frontend membaca error via `error.response?.data?.message`.

### Endpoint Kunci

| Method | Path | Role | Fungsi |
|---|---|---|---|
| POST | `/orders/{id}/complete` | client | Complete order sendiri (kuota enforced) |
| POST | `/admin/orders/{id}/complete` | admin | Complete order (tanpa constraint kuota) |
| GET | `/orders/{id}/progress` | client | Progress collected vs target |
| GET | `/admin/orders/{id}/export-data` | admin | Download xlsx mentah (blob) |
| POST | `/orders` | client | Buat order |
| POST | `/orders/{id}/upload-receipt` | client | Upload bukti pembayaran |
| POST | `/admin/orders/{id}/verify-payment` | admin | Verifikasi pembayaran |
| POST | `/admin/audit/{task_id}` | admin | Audit jawaban (`approve`/`reject`) |
| POST | `/tasks/{survey_id}/start` | surveyor | Mulai task |
| POST | `/tasks/{task_id}/submit` | surveyor | Submit jawaban |
| GET | `/wallet` | surveyor | Saldo poin |
| POST | `/wallet/redeem` | surveyor | Penarikan poin |

### Endpoint Mobile (dipakai `surveyor-app`)

| Method | Path | Fungsi |
|---|---|---|
| POST | `/auth/register/surveyor` | Daftar surveyor (kirim OTP) |
| POST | `/auth/login/surveyor` | Login surveyor (kirim OTP) |
| POST | `/auth/verify-otp` | Verifikasi OTP → `{user, access_token, refresh_token}` |
| POST | `/auth/refresh` | Refresh token |
| PUT | `/users/me/profile` | Update profil (onboarding 6 langkah) |
| GET | `/users/me/profile` | Ambil profil |
| GET | `/users/me/summary` | Statistik: total_points, total_surveys, total_approved, total_pending |
| GET | `/users/me/activities` | Activity feed (filter `status=survey_completed` / `reward_paid`) |
| GET | `/surveys/available` | Daftar survei tersedia (paginasi) |
| GET | `/surveys/{id}/detail` | Detail survei + `task_id`/`task_status` |
| GET | `/surveys/history` | Riwayat survei surveyor |
| POST | `/tasks/{survey_id}/start` | Claim slot → `{task_id, form_schema}` |
| POST | `/tasks/{task_id}/answers/page` | Submit jawaban per halaman (idempoten) |
| POST | `/tasks/{task_id}/submit` | Submit final → `under_review` / `SCREENED_OUT` |
| GET | `/tasks` | Task in-progress |
| GET | `/tasks/my?status=...` | Riwayat task (filter status) |
| GET | `/tasks/{task_id}/detail` | Detail task (reward, reject_reason, paid_at) |
| GET | `/wallet` | Saldo wallet |
| POST | `/wallet/redeem` | Penarikan poin |

### Error Semantics

| Kode | HTTP | Arti |
|---|---|---|
| `NOT_FOUND` | 404 | Resource tidak ada |
| `AUTH_FORBIDDEN` | 403 | Bukan pemilik / role tidak sesuai |
| `ORDER_INVALID_TRANSITION` | 409 | Order tidak dalam status yang benar |
| `ORDER_QUOTA_NOT_MET` | 409 | Kuota survei belum penuh (jalur client) |
| `INTERNAL_ERROR` | 500 | Kegagalan repo/storage |

---

## 🗄️ Data Model

Database aktif: container `immich-postgres`, DB `surveyku`, user `hermes`.
Schema: `surveyku-backend/migrations/`.

### Tabel Utama

| Tabel | Kolom kunci | Keterangan |
|---|---|---|
| `users` | `id`, `email`, `phone`, `role`, `full_name`, `is_verified` | Client, surveyor, admin |
| `surveyor_profiles` | `user_id`, demografi, `ktp_status`, poin | Profil surveyor |
| `orders` | `id`, `client_id`, `package_type`, `target_respondents`, `demographic_criteria` (JSONB), `questionnaire_file_url`, `result_file_url`, `status`, `total_price` | Order survei |
| `surveys` | `id`, `order_id`, `form_schema` (JSONB), `quota`, `quota_filled`, `status` | Form survei (1:1 dengan order) |
| `tasks` | `id`, `survey_id`, `surveyor_id`, `status`, `answers` (JSONB), `paid_at` | Pengerjaan survei |
| `transactions` | — | Ledger payout reward |
| `point_transactions` | — | Riwayat poin |
| `redemptions` | `payment_proof_url` | Penarikan poin |
| `otp_codes` | — | OTP verifikasi |
| `settings` | `min_withdrawal` | Pengaturan aplikasi |
| `provinces`, `cities` | — | Master lokasi Indonesia |

### Relasi

```
users (client) 1───n orders 1───1 surveys 1───n tasks n───1 users (surveyor)
```

---

## 📏 Rules & Ketentuan

### Status Transition (domain-enforced)

- Order & Task hanya berpindah status sesuai `validTransitions` di
  `internal/domain/order/entity.go` dan `internal/domain/task/entity.go`.
- Jangan menambah transisi di luar map tersebut tanpa alasan bisnis.

### Keamanan

- **IDOR guard** — client hanya bisa mengakses/completing order miliknya
  (403 `AUTH_FORBIDDEN`). Selalu cek kepemilikan di service layer.
- **Server-side enforcement** — semua gate di frontend bersifat kosmetik;
  backend WAJIB memvalidasi (ownership, quota, role).
- JWT access token (15 menit) + refresh token (7 hari), auto-refresh di
  frontend.
- Jangan pernah menaruh secret di kode atau commit (cek `.gitignore`).

### Konvensi Kode

- **Go:** ikuti pola yang ada (handler → service → repo). Jangan buat
  abstraksi baru tanpa kebutuhan. Error dibungkus dengan `fmt.Errorf("...: %w")`.
- **TypeScript (web):** ikuti pola yang ada (hooks + services). Reuse komponen
  UI (`components/ui/`). Jangan duplikasi logika bisnis.
- **TypeScript (mobile):** ikuti pola feature (services → hooks → screens).
  Screens TIDAK menyentuh store/service langsung — lewat orchestration hooks.
  Reuse komponen `components/ui/` dan design tokens `theme/tokens.ts`.
- **Database:** perubahan schema lewat migration SQL baru (jangan edit
  migration lama yang sudah jalan).
- **Dokumentasi:** update `docs/business-flow/`, `docs/context/`,
  `docs/tasks/--.txt` setiap ada perubahan.

### Konvensi Commit/PR

- Conventional Commits: `feat(scope):`, `fix(scope):`, `docs:`, `test:`, dll.
- Branch: `feat/...`, `fix/...`, `docs/...`.
- PR squash merge. Workflow lengkap: `.kiro/github-pr.md` di masing-masing repo.
- **JANGAN commit/push/merge tanpa persetujuan eksplisit user.**

---

## 🚀 Deployment

Script utama: **`/home/whyrtch/surveyku-server.sh`**

```
./surveyku-server.sh {start|stop|restart|status|fix-loops|setup-smtp|setup-paypal}
```

### Komponen & Port

| Komponen | Jenis | Nama | Port |
|---|---|---|---|
| PostgreSQL | Container | `immich-postgres` | 5432 (internal) |
| Redis | Container | `surveyku-redis` | 6379 |
| MinIO | Container | `surveyku-minio` | 9000 (API), 9001 (console) |
| Backend | Container | `surveyku-backend` | 8080 |
| Web (Next.js) | Proses bare (`setsid`) | — | 3000 |
| Tunnel | Cloudflared (systemd user) | — | `survey.whyrtch.online` (backend), `admin-survey.whyrtch.online` (web) |

> MinIO data: `/home/whyrtch/Project/Survey/surveyku-minio` (bind mount ke
> `/data`). Container ada di network `bridge` + `immich_immich` — backend
> mengakses via nama container `surveyku-minio:9000`.

### Rebuild Backend

```bash
cd /home/whyrtch/Project/Survey/surveyku-backend
docker build -t surveyku-backend:latest .
# lalu recreate container (atau jalankan ./surveyku-server.sh restart)
```

> **PELAJARAN PENTING (insiden 2026-09-17):** selalu rebuild image dari
> **commit final** sebelum deploy. Image yang dibangun dari state antara branch
> fitur menyebabkan order selesai tanpa file hasil. Detail:
> `surveyku-backend/docs/context/2026-09-17-order-complete-with-result.md`.

### Env Files

- Backend dev lokal: `.env` di `surveyku-backend/` (DB_HOST=localhost:5433).
- Web: `.env` di `surveyku-web/` (`NEXT_PUBLIC_API_URL`, `NODE_ENV`).
- Env rahasia container: `/home/whyrtch/Project/.smtp.env`, `.web.env`,
  `.backend.env` (dikelola via `setup-smtp` / `setup-paypal`).

---

## 🛠️ Development

### Backend

```bash
cd /home/whyrtch/Project/Survey/surveyku-backend
make run          # jalankan server (go run ./cmd/server/main.go)
make dev          # hot reload (air)
make build        # build binary ke bin/server
make test         # jalankan semua test
make lint         # linter
make swagger      # generate Swagger docs
make migrate-up   # jalankan migration
```

### Frontend

```bash
cd /home/whyrtch/Project/Survey/surveyku-web
npm install
npm run dev       # dev server (port 3000)
npm run build     # production build
npm run lint      # ESLint
npx tsc --noEmit  # type-check
./restart-dev.sh  # reset cache .next + restart
```

### Mobile Surveyor

```bash
cd /home/whyrtch/Project/Survey/surveyor-app
npm install
cp .env.example .env.local   # isi Firebase config (opsional — mock mode tanpa Firebase)
npx expo start               # Expo dev server
npm run typecheck            # TypeScript type check
npm run lint                 # ESLint
npm test                     # Vitest unit test
npm run build:android        # EAS build production (Android)
npm run build:ios            # EAS build production (iOS)
npm run update:all           # EAS Update OTA
```

> **PENTING:** baca `surveyor-app/AGENTS.md` — Expo SDK 56 punya perubahan
> besar; cek https://docs.expo.dev/versions/v56.0.0/ sebelum menulis kode.

### Verifikasi Sebelum Commit (WAJIB)

1. Backend: `go build ./...` + `go test ./...` → semua pass.
2. Frontend web: `npx tsc --noEmit` + `npx eslint` + `npx next build` → pass.
3. Mobile: `npm run typecheck` + `npm run lint` + `npm test` → pass.
4. Update docs: `docs/business-flow/`, `docs/context/`, `docs/tasks/--.txt`.
5. Pastikan tidak ada: debug code, temp files, secrets, perubahan tak terkait,
   unused imports, lint/type/test error.

---

## 🔧 Troubleshooting

| Gejala | Penyebab | Solusi |
|---|---|---|
| Upload file gagal `INTERNAL_ERROR` | Backend memakai NoOp storage (MinIO belum siap saat start) | `./surveyku-server.sh restart` |
| Order COMPLETED tapi client lihat "Hasil sedang disiapkan" | `result_file_url` NULL (order selesai tanpa file) | Admin klik **"Generate Hasil Akhir"** (self-heal) |
| Backend tidak punya endpoint baru | Image stale (dibangun dari commit lama) | Rebuild dari commit final + restart |
| Web tidak jalan | Proses `next dev` mati | `./surveyku-server.sh start` atau cek `tail -f surveyku-web/web.log` |
| Service restart loop (cloudflared) | Token tunnel hilang | `sudo ./surveyku-server.sh fix-loops` |
| Test backend gagal | `fakeOrderRepo` menyimpan pointer (mutasi bocor) | Gunakan `cloneOrder` (lihat test) |

---

## ⚠️ Common Pitfalls (jebakan yang sering terjadi)

1. **`StatusApprovedPaid` = `"APPROVED_UNPAID"`** — nama konstanta Go tidak
   sama dengan nilai string. Jangan "perbaiki".
2. **Jangan edit migration yang sudah jalan** — buat migration baru.
3. **Jangan panggil repo langsung dari handler** — lewat service layer.
4. **Jangan menambah upload UI** — hasil akhir selalu di-generate backend.
5. **Jangan commit tanpa update docs** — business-flow, context, tasks.
6. **DB aktif di luar folder Survey** — DB di `immich-postgres` (mount
   `/DATA/AppData/immich/pgdata`). MinIO sudah di dalam folder
   (`surveyku-minio/`). Jangan buat folder data baru di `Project/Survey/`
   selain yang sudah ada.
7. **Frontend `next dev` berjalan dari `Survey/surveyku-web`** — jika folder
   dipindah lagi, update `surveyku-server.sh` dan restart web.
8. **Mobile: jangan bypass orchestration hooks** — screens tidak boleh
   memanggil store/service langsung (pola `features/*/hooks`).
9. **Mobile: `EXPO_PUBLIC_FIREBASE_PROJECT_ID` kosong = mock mode** — jangan
   bingung kalau data tidak muncul di Firestore saat dev tanpa env.
10. **Mobile: server tidak paham logic `show`** — question tersembunyi yang
    `required:true` gagal 422; app harus tampilkan pesan ramah, bukan crash.

---

## 📚 Referensi Dokumen

- `surveyku-backend/README.md` — detail API backend (endpoint lengkap)
- `surveyku-web/README.md` — detail frontend web
- `surveyor-app/README.md` — detail mobile surveyor
- `surveyor-app/ARCHITECTURE.md` — arsitektur mobile (routing, data flow, survey engine)
- `surveyor-app/MOBILE_API_FLOW.md` — kontrak API mobile ↔ backend (endpoint lengkap)
- `surveyor-app/MOBILE_MASTER_DATA.md` — master data (provinsi, kota, pekerjaan, dll)
- `surveyor-app/SETUP.md` — setup Firebase + EAS build
- `surveyor-app/PRODUCTION_CHECKLIST.md` — checklist produksi
- `surveyor-app/.kiro/specs/surveyor-foundation/` — spec foundation (design, requirements, tasks)
- `surveyku-backend/docs/business-flow/order-completion-flow.md` — flow completion
- `surveyku-web/docs/business-flow/order-creation.md` — flow pembuatan order
- `surveyku-backend/docs/context/2026-09-17-order-complete-with-result.md` — konteks + insiden deployment
- `surveyku-web/docs/context/2026-09-17-order-complete-with-result.md` — konteks frontend
- `surveyku-backend/docs/` — Swagger, tabel, flow API mobile