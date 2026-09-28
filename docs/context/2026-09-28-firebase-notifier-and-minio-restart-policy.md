# 2026-09-28 — Firebase Notifier Credential Mount + MinIO Restart Policy

Dokumen ini mencatat dua insiden produksi yang ditemukan pada sesi ini dan
perbaikannya. Keduanya menyebabkan **kehilangan fungsi secara senyap** — log
tetap `200 OK`, tidak ada error yang terlihat pengguna, tapi fiturnya mati.

---

## Insiden 1 — Notifikasi Firestore (APP-01) diam-diam NoOp

### Gejala

`APP-01` (PR `surveyku-backend#4`) sudah ter-merge dan dianggap selesai, tetapi
notifikasi survei ke app mobile tidak pernah terkirim. Log backend:

```json
{"level":"INFO","msg":"Firebase not configured, using NoOp notifier (survey notifications disabled)"}
```

Di `docs/tasks/project-implementation-tasks.md`, item ini memang tercatat
sebagai "verifikasi live yang masih perlu dilakukan manual" —rupanya memang
tidak pernah aktif sama sekali sejak di-deploy.

### Akar penyebab (tiga lapis)

1. **Env kosong di container.** `cmd/server/main.go:108` hanya membuat
   `FirestoreNotifier` bila `cfg.Firebase.CredentialsPath != ""`. Container
   berjalan dengan `FIREBASE_CREDENTIALS_PATH=` (string kosong), sehingga
   cabang tersebut dilewati dan jatuh ke `NoOpNotifier`.

2. **Credential tidak pernah ada di dalam container.**
   `surveyku-server.sh` menjalankan backend via `docker run` yang **tidak punya
   volume mount sama sekali**, dan `surveyku-backend/Dockerfile` hanya menyalin
   `server` + `migrations`. Path dari `.env` adalah relatif
   (`./credentials/firebase-adminsdk.json`), yang di dalam container
   (`WORKDIR /app`) menjadi `/app/credentials/firebase-adminsdk.json` — tidak
   pernah ada.

3. **Env & mount membeku saat pembuatan container.** `do_start` hanya memanggil
   `docker start`, yang mempertahankan konfigurasi lama. Env/mount baru hanya
   bisa masuk lewat `apply_backend_env`, yang hanya dipanggil dari
   `setup-smtp` / `setup-paypal`. Artinya konfigurasi tidak bisa diperbarui
   lewat `start` / `restart` biasa.

### Perbaikan

| File | Perubahan |
|---|---|
| `surveyku-server.sh` | `read_backend_env_value()` — baca satu key dari `surveyku-backend/.env` |
| `surveyku-server.sh` | `apply_backend_env()` — mount `credentials/` ke `/app/credentials:ro` + kirim `FIREBASE_CREDENTIALS_PATH` |
| `surveyku-server.sh` | `backend_missing_firebase_creds()` — deteksi config yang belum terpasang |
| `surveyku-server.sh` | `ensure_backend_firebase()` — `do_start` me-*recreate* container sendiri bila perlu (pola self-heal, sama seperti `ensure_backend_storage`) |

Pola self-heal ini sengaja mengikuti `ensure_backend_storage()` yang sudah ada:
deteksi kondisi salah → perbaiki otomatis → lanjut start.

### Jebakan yang harus diingat

`FIREBASE_BUCKET` **tidak boleh** diteruskan ke container. `main.go:83`:

```go
if cfg.Firebase.CredentialsPath != "" && cfg.Firebase.Bucket != "" {
    fb, _ := storage.NewFirebaseStorage(...)   // Firebase Storage dipilih
}
```

Kalau Bucket terisi, storage **berpindah dari MinIO ke Firebase Storage**.
Data KTP / kuesioner / file hasil ada di MinIO (bind mount
`surveyku-minio/`), sehingga file lama akan putus URL-nya. Notifier sendiri
hanya butuh `FIREBASE_CREDENTIALS_PATH` (`main.go:108` tidak mengecek bucket).

