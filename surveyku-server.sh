#!/usr/bin/env bash
# SurveyKu Server Manager (container-based)
#
# Setup aktual:
#   - PostgreSQL, Redis, MinIO, backend  -> container Docker
#   - Web (Next.js)                      -> proses bare (setsid)
#   - Cloudflared tunnel                 -> systemd user service
#
# Usage: ./surveyku-server.sh [action]
#   start | stop | restart | status | fix-loops | setup-smtp | setup-paypal
#   default: start

set -euo pipefail

PROJECT_DIR="/home/whyrtch/Project"
BACKEND_DIR="$PROJECT_DIR/Survey/surveyku-backend"
WEB_DIR="$PROJECT_DIR/Survey/surveyku-web"
WEB_PID_FILE="$WEB_DIR/.web.pid"
WEB_LOG="$WEB_DIR/web.log"
SMTP_ENV_FILE="$PROJECT_DIR/.smtp.env"
WEB_ENV_FILE="$PROJECT_DIR/.web.env"
BACKEND_ENV_FILE="$PROJECT_DIR/.backend.env"

POSTGRES_CONTAINER="immich-postgres"
REDIS_CONTAINER="surveyku-redis"
MINIO_CONTAINER="surveyku-minio"
BACKEND_CONTAINER="surveyku-backend"
BACKEND_IMAGE="surveyku-backend:latest"

BACKEND_PORT=8080
WEB_PORT=3000
MINIO_API_PORT=9000
MINIO_CONSOLE_PORT=9001

# Service sistem yang rusak (restart loop) dan harus di-disable via sudo.
# cloudflared sistem: token /etc/cloudflared/token hilang.
# (casaos* sudah diperbaiki oleh casaos-immich.sh — gateway butuh port 80 bebas)
BROKEN_SERVICES=("cloudflared")

log() { echo -e "\033[1m$1\033[0m"; }
ok()  { echo -e "  \033[32m✓\033[0m $1"; }
err() { echo -e "  \033[31m✗\033[0m $1" >&2; }

check_docker() {
	if ! command -v docker &>/dev/null; then
		err "Docker tidak terinstall"
		exit 1
	fi
	if ! timeout 5 docker info &>/dev/null 2>&1; then
		err "Docker daemon tidak aktif. Jalankan: sudo systemctl start docker"
		exit 1
	fi
}

container_running() {
	docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^$1$"
}

container_exists() {
	docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^$1$"
}

wait_for_port() {
	local host=$1 port=$2 max=${3:-60} sleep_s=${4:-2} attempt=0
	echo "  ⏳ Menunggu $host:$port..."
	while ! (echo > "/dev/tcp/$host/$port") 2>/dev/null; do
		attempt=$((attempt + 1))
		if [ "$attempt" -ge "$max" ]; then
			err "$host:$port tidak respond setelah $((max * sleep_s))s"
			return 1
		fi
		sleep "$sleep_s"
	done
	ok "$host:$port ready"
}

ensure_container() {
	local name=$1
	if container_running "$name"; then
		ok "$name sudah berjalan"
		return 0
	fi
	if container_exists "$name"; then
		docker start "$name" >/dev/null 2>&1 && ok "$name di-start" || {
			err "$name gagal start"
			return 1
		}
	else
		err "$name tidak ada. Buat container dulu."
		return 1
	fi
}

# Deteksi apakah startup backend terakhir memakai NoOp storage (MinIO tidak
# terjangkau saat proses backend start). Dalam kondisi ini upload file mati
# sampai backend di-restart, jadi script akan restart otomatis setelah MinIO
# dipastikan siap.
backend_using_noop_storage() {
	local started_at
	started_at=$(docker inspect "$BACKEND_CONTAINER" --format '{{.State.StartedAt}}' 2>/dev/null) || return 1
	[ -z "$started_at" ] && return 1
	docker logs --since "$started_at" "$BACKEND_CONTAINER" 2>&1 | grep -q "using NoOp storage"
}

