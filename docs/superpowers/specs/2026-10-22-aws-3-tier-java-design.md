# Thiết kế: Java Login App trên AWS 3-Tier (VPN + Transit Gateway + Ansible)

- Ngày: 2026-10-22
- Trạng thái: bản nháp, chờ duyệt
- Nguồn gốc: DevOps-Project-01 (`README.md` gốc + sơ đồ kiến trúc trong README)

Ký hiệu trong tài liệu:
- **[Đã chốt]**: chủ project đã quyết định trong buổi trao đổi.
- **[Claude chọn]**: lựa chọn mặc định do Claude đề xuất, chủ project chưa xác nhận riêng; có thể đổi.
- **[Builder]**: để người triển khai tự quyết.

---

## 1. Mục đích và lý do

Project để đưa vào **CV**. Sản phẩm cuối là **một video demo** cho nhà tuyển dụng xem.
Video phải cho thấy:

1. Một kiến trúc 3 lớp đúng chuẩn doanh nghiệp, **bám sát sơ đồ trong README**:
   văn phòng → Site-to-Site VPN → Transit Gateway → bastion → Nginx → Tomcat → RDS.
2. Mọi thứ được **tự động hóa**: Terraform dựng hạ tầng, Packer + Ansible dựng máy,
   pipeline build và đẩy artifact, Ansible deploy.
3. Hệ thống **tự phục hồi và cập nhật không downtime**: tắt một máy thì ASG tự
   dựng lại máy đã cấu hình sẵn; rolling deploy phiên bản mới trong lúc web vẫn chạy.

Hạ tầng **không chạy lâu dài**. Mỗi lần làm hoặc quay video thì dựng lên, xong thì xóa.

## 2. Mục tiêu / Không làm / Không được xảy ra

**Mục tiêu**
- Dựng lại toàn bộ hệ thống từ con số 0 bằng vài lệnh, lặp lại được.
- Kiến trúc mạng đúng như sơ đồ: 2 VPC (quản trị + ứng dụng) nối qua Transit Gateway,
  Site-to-Site VPN thật vào TGW từ một "văn phòng" giả lập. **[Đã chốt]**
- Ansible là nguồn cấu hình duy nhất cho mọi máy (Nginx, Tomcat, CGW, bastion).
- Auto Scaling hoạt động thật: máy mới lên là phục vụ được ngay, không cần ai chạy Ansible.
- Không còn mật khẩu hay secret nào nằm trong code.

**Không làm (non-goals)**
- Không chạy production, không SLA, không cần domain riêng hay HTTPS. **[Claude chọn]**
  Truy cập web qua DNS của NLB public.
- Không viết lại app Java. Chỉ sửa tối thiểu để chạy được trên hạ tầng mới (mục 7).
- Không dùng Kubernetes hay container.

**Không được xảy ra (anti-goals)**
- Vượt ngân sách $200 credit, ví dụ do quên xóa hạ tầng.
- Lộ secret: mật khẩu DB, PSK của VPN, khóa WireGuard bị commit lên GitHub.
- Mở SSH từ Internet vào bất kỳ máy nào trong VPC ứng dụng.
- Sau khi làm xong, sơ đồ kiến trúc vẽ lại **khác** sơ đồ gốc ở phần mạng.

## 3. Ràng buộc

- Tài khoản AWS Free Plan có **$200 credit**.
- Region: **us-east-1** (theo README gốc). **[Claude chọn]**
- Chi phí khi toàn bộ hệ thống đang chạy ước khoảng **$0.5–0.7/giờ** (đã tính ElastiCache,
  CloudFront). Nhờ quy tắc "dựng lên → làm → destroy", cả project dự kiến tốn khoảng $30–60.
- Máy làm việc của chủ project là Linux (Ubuntu). Ở nhà không có router IPsec với IP
  tĩnh, nên "văn phòng" phải giả lập trên AWS. **[Đã chốt]**
- Thư mục hiện tại chưa phải git repo. Repo gốc có secret của tác giả cũ
  (`settings.xml`, `application.properties`) và phải xóa trước khi push.

