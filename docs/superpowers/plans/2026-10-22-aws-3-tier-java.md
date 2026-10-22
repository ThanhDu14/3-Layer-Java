# Java Login App on AWS 3-Tier (VPN + TGW + Ansible) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Dựng lại DevOps-Project-01 thành một hệ thống 3 lớp chạy thật trên AWS: văn phòng giả lập → Site-to-Site VPN → Transit Gateway → bastion; CloudFront → NLB → Nginx → NLB nội bộ → Tomcat → RDS + ElastiCache. Toàn bộ dựng/xóa bằng `make up` / `make down`.

**Architecture:** Terraform chia 2 stack: `bootstrap/` (giữ lâu dài: state, Budget, CodeArtifact, OIDC, SNS, Packer profile) và `live/` (dựng rồi xóa). Ansible roles là nguồn cấu hình duy nhất; Packer dùng chúng để bake AMI web/app, systemd `ExecStartPre` render cấu hình runtime từ SSM Parameter Store lúc boot. Dynamic inventory `aws_ec2` + bastion ProxyJump qua WireGuard → IPsec dùng cho vận hành và rolling deploy.

**Tech Stack:** Java 11 / Spring Boot 2.7.18 (WAR, JSP) · Tomcat 9 · Nginx · MySQL 8 (RDS) · Redis 7 (ElastiCache) + Spring Session · Terraform ≥ 1.10 + `hashicorp/aws ~> 6.0` · Packer + `amazon` plugin · Ansible core ≥ 2.17 + Molecule (docker) · strongSwan (swanctl) · WireGuard · GitHub Actions · AWS CodeArtifact · SonarCloud.

**Spec:** `docs/superpowers/specs/2026-10-22-aws-3-tier-java-design.md`

## Global Constraints

- Region `us-east-1`; mọi resource có tag `Project=java3tier`, `Environment=dev`; tên resource bắt đầu bằng `java3tier-`.
- EC2/ASG instance có thêm tag `Tier` ∈ {`web`, `app`, `bastion`, `cgw`}; AMI bake có tag `Role` ∈ {`web`, `app`} và `AppVersion`.
- CIDR: văn phòng `10.10.0.0/16` (public `10.10.1.0/24`, LAN `10.10.2.0/24`); quản trị `192.168.0.0/16` (public `192.168.1.0/24`); ứng dụng `172.32.0.0/16` (public `172.32.1.0/24`,`172.32.2.0/24`; web `172.32.11.0/24`,`172.32.12.0/24`; app `172.32.21.0/24`,`172.32.22.0/24`; data `172.32.31.0/24`,`172.32.32.0/24`); WireGuard `10.99.0.0/24` (server `10.99.0.1`, laptop `10.99.0.2`), UDP `51820`. AZ: `us-east-1a`, `us-east-1b`.
- Java target 11; Spring Boot 2.7.18 dùng `javax.*` ⇒ chỉ Tomcat **9.0.x** (không dùng Tomcat 10). Runtime: `java-11-amazon-corretto-headless`.
- Kích cỡ: EC2 `t3.micro`; RDS `db.t3.micro` MySQL 8.0 Multi-AZ; ElastiCache `cache.t3.micro` × 2, Redis 7.1. ASG web và app: min 2 / max 4 / desired 2, target tracking CPU 60%.
- Base AMI: Amazon Linux 2023 (`/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64`) cho web/app/bastion; Ubuntu 24.04 (`/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id`) cho CGW.
- SSM parameter (chính xác): `/java3tier/db/host`, `/java3tier/db/name`=`UserDB`, `/java3tier/db/master_username`=`admin`, `/java3tier/db/master_password` (SecureString), `/java3tier/db/app_username`=`appuser`, `/java3tier/db/app_password` (SecureString), `/java3tier/redis/host`, `/java3tier/redis/auth_token` (SecureString), `/java3tier/app/internal_nlb_dns`, `/java3tier/app/version`.
- Maven coordinates: `com.devopsrealtime:dptweb:<version>:war`; CodeArtifact domain `java3tier`, repository `maven-releases`; CI version `1.0.${{ github.run_number }}`.
- Không secret nào trong git (gitleaks phải sạch). Mọi file sinh ra chứa secret nằm dưới `ansible/.generated/` (gitignored).
- Không security group nào cho port 22 từ `0.0.0.0/0`. SSH vào VPC ứng dụng chỉ từ `192.168.1.0/24` (bastion). Văn phòng/WireGuard không có route trực tiếp tới `172.32.0.0/16`.
- AWS Budget $100/tháng, cảnh báo email ở 20%/50%/100% — nằm trong `bootstrap/`, không bao giờ bị `make down` xóa.
- Lệnh test Java luôn chạy bằng JDK 11 qua Docker (`make app-test`), không dùng JDK 25 trên máy host.

## Review Focus

1. **IP public của laptop đổi giữa các buổi làm** → `make up` phải tự lấy IP hiện tại (`https://checkip.amazonaws.com`) làm `admin_cidr`, không dùng giá trị cũ trong tfvars. Test: Task 22 Step 1.
2. **Tomcat boot trước khi DB user / parameter sẵn sàng** → app vẫn qua health check của NLB (health `lb` không phụ thuộc DB/Redis), render script thoát lỗi rõ ràng khi thiếu parameter, systemd tự thử lại. Test: Task 2 (`healthLbIsUpWithoutDatabase`), Task 10 (`render fails on missing parameter`).
3. **Deploy một version không tồn tại** → rolling deploy phải dừng *trước* khi rút bất kỳ máy nào khỏi target group. Test: Task 23 Step 4.
4. **Máy Tomcat đang giữ phiên của người dùng bị terminate** → người dùng vẫn đăng nhập (session ở Redis). Test: Task 4 (`sessionSurvivesInstanceSwap`), Task 24 chaos script.
5. **Chạy lại `make up` trên stack đang chạy** → idempotent: roles không đổi gì ở lần chạy 2, `db_init` không lỗi, khóa WireGuard của laptop không bị sinh lại. Test: molecule idempotence (Task 7–12), Task 11 (`client key unchanged on second converge`).

---

## Cấu trúc file sau khi xong

```
.github/workflows/ci.yml
Makefile
requirements-dev.txt                 # ansible-core, ansible-lint, molecule, molecule-plugins[docker], boto3, botocore, PyMySQL
scripts/{check-tools.sh,up.sh,down.sh,smoke.sh,gen-ansible-vars.sh,load-check.sh,chaos-kill-app.sh,prune-amis.sh}
db/schema.sql                        # nguồn schema duy nhất (test + db_init)
web-static/static/{css/app.css,img/logo.svg}
Java-Login-App/                      # app (sửa)
infrastructure/
  bootstrap/{versions.tf,main.tf,variables.tf,outputs.tf,terraform.tfvars.example,tests/bootstrap.tftest.hcl}
  live/{versions.tf,main.tf,variables.tf,outputs.tf,terraform.tfvars.example,backend.hcl.example,tests/live.tftest.hcl}
  modules/{vpc,tgw,vpn,office,bastion,security,nlb,asg,rds,elasticache,params,cloudfront,monitoring}/{main.tf,variables.tf,outputs.tf,tests/*.tftest.hcl}
packer/{java3tier.pkr.hcl,variables.pkr.hcl}
ansible/
  ansible.cfg requirements.yml .ansible-lint
  inventory/aws_ec2.yml
  group_vars/{all.yml,tier_web.yml,tier_app.yml,tier_bastion.yml,tier_cgw.yml}
  playbooks/{packer-web.yml,packer-app.yml,cgw.yml,bastion.yml,db_init.yml,rolling_deploy.yml}
  roles/{common,nginx,tomcat,app_deploy,bastion,db_init,wireguard,strongswan}/  (mỗi role có molecule/default/)
docs/{runbook.md,architecture.md}
```

Xóa: `Java-Login-App/settings.xml`, `infrastructure/main.tf`, `infrastructure/variables.tf`, `infrastructure/modules/alb/`, `Java-Login-App/src/main/java/com/dpt/demo/{login,register}.java`, `pages/{confirm,fail}.jsp`.

---

## Phase 0 — Repo và công cụ

### Task 1: Dọn secret, khởi tạo git, cài toolchain

**Files:**
- Create: `.gitignore`, `Makefile`, `requirements-dev.txt`, `scripts/check-tools.sh`
- Delete: `Java-Login-App/settings.xml`
- Modify: `Java-Login-App/src/main/resources/application.properties` (xóa 3 dòng `spring.datasource.*`), `Java-Login-App/pom.xml` (xóa khối `<distributionManagement>`)

