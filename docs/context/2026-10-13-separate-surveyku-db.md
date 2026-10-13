# Database SurveyKu dipisah dari Immich

Tanggal: 2026-10-13 · Repo: `survey-agents` (root) + `surveyku-backend`

Ringkas: database `surveyku` pindah dari `immich-postgres` ke container
sendiri, `surveyku-postgres`. Semua container SurveyKu sekarang ada di network
`surveyku` dan tidak lagi bergantung pada Immich.

---

## Kenapa

- Immich akan dipindah dari CasaOS ke compose sendiri dan di-upgrade ke v3.
  Compose bawaan Immich memakai nama container dan network yang berbeda
  (`immich_postgres`, `immich_default`), jadi SurveyKu akan putus dari
  database-nya.
- Restart/upgrade Immich ikut mematikan SurveyKu (dan sebaliknya).
- User `hermes` adalah **superuser** di `immich-postgres`, artinya backend
  SurveyKu bisa membaca dan menghapus database foto Immich.

---

## Setelah dipisah

| | Sebelum | Sesudah |
|---|---|---|
| Container DB | `immich-postgres` (Postgres 14 + VectorChord) | `surveyku-postgres` (`postgres:17-alpine`) |
| Data | `/DATA/AppData/immich/pgdata` (bersama Immich) | volume Docker `surveyku-pgdata` (SSD) |
| Role `hermes` | superuser | pemilik database `surveyku` saja |
| Superuser | — | `postgres`, password acak yang tidak disimpan; akses admin lewat `docker exec surveyku-postgres psql -U postgres` |
| Network | `immich_immich` | `surveyku` (backend, redis, minio, postgres) |
| `stop` | Postgres dibiarkan jalan (dipakai Immich) | Postgres ikut dimatikan |

Perubahan `surveyku-server.sh`:

- `ensure_network` membuat network `surveyku` dan menyambungkan
  `surveyku-redis` serta `surveyku-minio` (keduanya dibuat di luar script).
- `ensure_postgres` membuat `surveyku-postgres` kalau belum ada, dengan
  role/database dari `surveyku-backend/.env` (`DB_USER`, `DB_NAME`,
  `DB_PASSWORD`). Password dikirim lewat stdin, bukan argumen.
  **Container baru berisi database kosong**; data tidak dipindah otomatis.
- `apply_backend_env` selalu memakai network `surveyku` dan
  `DB_HOST=surveyku-postgres` (tidak lagi menyalin dari container lama).
- `backend_needs_recreate` me-recreate backend kalau network atau `DB_HOST`
  masih yang lama.

`surveyku-backend/docker-compose.yml` (MinIO) sekarang join network external
`surveyku`, bukan `immich_immich`.

---

## Cara migrasi yang dipakai

Downtime backend ±12 detik (00:20:21–00:20:33 WIB). Immich tidak terganggu.

1. Backup ke `/mnt/storage/backups/db-split-202610130018/`:
   `pg_dumpall` seluruh `immich-postgres` dan `pg_dump -Fc surveyku`.
2. `ensure_network` + `ensure_postgres` (container baru, database kosong).
3. `docker stop surveyku-backend`.
4. `pg_dump --no-owner --no-privileges surveyku` dari `immich-postgres`,
   di-restore sebagai `hermes` ke `surveyku-postgres`, sehingga semua objek
   dimiliki `hermes`. `pgcrypto` adalah trusted extension (PG13+), jadi
   pemilik database boleh membuatnya.
5. Jumlah baris 14 tabel dibandingkan: sama persis.
6. `apply_backend_env` → backend dibuat ulang di network `surveyku`.
7. `surveyku-redis` dan `surveyku-minio` dilepas dari `immich_immich`.

Verifikasi: `GET /api/v1/master/provinces` (baca DB) → 200 lewat
`survey.whyrtch.online`, log backend "MinIO storage initialized
successfully", `status` semua hijau, dan `start` berikutnya tidak me-recreate
backend.

---

## Rollback

Data lama masih utuh di `immich-postgres` (DB `surveyku`, role `hermes`) dan
**belum dihapus**. Data yang masuk setelah 00:20 WIB hanya ada di
`surveyku-postgres`, jadi rollback setelah ada data baru harus dump balik dulu.

Hapus database lama setelah beberapa hari stabil:

```bash
docker exec immich-postgres psql -U postgres -c 'DROP DATABASE surveyku' -c 'DROP ROLE hermes'
```