# Restart backend jika storage-nya NoOp (MinIO belum siap saat backend start).
ensure_backend_storage() {
	if ! container_running "$BACKEND_CONTAINER"; then
		return 0
	fi
	if backend_using_noop_storage; then
		echo "  Backend memakai NoOp storage (MinIO belum siap saat start), restart backend..."
		docker restart "$BACKEND_CONTAINER" >/dev/null 2>&1 && ok "Backend di-restart, MinIO storage aktif" || {
			err "Gagal restart backend"
			return 1
		}
	fi
}

start_web() {
	if pgrep -f "next dev" >/dev/null 2>&1; then
		ok "Web sudah berjalan (PID: $(pgrep -f 'next dev' | head -1))"
		return 0
	fi

	if [ ! -d "$WEB_DIR/node_modules" ]; then
		echo "  📦 Install dependencies..."
		( cd "$WEB_DIR" && npm install 2>&1 | tail -3 )
	fi

	echo "  Menjalankan web (dev mode, port $WEB_PORT)..."
	cd "$WEB_DIR"
	export NEXT_PUBLIC_API_URL="https://survey.whyrtch.online/api/v1"
	export PORT="$WEB_PORT"
	# Load env tambahan untuk web (mis. PAYPAL_CLIENT_ID) dari .web.env jika ada
	if [ -f "$WEB_ENV_FILE" ]; then
		set -a # auto-export agar diwarisi child process (npm run dev)
		# shellcheck disable=SC1090
		source "$WEB_ENV_FILE"
		set +a
	fi
	setsid nohup npm run dev > "$WEB_LOG" 2>&1 < /dev/null &
	local pid=$!
	echo "$pid" > "$WEB_PID_FILE"
	disown "$pid" 2>/dev/null || true

	sleep 5
	if kill -0 "$pid" 2>/dev/null; then
		ok "Web berjalan (PID: $pid)"
		wait_for_port "localhost" "$WEB_PORT" 40 2 || {
			err "Web gagal bind port. Cek: tail -20 $WEB_LOG"
			return 1
		}
	else
		err "Web process crash. Cek: tail -20 $WEB_LOG"
		return 1
	fi
}

stop_web() {
	local pids
	pids=$(pgrep -f "next dev" 2>/dev/null || true)
	if [ -n "$pids" ]; then
		for p in $pids; do
			kill "$p" 2>/dev/null || true
		done
		sleep 2
		for p in $pids; do
			kill -0 "$p" 2>/dev/null && kill -9 "$p" 2>/dev/null || true
		done
		ok "Web stopped"
	fi
	rm -f "$WEB_PID_FILE"
}

start_cloudflared() {
	if systemctl --user is-active cloudflared &>/dev/null; then
		ok "Cloudflared user service sudah berjalan"
		return 0
	fi
	if [ -f "$HOME/.cloudflared/credentials.json" ]; then
		systemctl --user start cloudflared 2>/dev/null && ok "Cloudflared user service di-start" || {
			err "Gagal start cloudflared"
			return 1
		}
	else
		err "credentials.json tidak ditemukan di $HOME/.cloudflared/"
		return 1
	fi
}

verify_endpoints() {
	echo ""
	log "Verifikasi endpoint:"
	local fail=0
	timeout 10 curl -s -o /dev/null -w "  Backend  :8080 -> HTTP %{http_code}\n" "http://localhost:$BACKEND_PORT/api/v1/health" || fail=1
	timeout 10 curl -s -o /dev/null -w "  MinIO    :9000 -> HTTP %{http_code}\n" "http://localhost:$MINIO_API_PORT/minio/health/live" || fail=1
	timeout 30 curl -s -o /dev/null -w "  Web      :3000 -> HTTP %{http_code}\n" "http://localhost:$WEB_PORT" || fail=1
	if systemctl --user is-active cloudflared &>/dev/null; then
		timeout 10 curl -s -o /dev/null -w "  Tunnel   survey.whyrtch.online -> HTTP %{http_code}\n" "https://survey.whyrtch.online/api/v1/health" || fail=1
	fi
	return "$fail"
}