**Interfaces:**
- Produces: `make tools` (tạo `.venv`, cài `requirements-dev.txt`, `ansible-galaxy collection install -r ansible/requirements.yml` khi file tồn tại); `make check-tools`; biến Makefile `VENV=.venv`, `ANSIBLE=$(VENV)/bin/ansible-playbook`.

- [ ] **Step 1: Chạy gitleaks trên thư mục hiện tại, xác nhận đang có secret**
  Run: `docker run --rm -v "$PWD":/repo zricethezav/gitleaks:<tag v8.x mới nhất, ghi cố định vào Makefile> detect --no-git --source /repo -v`
  Expected: có finding ở `Java-Login-App/settings.xml` và/hoặc `application.properties` (nếu gitleaks không bắt được mật khẩu `Admin123`, xác nhận bằng `grep -rn "Admin123" .`).
- [ ] **Step 2: Xóa `settings.xml`, xóa 3 dòng datasource, xóa `<distributionManagement>`**
- [ ] **Step 3: Viết `.gitignore` gốc** gồm: `.venv/`, `**/.terraform/`, `*.tfstate`, `*.tfstate.*`, `*.tfvars` (giữ `!*.tfvars.example`), `backend.hcl`, `ansible/.generated/`, `*.war`, `target/`, `.molecule/`, `*.pem`, `*.key`.
- [ ] **Step 4: Chạy lại gitleaks + grep**
  Expected: `no leaks found`; `grep -rn "Admin123\|prdevop26" .` không ra gì.
- [ ] **Step 5: Viết `scripts/check-tools.sh`** — kiểm tra `terraform` (≥1.10), `packer`, `docker`, `aws`, `wg`, `.venv/bin/ansible-playbook`, `.venv/bin/molecule`; in version từng cái, thoát 1 và liệt kê thứ thiếu.
- [ ] **Step 6: Cài phần còn thiếu**: Packer từ repo apt HashiCorp, `sudo apt install wireguard-tools`, `make tools`.
- [ ] **Step 7: `make check-tools`** → Expected: exit 0, đủ 7 dòng version.
- [ ] **Step 8: Khởi tạo git và push**
  ```bash
  git init -b main && git add -A && git commit -m "chore: import DevOps-Project-01, remove leaked credentials"
  git remote add origin <URL repo bạn vừa tạo> && git push -u origin main
  ```

---

## Phase 1 — Ứng dụng

> Lệnh test chung: `make app-test` =
> `docker run --rm --network host -v /var/run/docker.sock:/var/run/docker.sock -v "$PWD":/work -v "$HOME/.m2":/root/.m2 -w /work/Java-Login-App maven:3.9-eclipse-temurin-11 mvn -B verify`
> (`--network host` + docker.sock để Testcontainers chạy được từ trong container).

### Task 2: Test harness, SecurityConfig, health endpoint

**Files:**
- Modify: `Java-Login-App/pom.xml`, `Java-Login-App/src/main/resources/application.properties`, `Java-Login-App/src/test/java/com/dpt/demo/MyWebAppApplicationTests.java`
- Create: `.../SecurityConfig.java`, `src/test/resources/application-test.properties`, `src/test/java/com/dpt/demo/WebSecurityTest.java`

**Interfaces:**
- Produces: profile test `test` (H2 `jdbc:h2:mem:userdb;MODE=MySQL;DATABASE_TO_LOWER=TRUE`, `spring.sql.init.mode=always`, `spring.sql.init.schema-locations=file:../db/schema.sql`, `spring.session.store-type=none`); `GET /actuator/health/lb` (group `lb` chỉ gồm `ping`).
- pom: thêm `spring-boot-starter-jdbc`, `spring-boot-starter-actuator`, `javax.servlet:jstl`, `com.h2database:h2` (test), đổi `mysql:mysql-connector-java` → `com.mysql:mysql-connector-j` (runtime), `tomcat-jasper` → scope `provided` và bỏ version cứng; thêm execution `build-info` cho `spring-boot-maven-plugin`; `<finalName>dptweb</finalName>`.
- `SecurityConfig.filterChain(HttpSecurity) : SecurityFilterChain` — permitAll: `/`, `/home`, `/login`, `/register`, `/user`, `/logout`, `/actuator/health/**`, `/static/**`, `/error`; `anyRequest().denyAll()`; tắt `formLogin`, `httpBasic`, `logout` mặc định; **giữ CSRF**.

- [ ] **Step 1: Tạo `db/schema.sql`** (cần cho profile test):
  ```sql
  CREATE TABLE IF NOT EXISTS Employee (
    id INT UNSIGNED AUTO_INCREMENT NOT NULL,
    first_name VARCHAR(250), last_name VARCHAR(250), email VARCHAR(250),
    username VARCHAR(250) NOT NULL, password VARCHAR(250) NOT NULL,
    regdate TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    CONSTRAINT uk_employee_username UNIQUE (username)
  );
  ```
- [ ] **Step 2: Viết test thất bại `WebSecurityTest`** (`@SpringBootTest @AutoConfigureMockMvc @ActiveProfiles("test")`):
  - `homePageIsPublic`: `GET /` → 200, `view().name("home")`
  - `loginAndRegisterFormsArePublic`: `GET /login`, `GET /register` → 200
  - `healthLbIsUpWithoutDatabase`: với `@TestPropertySource(properties={"spring.datasource.url=jdbc:mysql://127.0.0.1:1/none","spring.sql.init.mode=never"})` trong một class test riêng → `GET /actuator/health/lb` → 200, `jsonPath("$.status").value("UP")`
  - `postWithoutCsrfIsForbidden`: `POST /login` không có `csrf()` → 403
  - `unknownPathIsDenied`: `GET /admin` → 403
  Thêm `@ActiveProfiles("test")` cho `MyWebAppApplicationTests`.
- [ ] **Step 3: `make app-test`** → Expected: FAIL (`/` trả 401 do Spring Security mặc định).
- [ ] **Step 4: Sửa pom, `application.properties`** (thêm `management.endpoints.web.exposure.include=health`, `management.endpoint.health.group.lb.include=ping`), tạo `SecurityConfig`, `application-test.properties`.
- [ ] **Step 5: `make app-test`** → Expected: PASS toàn bộ.
- [ ] **Step 6: Commit** `feat(app): security config, health endpoint, test harness`

### Task 3: Đăng ký/đăng nhập an toàn (JdbcTemplate, BCrypt, session)

**Files:**
- Create: `.../UserRepository.java`, `.../UsernameTakenException.java`, `.../LoginController.java`, `.../RegisterController.java`, `src/test/java/com/dpt/demo/AuthFlowTest.java`
- Delete: `login.java`, `register.java`, `pages/confirm.jsp`, `pages/fail.jsp`
- Modify: `pages/login.jsp`, `pages/register.jsp`, `pages/user.jsp` (CSRF hidden input `${_csrf.parameterName}`/`${_csrf.token}`, in biến bằng `<c:out>`, form `POST /logout` trên trang user)

**Interfaces:**
- `UserRepository` (`@Repository`, dùng `JdbcTemplate` + `PasswordEncoder`):
  - `void create(String firstName, String lastName, String email, String username, String rawPassword) throws UsernameTakenException`
  - `Optional<String> authenticate(String username, String rawPassword)` → trả `username` khi đúng
- Bean `PasswordEncoder passwordEncoder()` = `BCryptPasswordEncoder` (đặt trong `SecurityConfig`).
- Session attribute: `"username"`.
- Endpoints và chuỗi hiển thị (chính xác):
  - `POST /register` (params `firstName,lastName,email,userName,password`) → view `register`, `message` = `user account has been added for <userName>` | `Username already exists` | `Username and password are required`
  - `POST /login` (params `userName,password`) → đúng: `request.changeSessionId()`, set session, `redirect:/user`; sai: view `login`, `errorMessage` = `Invalid username or password`
  - `GET /user` → có session: view `user` với `username`; không: `redirect:/login`
  - `POST /logout` → invalidate session, `redirect:/login`