## 4. Kiến trúc tổng quan

```
                         ┌──────────────── VPC "Văn phòng" 10.10.0.0/16 ────────────────┐
 Laptop ══WireGuard═════▶│ CGW EC2 (strongSwan + WireGuard, Elastic IP, public subnet)   │
 (kỹ sư làm từ xa)       │ private subnet "LAN văn phòng"                                 │
                         └───────────────┬────────────────────────────────────────────────┘
                                         ║ Site-to-Site VPN (2 tunnel IPsec)
                                         ▼
                                 ┌───────────────┐
                                 │Transit Gateway│
                                 └──┬─────────┬──┘
              ┌─────────────────────┘         └─────────────────────────┐
 ┌── VPC Quản trị 192.168.0.0/16 ──┐   ┌──────── VPC Ứng dụng 172.32.0.0/16 ─────────────────────┐
 │ public subnet: Bastion (IGW)    │   │ public : NLB public, NAT Gateway, IGW                    │
 └─────────────────────────────────┘   │ private: ASG Nginx (2 AZ)                                │
                                        │ private: NLB nội bộ                                      │
 Người dùng Internet ──HTTP──▶ NLB public ──▶ Nginx ──▶ NLB nội bộ ──▶ ASG Tomcat (2 AZ)       │
                                        │ private: RDS MySQL Multi-AZ (primary 1a, standby 1b)     │
                                        └──────────────────────────────────────────────────────────┘
```

### 4.1 Quy hoạch mạng

| VPC | CIDR | Subnet | Nội dung |
|---|---|---|---|
| Văn phòng (giả lập) | `10.10.0.0/16` | 1 public, 1 private, 1 AZ | CGW EC2; "LAN văn phòng" |
| Quản trị | `192.168.0.0/16` | 1 public, 1 AZ | Bastion |
| Ứng dụng | `172.32.0.0/16` | 2 public, 6 private, trên 2 AZ (1a, 1b) | NLB, NAT; Nginx; NLB nội bộ; Tomcat; RDS |
| Dải WireGuard | `10.99.0.0/24` | — | IP của laptop trong đường hầm |

- CIDR của VPC quản trị và ứng dụng lấy theo README. Code Terraform hiện tại dùng
  `192.168.0.0/16` cho VPC ứng dụng, nên phải đổi.
- Chia subnet chi tiết: **[Builder]**.
- VPC ứng dụng dùng **1 NAT Gateway** thay vì 1 NAT mỗi AZ để tiết kiệm. **[Claude chọn]**

### 4.2 Các luồng truy cập

**Người dùng web:** Internet → CloudFront (HTTPS) → NLB public (TCP 80) → Nginx (80) → NLB nội bộ (TCP 8080) → Tomcat (8080) → RDS (3306) và ElastiCache (6379).
File tĩnh `/static/*`: CloudFront → S3.
Theo sơ đồ là **NLB** ở cả hai tầng. Code hiện tại dùng ALB, nên phải đổi. **[Đã chốt: giữ đúng sơ đồ]**

**Quản trị (kỹ sư):** laptop →(WireGuard)→ CGW →(IPsec)→ TGW → bastion → máy private trong VPC ứng dụng.
- Bastion chỉ nhận SSH từ `10.10.0.0/16` và `10.99.0.0/24`.
- Máy Nginx và Tomcat chỉ nhận SSH từ bastion.
- RDS chỉ nhận 3306 từ security group tầng Tomcat và từ bastion (để init DB).
- Route table của TGW chỉ cho các luồng: văn phòng ↔ quản trị, quản trị ↔ ứng dụng.
  Văn phòng **không** đi thẳng vào VPC ứng dụng. **[Claude chọn: đúng tinh thần "phải qua bastion" của sơ đồ]**
- Không dùng SSM Session Manager. **[Đã chốt]**

### 4.3 Site-to-Site VPN và văn phòng giả lập **[Đã chốt]**

