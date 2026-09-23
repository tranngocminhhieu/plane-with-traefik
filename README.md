# plane-with-traefik

Deploy [Plane](https://plane.so) community edition **phía sau một Traefik có sẵn**.

Repo này **không fork, không sửa** file nào của Plane. Mọi thứ của nhà phát triển
gốc (`setup.sh`, `docker-compose.yaml`, `plane.env`) được tải mới ở thời điểm
deploy và giữ nguyên xi. Phần riêng của mình gói gọn trong **2 file override**:

```
plane-with-traefik/
├── README.md
├── LICENSE
├── .gitignore
├── plane.sh                          ← wrapper, xem "Vì sao cần plane.sh"
├── docker-compose.override.yaml      ← 1. đè phần mạng/cổng/image
├── plane.local.env.example           ← 2. mẫu cho biến riêng
│
├── plane.local.env                   (secret của bạn — .gitignore)
└── plane-app/                        (100% của Plane, setup.sh tạo — .gitignore trọn gói)
    ├── docker-compose.yaml
    └── plane.env
```

Thư mục `plane-app/` thuộc về `setup.sh`, repo này không đụng vào và cũng không
giữ bản sao nào của nó. Mọi thứ của mình nằm ở thư mục gốc.

Nguyên tắc: **`plane.env` không bao giờ bị sửa.** Muốn đổi gì thì khai lại biến đó
trong `plane.local.env`. Nhờ vậy nâng cấp Plane chỉ là tải đè `plane.env` bản mới,
cấu hình của bạn không mất và cũng không lẫn vào file gốc.

## Hai file override làm gì

**`docker-compose.override.yaml`** sửa đúng 2 chỗ:

1. **Gỡ publish cổng 80/443** của service `proxy` (dùng `!override []`) rồi gắn nó
   vào network `proxy_net` kèm label Traefik, với rule `Host(${APP_DOMAIN})` và tên
   router `${COMPOSE_PROJECT_NAME}` đều đọc từ env file. Mặc định Plane tự chiếm 80/443, đụng ngay với Traefik đang chạy. Giờ
   Traefik lo TLS, Caddy nội bộ của Plane chỉ nghe HTTP trong mạng nội bộ.
2. **Đổi image MinIO sang quay.io.** Repo `minio/minio` trên Docker Hub đã bị gỡ —
   bản gốc của Plane pull nó sẽ chết với `pull access denied ... repository does
   not exist`. Image chính chủ giờ ở `quay.io/minio/minio`, và đã pin theo release
   thay vì `latest`.

**`plane.local.env`** chỉ chứa 11 biến thực sự khác bản gốc: domain (3 biến),
secret ứng dụng (2), mật khẩu Postgres / RabbitMQ / MinIO (6).

## Yêu cầu trước khi bắt đầu

- Docker + Docker Compose v2.24 trở lên (cần cú pháp `!override`)
- **Traefik đã chạy sẵn**, có network ngoài tên `proxy_net`, một entrypoint
  `websecure` và một certresolver `letsencrypt`. Tên khác thì sửa label trong
  `docker-compose.override.yaml`.
- **DNS đã trỏ**: bản ghi A của domain chỉ về IP máy này, trước khi chạy — nếu không
  Let's Encrypt sẽ không cấp được cert.
- RAM ≥ 4GB (8GB cho production), đĩa trống ≥ 20GB.

---

## Bước 0 — Điền domain và secret

```bash
cp plane.local.env.example plane.local.env
chmod 600 plane.local.env

# sinh secret, dán vào 6 dòng còn trống trong file
for i in 1 2; do openssl rand -hex 32; done; for i in 1 2; do openssl rand -hex 16; done
```

Mở `plane.local.env` và điền:

- **`PLANE_INSTANCE`** (và `COMPOSE_PROJECT_NAME` bằng nó) — tên instance, quyết định tiền tố container/volume
  **và tên router Traefik**. Một máy chạy nhiều bản Plane thì mỗi bản một tên khác
  nhau; trùng tên là bản chạy sau chiếm luôn container của bản trước.
- **`APP_DOMAIN`** — domain của bạn.
- 6 dòng secret còn trống.

Không phải sửa gì trong `docker-compose.override.yaml`: cả domain lẫn tên router
đều đọc biến từ file này.

## Bước 1 — Tải bộ cài của Plane

```bash
curl -fsSL -o setup.sh https://github.com/makeplane/plane/releases/latest/download/setup.sh
```

## Bước 2 — Cho phép chạy

```bash
chmod +x setup.sh
```

## Bước 3 — Sinh file gốc

```bash
./setup.sh
```

Chọn **`1` (Install)**, rồi **thoát menu**. Bước này chỉ tải `docker-compose.yaml`
và `plane.env` vào `plane-app/`, không đụng tới hai file override của bạn.

> ⚠ **Bước này sẽ kết thúc bằng lỗi — đúng như dự kiến, cứ bỏ qua:**
> ```
> plane-minio Error pull access denied for minio/minio, repository does not exist
> Failed to pull the images. Exiting...
> ```
> `setup.sh` pull bằng file gốc nên vẫn trỏ vào `minio/minio` đã bị gỡ khỏi Docker
> Hub. Không sao: hai file gốc đã được ghi xong **trước** bước pull, và `./plane.sh up`
> ở Bước 4 sẽ pull lại bằng image quay.io trong file override. Kiểm tra nhanh:
> `ls plane-app/docker-compose.yaml plane-app/plane.env`

> ⛔ **Đừng dùng tiếp menu Start / Restart / Stop của `setup.sh`.** Script gọi
> compose bằng `-f docker-compose.yaml` tường minh nên **bỏ qua file override** —
> Plane sẽ lại đòi cổng 80/443 và đụng Traefik. Từ đây trở đi chỉ dùng `./plane.sh`.

## Bước 4 — Khởi động

```bash
./plane.sh up
```

Lệnh này pull image rồi `up -d` với đủ 2 compose file và 2 env file. Migration DB
chạy nền vài phút; theo dõi bằng `./plane.sh logs migrator` cho tới khi container
`migrator` thoát với mã 0.

## Bước 5 — Tạo tài khoản quản trị

Mở `https://<domain>/god-mode/` và tạo **Instance Admin** đầu tiên. Ai vào trước
thì được, nên làm ngay.

Sau đó trong `/god-mode/` nên:
- **Tắt `enable_signup`** nếu là hệ thống nội bộ — mặc định ai biết domain cũng tự đăng ký được.
- **Cấu hình SMTP** — mặc định chưa có, nên không mời được thành viên qua email và không dùng được magic link.

---

## Vận hành

```bash
./plane.sh up                 # pull + khởi động
./plane.sh ps                 # trạng thái
./plane.sh logs api           # xem log 1 service
./plane.sh down               # tắt — GIỮ NGUYÊN data
./plane.sh restart
./plane.sh backup             # dump DB + file đính kèm + config → ./backups/
./plane.sh <lệnh compose bất kỳ>
```

### Vì sao cần `plane.sh`

Stack chạy bằng 2 compose file và 2 env file. Gõ `docker compose up -d` trần là
Compose không nạp `plane.env` (nó chỉ tự tìm `.env`), nên rơi về mật khẩu mặc định
`plane:plane` và không vào được DB. `plane.sh` chỉ làm đúng một việc là ghép đủ cờ:

```bash
docker compose --project-directory plane-app \
               -f plane-app/docker-compose.yaml -f docker-compose.override.yaml \
               --env-file plane-app/plane.env  --env-file plane.local.env  <lệnh>
```

Thích gõ tay thì dùng nguyên câu trên, thứ tự `--env-file` không được đảo.

## Data nằm ở đâu

Tất cả trong Docker named volume, **không** nằm trong thư mục repo:

| Volume | Chứa gì | Quan trọng |
|---|---|---|
| `plane-app_pgdata` | Postgres: project, issue, user, comment | ⭐ sống còn |
| `plane-app_uploads` | MinIO: file đính kèm, ảnh, avatar | ⭐ sống còn |
| `plane-app_rabbitmq_data`, `plane-app_redisdata` | hàng đợi, cache | mất vẫn chạy lại được |
| `plane-app_proxy_config`, `plane-app_proxy_data` | Caddy nội bộ | không cần (cert do Traefik giữ) |
| `plane-app_logs_*` | log | không cần |

`./plane.sh down` giữ nguyên volume. `docker compose down -v` và option uninstall
của `setup.sh` thì **xoá sạch** — cân nhắc kỹ.

Chạy production lâu dài nên trỏ `DATABASE_URL` sang Postgres ngoài và `AWS_S3_*`
sang S3 thật (khai đè trong `plane.local.env`), thay vì để trong volume local.

## Nâng cấp

```bash
./plane.sh backup
./plane.sh upgrade v1.5.0     # tải file gốc bản mới, bản cũ lùi vào archive/
```

`plane.local.env` không bị đụng. Script sẽ cảnh báo nếu bạn đang đè một biến mà
bản Plane mới đã bỏ — lúc đó override thành vô nghĩa và cần xem lại.

## Giấy phép

MIT — xem [LICENSE](LICENSE). Repo này chỉ là lớp cấu hình; bản thân Plane theo
giấy phép riêng của [makeplane/plane](https://github.com/makeplane/plane).

## Chạy nhiều instance trên cùng một máy

Được, miễn mỗi bản một `PLANE_INSTANCE` và một `APP_DOMAIN` riêng trong
`plane.local.env`. Container, volume và router Traefik đều lấy tiền tố từ biến đó
nên không đụng nhau. Service `proxy` không publish cổng nào ra host nên cũng không
có chuyện tranh cổng.