- [ ] **Step 1: Viết test thất bại `AuthFlowTest`** (MockMvc, profile test, `@Sql` xóa bảng trước mỗi test):
  - `registerStoresBcryptHashNotPlaintext`: đăng ký `alice/secret1` → `select password from Employee where username='alice'` bắt đầu bằng `$2` và khác `secret1`
  - `registerDuplicateUsernameShowsMessage` → `model().attribute("message","Username already exists")`
  - `registerBlankPasswordRejected` → `Username and password are required`, không có dòng nào được insert
  - `loginSuccessRedirectsToUserAndSetsSession` → `redirectedUrl("/user")`, `request().sessionAttribute("username","alice")`
  - `wrongPasswordAfterAnotherUsersSuccessfulLoginIsRejected` (hồi quy lỗi field `userId`): alice đăng nhập đúng, rồi `bob/sai` → view `login`, `errorMessage` = `Invalid username or password`
  - `sqlInjectionLoginIsRejected`: `userName="' OR '1'='1"`, `password="' OR '1'='1"` → view `login`
  - `userPageWithoutSessionRedirectsToLogin`
  - `logoutInvalidatesSession`: sau logout, `GET /user` với session cũ → `redirect:/login`
- [ ] **Step 2: `make app-test`** → Expected: FAIL (class `UserRepository` chưa có / controller cũ).
- [ ] **Step 3: Implement** repository, exception, 2 controller; xóa file cũ; sửa JSP.
- [ ] **Step 4: `make app-test`** → Expected: PASS.
- [ ] **Step 5: Commit** `fix(app): bcrypt passwords, prepared statements, session-based login`

### Task 4: Spring Session Redis, footer version/máy phục vụ, CSS tĩnh

**Files:**
- Modify: `pom.xml` (thêm `spring-boot-starter-data-redis`, `spring-session-data-redis`; test: `org.testcontainers:testcontainers` + `junit-jupiter` qua BOM `org.testcontainers:testcontainers-bom` ≥ 1.21.4 — bản cũ hơn không nói chuyện được với Docker 29), `application.properties`, mọi JSP (include footer + `<link rel="stylesheet" href="/static/css/app.css">`)
- Create: `.../GlobalModelAdvice.java`, `src/main/webapp/pages/_footer.jspf`, `web-static/static/css/app.css`, `web-static/static/img/logo.svg`, `src/test/java/com/dpt/demo/RedisSessionTest.java`, `src/test/java/com/dpt/demo/RenderedPagesTest.java`

**Interfaces:**
- `application.properties`: `spring.session.store-type=redis`, `spring.session.redis.configure-action=none` (ElastiCache chặn `CONFIG`), `spring.session.timeout=30m`. Profile test vẫn `none`.
- Runtime đọc từ env (do Task 10 render): `SPRING_DATASOURCE_URL`, `SPRING_DATASOURCE_USERNAME`, `SPRING_DATASOURCE_PASSWORD`, `SPRING_REDIS_HOST`, `SPRING_REDIS_PORT`, `SPRING_REDIS_PASSWORD`, `SPRING_REDIS_SSL`.
- `GlobalModelAdvice` (`@ControllerAdvice`): `@ModelAttribute("appVersion") String appVersion()` (từ `BuildProperties`, fallback `dev`); `@ModelAttribute("servedBy") String servedBy()` (`InetAddress.getLocalHost().getHostName()`).
- Footer HTML (chính xác, smoke test parse): `<footer id="build">v<span id="app-version">${appVersion}</span> · served by <span id="served-by">${servedBy}</span></footer>`

- [ ] **Step 1: Viết test thất bại `RedisSessionTest`** — Testcontainers `redis:7.2` khởi động với lệnh `redis-server --rename-command CONFIG ""` (mô phỏng ElastiCache), properties `spring.session.store-type=redis`, `spring.redis.host/port` từ container:
  - `contextStartsWhenConfigCommandDisabled` (chỉ cần context load)
  - `sessionSurvivesInstanceSwap`: đăng nhập trên MockMvc → lấy cookie `SESSION` → tạo `MockMvc` thứ hai từ một `ApplicationContext` khác (`new SpringApplicationBuilder(...)` cùng Redis) → `GET /user` với cookie đó trả view `user`
- [ ] **Step 2: Viết test thất bại `RenderedPagesTest`** (`webEnvironment = RANDOM_PORT`, profile test, `TestRestTemplate` giữ cookie, lấy CSRF bằng regex `name="_csrf" value="([^"]+)"`):
  - `footerShowsVersionAndHost`: `GET /` chứa `id="app-version"` và `id="served-by"` không rỗng
  - `usernameIsHtmlEscaped`: đăng ký `userName=<script>x</script>` → HTML trả về không chứa `<script>x</script>`, có `&lt;script&gt;`
- [ ] **Step 3: `make app-test`** → Expected: FAIL.
- [ ] **Step 4: Implement** (pom, properties, advice, footer, CSS/logo).
- [ ] **Step 5: `make app-test`** → Expected: PASS. `ls Java-Login-App/target/dptweb.war` tồn tại.
- [ ] **Step 6: Commit** `feat(app): redis-backed sessions, build footer, static assets`

---

## Phase 2 — Bootstrap và CI

> Test Terraform: `make tf-test` = với mỗi thư mục có `tests/`: `terraform -chdir=<dir> init -backend=false && terraform -chdir=<dir> test`. Mọi `*.tftest.hcl` dùng `mock_provider "aws" {}` (+ `mock_provider "random" {}` khi cần), `command = plan`, nên **không cần credentials AWS**. Dùng `override_data` cho `aws_caller_identity` (`account_id = "111122223333"`) và `aws_ssm_parameter` AMI.

### Task 5: Stack `bootstrap/`

**Files:** Create `infrastructure/bootstrap/{versions.tf,main.tf,variables.tf,outputs.tf,terraform.tfvars.example,tests/bootstrap.tftest.hcl}`

**Interfaces:**
- Variables: `aws_region` (default `us-east-1`), `alert_email` (string), `github_repo` (`"owner/name"`).
- State của bootstrap: **local** (`infrastructure/bootstrap/terraform.tfstate`, gitignored).
- Resources: S3 `java3tier-tfstate-<account_id>` (versioning, SSE-S3, block public access đủ 4 cờ); `aws_budgets_budget` COST $100/tháng, 3 notification ACTUAL 20/50/100 % tới `alert_email`; CodeArtifact domain `java3tier` + repository `maven-releases`; OIDC provider `token.actions.githubusercontent.com`; IAM role `java3tier-gha-publisher` (trust `repo:<github_repo>:ref:refs/heads/main`, quyền `codeartifact:GetAuthorizationToken/GetRepositoryEndpoint/PublishPackageVersion/PutPackageMetadata/ReadFromRepository` + `sts:GetServiceBearerToken`); SNS topic `java3tier-alerts` + subscription email; IAM instance profile `java3tier-packer` (CodeArtifact read + `sts:GetServiceBearerToken`).
- Outputs: `state_bucket`, `codeartifact_domain`, `codeartifact_domain_owner`, `codeartifact_repository`, `gha_role_arn`, `alerts_topic_arn`, `packer_instance_profile`.

- [ ] **Step 1: Viết `tests/bootstrap.tftest.hcl`** với các assert:
  - tên bucket == `"java3tier-tfstate-111122223333"`
  - public access block: cả 4 cờ `true`
  - tập threshold của budget == `[20, 50, 100]`
  - trust policy của role GHA chứa `repo:owner/name:ref:refs/heads/main` (đặt `github_repo = "owner/name"` trong `variables {}`)
  - repository CodeArtifact tên `maven-releases` thuộc domain `java3tier`
- [ ] **Step 2: `make tf-test`** → Expected: FAIL (chưa có resource).
- [ ] **Step 3: Implement** bootstrap.
- [ ] **Step 4: `make tf-test`** → PASS.
- [ ] **Step 5: Apply thật**: `terraform -chdir=infrastructure/bootstrap apply` → bấm xác nhận email SNS và email Budget. Kiểm tra: `aws codeartifact describe-repository --domain java3tier --repository maven-releases` thành công.
- [ ] **Step 6: Commit** `feat(infra): bootstrap stack (state, budget, codeartifact, oidc, alerts)`

### Task 6: GitHub Actions CI → SonarCloud → CodeArtifact

**Files:** Create `.github/workflows/ci.yml`, `Java-Login-App/ci-settings.xml`