- Customer Gateway trên AWS trỏ tới Elastic IP của máy CGW.
- VPN connection gắn **thẳng vào Transit Gateway** (attachment loại VPN).
- Máy CGW: Ubuntu hoặc Amazon Linux, t3.micro, tắt source/dest check, chạy strongSwan (IPsec) và WireGuard.
- Định tuyến: bắt đầu bằng **static route**. Nâng lên BGP (FRR trên CGW) là phần mở rộng
  nếu còn thời gian. **[Claude chọn]**
- PSK và IP bên trong tunnel lấy từ Terraform output rồi đưa vào Ansible.

### 4.4 WireGuard (laptop vào "văn phòng") **[Đã chốt]**

- Máy CGW chạy WireGuard server (UDP 51820). Security group chỉ mở 51820 cho IP public của laptop.
- Ansible sinh khóa cho cả hai đầu, cấu hình server, và xuất file `office.conf` cho laptop
  (lưu ngoài git). Laptop gõ `wg-quick up office`.
- `AllowedIPs` phía laptop: `10.10.0.0/16, 192.168.0.0/16` (split tunnel). Không có `172.32.0.0/16`,
  vì laptop chỉ vào VPC ứng dụng qua bastion.
- Máy CGW NAT/route traffic từ `10.99.0.0/24` vào IPsec.

## 5. Tầng dữ liệu

- RDS MySQL 8, **Multi-AZ**, `db.t3.micro`, 20 GB, trong DB subnet group private. **[Claude chọn: loại nhỏ nhất có Multi-AZ]**
- Schema lấy theo **`Java-Login-App/README.md`**, vì đó là thứ code thật sự dùng:
  database `UserDB`, bảng `Employee`. README lớn mô tả `javaapp`/`users`; bỏ phần đó.
- Mật khẩu master do Terraform sinh ngẫu nhiên, lưu ở **SSM Parameter Store (SecureString)**.
  Ansible và Tomcat đọc ở đó, không nằm trong git. **[Claude chọn]**
- Init schema bằng role Ansible `db_init` chạy trên bastion. Idempotent: `CREATE ... IF NOT EXISTS`.
- Sơ đồ có read replica (master "M" → slave "S"). Theo mục 4, mặc định dùng Multi-AZ standby.
  Thêm read replica là tùy chọn, vì app không tách đọc/ghi. **[Claude chọn]**

## 6. Cấu hình máy: Ansible + Packer **[Đã chốt: phương án "bake AMI + dynamic inventory"]**

### 6.1 Roles

| Role | Chạy trên | Việc |
|---|---|---|
| `common` | mọi máy | cập nhật OS, timezone, user, cứng hóa SSH, CloudWatch agent |
| `nginx` | AMI web | cài Nginx; template `app.conf`, `proxy_pass` tới DNS của NLB nội bộ |
| `tomcat` | AMI app | Java 11 (Corretto) + **Tomcat 9** cài từ tarball + systemd (không dùng gói `yum tomcat` của AL2) |
| `app_deploy` | AMI app + rolling deploy | tải `.war` theo version từ kho artifact; cấu hình DB đọc từ Parameter Store |
| `db_init` | bastion | tạo `UserDB` + bảng `Employee` |
| `bastion` | bastion | công cụ client (mysql, ansible nếu cần) |
| `strongswan` | CGW | cấu hình IPsec 2 tunnel tới TGW |
| `wireguard` | CGW | WireGuard server + xuất cấu hình cho laptop |

### 6.2 Packer bake AMI

- 2 AMI: `web-ami` (`common` + `nginx`) và `app-ami` (`common` + `tomcat` + `app_deploy` với version hiện hành).
- Base: Amazon Linux 2023. **[Claude chọn]**
- Khi bake, Packer chạy trong một subnet có đường ra Internet; cách dựng do **[Builder]** quyết.
- Các giá trị chỉ có lúc chạy (DNS của NLB nội bộ, endpoint RDS) **không bake cứng**.
  Lúc boot, một bước nhỏ trong user_data đọc chúng từ Parameter Store hoặc tag rồi render
  config. Cách làm cụ thể: **[Builder]**.