`surveyku-backend/.env` lokal memang berisi `FIREBASE_BUCKET`, tapi nilainya
tidak boleh diteruskan. Ini sudah dikunci menjadi `FIREBASE_BUCKET=` kosong di
`apply_backend_env`, dan dideteksi oleh `backend_missing_firebase_creds()`.

### Verifikasi

```
MinIO storage initialized successfully
Firestore notifier initialized successfully
```

Mount: `/home/.../surveyku-backend/credentials -> /app/credentials RW=false`
Env: `FIREBASE_CREDENTIALS_PATH=./credentials/firebase-adminsdk.json`,
`FIREBASE_BUCKET=` (kosong).

Restart kedua tidak merecreate container → `ensure_backend_firebase` idempoten.

> ⚠️ **Catatan added 2026-09-28 setelah merge PR #1.** Baris di atas benar
> secara literal tapi **tidak menguji apa pun**: pada iterasi pertama jalur
> recreate tidak pernah dieksekusi, sehingga tidak ada yang diverifikasi.
> Penyebabnya deteksi image drift membandingkan dua ID di namespace berbeda —
> lihat "Jebakan deteksi image drift" di bawah. Diperbaiki di PR #2 dan diuji
> ulang dengan jalur recreate yang benar-benar berjalan.

---

## Jebakan deteksi image drift (containerd image store)

Mesin ini memakai **containerd image store** dan BuildKit menghasilkan
**manifest list** (build output memuat `attestation manifest`). Akibatnya tag
`latest` menunjuk ke *image index*, bukan config digest:

```bash
docker inspect <container> --format '{{.Image}}'   # → config digest  sha256:30828d43
docker image inspect <tag>    --format '{{.Id}}'   # → image index    sha256:295fbc0c
```

Keduanya **tidak akan pernah sama**, meskipun menunjuk image yang sama pada
build biasa. Versi pertama `backend_needs_recreate()` membandingkan kedua
nilai itu, jadi selalu mengembalikan "tidak perlu recreate" dan image baru
tidak pernah ter-deploy — gejala persis yang seharusnya dihilangkan.

