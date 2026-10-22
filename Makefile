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