**Interfaces:**
- Repo variables (đặt bằng `gh variable set`): `AWS_ROLE_ARN`, `CODEARTIFACT_DOMAIN`, `CODEARTIFACT_DOMAIN_OWNER`, `CODEARTIFACT_REPO`, `SONAR_ORG`, `SONAR_PROJECT_KEY`; secret: `SONAR_TOKEN`.
- `ci-settings.xml`: server id `codeartifact`, username `aws`, password `${env.CODEARTIFACT_AUTH_TOKEN}`.
- Job `test` (mọi push/PR): `actions/setup-java` temurin 11 + cache maven → `mvn -B verify` → nếu có `SONAR_TOKEN`: `mvn -B sonar:sonar -Dsonar.organization=$SONAR_ORG -Dsonar.projectKey=$SONAR_PROJECT_KEY -Dsonar.host.url=https://sonarcloud.io`.
- Job `publish` (`needs: test`, chỉ `push` vào `main`, `permissions: id-token: write, contents: read`): `aws-actions/configure-aws-credentials` (role `AWS_ROLE_ARN`) → lấy token CodeArtifact → `mvn -B versions:set -DnewVersion=1.0.${{ github.run_number }}` → `mvn -B -s ci-settings.xml deploy -DskipTests -DaltDeploymentRepository=codeartifact::default::<endpoint>`.

- [ ] **Step 1: Lint workflow**: `docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint:latest` → Expected: không lỗi.
- [ ] **Step 2: Tạo project trên SonarCloud** (import repo GitHub), đặt variables/secret bằng `gh`.
- [ ] **Step 3: Push, theo dõi**: `gh run watch` → Expected: `test` và `publish` xanh.
- [ ] **Step 4: Xác minh artifact**:
  `aws codeartifact list-package-versions --domain java3tier --repository maven-releases --format maven --namespace com.devopsrealtime --package dptweb`
  Expected: có version `1.0.<run_number>`.
- [ ] **Step 5: Commit** `ci: build, sonarcloud scan, publish war to codeartifact`

---

## Phase 3 — Ansible roles

> Test role chung: `make molecule ROLE=<role>` = `cd ansible/roles/<role> && ../../../.venv/bin/molecule test` (driver docker; image `amazonlinux:2023` cho role chạy trên AL2023, `ubuntu:24.04` cho `wireguard`/`strongswan`). Molecule mặc định chạy cả bước **idempotence**. `make lint` = `ansible-lint ansible/` (profile `production`).
>
> Biến toàn cục (trong `group_vars/all.yml`, molecule ghi đè): `java3tier_services_enabled` (bool), `java3tier_services_started` (bool). Molecule: `false/false`; Packer bake: `true/false`; vận hành: `true/true`.

### Task 7: Khung Ansible + role `common`

**Files:** Create `ansible/{ansible.cfg,requirements.yml,.ansible-lint}`, `ansible/inventory/aws_ec2.yml`, `ansible/group_vars/{all,tier_web,tier_app,tier_bastion,tier_cgw}.yml`, `ansible/roles/common/{defaults,tasks,handlers,templates}/…`, `ansible/roles/common/molecule/default/{molecule.yml,converge.yml,verify.yml}`

**Interfaces:**
- `requirements.yml`: `amazon.aws`, `community.aws`, `community.mysql`, `community.general`, `ansible.posix`.
- Inventory `aws_ec2.yml`: `regions: [us-east-1]`, filter `tag:Project: java3tier` + `instance-state-name: running`, `keyed_groups: [{key: tags.Tier, prefix: tier}]`, `hostnames: [private-ip-address]`, `compose: {ansible_host: "public_ip_address if tags.Tier == 'cgw' else private_ip_address"}`.
- Group vars: `ansible_user` = `ec2-user` (AL2023) / `ubuntu` (`tier_cgw`); `ansible_ssh_private_key_file: ~/.ssh/java3tier_ed25519`; `tier_web`/`tier_app`: `ansible_ssh_common_args: "-o ProxyJump=ec2-user@{{ groups['tier_bastion'] | first }}"`.
- Role `common` vars: `common_cw_log_files: []` (list `{path, log_group}`).
- Role `common` làm: `PasswordAuthentication no`, `PermitRootLogin no` (handler reload sshd chỉ khi `java3tier_services_started`); cài `amazon-cloudwatch-agent` và render `/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json` từ `common_cw_log_files`; enable agent theo `java3tier_services_enabled`.

- [ ] **Step 1: Viết `verify.yml`** assert: `sshd_config` chứa `PasswordAuthentication no` và `PermitRootLogin no`; file JSON agent parse được (`from_json`) và chứa path `/var/log/test.log` (converge truyền `common_cw_log_files: [{path: /var/log/test.log, log_group: /java3tier/test}]`).
- [ ] **Step 2: `make molecule ROLE=common`** → FAIL (role trống).
- [ ] **Step 3: Implement** khung + role.
- [ ] **Step 4: `make molecule ROLE=common` && `make lint`** → PASS, idempotence `changed=0`.
- [ ] **Step 5: Commit** `feat(ansible): scaffold, dynamic inventory, common role`

### Task 8: Role `nginx` (tầng Web)

**Files:** Create `ansible/roles/nginx/{defaults,tasks,handlers,templates,files}/…`, `molecule/default/*`

**Interfaces:**
- Templates/files: `/etc/nginx/conf.d/java3tier.conf`, `/usr/local/bin/render-web-config`, systemd drop-in `/etc/systemd/system/nginx.service.d/java3tier.conf` (`ExecStartPre=/usr/local/bin/render-web-config`).
- `render-web-config`: đọc `/java3tier/app/internal_nlb_dns` từ SSM (hoặc env `RENDER_WEB_BACKEND` khi được đặt — dùng cho test), ghi `/etc/nginx/java3tier/backend.conf` với đúng một dòng `set $app_backend "<dns>";`; thoát mã ≠ 0 kèm thông báo `missing parameter /java3tier/app/internal_nlb_dns` nếu không lấy được.
- `java3tier.conf`: `listen 80`; `location = /nginx-health { return 200 "ok"; }`; `location / { resolver 169.254.169.253 valid=30s; include /etc/nginx/java3tier/backend.conf; proxy_pass http://$app_backend:8080; }` + `Host`, `X-Forwarded-For`, `X-Forwarded-Proto https`. (Dùng biến + resolver để Nginx resolve lại IP của NLB, không giữ IP cũ mãi.)
- Var log: `common_cw_log_files` cho tier web = access/error log của nginx → log group `/java3tier/web`.

- [ ] **Step 1: Viết `verify.yml`**: chạy `RENDER_WEB_BACKEND=backend.test /usr/local/bin/render-web-config`; assert nội dung `backend.conf` == `set $app_backend "backend.test";`; `nginx -t` exit 0; chạy script không có env và không có AWS → exit ≠ 0, stderr chứa `missing parameter`.
- [ ] **Step 2: `make molecule ROLE=nginx`** → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: `make molecule ROLE=nginx` && `make lint`** → PASS.
- [ ] **Step 5: Commit** `feat(ansible): nginx role with boot-time backend rendering`

### Task 9: Role `tomcat`

**Files:** Create `ansible/roles/tomcat/…`, `molecule/default/*`

**Interfaces:**
- Defaults: `tomcat_version` (bản 9.0.x mới nhất tại thời điểm làm, lấy từ `https://archive.apache.org/dist/tomcat/tomcat-9/`), `tomcat_checksum` (`sha512:` của tarball đó), `tomcat_home: /opt/tomcat`, user/group `tomcat`, `tomcat_java_opts: "-Xms256m -Xmx512m"`.
- Cài `java-11-amazon-corretto-headless`; giải nén vào `/opt/apache-tomcat-<ver>`, symlink `/opt/tomcat`; **xóa toàn bộ webapps mặc định**; `server.xml` có `RemoteIpValve` (`internalProxies="172\.32\.\d+\.\d+"`, `protocolHeader="X-Forwarded-Proto"`).
- Unit `/etc/systemd/system/tomcat.service`: `Type=simple`, `ExecStart=/opt/tomcat/bin/catalina.sh run`, `EnvironmentFile=-/etc/java3tier/app.env`, `Restart=on-failure`, `RestartSec=10`.

- [ ] **Step 1: `verify.yml`**: `/opt/tomcat/bin/version.sh` chứa `Apache Tomcat/9.0.`; `java -version` chứa `11.`; `/opt/tomcat/webapps` rỗng; `server.xml` chứa `RemoteIpValve`; unit chứa `EnvironmentFile=-/etc/java3tier/app.env` và `Restart=on-failure`.
- [ ] **Step 2: FAIL → Step 3: Implement → Step 4: PASS + lint.**
- [ ] **Step 5: Commit** `feat(ansible): tomcat 9 role`

