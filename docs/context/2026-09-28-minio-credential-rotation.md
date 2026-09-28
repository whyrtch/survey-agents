# 2026-09-28 — Rotasi Credential MinIO

MinIO memakai credential default `minioadmin:minioadmin`. Bucket `surveyku`
berisi data KTP (PII), jadi credential default pada layanan yang menyimpan
identitas pribadi adalah risiko kepatuhan, bukan cuma “
enak”. Rotasi dilakukan tanpa downtime dan tanpa kehilangan data.

Dokumen ini melanjutkan
`2026-09-28-firebase-notifier-and-minio-restart-policy.md` — bacalah
bersama karena keduanya menyangkut file yang sama.

---

## Temuan awal

Credential default ada di dua tempat, dan keduanya harus dibereskan:

| Lokasi | Nilai | Perbaikan |
|---|---|---|
| `docker-compose.yml` | `MINIO_ROOT_USER`/`PASSWORD: minioadmin` inline | `${MINIO_ACCESS_KEY}` / `${MINIO_SECRET_KEY}` dari `.env` |
| `internal/config/config.go:201-202` | `getEnv("MINIO_ACCESS_KEY", "minioadmin")` | backend **tidak** menerima env ini di container → jatuh ke default |

Yang kedua ini yang mudah terlewat. Container backend berjalan hanya dengan
`MINIO_ENDPOINT` dan `MINIO_PUBLIC_URL`; `MINIO_ACCESS_KEY`/`MINIO_SECRET_KEY`
tidak pernah dikirim, jadi Go selalu memakai default `minioadmin`. Kalau
credential MinIO dirotasi tanpa mengirim key baru ke container, **semua
signature request akan ditolak** (`SignatureDoesNotMatch`) dan storage berhenti
dengan diam — bukan fallback NoOp, tapi request yang gagal terus.

## Kenapa ini lebih mudah dari yang dibayangkan

`.minio.sys/config/config.json` pada `RELEASE.2025-09-07` berupa **direktori**
berisi `xl.meta` terenkripsi — credential root tidak bisa diedit manual. Tapi
env var ternyata meng-override config tersimpan.

Diverifikasi lebih dulu di salinan data, bukan di produksi:

```
TES 1: credential lama  -> DITOLAK
TES 2: credential baru  -> bisa akses
TES 3: data utuh       -> ktp 1, questionnaire 14, redemption_proof 1, result 2
```

Artinya rotasi cukup dengan recreate container memakai env baru — **tidak perlu**
menghapus `.minio.sys/config` dan tidak perlu migrasi. Jalur riskier itu memang
tidak diambil.

## Prosedur

1. Backup konsisten: `docker stop surveyku-minio` → `tar` → `docker start`.
   Disimpan di `/home/whyrtch/Project/.minio-backups/`.
2. Generate credential baru, tulis ke `surveyku-backend/.env`
   (`MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY`) — file ini sudah git-ignored.
3. Perketat izin `surveyku-backend/.env` dari `644` → `600`. Sekarang file itu
   menyimpan secret sungguhan, sebelumnya world-readable.
4. Ubah `docker-compose.yml` supaya membaca dari `.env` via env substitution.
5. `surveyku-server.sh` mengirim `MINIO_ACCESS_KEY`/`MINIO_SECRET_KEY`/
   `MINIO_BUCKET` secara eksplisit ke container backend.
6. Recreate MinIO dari compose, lalu recreate backend.
7. Hapus container lama **hanya setelah** semua verifikasi lulus.

## Jebakan yang hampir menyebabkan outage

**`docker-compose.yml` tidak mendeklarasikan network sama sekali.** Bahkan
sebelum rotasi, file itu tidak bisadireproduksi: menjalankan
`docker compose up -d` akan membuat MinIO masuk ke network
`surveyku-backend_default`, sementara `surveyku-backend` hanya JOIN ke
`immich_immich` dan mencari MinIO lewat DNS `surveyku-minio:9000`. Hasilnya
backend gagal resolve → **fallback ke NoOp storage → semua upload file mati.**

Topology yang berjalan sebenarnya: MinIO di network `bridge` **dan**
`immich_immich`.

Percobaan pertama menambahkan `default: {external: true, name: bridge}` supaya
meniru kondisi itu, dan **gagal total**:

```
invalid config for network bridge: invalid endpoint settings:
network-scoped aliases are only supported for user-defined networks
```

MinIO sempat down. Di-rollback dengan me-*rename* container lama (bukan
`docker rm`) supaya pulih tanpa tarik image lagi.

Penyelesaiannya: `bridge` memang tidak diperlukan. Backend lewat
`immich_immich`, akses host lewat published port. Jadi compose hanya mendeklarasikan
`immich_immich`.