### 6.3 Dynamic inventory

- Plugin `amazon.aws.aws_ec2`, lọc theo tag `Project`, nhóm theo tag `Tier`
  (`tier_web`, `tier_app`, `tier_bastion`, `tier_cgw`).
- Kết nối máy private bằng IP private, qua bastion (`ProxyJump`), từ laptop đang bật WireGuard.
- Bastion kết nối qua IP private sau khi đã vào VPN. CGW là "thiết bị biên" của văn phòng nên
  luôn được quản trị qua Elastic IP, SSH chỉ mở cho IP public của laptop. Cách này giải quyết
  bài toán "gà và trứng" (cần VPN để cấu hình chính máy làm VPN). **[Claude chọn]**

### 6.4 Cập nhật phiên bản

- `rolling_deploy.yml` với `serial: 1`: lần lượt rút máy khỏi target group, đổi `.war`,
  kiểm tra health, gắn lại vào target group.
- Song song đó, bake `app-ami` mới và cập nhật launch template, để máy scale out sau này
  có đúng version. Có thể dùng ASG **instance refresh** thay cho bước này. **[Builder]** chọn,
  nhưng video phải có ít nhất một cảnh rolling deploy không downtime.

## 7. Thay đổi trên app Java (tối thiểu)

- Bỏ URL, user, mật khẩu DB ghi cứng trong `application.properties`. Đọc từ biến môi trường
  hoặc file cấu hình ngoài do Ansible render (ví dụ `setenv.sh` của Tomcat).
- Xóa `settings.xml` và `distributionManagement` trỏ tới JFrog của tác giả cũ, thay bằng kho mới (mục 8).
- Kiểm tra lại driver: code dùng `com.mysql.jdbc.Driver`; với MySQL 8 nên dùng driver mới. **[Builder]**
- Đổi sang `PreparedStatement` để hết SQL injection: **tùy chọn**, nhỏ và có ích cho CV. **[Claude chọn: nên làm]**
- Lỗi phát hiện khi lên kế hoạch, **bắt buộc sửa** để app chạy đúng:
  - `spring-boot-starter-security` có trong `pom.xml` nhưng không có cấu hình, nên mặc định khóa
    mọi trang sau trang login của Spring. Cần `SecurityConfig` mở các trang của app, giữ CSRF.
  - `login.java` lưu `userId` vào **field của controller** (singleton): sau khi một người đăng nhập
    đúng, mọi người khác nhập sai mật khẩu vẫn vào được. Phải chuyển sang session.
  - Mật khẩu lưu dạng plain text: chuyển sang BCrypt.
- App kết nối DB bằng user riêng `appuser` (chỉ SELECT/INSERT trên `UserDB`), không dùng
  tài khoản master. **[Claude chọn]**
- Trang hiển thị **version app** và **tên máy Tomcat** đang phục vụ, phục vụ các cảnh demo.

## 8. CI và kho artifact **[Đã chốt]**

- **GitHub Actions**: khi push lên `main` thì `mvn test`, `mvn package`, rồi publish `.war` có version.
- **AWS CodeArtifact** làm Maven repo (thay JFrog trong sơ đồ). Xác thực bằng IAM; GitHub Actions
  dùng OIDC role, không lưu access key.
- **SonarCloud** quét code (thay SonarQube trong sơ đồ). Gói free yêu cầu **repo public**.
  Chủ project tự tạo repo GitHub; mặc định là public. **[Claude chọn]**
- Tách khỏi pipeline: bake AMI và deploy chạy từ laptop (vì cần VPN).
  Sơ đồ có máy build Maven trong private subnet; thay bằng GitHub Actions runner.

## 8a. ElastiCache: session dùng chung **[Đã chốt: có làm]**

- Redis (ElastiCache) 2 node `cache.t3.micro`, Multi-AZ, tự failover, mã hóa đường truyền + auth token
  (lưu ở Parameter Store).
- App dùng **Spring Session Data Redis**: phiên đăng nhập và CSRF token nằm ở Redis, nên mọi Tomcat
  trong ASG đều phục vụ được bất kỳ request nào. Đây là điều kiện để tầng App thật sự stateless.