### Task 10: Role `app_deploy`

**Files:** Create `ansible/roles/app_deploy/…`, `molecule/default/*` (molecule `dependency` gồm role `tomcat`)

**Interfaces:**
- Vars: `app_version` (bắt buộc), `app_codeartifact_domain`, `app_codeartifact_domain_owner`, `app_codeartifact_repository`, `app_war_src` (mặc định rỗng; nếu đặt thì copy file local thay vì tải CodeArtifact — dùng cho molecule).
- Tải WAR trên máy đích bằng `aws codeartifact get-package-version-asset --format maven --namespace com.devopsrealtime --package dptweb --package-version {{ app_version }} --asset dptweb-{{ app_version }}.war <dest>` → cài thành `/opt/tomcat/webapps/ROOT.war` (xóa thư mục `ROOT/` cũ), ghi `/etc/java3tier/app-version` = `app_version`; restart tomcat chỉ khi `java3tier_services_started`.
- `/usr/local/bin/render-app-config`: đọc các parameter `/java3tier/db/*`, `/java3tier/redis/*` (SecureString có decrypt) — hoặc từ env `RENDER_APP_FROM_ENV=1` cho test — ghi `/etc/java3tier/app.env` (owner `tomcat`, mode `0600`) với đúng các key:
  `SPRING_DATASOURCE_URL=jdbc:mysql://<db_host>:3306/UserDB?sslMode=REQUIRED`, `SPRING_DATASOURCE_USERNAME`, `SPRING_DATASOURCE_PASSWORD`, `SPRING_REDIS_HOST`, `SPRING_REDIS_PORT=6379`, `SPRING_REDIS_PASSWORD`, `SPRING_REDIS_SSL=true`. Thiếu parameter → exit ≠ 0, stderr `missing parameter <tên>`.
- Drop-in `/etc/systemd/system/tomcat.service.d/java3tier.conf`: `ExecStartPre=+/usr/local/bin/render-app-config`.

- [ ] **Step 1: `verify.yml`**: `ROOT.war` tồn tại (converge dùng `app_war_src` là một file war giả); `/etc/java3tier/app-version` == `1.0.0-test`; chạy render với `RENDER_APP_FROM_ENV=1` và env giả → `app.env` mode `0600`, chứa đủ 7 key, URL đúng dạng trên; chạy render **không** env → exit ≠ 0, stderr chứa `missing parameter`.
- [ ] **Step 2: FAIL → Step 3: Implement → Step 4: PASS + lint.**
- [ ] **Step 5: Commit** `feat(ansible): app_deploy role with ssm-rendered runtime config`

### Task 11: Role `wireguard` và `strongswan` (máy CGW, Ubuntu 24.04)

**Files:** Create `ansible/roles/wireguard/…`, `ansible/roles/strongswan/…`, mỗi role một `molecule/default/*`

**Interfaces:**
- `wireguard` vars: `wireguard_port: 51820`, `wireguard_server_address: 10.99.0.1/24`, `wireguard_client_address: 10.99.0.2/32`, `wireguard_client_allowed_ips: ["10.10.0.0/16", "192.168.0.0/16"]`, `wireguard_endpoint` (mặc định `{{ ansible_host }}`), `wireguard_generated_dir: "{{ playbook_dir }}/../.generated"`.
  - Khóa **laptop** sinh trên control node (`wg genkey` → `.generated/laptop.key`, chỉ sinh khi chưa có); khóa **server** sinh trên CGW (`/etc/wireguard/server.key`, chỉ sinh khi chưa có). Server chỉ nhận public key của laptop.
  - Server: `/etc/wireguard/wg0.conf` (`ListenPort`, `[Peer] AllowedIPs = 10.99.0.2/32`), `net.ipv4.ip_forward=1`, enable `wg-quick@wg0` theo cờ services.
  - Xuất `.generated/office.conf` (mode 0600) với `Endpoint = <endpoint>:51820` và `AllowedIPs = 10.10.0.0/16, 192.168.0.0/16`.
- `strongswan` vars: `strongswan_tunnels` (list 2 phần tử `{outside_ip, psk, cgw_inside_cidr, aws_inside_ip}`, lấy từ `.generated/vpn.yml` của Task 22), `strongswan_remote_cidrs: ["192.168.0.0/16"]`.
  - Gói `charon-systemd`, `strongswan-swanctl`; `/etc/swanctl/conf.d/aws.conf`: 2 connection route-based, `if_id_in/if_id_out` = 1 và 2, `local_ts = remote_ts = 0.0.0.0/0`, `start_action = start`, DPD restart, IKEv2, AES-256/SHA-256/modp2048; `charon.install_routes = no`.
  - Service `java3tier-xfrm.service` tạo `xfrm1`/`xfrm2` (`ip link add xfrmN type xfrm if_id N`), gán `cgw_inside_cidr`, route `192.168.0.0/16` qua `xfrm1` metric 100 và `xfrm2` metric 200; iptables `TCPMSS --clamp-mss-to-pmtu` trên `xfrm+`.

- [ ] **Step 1: `verify.yml` (wireguard)**: `wg0.conf` chứa `ListenPort = 51820` và public key của laptop; `office.conf` trên control node chứa đúng `AllowedIPs = 10.10.0.0/16, 192.168.0.0/16`; **`client key unchanged on second converge`**: lưu checksum của `laptop.key` trong prepare, so sánh sau idempotence step.
- [ ] **Step 2: `verify.yml` (strongswan)** với 2 tunnel giả (`203.0.113.10`, `203.0.113.20`): `aws.conf` chứa cả 2 outside IP, `if_id_in = 1`, `if_id_in = 2`, `start_action = start`; unit xfrm chứa `if_id 1` và `if_id 2`; `swanctl.conf` có `install_routes = no`; file chứa PSK có mode `0600`.
- [ ] **Step 3: FAIL → Step 4: Implement → Step 5: PASS + lint cho cả hai role.**
- [ ] **Step 6: Commit** `feat(ansible): wireguard + strongswan roles for office CGW`

### Task 12: Role `bastion` và `db_init`

**Files:** Create `ansible/roles/bastion/…`, `ansible/roles/db_init/…`, `ansible/roles/db_init/molecule/default/*` (2 platform: `mysql:8.0` và `amazonlinux:2023` cùng network)

**Interfaces:**
- `bastion`: cài `mariadb105`, `python3-PyMySQL`.
- `db_init` vars (playbook truyền vào từ lookup SSM trên control node): `db_init_host`, `db_init_master_user`, `db_init_master_password`, `db_init_app_user: appuser`, `db_init_app_password`. Làm: `community.mysql.mysql_db` `UserDB` present → `mysql_db state=import` với `db/schema.sql` → `mysql_user appuser@'%'` priv `UserDB.Employee:SELECT,INSERT`.

- [ ] **Step 1: `verify.yml`**: đăng nhập `appuser` → `INSERT` vào `Employee` thành công; `DROP TABLE Employee` bị từ chối (`ERROR 1142`); idempotence của molecule pass (chạy lần 2 không lỗi, `changed=0` trừ task import được đánh `changed_when: false`).
- [ ] **Step 2: FAIL → Step 3: Implement → Step 4: PASS + lint.**
- [ ] **Step 5: Commit** `feat(ansible): bastion and db_init roles`

---

## Phase 4 — Packer

### Task 13: Bake AMI web/app

**Files:** Create `packer/{java3tier.pkr.hcl,variables.pkr.hcl}`, `ansible/playbooks/{packer-web.yml,packer-app.yml}`, `scripts/prune-amis.sh`; Modify `Makefile` (`ami`, `ami-web`, `ami-app`)

**Interfaces:**
- Variables: `app_version` (bắt buộc cho app), `instance_profile` (= output `packer_instance_profile`), `codeartifact_domain_owner`.
- 2 source `amazon-ebs.web` / `amazon-ebs.app`: base AL2023 qua `data "amazon-parameterstore"`, `t3.micro`, default VPC, `ssh_username = "ec2-user"`, `iam_instance_profile`, `ami_name = "java3tier-<role>-{{timestamp}}"`, tags `Project=java3tier`, `Role=<role>`, `AppVersion=<app_version|n/a>`.
- Provisioner `ansible` chạy `packer-<role>.yml` với `java3tier_services_enabled=true java3tier_services_started=false`.
  - `packer-web.yml`: `common` + `nginx`; `packer-app.yml`: `common` + `tomcat` + `app_deploy`.
