# plane-with-traefik

Deploy [Plane](https://plane.so) community edition **phía sau một Traefik có sẵn**, bằng ba lệnh.

```bash
git clone https://github.com/tranngocminhhieu/plane-with-traefik.git
cd plane-with-traefik
./plane.sh init ticket.example.com     # sinh secret + tải file gốc của Plane
./plane.sh up                          # khởi động
```

Rồi mở `https://ticket.example.com/god-mode/` để tạo tài khoản quản trị.

Repo này **không fork, không sửa** file nào của Plane. Mọi thứ của nhà phát triển
gốc được tải mới lúc deploy và giữ nguyên xi; phần riêng gói trong **2 file override**.

## Yêu cầu

- Docker + Docker Compose **v2.24 trở lên** (cần cú pháp `!override`)
- **Traefik đã chạy sẵn**, có network ngoài `proxy_net`, entrypoint `websecure`,
  certresolver `letsencrypt`. Tên khác thì sửa trong `docker-compose.override.yaml`.
- **DNS đã trỏ**: bản ghi A của domain chỉ về máy này. `init` sẽ kiểm tra và cảnh
  báo nếu chưa — không trỏ đúng thì Let's Encrypt không cấp được cert.
- RAM ≥ 4GB (8GB cho production), đĩa trống ≥ 20GB.

## Cấu trúc

```
plane-with-traefik/
├── plane.sh                          ← wrapper, xem "Vì sao cần plane.sh"
├── docker-compose.override.yaml      ← 1. đè phần mạng/cổng/image
├── plane.local.env.example           ← 2. mẫu cho biến riêng
├── README.md  LICENSE  .gitignore
│
├── plane.local.env                   (secret của bạn — .gitignore)
└── plane-app/                        (100% của Plane — .gitignore trọn gói)
    ├── docker-compose.yaml
    └── plane.env
```

Nguyên tắc: **`plane.env` không bao giờ bị sửa.** Muốn đổi gì thì khai lại biến đó
trong `plane.local.env`, Compose nạp file sau đè file trước. Nhờ vậy nâng cấp Plane
chỉ là tải đè `plane.env` bản mới, cấu hình của bạn không mất và không lẫn vào file gốc.

## Hai file override làm gì

**`docker-compose.override.yaml`** sửa đúng 2 chỗ:

1. **Gỡ publish cổng 80/443** của service `proxy` (dùng `!override []`), gắn nó vào
   `proxy_net` kèm label Traefik. Mặc định Plane tự chiếm 80/443, đụng ngay với
   Traefik. Giờ Traefik lo TLS, Caddy nội bộ của Plane chỉ nghe HTTP trong mạng nội bộ.
2. **Đổi image MinIO sang quay.io.** Repo `minio/minio` trên Docker Hub đã bị gỡ —
   bản gốc pull nó sẽ chết với `pull access denied ... repository does not exist`.
   Image chính chủ giờ ở `quay.io/minio/minio`, đã pin theo release thay vì `latest`.

**`plane.local.env`** chứa 13 biến khác bản gốc: tên instance (2), domain (3),
secret ứng dụng (2), mật khẩu Postgres / RabbitMQ / MinIO (6).

## `init` làm gì cho bạn

```bash
./plane.sh init <domain> [tên-instance]
```

- Sinh ngẫu nhiên cả 6 secret, `chmod 600` — không còn `change-this-key-on-deployment`
- Đặt `PLANE_INSTANCE` (mặc định lấy nhãn đầu của domain) — quyết định tiền tố
  container, volume **và tên router Traefik**
- Kiểm tra DNS đã trỏ về máy này chưa
- **Từ chối ghi đè** `plane.local.env` đang có — ghi đè là mất secret mà Postgres
  đã khởi tạo theo, tức là mất data
- **Từ chối trùng tên** với compose project đang chạy — xem mục dưới
- Tải `docker-compose.yaml` + `plane.env` bản mới nhất thẳng từ GitHub release

Ghim một bản cụ thể: `PLANE_RELEASE=v1.4.2 ./plane.sh init ...`

## Vận hành

```bash
./plane.sh up                 # pull + khởi động
./plane.sh ps                 # trạng thái
./plane.sh logs api           # xem log 1 service
./plane.sh down               # tắt — GIỮ NGUYÊN data
./plane.sh restart
./plane.sh backup             # dump DB + file đính kèm + config → ./backups/
./plane.sh upgrade v1.5.0     # tải file gốc bản mới rồi khởi động lại
./plane.sh <lệnh compose bất kỳ>
```

Sau khi `up`, migration DB chạy nền vài phút — theo dõi bằng `./plane.sh logs migrator`
cho tới khi container `migrator` thoát với mã 0.

### Việc cần làm ngay sau lần chạy đầu

Vào `https://<domain>/god-mode/`, tạo **Instance Admin** (ai vào trước thì được), rồi:

- **Tắt `enable_signup`** nếu là hệ thống nội bộ — mặc định ai biết domain cũng tự đăng ký được
- **Cấu hình SMTP** — mặc định chưa có nên không mời được thành viên qua email, không dùng được magic link

### Vì sao cần `plane.sh`

Stack chạy bằng 2 compose file và 2 env file. Gõ `docker compose up -d` trần thì
Compose không nạp `plane.env` (nó chỉ tự tìm `.env`), rơi về mật khẩu mặc định
`plane:plane` và không vào được DB. Script chỉ làm đúng một việc là ghép đủ cờ:

```bash
docker compose --project-directory plane-app \
               -f plane-app/docker-compose.yaml -f docker-compose.override.yaml \
               --env-file plane-app/plane.env  --env-file plane.local.env  <lệnh>
```

Thích gõ tay thì dùng nguyên câu trên, thứ tự `--env-file` không được đảo.

## Chạy nhiều instance trên cùng một máy

Được, miễn mỗi bản một `PLANE_INSTANCE` và một `APP_DOMAIN` riêng — `init` tự lo và
từ chối nếu trùng. Container, volume và router Traefik đều lấy tiền tố từ
`PLANE_INSTANCE` nên không đụng nhau; service `proxy` cũng không publish cổng nào
ra host nên không tranh cổng.

> ⚠ **Đừng bỏ qua `PLANE_INSTANCE`.** Compose lấy tên project từ *thư mục chứa
> compose file*, tức là `plane-app` với **mọi** bản clone. Hai bản cùng tên thì bản
> chạy sau **chiếm và dựng lại container của bản trước** chứ không tạo stack mới.

## Data nằm ở đâu

Tất cả trong Docker named volume, **không** nằm trong thư mục repo. Với
`PLANE_INSTANCE=plane`:

| Volume | Chứa gì | Quan trọng |
|---|---|---|
| `plane_pgdata` | Postgres: project, issue, user, comment | ⭐ sống còn |
| `plane_uploads` | MinIO: file đính kèm, ảnh, avatar | ⭐ sống còn |
| `plane_rabbitmq_data`, `plane_redisdata` | hàng đợi, cache | mất vẫn chạy lại được |
| `plane_proxy_config`, `plane_proxy_data` | Caddy nội bộ | không cần (cert do Traefik giữ) |
| `plane_logs_*` | log | không cần |

`./plane.sh down` giữ nguyên volume. `docker compose down -v` thì **xoá sạch**.

Chạy production lâu dài nên trỏ `DATABASE_URL` sang Postgres ngoài và `AWS_S3_*`
sang S3 thật (khai đè trong `plane.local.env`), thay vì để trong volume local.

## Nâng cấp

```bash
./plane.sh backup
./plane.sh upgrade v1.5.0
```

`plane.local.env` không bị đụng, bản gốc cũ lùi vào `plane-app/archive/`. Script
cảnh báo nếu bạn đang đè một biến mà bản Plane mới đã bỏ — lúc đó override thành
vô nghĩa và cần xem lại.

## Nếu muốn dùng `setup.sh` của Plane

`init` đã thay thế nó, nhưng nếu bạn cần menu gốc (backup, view logs…):

```bash
curl -fsSL -o setup.sh https://github.com/makeplane/plane/releases/latest/download/setup.sh
chmod +x setup.sh && ./setup.sh     # chọn 1 (Install), rồi thoát
```

> ⚠ Bước này **luôn kết thúc bằng lỗi** `pull access denied for minio/minio` — bỏ
> qua được: `setup.sh` pull bằng file gốc nên không thấy override, nhưng
> `docker-compose.yaml` và `plane.env` đã ghi xong **trước** bước pull.
>
> ⛔ Và **đừng dùng menu Start / Restart / Stop của nó**: `setup.sh` gọi compose bằng
> `-f docker-compose.yaml` tường minh nên **bỏ qua file override** — Plane sẽ lại đòi
> cổng 80/443 và đụng Traefik. Chỉ dùng `./plane.sh`.

## Giấy phép

MIT — xem [LICENSE](LICENSE). Repo này chỉ là lớp cấu hình; bản thân Plane theo
giấy phép riêng của [makeplane/plane](https://github.com/makeplane/plane).
