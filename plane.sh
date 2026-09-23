#!/usr/bin/env bash
# plane.sh — cửa ngõ duy nhất để vận hành Plane self-host sau Traefik.
#
# Vì sao cần: stack chạy bằng 2 compose file và 2 env file. Gõ `docker compose
# up -d` trần thì Compose không nạp plane.env (nó chỉ tự tìm .env), rơi về mật
# khẩu mặc định plane:plane và không vào được DB. Script chỉ ghép đủ cờ.
#
#   ./plane.sh up | down | restart | ps | logs [service] | pull | config
#   ./plane.sh backup [thư-mục]     # dump DB + uploads + config
#   ./plane.sh upgrade v1.5.0       # tải file gốc bản mới rồi khởi động lại
#   ./plane.sh <lệnh docker compose bất kỳ>
#
# Lần đầu cài: làm theo Bước 0–5 trong README.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$ROOT/plane-app"
GH_REPO="makeplane/plane"

# plane.env là bản GỐC của Plane, không sửa. plane.local.env là phần mình chế,
# nạp sau nên đè lên. Thứ tự hai cờ --env-file là quan trọng, đừng đảo.
compose() {
  docker compose \
    --project-directory "$APP_DIR" \
    -f "$APP_DIR/docker-compose.yaml" \
    -f "$ROOT/docker-compose.override.yaml" \
    --env-file "$APP_DIR/plane.env" \
    --env-file "$ROOT/plane.local.env" \
    "$@"
}

die() { echo "✗ $*" >&2; exit 1; }

require_files() {
  [ -f "$APP_DIR/docker-compose.yaml" ] || die "thiếu plane-app/docker-compose.yaml — chạy ./setup.sh chọn 1 (Bước 1–3 trong README)"
  [ -f "$APP_DIR/plane.env" ]           || die "thiếu plane-app/plane.env — chạy ./setup.sh chọn 1 (Bước 1–3 trong README)"
  [ -f "$ROOT/plane.local.env" ]        || die "thiếu plane.local.env — chép từ plane.local.env.example (Bước 0 trong README)"

  # Thiếu COMPOSE_PROJECT_NAME thì Compose lấy tên thư mục "plane-app" làm tên
  # project. Hai bản Plane trên cùng máy sẽ trùng tên và bản chạy sau CHIẾM LUÔN
  # container của bản trước. Tên router Traefik cũng lấy từ biến này, để trống là
  # label thành "traefik.http.routers..rule" và Traefik bỏ qua.
  grep -qE '^PLANE_INSTANCE=.+' "$ROOT/plane.local.env" \
    || die "plane.local.env chưa đặt PLANE_INSTANCE (xem Bước 0 trong README)"
}

# Tải file gốc của một release về plane-app. Bản cũ lùi vào archive/ chứ không đè
# thẳng, để còn đường quay lại khi bản mới đổi biến.
fetch_upstream() {
  local release="$1" ts base tmp_compose tmp_env
  ts="$(date +%s)"
  base="https://github.com/$GH_REPO/releases/download/$release"
  mkdir -p "$APP_DIR/archive"
  tmp_compose="$(mktemp)"; tmp_env="$(mktemp)"

  echo "→ tải docker-compose.yml của $release"
  curl -fsSL "$base/docker-compose.yml" -o "$tmp_compose" \
    || die "không tải được $base/docker-compose.yml (sai tag release?)"
  echo "→ tải variables.env của $release"
  curl -fsSL "$base/variables.env" -o "$tmp_env" \
    || die "không tải được $base/variables.env"

  cp "$APP_DIR/docker-compose.yaml" "$APP_DIR/archive/$ts.docker-compose.yaml"
  cp "$APP_DIR/plane.env"           "$APP_DIR/archive/$ts.env"
  mv "$tmp_compose" "$APP_DIR/docker-compose.yaml"
  mv "$tmp_env"     "$APP_DIR/plane.env"
  echo "✓ đã cập nhật file gốc (bản cũ ở archive/$ts.*)"
}

# Biến mà bản mới có thêm thì không sao, nó rơi về mặc định. Ngược lại mới nguy:
# biến mình đang đè mà upstream đã bỏ — override thành vô nghĩa, không ai báo.
check_drift() {
  local orphan=() key
  while IFS= read -r key; do
    # PLANE_INSTANCE/COMPOSE_PROJECT_NAME là biến điều khiển của riêng repo này,
    # plane.env gốc không có và sẽ không bao giờ có — bỏ qua, đừng báo nhầm.
    case "$key" in PLANE_INSTANCE|COMPOSE_PROJECT_NAME) continue ;; esac
    grep -qE "^${key}=" "$APP_DIR/plane.env" || orphan+=("$key")
  done < <(grep -oE '^[A-Z_0-9]+=' "$ROOT/plane.local.env" | tr -d '=')

  if [ "${#orphan[@]}" -gt 0 ]; then
    echo "⚠ plane.local.env đang đè biến mà plane.env bản mới KHÔNG còn: ${orphan[*]}"
    echo "  Kiểm tra xem Plane đã đổi tên hay bỏ hẳn biến này."
  fi
}

cmd="${1:-help}"; shift || true

case "$cmd" in
  up)
    require_files
    compose pull
    compose up -d
    echo
    compose ps --format '{{.Name}}\t{{.Status}}'
    echo
    echo "Migration chạy nền vài phút — theo dõi: ./plane.sh logs migrator"
    ;;

  down)     require_files; compose down ;;          # giữ nguyên volume, data an toàn
  restart)  require_files; compose restart "$@" ;;
  ps)       require_files; compose ps --format '{{.Name}}\t{{.Status}}' ;;
  logs)     require_files; compose logs -f --tail=100 "$@" ;;
  pull)     require_files; compose pull ;;
  config)   require_files; compose config ;;

  upgrade)
    require_files
    [ $# -ge 1 ] || die "cần tag release, ví dụ: ./plane.sh upgrade v1.5.0"
    echo "⚠ Backup trước đã: ./plane.sh backup"
    fetch_upstream "$1"
    check_drift
    compose pull
    compose up -d
    echo "✓ xong — theo dõi migration: ./plane.sh logs migrator"
    ;;

  backup)
    require_files
    out="${1:-$ROOT/backups}"
    mkdir -p "$out"
    stamp="$(date +%F-%H%M)"
    echo "→ dump Postgres"
    # Lấy mật khẩu từ chính env của container thay vì hardcode, để đổi mật khẩu
    # trong plane.local.env là backup vẫn chạy. pg_dump hỏi mật khẩu qua PGPASSWORD.
    compose exec -T plane-db sh -c \
      'PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB"' \
      | gzip > "$out/plane-db-$stamp.sql.gz"
    echo "→ đóng gói file đính kèm (MinIO)"
    docker run --rm -v plane-app_uploads:/d:ro -v "$out:/b" alpine \
      tar czf "/b/plane-uploads-$stamp.tar.gz" -C /d .
    echo "→ giữ luôn cấu hình (có secret — bảo quản như mật khẩu)"
    tar czf "$out/plane-config-$stamp.tar.gz" \
      -C "$APP_DIR" plane.env docker-compose.yaml \
      -C "$ROOT"    plane.local.env docker-compose.override.yaml
    ls -lh "$out"/*"$stamp"*
    ;;

  help|-h|--help)
    # in khối chú thích đầu file, dừng ở dòng đầu tiên không phải comment
    awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "${BASH_SOURCE[0]}"
    ;;

  *)
    require_files
    compose "$cmd" "$@"
    ;;
esac