- `make ami APP_VERSION=1.0.N` bake cả hai. `scripts/prune-amis.sh` giữ 2 AMI mới nhất cho mỗi `Role`, deregister + xóa snapshot phần còn lại.

- [ ] **Step 1: `packer init packer && packer validate -var app_version=0 packer`** → PASS.
- [ ] **Step 2: `make ami APP_VERSION=<version từ Task 6>`** → Expected: 2 AMI ID in ra.
- [ ] **Step 3: Kiểm tra**: `aws ec2 describe-images --owners self --filters Name=tag:Project,Values=java3tier --query 'Images[].Tags'` → có `Role=web` và `Role=app` với `AppVersion=<version>`.
- [ ] **Step 4: `scripts/prune-amis.sh --dry-run`** → in danh sách sẽ xóa (rỗng nếu ≤ 2 mỗi role).
- [ ] **Step 5: Commit** `feat(packer): bake web/app AMIs with ansible roles`

---

## Phase 5 — Terraform `live/`

> Mỗi module có `tests/<module>.tftest.hcl` (mock provider, `command = plan`). Mọi module nhận `name_prefix` (mặc định `java3tier`) và `tags` (map).

### Task 14: Module `vpc` (viết lại, dùng chung cho cả 3 VPC)

**Files:** Modify (viết lại) `infrastructure/modules/vpc/{main,variables,outputs}.tf`; Create `tests/vpc.tftest.hcl`

**Interfaces:**
- Variables: `name`, `cidr`, `azs` (list), `public_subnets` (list), `private_subnets` (map(list(string)) theo tier), `nat_gateway` (bool, default false — tạo **1** NAT ở public subnet đầu tiên), `enable_flow_logs` (bool, default false).
- Outputs: `vpc_id`, `public_subnet_ids` (list), `private_subnet_ids` (map(list(string))), `public_route_table_id`, `private_route_table_id` (một RT private dùng chung).

- [ ] **Step 1: Tests**:
  - `app_vpc`: CIDR/subnet của VPC ứng dụng (Global Constraints) → 2 public, 6 private, đúng 1 `aws_nat_gateway`, `private_subnet_ids["data"]` có 2 phần tử nằm ở 2 AZ khác nhau
  - `office_vpc`: `nat_gateway=false`, private `{lan=["10.10.2.0/24"]}` → 0 NAT, 1 private subnet
- [ ] **Step 2: `make tf-test`** FAIL → **Step 3: Implement** → **Step 4:** PASS.
- [ ] **Step 5: Commit** `refactor(infra): generic vpc module`

### Task 15: Module `tgw` và `vpn`

**Files:** Create `infrastructure/modules/{tgw,vpn}/…` + tests

**Interfaces:**
- `vpn` vars: `customer_gateway_ip`, `transit_gateway_id`, `bgp_asn` (default 65000). Tạo `aws_customer_gateway` (`type = "ipsec.1"`) + `aws_vpn_connection` (`static_routes_only = true`). Outputs: `vpn_connection_id`, `transit_gateway_attachment_id`, `tunnels` (sensitive, list 2 phần tử `{outside_ip, psk, cgw_inside_cidr, aws_inside_ip}`, `cgw_inside_cidr` = `<tunnelN_cgw_inside_address>/30`).
- `tgw` vars: `amazon_side_asn` (64512), `vpc_attachments` (map `{mgmt = {vpc_id, subnet_ids}, app = {...}}`), `vpn_attachment_id`, `vpc_routes` (list `{route_table_id, cidr}` — các route trong VPC route table trỏ về TGW). TGW tắt default route table association/propagation. Outputs: `transit_gateway_id`, `route_table_ids` (map `office|mgmt|app`).
- Bảng định tuyến TGW (chính xác):
  | TGW route table | Gắn với | Routes |
  |---|---|---|
  | `office` | VPN attachment | `192.168.0.0/16` → mgmt |
  | `mgmt` | mgmt attachment | `10.10.0.0/16`, `10.99.0.0/24` → VPN; `172.32.0.0/16` → app |
  | `app` | app attachment | `192.168.0.0/16` → mgmt |

- [ ] **Step 1: Tests (`tgw`)**: route table `office` có route `192.168.0.0/16` và **không có** route `172.32.0.0/16`; `app` chỉ có `192.168.0.0/16`; `default_route_table_association == "disable"`. **(`vpn`)**: `static_routes_only == true`, `type == "ipsec.1"`.
- [ ] **Step 2: FAIL → Step 3: Implement → Step 4: PASS.**
- [ ] **Step 5: Commit** `feat(infra): transit gateway and site-to-site vpn modules`

### Task 16: Module `office` và `bastion`

**Files:** Create `infrastructure/modules/{office,bastion}/…` + tests

**Interfaces:**
- `office` vars: `admin_cidr` (IP laptop `/32`), `vpn_peer_ips` (list 2 outside IP), `key_name`, `aws_cidrs` (default `["192.168.0.0/16"]`). Gọi module `vpc` (`10.10.0.0/16`, public `10.10.1.0/24`, private `{lan = ["10.10.2.0/24"]}`); EC2 CGW Ubuntu 24.04 `t3.micro`, `source_dest_check = false`, EIP, tag `Tier=cgw`; SG: `22/tcp` và `51820/udp` từ `admin_cidr`; `500/udp`, `4500/udp`, protocol `50` từ từng `vpn_peer_ips`; route `aws_cidrs` + `10.99.0.0/24` trong RT public/private trỏ về ENI của CGW (route `10.99.0.0/24` chỉ cần trong RT private). Outputs: `vpc_id`, `cgw_public_ip`, `cgw_instance_id`.
- `bastion` vars: `subnet_id`, `vpc_id`, `key_name`, `allowed_cidrs` (default `["10.10.0.0/16","10.99.0.0/24"]`). AL2023 `t3.micro`, public IP (để ra Internet), tag `Tier=bastion`; SG chỉ `22/tcp` từ `allowed_cidrs`. Outputs: `private_ip`, `security_group_id`.

- [ ] **Step 1: Tests**: CGW `source_dest_check == false`; SG CGW không có ingress `0.0.0.0/0` trên 22; SG bastion chỉ chứa 2 CIDR trong `allowed_cidrs`; route `192.168.0.0/16` của office trỏ tới `network_interface_id` của CGW.
- [ ] **Step 2: FAIL → Step 3: Implement → Step 4: PASS.**
- [ ] **Step 5: Commit** `feat(infra): simulated office (cgw) and bastion modules`

### Task 17: Module `security` (viết lại cho VPC ứng dụng)

**Files:** Modify (viết lại) `infrastructure/modules/security/…`; Create `tests/security.tftest.hcl`

**Interfaces:**
- Vars: `vpc_id`, `admin_cidr` (default `192.168.1.0/24` — subnet bastion; SG không tham chiếu được SG qua TGW nên dùng CIDR).
- SGs (dùng `aws_vpc_security_group_ingress_rule`), outputs `*_sg_id`:
  | SG | Ingress |
  |---|---|
  | `nlb_public` | 80 từ managed prefix list `com.amazonaws.global.cloudfront.origin-facing` |
  | `web` | 80 từ `nlb_public`; 22 từ `admin_cidr` |
  | `nlb_internal` | 8080 từ `web` |
  | `app` | 8080 từ `nlb_internal`; 22 từ `admin_cidr` |
  | `rds` | 3306 từ `app`; 3306 từ `admin_cidr` |
  | `redis` | 6379 từ `app` |

- [ ] **Step 1: Tests**: không rule nào có `cidr_ipv4 == "0.0.0.0/0"`; nguồn của `rds` đúng bằng `{app SG, 192.168.1.0/24}`; `nlb_public` chỉ có 1 ingress và đó là prefix list.
- [ ] **Step 2: FAIL → Step 3: Implement → Step 4: PASS.**
- [ ] **Step 5: Commit** `feat(infra): tiered security groups`

### Task 18: Module `nlb` và `asg`

**Files:** Create `infrastructure/modules/nlb/…`; Modify (viết lại) `infrastructure/modules/asg/…`; tests cho cả hai. Delete `infrastructure/modules/alb/`.