Verified: `docker exec surveyku-backend getent hosts surveyku-minio` →
`172.18.0.7`, dan backend membaca objek lewat MinIO dengan credential baru.

## Perilaku yang harus dipertahankan

- **Jangan pernah menulis credential literal di `docker-compose.yml`** — file
  itu ter-commit. Selalu pakai env substitution.
- Credential hanya di `surveyku-backend/.env` (izin `600`, git-ignored).
  Jangan disalin ke file lain.
- Kalau credential MinIO dirotasi lagi: update `.env`, lalu
  `./surveyku-server.sh restart`. `ensure_backend_config()` mendeteksi drift
  dan me-*recreate* container backend otomatis, jadi tidak perlu langkah manual
  tambahan.
- Kalau MinIO perlu `docker compose up -d`, pastikan `immich_immich` masih
  ada (external network). Compose tidak akan membuatnya.

## Verifikasi akhir

```
MinIO storage initialized successfully
Firestore notifier initialized successfully
```

- Credential lama `minioadmin` → **ditolak** (S3 list bucket)
- Credential baru → bisa akses
- Integritas data: 18 object (1 ktp, 14 questionnaire, 1 redemption_proof, 2 result)
- Baca objek end-to-end lewat `GET /api/v1/files/questionnaire/<uuid>` →
  HTTP 200, 19251 bytes, `Microsoft Excel 2007+` (header zip `PK`)
- `surveyku-minio` `RestartPolicy=unless-stopped`, `Status=healthy`
- Tidak ada credential di file ter-track

## Follow-up

### ✅ Default `minioadmin` di config.go — sudah dikerjakan

`internal/config/config.go:201-202` tidak lagi memakai `minioadmin` sebagai
default. Sekarang kosong, konsisten dengan `JWT_*_SECRET` yang sudah begitu.

Tidak dibuat **hard-fail** di `Load()` (seperti JWT), karena MinIO hanya salah
satu dari tiga opsi storage (Firebase > MinIO > NoOp) — kalau Firebase yang
primary, credential MinIO memang tidak perlu ada. Hard-fail akan salah.

Sebagai gantinya, `cmd/server/main.go` melewati percobaan koneksi MinIO kalau
credential kosong, dan log menyebut nama env yang harus diisi:

```
WARN MinIO credentials not configured, using NoOp storage (file uploads disabled)
     hint=set MINIO_ACCESS_KEY and MINIO_SECRET_KEY
```

Tanpa ini, kredensial kosong akan dikirim ke server dan gagal sebagai `403`,
jauh dari penyebab sebenarnya.

Test baru di `internal/config/config_test.go` (4 test) mengunci perilaku ini.
Satu test menyoroti jebakan `getEnv`: variabel yang di-set ke string kosong
**tidak** digantikan default (`os.LookupEnv` mengembalikan `ok=true`), jadi
"di-set kosong" berbeda dari "belum diset".

`.env.example` juga diperbaiki — sebelumnya menyatakan MinIO "DEPRECATED, use
Firebase instead", padahal MinIO-lah storage yang benar-benar dipakai, dan
`FIREBASE_BUCKET` yang terisi justru membuat `main.go` memilih Firebase
Storage.

### ⚠️ Alur deploy di AGENTS.md tidak pernah benar-benar recreate

Ini kemungkinan akar insiden "image stale" di
`2026-09-17-order-complete-with-result.md`.

`AGENTS.md` menulis:

```bash
docker build -t surveyku-backend:latest .
/home/whyrtch/surveyku-server.sh restart   # "Recreate container"
```

Tapi `do_start` hanya memanggil `ensure_container`, yang menjalankan
`docker start` pada container yang ada. **`docker start` memakai image yang
terpasang di container, bukan tag `latest` yang baru di-build.** Image baru
tidak pernah aktif, dan tidak ada error — endpoint baru hanya mysteriously
tidak ada.

Dibuktikan saat sesi ini: image ID container `3e61e956…` vs tag `latest`
`30828d43…` setelah `docker build` sukses.

`backend_needs_recreate()` sekarang membandingkan image ID keduanya dan
me-*recreate* container kalau beda. Alur deploy di `AGENTS.md` jadi benar
tanpa perlu diubah.

### Masih terbuka

- Rotasi `MINIO_ROOT_USER` MinIO **tidak** membuat user/service account baru
  di dalam MinIO — credential root berubah, tapi itu tetap root. Kalau butuh
  least-privilege, langkah berikutnya `mc admin user add` untuk user non-root,
  lalu credential itu dipakai backend.
- `gofmt -l` menandai 12 file di repo, termasuk `internal/config/config.go`
  (blok `AppConfig`). Sudah unformatted sebelum sesi ini dan **sengaja tidak
  dirapikan** agar diff tetap fokus. Tidak ada CI gofmt gate di repo ini.