- ElastiCache chặn lệnh `CONFIG`, nên phải tắt bước tự cấu hình keyspace notification của Spring Session.
- Cảnh demo: đăng nhập, terminate đúng máy Tomcat đang phục vụ, F5 vẫn còn đăng nhập
  (trang hiển thị tên máy phục vụ).

## 8b. CloudFront **[Đã chốt: có làm]**

- CloudFront đứng **trước** NLB public, thay vì Nginx proxy sang CloudFront như README. **[Claude chọn]**
  - Behavior mặc định → origin là NLB public, không cache, chuyển tiếp cookie/header/body.
  - Behavior `/static/*` → S3 bucket (Origin Access Control), có cache.
- Có HTTPS miễn phí qua domain `*.cloudfront.net`, nên không cần mua domain.
- NLB public chỉ nhận traffic từ dải IP của CloudFront (managed prefix list), nên không ai
  đi tắt vào NLB được.
- App thêm một ít CSS/ảnh tĩnh để có thứ cho CloudFront phục vụ.

## 9. Giám sát và ngân sách

- Giữ và mở rộng module `monitoring` hiện có: alarm CPU cho RDS và ASG, log group cho app.
- **SNS → email** khi alarm kêu (có icon email trong sơ đồ).
- Trạng thái tunnel VPN (`TunnelState`) có alarm. **[Claude chọn]**
- **AWS Budget**: cảnh báo email ở mức $20, $50, $100. Tạo **một lần, không nằm chung
  stack bị destroy**. **[Claude chọn]**
- CloudTrail, S3 trong sơ đồ: **[Builder]** quyết có làm hay không.

## 10. Vòng đời và tổ chức code

- Terraform tách thành ít nhất 2 phần, để `destroy` không xóa nhầm thứ cần giữ:
  - `bootstrap/`: S3 bucket cho state, DynamoDB lock, AWS Budget, CodeArtifact repo, IAM OIDC cho GitHub. Giữ lâu dài, chi phí gần 0.
  - `live/`: toàn bộ mạng, VPN, ASG, RDS… Dựng lên rồi destroy.
- Dùng lại các module hiện có trong `infrastructure/modules` khi được. Thêm module
  `tgw`, `vpn`, `office`, `nlb`. Bỏ module `alb`.
- Một script `make up` / `make down` (hoặc tương đương) gói các bước:
  terraform apply → Ansible cấu hình CGW → bật WireGuard → db_init → kiểm tra web.
- Cấu trúc thư mục cụ thể: **[Builder]**.

## 11. Kịch bản video demo (để định hướng, không phải yêu cầu cứng)

1. Sơ đồ kiến trúc và repo.
2. `make up`: Terraform dựng hạ tầng.
3. Bật WireGuard, ping tới bastion qua VPN, xem trạng thái tunnel trong console.
4. Chạy Ansible với dynamic inventory, cho thấy nhóm `tier_web` / `tier_app` tự xuất hiện.
5. Mở web qua NLB public, đăng ký rồi đăng nhập, sau đó xem bản ghi trong RDS từ bastion.
6. Terminate một máy Tomcat, ASG tự dựng lại, web không gián đoạn.
7. Push code, pipeline build và đẩy `.war`, chạy rolling deploy, web hiển thị version mới.
8. Alarm hoặc email SNS, rồi `make down`.

## 12. Để người triển khai quyết định

- Chia subnet chi tiết, tên resource, tag ngoài `Project`/`Tier`/`Environment`.
- Cách Packer có đường ra Internet khi bake; cách render config lúc boot.
- Instance refresh hay chỉ rolling deploy Ansible.
- Phiên bản Terraform provider, collection Ansible.
- CloudTrail, S3 log.

## 13. Câu hỏi còn mở

Không còn. Đã chốt ngày 2026-10-22: CI = GitHub Actions + CodeArtifact + SonarCloud;
có làm ElastiCache và CloudFront; chủ project tự tạo repo GitHub.