check_restart_loops() {
	echo ""
	log "Cek restart loop (service sistem):"
	local found=0
	for svc in "${BROKEN_SERVICES[@]}"; do
		if systemctl is-active "$svc" &>/dev/null; then
			local counter
			counter=$(systemctl show "$svc" -p NRestarts --value 2>/dev/null || echo "?")
			err "$svc AKTIF (restart counter: $counter). Jalankan: sudo ./surveyku-server.sh fix-loops"
			found=1
		fi
	done
	[ "$found" -eq 0 ] && ok "Tidak ada service bermasalah yang aktif"
}

# --- Email Service (SMTP) & Payment (PayPal) ---

backend_smtp_configured() {
	docker exec "$BACKEND_CONTAINER" env 2>/dev/null | grep -q "^SMTP_HOST=."
}

backend_paypal_configured() {
	docker exec "$BACKEND_CONTAINER" env 2>/dev/null | grep -q "^PAYPAL_CLIENT_ID=." &&
		docker exec "$BACKEND_CONTAINER" env 2>/dev/null | grep -q "^PAYPAL_SECRET=."
}

load_backend_env() {
	if [ -f "$SMTP_ENV_FILE" ]; then
		# shellcheck disable=SC1090
		source "$SMTP_ENV_FILE"
	fi
	if [ -f "$BACKEND_ENV_FILE" ]; then
		# shellcheck disable=SC1090
		source "$BACKEND_ENV_FILE"
	fi
}

