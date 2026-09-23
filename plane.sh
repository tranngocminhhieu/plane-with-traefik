#!/usr/bin/env bash
# plane.sh — chuyển thẳng mọi lệnh sang docker compose, kèm đủ cờ để nạp file
# override và env riêng. KHÔNG có lệnh nào của riêng script này.
#
#   ./plane.sh up -d
#   ./plane.sh ps
#   ./plane.sh logs -f api
#   ./plane.sh down
#   ...bất kỳ lệnh docker compose nào, cờ giữ nguyên như tài liệu Docker.
#
# Vì sao cần: Compose chỉ tự tìm file tên .env, không biết plane.env, nên gõ
# `docker compose up -d` trần là rơi về mật khẩu mặc định plane:plane và không
# vào được DB. Script chỉ ghép cờ, không diễn giải lệnh — nhà phát triển Plane
# hay Docker đổi gì thì nó vẫn đúng.
#
# Cài đặt, nâng cấp, backup: dùng setup.sh của Plane (xem README).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$ROOT/plane-app"

[ -f "$APP_DIR/docker-compose.yaml" ] || { echo "✗ thiếu plane-app/docker-compose.yaml — chạy ./setup.sh chọn 1 (Install)" >&2; exit 1; }
[ -f "$ROOT/plane.local.env" ]        || { echo "✗ thiếu plane.local.env — chép từ plane.local.env.example" >&2; exit 1; }

# plane.env là bản gốc của Plane, không sửa. plane.local.env nạp sau nên đè lên.
# Thứ tự hai cờ --env-file là quan trọng, đừng đảo.
exec docker compose \
  --project-directory "$APP_DIR" \
  -f "$APP_DIR/docker-compose.yaml" \
  -f "$ROOT/docker-compose.override.yaml" \
  --env-file "$APP_DIR/plane.env" \
  --env-file "$ROOT/plane.local.env" \
  "$@"
