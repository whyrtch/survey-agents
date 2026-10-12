# Web pindah dari `next dev` ke production build + systemd

Tanggal: 2026-10-12 · Repo: `survey-agents` (root)

Ringkas: setelah `~/Project` dipindah ke HDD eksternal, web (`next dev`)
menghabiskan RAM dan swap server. Web sekarang jalan dari production build
lewat systemd user service, dan otomatis jalan setelah reboot.

---

## Insiden — `next dev` dari HDD menghabiskan RAM

`~/Project` dipindah ke HDD USB (`/mnt/storage/Project`, ext4) dan
`~/Project` menjadi symlink. Saat web dinyalakan lagi dengan `npm run dev`:

- Turbopack terus membuat worker `postcss.js` sampai **284 proses** (~100 MB
  masing-masing)
- RAM 10 GB + swap 4 GB habis (sisa 338 MB), load sampai 22
- HDD 97% sibuk, iowait 58–75%; halaman pertama tidak pernah selesai di-compile

Web dihentikan manual sebelum server macet. Server ini dikonfigurasi
`kernel.softlockup_panic=1`, jadi kondisi seperti ini bisa berakhir panic.

Penyebab: dev mode meng-compile on-demand dan membaca ribuan file kecil di
`node_modules`. Di SSD masih tertolong; di HDD USB worker menumpuk. Cache
`.next` juga harus dibangun ulang karena path berubah.

Catatan: web juga sudah mati sejak reboot sebelumnya. Tidak ada yang
menyalakannya otomatis saat boot, jadi web mati setiap kali server reboot
sampai `surveyku-server.sh start` dijalankan manual.

---

## Jebakan — `pgrep -f "next dev"`

`start_web`, `stop_web`, dan `status` mendeteksi web dengan
`pgrep -f "next dev"`. Pola itu cocok dengan proses **apa pun** yang command
line-nya memuat teks tersebut, termasuk shell yang menjalankan pgrep:

- `status` melaporkan "Web berjalan (PID: …)" padahal port 3000 kosong; PID
  itu milik shell yang sedang mengecek
- `pkill -f 'next dev'` dari sebuah shell ikut membunuh shell itu sendiri

Sekarang web dideteksi lewat port (`/dev/tcp/localhost/3000`) dan PID diambil
dari `ss -ltnp`.

---

## Perbaikan

**Production build.** `start` menjalankan `.next/standalone/server.js`
(`next.config.ts` sudah `output: "standalone"`), sama seperti `Dockerfile`.
`public/` dan `.next/static/` disalin ke folder standalone setelah build,
sesuai dokumentasi Next.js 16 (`output.md`). Build ulang otomatis kalau ada
file di `src/`, `public/`, `package*.json`, `next.config.ts`, `.env`, atau
`.web.env` yang lebih baru dari `server.js`. Build makan ~1 menit dan RAM
masih tersisa >7.5 GB. Web berjalan dengan ~50–105 MB.

`NEXT_PUBLIC_API_URL` harus di-set saat **build** (di-inline ke bundle),
bukan hanya saat runtime. `load_web_env` dipanggil di keduanya.

**systemd user service** `~/.config/systemd/user/surveyku-web.service`
(di luar repo; isi lengkap di bawah). `start`/`stop` memanggil
`systemctl --user`; kalau service belum terpasang, script kembali ke proses
bare. Linger user `whyrtch` sudah aktif, jadi service jalan saat boot tanpa
login.

**Action baru:** `build-web` (paksa build + restart web) dan `run-web`
(internal, ExecStart service).

---

## Dua bug yang ketemu saat uji

1. `web_listen_pid` mengembalikan status gagal saat tidak ada yang listen
   (`grep` tanpa hasil). Dengan `set -euo pipefail`, `pid=$(web_listen_pid)`
   menghentikan **seluruh** script — `stop` keluar sebelum mematikan
   container. Diperbaiki dengan `|| true`.
2. Next.js keluar dengan kode **143** saat menerima SIGTERM, sehingga service
   berstatus `failed` setiap kali di-stop. Diperbaiki dengan
   `SuccessExitStatus=143`.

Hasil uji: start/stop lewat script, stop saat web sudah mati, `kill -9`
(service menyala lagi dalam 16 detik), `status`, dan
`https://admin-survey.whyrtch.online` → 200.

---

## Isi `surveyku-web.service`

Kalau file hilang, buat ulang lalu jalankan
`systemctl --user daemon-reload && systemctl --user enable --now surveyku-web`.

```ini
[Unit]
Description=SurveyKu Web (Next.js production, port 3000)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=600
StartLimitBurst=10

[Service]
Type=simple
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/bin/bash %h/Project/Survey/surveyku-server.sh run-web
Restart=on-failure
RestartSec=15
SuccessExitStatus=143
TimeoutStopSec=15
MemoryHigh=2G
MemoryMax=3G
StandardOutput=append:%h/Project/Survey/surveyku-web/web.log
StandardError=append:%h/Project/Survey/surveyku-web/web.log

[Install]
WantedBy=default.target
```

- `PATH` eksplisit: `node`/`npm` ada di `~/.local/bin`, yang tidak termasuk
  PATH bawaan user manager systemd.
- `StartLimitBurst=10`: Project ada di HDD; kalau HDD terlambat ter-mount
  saat boot, service dicoba ulang.
- `MemoryMax=3G`: kalau kejadian worker menumpuk terulang, yang mati hanya
  web, bukan server.

Pelajaran: **jangan jalankan `next dev` di server.** Dev mode hanya untuk
mesin pengembangan.