# Recreate backend container dengan env SMTP (dari .smtp.env) dan PayPal (dari .backend.env).
# Env lain (DB, Redis, JWT, dll) diambil dari container yang sedang berjalan.
apply_backend_env() {
	if ! container_exists "$BACKEND_CONTAINER"; then
		err "Container $BACKEND_CONTAINER tidak ada"
		return 1
	fi
	load_backend_env

	local network restart_policy
	network=$(docker inspect "$BACKEND_CONTAINER" --format '{{.HostConfig.NetworkMode}}' 2>/dev/null)
	restart_policy=$(docker inspect "$BACKEND_CONTAINER" --format '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null)
	[ -z "$restart_policy" ] && restart_policy="unless-stopped"

	# Kumpulkan env lama (kecuali SMTP_* / VERIFY_URL / PAYPAL_* / MINIO_*) + env baru
	local env_args=()
	while IFS= read -r line; do
		[ -z "$line" ] && continue
		case "$line" in
			SMTP_*|VERIFY_URL=*|PAYPAL_*|MINIO_*) continue ;;
		esac
		env_args+=(-e "$line")
	done < <(docker inspect "$BACKEND_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null)

	env_args+=(
		-e "SMTP_HOST=${SMTP_HOST:-}"
		-e "SMTP_PORT=${SMTP_PORT:-587}"
		-e "SMTP_USER=${SMTP_USER:-}"
		-e "SMTP_PASSWORD=${SMTP_PASSWORD:-}"
		-e "SMTP_FROM=${SMTP_FROM:-}"
		-e "VERIFY_URL=${VERIFY_URL:-}"
		-e "PAYPAL_CLIENT_ID=${PAYPAL_CLIENT_ID:-}"
		-e "PAYPAL_SECRET=${PAYPAL_SECRET:-}"
		-e "PAYPAL_IS_PRODUCTION=${PAYPAL_IS_PRODUCTION:-false}"
		-e "PAYPAL_WEBHOOK_ID=${PAYPAL_WEBHOOK_ID:-}"
		-e "PAYPAL_CURRENCY=${PAYPAL_CURRENCY:-USD}"
		-e "PAYPAL_IDR_TO_USD_RATE=${PAYPAL_IDR_TO_USD_RATE:-0.000064}"
		-e "PAYPAL_RETURN_URL=${PAYPAL_RETURN_URL:-}"
		-e "PAYPAL_CANCEL_URL=${PAYPAL_CANCEL_URL:-}"
		-e "MINIO_ENDPOINT=${MINIO_ENDPOINT:-localhost:9000}"
		-e "MINIO_PUBLIC_URL=${MINIO_PUBLIC_URL:-}"
	)

	# Pastikan MinIO siap SEBELUM backend dibuat ulang.
	# Jika backend start saat MinIO belum siap, storage fallback ke NoOp
	# dan upload file mati sampai backend di-restart manual.
	if ! container_running "$MINIO_CONTAINER"; then
		ensure_container "$MINIO_CONTAINER" || return 1
	fi
	wait_for_port "localhost" "$MINIO_API_PORT" 30 2 || return 1

	echo "  Menghentikan container lama..."
	docker stop "$BACKEND_CONTAINER" >/dev/null 2>&1 || true
	docker rm "$BACKEND_CONTAINER" >/dev/null 2>&1 || true

	echo "  Membuat ulang container backend..."
	if ! docker run -d --name "$BACKEND_CONTAINER" \
		--network "$network" \
		--restart "$restart_policy" \
		-p "$BACKEND_PORT:$BACKEND_PORT" \
		"${env_args[@]}" \
		"$BACKEND_IMAGE" >/dev/null 2>&1; then
		err "Gagal membuat ulang container $BACKEND_CONTAINER"
		return 1
	fi
	ok "Container dibuat ulang (SMTP: ${SMTP_HOST:-belum diisi}, PayPal: ${PAYPAL_CLIENT_ID:+terkonfigurasi})"
	return 0
}

ensure_backend_env() {
	if ! container_running "$BACKEND_CONTAINER"; then
		err "Backend tidak berjalan, skip cek SMTP/PayPal"
		return 1
	fi
	local smtp_ok=1 paypal_ok=1
	backend_smtp_configured && smtp_ok=0
	backend_paypal_configured && paypal_ok=0

	if [ "$smtp_ok" -eq 0 ] && [ "$paypal_ok" -eq 0 ]; then
		local host
		host=$(docker exec "$BACKEND_CONTAINER" env | grep "^SMTP_HOST=" | cut -d= -f2)
		ok "SMTP terkonfigurasi ($host), PayPal terkonfigurasi"
		return 0
	fi

	if [ -f "$SMTP_ENV_FILE" ] || [ -f "$BACKEND_ENV_FILE" ]; then
		echo "  Env SMTP/PayPal belum lengkap di container, menerapkan dari file env..."
		apply_backend_env || return 1
		wait_for_port "localhost" "$BACKEND_PORT" 40 2 || return 1
	else
		err "SMTP/PayPal belum dikonfigurasi. Jalankan: ./surveyku-server.sh setup-smtp / setup-paypal"
		return 1
	fi
}

do_setup_smtp() {
	log "📧 Setup SMTP Email Service"
	echo ""
	echo "Masukkan konfigurasi SMTP (Enter untuk memakai default):"
	read -rp "  SMTP Host [smtp.gmail.com]: " SMTP_HOST
	SMTP_HOST=${SMTP_HOST:-smtp.gmail.com}
	read -rp "  SMTP Port [587]: " SMTP_PORT
	SMTP_PORT=${SMTP_PORT:-587}
	read -rp "  SMTP User (email pengirim): " SMTP_USER
	read -rsp "  SMTP Password (App Password): " SMTP_PASSWORD
	echo ""
	read -rp "  SMTP From [${SMTP_USER:-noreply@surveyku.com}]: " SMTP_FROM
	SMTP_FROM=${SMTP_FROM:-${SMTP_USER:-noreply@surveyku.com}}
	read -rp "  Verify URL [https://admin-survey.whyrtch.online/verify-email]: " VERIFY_URL
	VERIFY_URL=${VERIFY_URL:-https://admin-survey.whyrtch.online/verify-email}

	if [ -z "$SMTP_USER" ]; then
		err "SMTP User wajib diisi"
		return 1
	fi

	cat > "$SMTP_ENV_FILE" <<EOF
SMTP_HOST=$SMTP_HOST
SMTP_PORT=$SMTP_PORT
SMTP_USER=$SMTP_USER
SMTP_PASSWORD=$SMTP_PASSWORD
SMTP_FROM=$SMTP_FROM
VERIFY_URL=$VERIFY_URL
EOF
	chmod 600 "$SMTP_ENV_FILE"
	ok "Konfigurasi disimpan ke $SMTP_ENV_FILE"

	apply_backend_env || return 1
	echo ""
	log "Selesai. Verifikasi dengan: ./surveyku-server.sh status"
}

do_setup_paypal() {
	log "💳 Setup PayPal Payment"
	echo ""
	echo "Masukkan konfigurasi PayPal (kosongkan untuk melewati):"
	read -rp "  PayPal Client ID: " PAYPAL_CLIENT_ID
	read -rsp "  PayPal Secret: " PAYPAL_SECRET
	echo ""
	read -rp "  Production? (true/false) [false]: " PAYPAL_IS_PRODUCTION
	PAYPAL_IS_PRODUCTION=${PAYPAL_IS_PRODUCTION:-false}
	read -rp "  Webhook ID [kosong]: " PAYPAL_WEBHOOK_ID
	read -rp "  Currency [USD]: " PAYPAL_CURRENCY
	PAYPAL_CURRENCY=${PAYPAL_CURRENCY:-USD}
	read -rp "  IDR to USD rate [0.000064]: " PAYPAL_IDR_TO_USD_RATE
	PAYPAL_IDR_TO_USD_RATE=${PAYPAL_IDR_TO_USD_RATE:-0.000064}
	read -rp "  Return URL [https://admin-survey.whyrtch.online/order/success]: " PAYPAL_RETURN_URL
	PAYPAL_RETURN_URL=${PAYPAL_RETURN_URL:-https://admin-survey.whyrtch.online/order/success}
	read -rp "  Cancel URL [https://admin-survey.whyrtch.online/order/cancel]: " PAYPAL_CANCEL_URL
	PAYPAL_CANCEL_URL=${PAYPAL_CANCEL_URL:-https://admin-survey.whyrtch.online/order/cancel}

	if [ -z "$PAYPAL_CLIENT_ID" ] || [ -z "$PAYPAL_SECRET" ]; then
		err "Client ID dan Secret wajib diisi"
		return 1
	fi

	# Backup file lama untuk mempertahankan var non-PayPal (mis. MINIO_*)
	if [ -f "$BACKEND_ENV_FILE" ]; then
		cp "$BACKEND_ENV_FILE" "$BACKEND_ENV_FILE.old"
	fi
	cat > "$BACKEND_ENV_FILE" <<EOF
PAYPAL_CLIENT_ID=$PAYPAL_CLIENT_ID
PAYPAL_SECRET=$PAYPAL_SECRET
PAYPAL_IS_PRODUCTION=$PAYPAL_IS_PRODUCTION
PAYPAL_WEBHOOK_ID=$PAYPAL_WEBHOOK_ID
PAYPAL_CURRENCY=$PAYPAL_CURRENCY
PAYPAL_IDR_TO_USD_RATE=$PAYPAL_IDR_TO_USD_RATE
PAYPAL_RETURN_URL=$PAYPAL_RETURN_URL
PAYPAL_CANCEL_URL=$PAYPAL_CANCEL_URL
EOF
	# Pertahankan var non-PayPal yang sudah ada (mis. MINIO_*) dari file lama
	if [ -f "$BACKEND_ENV_FILE.old" ]; then
		grep -E "^(MINIO_|SMTP_|VERIFY_URL)" "$BACKEND_ENV_FILE.old" >> "$BACKEND_ENV_FILE" 2>/dev/null || true
		rm -f "$BACKEND_ENV_FILE.old"
	fi
	chmod 600 "$BACKEND_ENV_FILE"
	ok "Konfigurasi disimpan ke $BACKEND_ENV_FILE"

	apply_backend_env || return 1
	echo ""
	log "Selesai. Verifikasi dengan: ./surveyku-server.sh status"
}

do_start() {
	log "🚀 Memulai SurveyKu Server..."
	echo ""

	check_docker
	ok "Docker daemon aktif"

	log "1. PostgreSQL ($POSTGRES_CONTAINER)"
	ensure_container "$POSTGRES_CONTAINER" || return 1
	if container_running "$POSTGRES_CONTAINER"; then
		echo "  Menunggu PostgreSQL siap..."
		local pg_ready=0
		for i in $(seq 1 30); do
			if docker exec "$POSTGRES_CONTAINER" pg_isready -U hermes 2>/dev/null; then
				pg_ready=1
				break
			fi
			sleep 2
		done
		[ "$pg_ready" -eq 1 ] && ok "PostgreSQL siap" || err "PostgreSQL belum siap"
	fi
	echo ""

	log "2. Redis ($REDIS_CONTAINER)"
	ensure_container "$REDIS_CONTAINER" || return 1
	echo ""

	log "3. MinIO ($MINIO_CONTAINER)"
	ensure_container "$MINIO_CONTAINER" || return 1
	if container_running "$MINIO_CONTAINER"; then
		wait_for_port "localhost" "$MINIO_API_PORT" 30 2 || return 1
		wait_for_port "localhost" "$MINIO_CONSOLE_PORT" 30 2 || return 1
	fi
	echo ""

	log "4. Backend ($BACKEND_CONTAINER, port $BACKEND_PORT)"
	ensure_container "$BACKEND_CONTAINER" || return 1
	if container_running "$BACKEND_CONTAINER"; then
		# Backend yang start saat MinIO belum siap akan memakai NoOp storage
		# (upload file mati). Deteksi dan restart otomatis setelah MinIO siap.
		ensure_backend_storage || return 1
		wait_for_port "localhost" "$BACKEND_PORT" 40 2 || return 1
	fi
	echo ""

	log "5. Email Service (SMTP) & Payment (PayPal)"
	ensure_backend_env || true
	echo ""

	log "6. Web (port $WEB_PORT)"
	start_web || return 1
	echo ""

	log "7. Cloudflared Tunnel"
	start_cloudflared || true
	echo ""

	verify_endpoints || true
	check_restart_loops

	echo ""
	log "========================================="
	log "✅ SurveyKu Server Siap"
	log "========================================="
	echo "   Backend  → http://localhost:$BACKEND_PORT"
	echo "   Web      → http://localhost:$WEB_PORT"
	echo "   MinIO    → http://localhost:$MINIO_CONSOLE_PORT (console)"
	echo "   Tunnel   → https://survey.whyrtch.online (backend)"
	echo "              https://admin-survey.whyrtch.online (web)"
	echo ""
	echo "   Logs:"
	echo "     Web:     tail -f $WEB_LOG"
	echo "     Backend: docker logs -f $BACKEND_CONTAINER"
	echo ""
}

do_stop() {
	log "🛑 Mematikan SurveyKu Server..."
	stop_web
	for name in "$BACKEND_CONTAINER" "$MINIO_CONTAINER" "$REDIS_CONTAINER"; do
		if container_running "$name"; then
			docker stop "$name" >/dev/null 2>&1 && ok "$name stopped"
		fi
	done
	# PostgreSQL dibiarkan jalan (dipakai bersama immich)
	echo ""
	log "PostgreSQL ($POSTGRES_CONTAINER) dibiarkan jalan."
	log "Cloudflared user service dibiarkan jalan."
	echo ""
	log "Semua service SurveyKu dihentikan."
}

do_status() {
	echo "===== SurveyKu Server Status ====="
	echo ""

	log "Docker daemon"
	if timeout 5 docker info &>/dev/null 2>&1; then
		ok "aktif"
	else
		err "tidak aktif"
	fi
	echo ""

	log "Containers"
	for name in "$POSTGRES_CONTAINER" "$REDIS_CONTAINER" "$MINIO_CONTAINER" "$BACKEND_CONTAINER"; do
		if container_running "$name"; then
			ok "$name berjalan"
		elif container_exists "$name"; then
			err "$name ada tapi tidak berjalan"
		else
			err "$name tidak ada"
		fi
	done
	echo ""

	log "Backend storage (MinIO)"
	if container_running "$BACKEND_CONTAINER"; then
		if backend_using_noop_storage; then
			err "NoOp storage (upload file mati). Jalankan: ./surveyku-server.sh restart"
		else
			ok "MinIO storage aktif"
		fi
	else
		err "Backend tidak berjalan"
	fi
	echo ""

	log "Web (port $WEB_PORT)"
	if [ -f "$WEB_PID_FILE" ] && kill -0 "$(cat "$WEB_PID_FILE")" 2>/dev/null; then
		ok "Web berjalan (PID: $(cat "$WEB_PID_FILE"))"
	elif pgrep -f "next dev" >/dev/null 2>&1; then
		ok "Web berjalan (PID: $(pgrep -f 'next dev' | head -1))"
	else
		err "Web tidak berjalan"
	fi
	echo ""

	log "Cloudflared Tunnel"
	if systemctl --user is-active cloudflared &>/dev/null; then
		ok "User service aktif"
	else
		err "User service tidak berjalan"
	fi
	echo ""

	log "Email Service (SMTP) & Payment (PayPal)"
	if container_running "$BACKEND_CONTAINER" && backend_smtp_configured && backend_paypal_configured; then
		local smtp_host
		smtp_host=$(docker exec "$BACKEND_CONTAINER" env | grep "^SMTP_HOST=" | cut -d= -f2)
		ok "SMTP terkonfigurasi ($smtp_host), PayPal terkonfigurasi"
	elif container_running "$BACKEND_CONTAINER" && backend_smtp_configured; then
		ok "SMTP terkonfigurasi, PayPal BELUM (jalankan: ./surveyku-server.sh setup-paypal)"
	elif container_running "$BACKEND_CONTAINER" && backend_paypal_configured; then
		ok "PayPal terkonfigurasi, SMTP BELUM (jalankan: ./surveyku-server.sh setup-smtp)"
	elif [ -f "$SMTP_ENV_FILE" ] || [ -f "$BACKEND_ENV_FILE" ]; then
		err "File env ada tapi belum diterapkan ke container (jalankan: ./surveyku-server.sh restart)"
	else
		err "Belum dikonfigurasi (jalankan: ./surveyku-server.sh setup-smtp / setup-paypal)"
	fi
	echo ""

	check_restart_loops
	echo ""
}

do_fix_loops() {
	log "🔧 Memperbaiki restart loop (membutuhkan sudo)..."
	for svc in "${BROKEN_SERVICES[@]}"; do
		if systemctl is-active "$svc" &>/dev/null || systemctl is-enabled "$svc" &>/dev/null; then
			echo "  Disable $svc..."
			sudo systemctl disable --now "$svc" 2>&1 && ok "$svc disabled" || err "$svc gagal di-disable"
		else
			ok "$svc sudah nonaktif"
		fi
	done
	echo ""
	log "Selesai. Verifikasi dengan: ./surveyku-server.sh status"
}

case "${1:-start}" in
	start)
		do_start
		;;
	stop)
		do_stop
		;;
	restart)
		do_stop
		sleep 2
		do_start
		;;
	status)
		do_status
		;;
	fix-loops)
		do_fix_loops
		;;
	setup-smtp)
		do_setup_smtp
		;;
	setup-paypal)
		do_setup_paypal
		;;
	*)
		echo "Usage: $0 {start|stop|restart|status|fix-loops|setup-smtp|setup-paypal}"
		exit 1
		;;
esac