# plane-with-traefik

Chạy [Plane](https://plane.so) community edition **phía sau một Traefik có sẵn**.

Repo này cố ý giữ mức can thiệp nhỏ nhất: **không fork, không viết lại công cụ của
Plane**. Cài đặt, nâng cấp, backup vẫn do `setup.sh` chính chủ lo — Plane đổi gì thì
những việc đó tự đúng theo. Phần của repo chỉ là **một file override cho Traefik** và
**một file env chứa cấu hình riêng**, cộng một wrapper 30 dòng không có lệnh nào của
riêng nó.

## Ai làm việc gì

| Việc | Dùng | Vì sao |
|---|---|---|
| Cài đặt, nâng cấp, backup, xem log | **`setup.sh` của Plane** | Chính chủ duy trì, luôn đúng khi họ đổi |
| **Khởi động / dừng** | **`./plane.sh`** | `setup.sh` gọi compose bằng `-f docker-compose.yaml` tường minh nên **bỏ qua file override** — Plane sẽ đòi cổng 80/443 và đụng Traefik |

`./plane.sh` chuyển thẳng mọi tham số sang `docker compose`, không diễn giải gì:

```bash
./plane.sh up -d
./plane.sh ps
./plane.sh logs -f api
./plane.sh down
```

## Yêu cầu

- Docker + Docker Compose **v2.24 trở lên** (cần cú pháp `!override`)
- **Traefik đã chạy sẵn**, có network ngoài `proxy_net`, entrypoint `websecure`,
  certresolver `letsencrypt`. Tên khác thì sửa trong `docker-compose.override.yaml`.
- **DNS đã trỏ**: bản ghi A của domain chỉ về máy này, trước khi chạy — nếu không
  Let's Encrypt sẽ không cấp được cert.
- RAM ≥ 4GB (8GB cho production), đĩa trống ≥ 20GB.

## Cài đặt

### 1. Lấy repo

```bash
git clone https://github.com/tranngocminhhieu/plane-with-traefik.git
cd plane-with-traefik
```

### 2. Điền cấu hình riêng

```bash
cp plane.local.env.example plane.local.env
chmod 600 plane.local.env

# sinh secret, dán vào 6 dòng còn trống
for i in 1 2; do openssl rand -hex 32; done; for i in 1 2; do openssl rand -hex 16; done
```

Mở `plane.local.env`, sửa `APP_DOMAIN` thành domain của bạn và điền đủ secret.
Không phải sửa gì trong `docker-compose.override.yaml` — label Traefik đọc
`${APP_DOMAIN}` từ chính file này.

### 3. Để `setup.sh` của Plane tải file gốc

```bash
curl -fsSL -o setup.sh https://github.com/makeplane/plane/releases/latest/download/setup.sh
chmod +x setup.sh
./setup.sh          # chọn 1 (Install), rồi thoát menu
```

> ⚠ **Bước này luôn kết thúc bằng lỗi — cứ bỏ qua:**
> ```
> plane-minio Error pull access denied for minio/minio, repository does not exist
> Failed to pull the images. Exiting...
> ```
> `setup.sh` pull bằng file gốc nên vẫn trỏ vào image MinIO đã bị gỡ khỏi Docker Hub.
> Không sao: `docker-compose.yaml` và `plane.env` đã ghi xong **trước** bước pull, và
> `./plane.sh up -d` sẽ pull lại bằng image đúng. Kiểm tra:
> `ls plane-app/docker-compose.yaml plane-app/plane.env`

### 4. Khởi động

```bash
./plane.sh up -d
./plane.sh logs -f migrator     # chờ migration xong rồi Ctrl-C
```

### 5. Tạo tài khoản quản trị

Mở `https://<domain>/god-mode/`, tạo **Instance Admin** (ai vào trước thì được), rồi:

- **Tắt `enable_signup`** nếu là hệ thống nội bộ — mặc định ai biết domain cũng tự đăng ký được
- **Cấu hình SMTP** — mặc định chưa có nên không mời được thành viên qua email, không dùng được magic link

## Nâng cấp và backup

Dùng menu của `setup.sh`:

```bash
./setup.sh          # 5 = Upgrade, 7 = Backup Data, 6 = View Logs
```

`Upgrade` dừng dịch vụ, tải file gốc bản mới rồi **dừng lại** ở đó (nó in
"PLEASE VALIDATE AND START SERVICES"). Khởi động lại bằng `./plane.sh up -d`.

> ⛔ **Đừng dùng 2 (Start), 3 (Stop), 4 (Restart)** — chúng bỏ qua file override.
> Dùng `./plane.sh up -d` / `./plane.sh down` / `./plane.sh restart`.

`Upgrade` ghi đè `plane.env` bằng bản mới. Không sao: cấu hình của bạn nằm trong
`plane.local.env` và được nạp sau nên vẫn thắng. Nhưng **nên xem `plane.env` bản mới**
xem Plane có thêm biến nào đáng quan tâm không.

## Cấu trúc

```
plane-with-traefik/
├── docker-compose.override.yaml      ← phần override cho Traefik
├── plane.local.env.example           ← mẫu cho cấu hình riêng
├── plane.sh                          ← wrapper 30 dòng, không có lệnh riêng
├── README.md  LICENSE  .gitignore
│
├── plane.local.env                   (secret của bạn — .gitignore)
├── setup.sh                          (của Plane — .gitignore)
└── plane-app/                        (của Plane, setup.sh tạo — .gitignore trọn gói)
    ├── docker-compose.yaml
    └── plane.env
```

**`plane.env` không bao giờ bị sửa.** Muốn đổi gì thì khai lại biến đó trong
`plane.local.env`; Compose nạp file sau đè file trước. Nhờ vậy `setup.sh` ghi đè
`plane.env` thoải mái mà cấu hình của bạn không mất.

## File override làm gì

**Một việc chính, vì Traefik:** gỡ publish cổng 80/443 của service `proxy`
(dùng `!override []`), gắn nó vào `proxy_net` kèm label router. Mặc định Plane tự
chiếm 80/443, đụng ngay với Traefik đang chạy. Giờ Traefik lo TLS, Caddy nội bộ của
Plane chỉ nghe HTTP trong mạng nội bộ.

**Một vá tạm, không liên quan Traefik:** đổi image MinIO sang `quay.io/minio/minio`.
Repo `minio/minio` trên Docker Hub đã bị gỡ nên file gốc **không pull được gì cả**.
Đây là chỗ duy nhất trong repo đi chệch khỏi nguyên tắc "không chế thêm", và nó tồn
tại chỉ vì file gốc đang hỏng. Kiểm tra định kỳ xem đã bỏ được chưa:

```bash
docker manifest inspect minio/minio:latest
```

Chạy được tức là Docker Hub đã có lại — xoá khối `plane-minio` trong file override.

## `plane.local.env` có gì

11 biến, đều là những biến **đã có sẵn** trong `plane.env` của Plane, chỉ khai lại
với giá trị khác:

- **domain** (3): `APP_DOMAIN`, `WEB_URL`, `CORS_ALLOWED_ORIGINS` — đổi sang `https`
  vì Traefik lo TLS
- **secret ứng dụng** (2): `SECRET_KEY`, `LIVE_SERVER_SECRET_KEY` — upstream để sẵn
  `change-this-key-on-deployment`
- **mật khẩu hạ tầng** (6): Postgres, RabbitMQ, MinIO — upstream mặc định `plane/plane`

Không có biến nào do repo này bịa ra.

## Data nằm ở đâu

Tất cả trong Docker named volume, **không** nằm trong thư mục repo:

| Volume | Chứa gì | Quan trọng |
|---|---|---|
| `plane-app_pgdata` | Postgres: project, issue, user, comment | ⭐ sống còn |
| `plane-app_uploads` | MinIO: file đính kèm, ảnh, avatar | ⭐ sống còn |
| `plane-app_rabbitmq_data`, `plane-app_redisdata` | hàng đợi, cache | mất vẫn chạy lại được |
| `plane-app_proxy_config`, `plane-app_proxy_data` | Caddy nội bộ | không cần (cert do Traefik giữ) |
| `plane-app_logs_*` | log | không cần |

Tiền tố `plane-app` là tên compose project mặc định, lấy từ thư mục `plane-app/`.
Repo này **cố ý không đặt `COMPOSE_PROJECT_NAME`**: đổi nó thì lệnh Backup và View
Logs của `setup.sh` không tìm thấy container nữa. Hệ quả là **một máy chạy một bản
Plane**; muốn bản thứ hai thì phải tự đặt tên project và tên router khác, và chấp
nhận mất tương thích với `setup.sh`.

`./plane.sh down` giữ nguyên volume. `docker compose down -v` thì **xoá sạch**.

Chạy production lâu dài nên trỏ `DATABASE_URL` sang Postgres ngoài và `AWS_S3_*` sang
S3 thật (khai đè trong `plane.local.env`), thay vì để trong volume local.

## Giấy phép

MIT — xem [LICENSE](LICENSE). Repo này chỉ là lớp cấu hình; bản thân Plane theo giấy
phép riêng của [makeplane/plane](https://github.com/makeplane/plane).