**Interfaces:**
- `nlb` vars: `name`, `internal` (bool), `subnet_ids`, `security_group_ids`, `port`, `health_check_path`, `deregistration_delay` (30). Health check HTTP, interval 10, healthy/unhealthy threshold 2. Outputs: `dns_name`, `arn_suffix`, `target_group_arn`, `target_group_arn_suffix`.
- `asg` vars: `name`, `tier` (`web`|`app`), `subnet_ids`, `security_group_ids`, `target_group_arns`, `key_name`, `instance_type` (`t3.micro`), `min_size` 2, `max_size` 4, `desired_capacity` 2, `cpu_target` 60, `ssm_parameter_paths` (list ARN path), `allow_codeartifact_read` (bool), `log_group_names` (list). AMI: `data "aws_ami"` `most_recent`, `owners = ["self"]`, filter `tag:Project=java3tier`, `tag:Role=<tier>`. Launch template IMDSv2 (`http_tokens = "required"`), không cần user_data; instance profile riêng (SSM read theo path, `CloudWatchAgentServerPolicy`, CodeArtifact read khi bật). `health_check_type = "ELB"`, grace 180; tag propagate `Project`, `Tier`, `Name`. Outputs: `asg_name`, `launch_template_id`.

- [ ] **Step 1: Tests**: `nlb` internal → `internal == true`, health path `/actuator/health/lb`, `deregistration_delay == "30"`; `asg` → min/max/desired 2/4/2, `http_tokens == "required"`, target tracking `target_value == 60`, filter AMI có `tag:Role` = `web`.
- [ ] **Step 2: FAIL → Step 3: Implement → Step 4: PASS.**
- [ ] **Step 5: Commit** `feat(infra): nlb and asg modules`

### Task 19: Module `rds`, `elasticache`, `params`

**Files:** Modify (viết lại) `infrastructure/modules/rds/…`; Create `infrastructure/modules/{elasticache,params}/…`; tests

**Interfaces:**
- `rds` vars: `subnet_ids`, `security_group_ids`, `master_username` (`admin`), `master_password`. MySQL `8.0`, `db.t3.micro`, `multi_az = true`, `db_name = "UserDB"`, gp3 20 GB, `backup_retention_period = 1`, `publicly_accessible = false`, `skip_final_snapshot = true`, `deletion_protection = false`, `apply_immediately = true`, `storage_encrypted = true`. Outputs: `address`, `identifier`.
- `elasticache` vars: `subnet_ids`, `security_group_ids`, `auth_token`. Replication group Redis `7.1`, `cache.t3.micro`, `num_cache_clusters = 2`, `automatic_failover_enabled = true`, `multi_az_enabled = true`, `transit_encryption_enabled = true`, `at_rest_encryption_enabled = true`, port 6379. Outputs: `primary_endpoint_address`, `replication_group_id`.
- `params` vars: `db_host`, `db_master_password`, `db_app_password`, `redis_host`, `redis_auth_token`, `internal_nlb_dns`. Tạo đúng 9 parameter trong Global Constraints (trừ `/java3tier/app/version`, do rolling deploy ghi). Password do root tạo bằng `random_password` (DB: 24 ký tự, `override_special = "!#$%^&*()-_=+"`; Redis: 32 ký tự alnum).

- [ ] **Step 1: Tests**: rds `multi_az == true`, `publicly_accessible == false`; redis `transit_encryption_enabled == true`, `num_cache_clusters == 2`; params: tập tên == 9 tên trong Global Constraints (trừ version), 3 cái `*_password`/`auth_token` có `type == "SecureString"`.
- [ ] **Step 2: FAIL → Step 3: Implement → Step 4: PASS.**
- [ ] **Step 5: Commit** `feat(infra): rds, elasticache, ssm parameters`

### Task 20: Module `cloudfront` và `monitoring`

**Files:** Create `infrastructure/modules/cloudfront/…`; Modify (viết lại) `infrastructure/modules/monitoring/…`; tests

**Interfaces:**
- `cloudfront` vars: `nlb_dns_name`. Bucket `java3tier-static-<account_id>` (`force_destroy = true`, block public), OAC + bucket policy chỉ cho `cloudfront.amazonaws.com` với `AWS:SourceArn` = distribution. Distribution: default behavior → origin NLB (`http-only`, port 80), allowed methods đủ 7, cache policy *CachingDisabled* `4135ea2d-6df8-44a3-9df3-4b5a84be39ad`, origin request policy *AllViewer* `216adef6-5c7f-47e4-b989-5492eafa07d3`; ordered behavior `/static/*` → S3, *CachingOptimized* `658327ea-f89d-4fab-a63d-7e88639e58f6`; `viewer_protocol_policy = "redirect-to-https"`; `PriceClass_100`; default certificate. Outputs: `domain_name`, `bucket_name`, `distribution_id`.
- `monitoring` vars: `alerts_topic_arn`, `rds_identifier`, `app_asg_name`, `vpn_connection_id`, `target_groups` (map `web|app` → `{tg_suffix, lb_suffix}`), `redis_replication_group_id`. Log groups `/java3tier/web`, `/java3tier/app` (retention 7). Alarms: RDS `CPUUtilization > 80` (5 phút), app ASG `CPUUtilization > 80`, VPN `TunnelState` (dimension `VpnId`) `Maximum < 1` trong 3 chu kỳ 5 phút, `UnHealthyHostCount > 0` (namespace `AWS/NetworkELB`) cho mỗi TG. Mọi alarm có `alarm_actions = [alerts_topic_arn]`.

- [ ] **Step 1: Tests**: cloudfront có đúng 2 origin và behavior `/static/*` dùng cache policy *CachingOptimized*; default behavior `viewer_protocol_policy == "redirect-to-https"`; monitoring tạo 5 alarm và alarm nào cũng chứa `alerts_topic_arn`.
- [ ] **Step 2: FAIL → Step 3: Implement → Step 4: PASS.**
- [ ] **Step 5: Commit** `feat(infra): cloudfront edge and monitoring`

### Task 21: Root `live/`

**Files:** Create `infrastructure/live/{versions.tf,main.tf,variables.tf,outputs.tf,terraform.tfvars.example,backend.hcl.example,tests/live.tftest.hcl}`, `infrastructure/README.md` (ngắn: thứ tự bootstrap → live). Delete `infrastructure/main.tf`, `infrastructure/variables.tf`.

**Interfaces:**
- Backend: `backend "s3" {}` partial; `backend.hcl` = `bucket = <state_bucket>`, `key = "live/terraform.tfstate"`, `region = "us-east-1"`, `use_lockfile = true`.
- Đọc bootstrap bằng `data "terraform_remote_state" "bootstrap" { backend = "local", config = { path = "../bootstrap/terraform.tfstate" } }`.
- Variables: `admin_cidr`, `ssh_public_key` (nội dung `~/.ssh/java3tier_ed25519.pub`).
- Wiring: 3 VPC (`vpc` module ×2 + `office`), `tgw`, `vpn`, `bastion`, `security`, `nlb` ×2 (public NLB ở public subnets, port 80 → TG web; internal NLB ở app subnets, port 8080 → TG app), `asg` ×2 (web: `ssm_parameter_paths = ["/java3tier/app/*"]`; app: `["/java3tier/db/*","/java3tier/redis/*"]`, `allow_codeartifact_read = true`), `rds`, `elasticache`, `params`, `cloudfront`, `monitoring`. VPC routes vào TGW: RT public của mgmt → `10.10.0.0/16`, `10.99.0.0/24`, `172.32.0.0/16`; RT private của app → `192.168.0.0/16`. Cả hai ASG `depends_on = [module.params]` (máy boot lần đầu là đọc được parameter).
- Outputs (Task 22 dùng): `cloudfront_domain`, `static_bucket`, `cgw_public_ip`, `bastion_private_ip`, `vpn_tunnels` (sensitive), `web_target_group_arn`, `app_target_group_arn`, `app_asg_name`, `web_asg_name`, `public_nlb_dns`.

- [ ] **Step 1: Test `live.tftest.hcl`** (mock `aws` + `random`, `override_data` cho remote state và AMI): plan thành công; assert `output.cloudfront_domain` khác rỗng; số `aws_autoscaling_group` == 2.
- [ ] **Step 2: FAIL → Step 3: Implement → Step 4: PASS**, `terraform -chdir=infrastructure/live validate` OK.
- [ ] **Step 5: Plan thật (không apply)**: `terraform -chdir=infrastructure/live init -backend-config=backend.hcl && terraform -chdir=infrastructure/live plan -var admin_cidr=$(curl -s https://checkip.amazonaws.com)/32` → Expected: plan không lỗi.
- [ ] **Step 6: Commit** `feat(infra): live stack wiring`

---