Perbaikan (PR #2): ambil kedua nilai lewat `docker inspect`, sehingga keduanya
memakai mekanisme resolusi yang sama dengan `docker run`. `docker create`
dipakai untuk me-resolve tag tanpa menjalankan container:

```bash
probe=$(docker create --name surveyku-image-probe "$BACKEND_IMAGE")
tagged_image=$(docker inspect "$probe" --format '{{.Image}}')
docker rm -f "$probe"
```

**Pelajaran:** jangan menyimpulkan "idempoten" dari `start` yang tidak
menghasilkan recreate. Uji hanya bermakna kalau jalurnya sudah dieksekusi
sesuai satu kali — pada bug ini, jalur itu justru tidak pernah jalan.

---

## Insiden 2 — MinIO tidak kembali setelah reboot

### Gejala

`surveyku-minio` berstatus `Exited (255)`. Backend sempat log:

```
"MinIO not available, using NoOp storage (file uploads disabled)"
→ dial tcp: lookup surveyku-minio ... server misbehaving
```

Artinya **semua upload file mati**: KTP, kuesioner, dan file hasil. Order tetap
bisa dibuat, hanya saja unggahan gagal.

### Akar penyebab

Bukan OOM (`OOMKilled=false`), bukan disk penuh (84%), dan bukan error MinIO
di log. Corelasinya dengan waktu boot:

| Waktu (UTC) | Peristiwa |
|---|---|
| `06:55:28` | Host reboot (`uptime -s`) |
| `06:55:54` | `surveyku-minio` mati, `ExitCode=255` |
| `06:55:56` | `immich-postgres` & `immich-server` **auto-start** |

Host pertama kali perlu restart karena Docker me-restart container dengan
`restart: unless-stopped`. `surveyku-minio` **tidak** ikut karena
`surveyku-backend/docker-compose.yml` tidak mendeklarasikan `restart:` —
sehingga policy-nya `no`, dan tidak ada yang menghidupkannya kembali sampai
seseorang menjalankan script secara manual.

Bukti langsung bahwa mekanismenya bekerja di host ini: `immich-server` dan
`immich-postgres` (keduanya `unless-stopped`) benar-benar auto-start 28 detik
setelah boot.

### Perbaikan

- `surveyku-backend/docker-compose.yml` — tambah `restart: unless-stopped`
  pada service `minio` (sumber deklaratif).
- `docker update --restart unless-stopped surveyku-minio` — diterapkan ke
  container yang sedang hidup, tanpa *recreate* dan tanpa downtime.

### Catatan tentang cara menguji

Restart policy **sengaja diabaikan** untuk `docker stop` / `docker kill` —
Docker menghormati penghentian manual. Jadi `docker kill` **tidak** membuktikan
apa-apa soal skenario reboot. Bukti yang sah adalah auto-start
`immich-*` di atas. Jangan pakai `docker kill` sebagai tes restart policy.

### Catatan forensik

Log container yang sudah di-*recreate* (`docker rm` + run) **hilang**. Saat
menyelidiki insiden MinIO, log lama ikut hilang karena
`apply_backend_env` menghapus dan membuat ulang container. Ambil
`docker inspect` / `docker logs` **sebelum** menjalankan
`./surveyku-server.sh restart` bila detail proses masih dibutuhkan.

---

## Handling secret

Credential adalah Firebase Admin SDK service account
(`firebase-adminsdk-fbsvc@projects-8f743`) dengan akses admin penuh ke project
tersebut. Perlakuan yang diterapkan:

| Lokasi | Perlindungan |
|---|---|
| `surveyku-backend/credentials/firebase-adminsdk.json` | `credentials/` di `.gitignore` **dan** `.dockerignore` |
| Root repo | pola `service.json`, `service-account*.json`, `*firebase-adminsdk*.json` di `.gitignore` |
| Container | bind mount `:ro`, bukan `COPY` ke image |

Sudah diverifikasi: private key **tidak ada** di file ter-track, **tidak ada**
di history git (4 repo, 0 kemunculan), dan **tidak ada** di dalam image
Docker.

Credential ini hanya boleh dipakai server-side. Jangan pernah memakainya
sebagai web config di `surveyor-app` — Firebase SDK sisi app sudah cukup untuk
pembacaan; Admin SDK hanya untuk penulisan notifikasi.

---

## Perilaku yang harus dipertahankan

- `FIREBASE_CREDENTIALS_PATH` relatif terhadap `.env` **harus** tetap
  `./credentials/...`, karena `WORKDIR` container adalah `/app`. Kalau path
  diubah, sesuaikan juga `mount_args` di `apply_backend_env`.
- Jangan pernah mengirim `FIREBASE_BUCKET` ke container backend.
- Kalau credential di-rotate di GCP Console, cukup ganti file di
  `surveyku-backend/credentials/` lalu `./surveyku-server.sh restart` — mount
  terjadi saat recreate, jadi file baru langsung terpakai.

## follow-up

- **MinIO masih memakai credential default** `minioadmin:minioadmin`
  (terlihat di log dan di `docker-compose.yml`). Belum diubah karena MinIO
  mengikat identitas root kredensial ke data di disk, jadi rotasi pada
  deployment existing bisa memutus akses bucket `surveyku` — perlu migrasi
  menyeluruh, bukan sekadar edit konfigurasi.
- `APP-01` masih perlu verifikasi end-to-end: buat order baru dari
  `surveyku-web`, pastikan dokumen muncul di koleksi `notifications` Firestore
  dan tampil di app.
