.PHONY: test lint hooks install eval

test:
	bats tests

lint:
	zsh -n wt/wt.zsh
	shellcheck install.sh ask/ask-hook.sh ask/agterm-ask ask/agterm-ask-mcp evals/ask-agents.sh
	shellcheck -s bash tests/helpers.bash

hooks:
	pre-commit install

install:
	./install.sh

# Платный eval на настоящих Codex и OpenCode, нужен запущенный agterm.
eval:
	evals/ask-agents.sh
