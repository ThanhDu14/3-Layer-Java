VENV    := .venv
ANSIBLE := $(VENV)/bin/ansible-playbook
GITLEAKS_IMAGE := zricethezav/gitleaks:v8.30.1

# molecule shells out to ansible-config etc., so venv tools must be on PATH.
export PATH := $(CURDIR)/$(VENV)/bin:$(PATH)

.PHONY: tools check-tools secrets-check

tools:
	python3 -m venv $(VENV)
	$(VENV)/bin/pip install --upgrade pip
	$(VENV)/bin/pip install -r requirements-dev.txt
	@if [ -f ansible/requirements.yml ]; then \
		$(VENV)/bin/ansible-galaxy collection install -r ansible/requirements.yml; \
	fi

check-tools:
	scripts/check-tools.sh

# gitleaks does not flag plain-text passwords like the ones the original repo shipped,
# so also grep for the known leaked values.
secrets-check:
	docker run --rm -v "$(CURDIR)":/repo $(GITLEAKS_IMAGE) detect --no-git --source /repo --redact
	@! grep -rn "Admin123\|prdevop26" --exclude-dir=.git --exclude-dir=docs --exclude-dir=.superpowers --exclude=Makefile . \
		|| (echo "known leaked credential found" >&2; exit 1)

# Java tests always run on JDK 11 in Docker (host JDK is newer than Spring Boot 2.7 supports).
# --network host + docker.sock let Testcontainers start sibling containers.
APP_TEST_IMAGE := maven:3.9-eclipse-temurin-11

.PHONY: app-test
app-test:
	docker run --rm --network host \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-v "$(CURDIR)":/work -v "$(HOME)/.m2":/root/.m2 \
		-w /work/Java-Login-App $(APP_TEST_IMAGE) mvn -B clean verify

# Local production-shaped stack (nginx -> tomcat 9 -> mysql + redis) on http://localhost:8088
.PHONY: local-up local-down
local-up:
	@test -f Java-Login-App/target/dptweb.war || $(MAKE) app-test
	docker compose -f local/docker-compose.yml up -d

local-down:
	docker compose -f local/docker-compose.yml down -v

# Ansible: collections, molecule per role, lint
.PHONY: collections molecule lint
collections:
	$(VENV)/bin/ansible-galaxy collection install -r ansible/requirements.yml

molecule:
	@test -n "$(ROLE)" || (echo "usage: make molecule ROLE=<role>" >&2; exit 1)
	cd ansible/roles/$(ROLE) && molecule test

lint:
	cd ansible && ansible-lint