## Phase 6 — Vận hành end-to-end

### Task 22: `make up` / `make down` / smoke test — triển khai thật lần đầu

**Files:** Create `scripts/{up.sh,down.sh,gen-ansible-vars.sh,smoke.sh}`, `ansible/playbooks/{cgw.yml,bastion.yml,db_init.yml}`; Modify `Makefile` (`up`, `down`, `smoke`)

**Interfaces:**
- `scripts/up.sh`: (1) `ADMIN_CIDR=$(curl -s https://checkip.amazonaws.com)/32`, in ra; (2) `terraform apply -var admin_cidr=$ADMIN_CIDR`; (3) `gen-ansible-vars.sh` → `ansible/.generated/vpn.yml` (`strongswan_tunnels`) và `live.yml` (TG ARN, bucket…) từ `terraform output -json`; (4) `cgw.yml` (roles `common`, `wireguard`, `strongswan`); (5) `sudo install -m600 ansible/.generated/office.conf /etc/wireguard/java3tier.conf && sudo wg-quick up java3tier`; (6) chờ `ping -c1 <bastion_private_ip>` (timeout 5 phút); (7) `bastion.yml` + `db_init.yml` (lookup mật khẩu bằng `amazon.aws.aws_ssm`); (8) `aws s3 sync web-static/ s3://<static_bucket>/`; (9) chờ mỗi TG có ≥ 2 target `healthy` (timeout 10 phút); (10) `smoke.sh https://<cloudfront_domain>`. Dừng ở bước lỗi đầu tiên (`set -euo pipefail`).
- `scripts/down.sh`: hỏi xác nhận → `sudo wg-quick down java3tier` (bỏ qua nếu không chạy) → `terraform destroy` → kiểm tra không còn instance `Project=java3tier` đang chạy. Không đụng `bootstrap/` và AMI.
- `scripts/smoke.sh <base_url> [EXPECT_VERSION]`: mỗi kiểm tra in `PASS <tên>` / `FAIL <tên>`, exit ≠ 0 nếu có FAIL:
  1. `home`: `GET /` → 200, chứa `Login Here`
  2. `static`: `GET /static/css/app.css` → 200
  3. `register`: user ngẫu nhiên → chứa `user account has been added for`
  4. `login`: → 302 `/user`; `GET /user` chứa `Welcome <user>`
  5. `wrong-password`: chứa `Invalid username or password`
  6. `shared-session`: 20 lần `GET /user` cùng cookie → cả 20 lần đều `Welcome`, và có ≥ 2 giá trị `served-by` khác nhau
  7. `nlb-locked`: `curl --max-time 5 http://<public_nlb_dns>/` **thất bại** (chỉ CloudFront vào được)
  8. `version` (khi có `EXPECT_VERSION`): mọi `app-version` thu được ở bước 6 == `EXPECT_VERSION`

- [ ] **Step 1: Kiểm tra lấy IP**: chạy `bash -c 'source scripts/up.sh --print-admin-cidr'` (flag chỉ in rồi thoát) → in ra `<ip>/32` đúng với `curl -s https://checkip.amazonaws.com`.
- [ ] **Step 2: Tạo SSH key**: `ssh-keygen -t ed25519 -f ~/.ssh/java3tier_ed25519 -N ''` (nếu chưa có).
- [ ] **Step 3: `make up`** → Expected: kết thúc bằng 7 dòng `PASS` (bước 8 bỏ qua).
- [ ] **Step 4: Kiểm tra mạng**: `aws ec2 describe-vpn-connections --query 'VpnConnections[0].VgwTelemetry[].Status'` → `["UP","UP"]`; `ansible-inventory -i ansible/inventory/aws_ec2.yml --graph` → `tier_web` 2, `tier_app` 2, `tier_bastion` 1, `tier_cgw` 1; từ laptop `ssh` thẳng tới IP 172.32.x **không** đi được, qua ProxyJump bastion thì được.
- [ ] **Step 5: Chạy lại `make up` lần 2** → Expected: Terraform `No changes`, Ansible `changed=0` trên CGW/bastion, smoke PASS (Review Focus 5).
- [ ] **Step 6: Commit** `feat: one-command up/down with end-to-end smoke test`

### Task 23: Rolling deploy không downtime

**Files:** Create `ansible/playbooks/rolling_deploy.yml`, `scripts/load-check.sh`; Modify `Makefile` (`deploy APP_VERSION=`)

**Interfaces:**
- Play 1 (`hosts: localhost`, `run_once`): `aws codeartifact describe-package-version … --package-version {{ app_version }}` — lỗi thì **dừng toàn bộ**, thông báo `version {{ app_version }} not found in CodeArtifact`.
- Play 2 (`hosts: tier_app`, `serial: 1`, `max_fail_percentage: 0`): deregister khỏi `app_target_group_arn` (`delegate_to: localhost`, id = `hostvars[inventory_hostname].instance_id`) → `aws elbv2 wait target-deregistered` → role `app_deploy` (`java3tier_services_started=true`) → `uri http://localhost:8080/actuator/health/lb` retry 30×5s → register → `aws elbv2 wait target-in-service`.
- Play 3 (localhost): `aws ssm put-parameter --name /java3tier/app/version --overwrite --value {{ app_version }}`.
- `scripts/load-check.sh <url> <seconds>`: gọi `GET /` mỗi 0.2s, in tổng số request và số response khác 200, exit ≠ 0 nếu có response khác 200.
- Sau deploy, nhắc trong output: `make ami APP_VERSION=… && terraform apply` để máy scale out sau này dùng version mới.

- [ ] **Step 1: Push một thay đổi nhỏ** (ví dụ đổi tiêu đề trang home) → CI publish `1.0.<N+1>`.
- [ ] **Step 2: Chạy `scripts/load-check.sh https://<cf> 300 &`** rồi `make deploy APP_VERSION=1.0.<N+1>`.
- [ ] **Step 3: Kiểm tra** → load-check exit 0 (0 response lỗi); `scripts/smoke.sh https://<cf> 1.0.<N+1>` PASS cả 8 kiểm tra.
- [ ] **Step 4: Version không tồn tại**: `make deploy APP_VERSION=9.9.9` → Expected: fail với `version 9.9.9 not found in CodeArtifact`; `aws elbv2 describe-target-health --target-group-arn <app_tg>` vẫn 2 `healthy` (Review Focus 3).
- [ ] **Step 5: Commit** `feat(ansible): zero-downtime rolling deploy`

### Task 24: Tự phục hồi, tài liệu, runbook quay video

**Files:** Create `scripts/chaos-kill-app.sh`, `docs/runbook.md`, `docs/architecture.md` (Mermaid); Modify `README.md` gốc (viết lại: giới thiệu, sơ đồ, công nghệ, cách chạy, chi phí, ảnh chụp)

**Interfaces:**
- `scripts/chaos-kill-app.sh <base_url>`: đăng nhập → đọc `served-by` → map hostname (`ip-172-32-…`) sang instance ID → `aws autoscaling terminate-instance-in-auto-scaling-group --no-should-decrement-desired-capacity` → trong 10 phút: mỗi 2s `GET /user` bằng cookie cũ, ghi số lần thành công/thất bại; thoát 0 khi (a) sau khi health check loại máy chết (≤ 30s), mọi request đều `Welcome` và (b) TG app trở lại 2 target `healthy`.
- `docs/runbook.md`: thứ tự lần đầu (bootstrap → CI → `make ami` → `make up`), mỗi buổi (`make up` … `make down`), xử lý sự cố (tunnel DOWN, đổi IP laptop, target unhealthy), kịch bản 8 cảnh của spec §11 kèm lệnh cụ thể.

- [ ] **Step 1: `scripts/chaos-kill-app.sh https://<cf>`** → Expected: exit 0, in số request lỗi trong cửa sổ ≤ 30s và thời gian ASG hồi phục (Review Focus 4).
- [ ] **Step 2: Viết `README.md`, `docs/architecture.md`, `docs/runbook.md`.**
- [ ] **Step 3: `make down`** → Expected: destroy xong, `aws ec2 describe-instances --filters Name=tag:Project,Values=java3tier Name=instance-state-name,Values=running` rỗng; Budget và AMI còn nguyên.
- [ ] **Step 4: Gitleaks lần cuối** (lệnh ở Task 1, chạy với `detect --source /repo` có lịch sử git) → `no leaks found`.
- [ ] **Step 5: Commit + push** `docs: architecture, runbook, demo script`
