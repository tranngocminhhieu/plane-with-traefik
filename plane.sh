#!/usr/bin/env bash
# plane.sh — cửa ngõ duy nhất để vận hành Plane self-host sau Traefik.
#
# Vì sao cần: stack chạy bằng 2 compose file và 2 env file. Gõ `docker compose
# up -d` trần thì Compose không nạp plane.env (nó chỉ tự tìm .env), rơi về mật
# khẩu mặc định plane:plane và không vào được DB. Script chỉ ghép đủ cờ.
#
#   ./plane.sh init <domain> [tên-instance]   # lần đầu: sinh cấu hình + tải file gốc
#   ./plane.sh up | down | restart | ps | logs [service] | pull | config
#   ./plane.sh backup [thư-mục]     # dump DB + uploads + config
#   ./plane.sh upgrade v1.5.0       # tải file gốc bản mới rồi khởi động lại
#   ./plane.sh <lệnh docker compose bất kỳ>
#
# Lần đầu cài: ./plane.sh init <domain> rồi ./plane.sh up. Chi tiết trong README.md.
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
  [ -f "$APP_DIR/docker-compose.yaml" ] || die "thiếu plane-app/docker-compose.yaml — chạy: ./plane.sh init <domain>"
  [ -f "$APP_DIR/plane.env" ]           || die "thiếu plane-app/plane.env — chạy: ./plane.sh init <domain>"
  [ -f "$ROOT/plane.local.env" ]        || die "thiếu plane.local.env — chạy: ./plane.sh init <domain>"

  # Thiếu COMPOSE_PROJECT_NAME thì Compose lấy tên thư mục "plane-app" làm tên
  # project. Hai bản Plane trên cùng máy sẽ trùng tên và bản chạy sau CHIẾM LUÔN
  # container của bản trước. Tên router Traefik cũng lấy từ biến này, để trống là
  # label thành "traefik.http.routers..rule" và Traefik bỏ qua.
  grep -qE '^PLANE_INSTANCE=.+' "$ROOT/plane.local.env" \
    || die "plane.local.env chưa đặt PLANE_INSTANCE — xem plane.local.env.example"
}

latest_release() {
  curl -fsSL "https://api.github.com/repos/$GH_REPO/releases/latest" \
    | grep -o '"tag_name": "[^"]*"' | sed 's/.*: "//;s/"//'
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

  [ -f "$APP_DIR/docker-compose.yaml" ] && cp "$APP_DIR/docker-compose.yaml" "$APP_DIR/archive/$ts.docker-compose.yaml"
  [ -f "$APP_DIR/plane.env" ]           && cp "$APP_DIR/plane.env"           "$APP_DIR/archive/$ts.env"
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
  init)
    domain="${1:-}"
    [ -n "$domain" ] || die "cần domain, ví dụ: ./plane.sh init ticket.example.com"
    [[ "$domain" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] \
      || die "domain không hợp lệ: $domain"
    # Tên instance mặc định lấy nhãn đầu của domain, đủ gợi nhớ mà vẫn khác nhau
    # giữa các bản trên cùng một máy.
    instance="${2:-$(echo "${domain%%.*}" | tr -cd 'a-z0-9-')}"
    [ -n "$instance" ] || die "tên instance rỗng — truyền tay: ./plane.sh init $domain <tên>"

    # ── Chốt an toàn ─────────────────────────────────────────────────────────
    # Ghi đè plane.local.env là xoá mất secret mà Postgres/MinIO đã khởi tạo theo.
    # Stack sẽ không vào được DB nữa và data coi như mất. Không bao giờ ghi đè.
    [ -f "$ROOT/plane.local.env" ] \
      && die "plane.local.env đã tồn tại — xoá tay nếu thực sự muốn làm lại (MẤT DATA của stack cũ)"

    # Trùng tên project là bản mới CHIẾM container của bản đang chạy.
    if docker compose ls --format json 2>/dev/null | grep -q "\"Name\":\"$instance\""; then
      die "đã có compose project tên '$instance' trên máy này — chọn tên khác: ./plane.sh init $domain <tên-khác>"
    fi

    echo "→ instance : $instance"
    echo "→ domain   : $domain"

    # DNS sai thì Let's Encrypt không cấp được cert. Cảnh báo thôi, không chặn:
    # có người trỏ DNS sau, hoặc chạy sau một lớp proxy khác.
    host_ip="$(curl -fsS --max-time 8 https://ifconfig.me 2>/dev/null || echo '')"
    # || true bắt buộc: pipefail + getent trả mã 2 khi domain chưa phân giải được,
    # không chặn thì set -e giết cả script ngay tại bước cảnh báo.
    dns_ip="$(getent hosts "$domain" | awk '{print $1; exit}' || true)"
    if [ -z "$dns_ip" ]; then
      echo "⚠ $domain chưa phân giải được — Let's Encrypt sẽ KHÔNG cấp cert cho tới khi bạn trỏ DNS."
    elif [ -n "$host_ip" ] && [ "$dns_ip" != "$host_ip" ]; then
      echo "⚠ $domain đang trỏ về $dns_ip, không phải máy này ($host_ip) — cert sẽ fail."
    else
      echo "✓ DNS đã trỏ đúng về máy này"
    fi

    # ── Sinh cấu hình ────────────────────────────────────────────────────────
    command -v openssl >/dev/null || die "cần openssl để sinh secret"
    # umask trong subshell để nó chỉ ảnh hưởng file secret này, không lây sang
    # thư mục plane-app tạo sau đó (bị 700 thì user khác không đọc được file gốc).
    ( umask 077
      sed -e "s|^PLANE_INSTANCE=.*|PLANE_INSTANCE=$instance|" \
          -e "s|^APP_DOMAIN=.*|APP_DOMAIN=$domain|" \
          -e "s|^SECRET_KEY=.*|SECRET_KEY=$(openssl rand -hex 32)|" \
          -e "s|^LIVE_SERVER_SECRET_KEY=.*|LIVE_SERVER_SECRET_KEY=$(openssl rand -hex 32)|" \
          -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$(openssl rand -hex 16)|" \
          -e "s|^RABBITMQ_PASSWORD=.*|RABBITMQ_PASSWORD=$(openssl rand -hex 16)|" \
          -e "s|^AWS_ACCESS_KEY_ID=.*|AWS_ACCESS_KEY_ID=plane-$(openssl rand -hex 6)|" \
          -e "s|^AWS_SECRET_ACCESS_KEY=.*|AWS_SECRET_ACCESS_KEY=$(openssl rand -hex 20)|" \
          "$ROOT/plane.local.env.example" > "$ROOT/plane.local.env" )
    chmod 600 "$ROOT/plane.local.env"
    echo "✓ đã tạo plane.local.env (secret sinh ngẫu nhiên, chmod 600)"

    # ── Tải file gốc của Plane ───────────────────────────────────────────────
    # Làm thẳng bằng curl thay vì gọi setup.sh: setup.sh pull bằng file gốc nên
    # luôn chết ở image minio/minio đã bị gỡ khỏi Docker Hub, gây hoang mang vô ích.
    release="${PLANE_RELEASE:-$(latest_release)}"
    echo "→ bản Plane: $release"
    mkdir -p "$APP_DIR"
    fetch_upstream "$release"

    echo
    echo "Xong. Chạy tiếp:  ./plane.sh up"
    ;;

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
