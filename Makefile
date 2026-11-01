.PHONY: test lint hooks install install-gui eval eval-gui

test:
	bats tests

lint:
	zsh -n wt/wt.zsh
	zsh -n wt/gui-bridge.zsh
	shellcheck install.sh wt/agterm-worktrees ask/ask-hook.sh ask/agterm-ask ask/agterm-ask-mcp evals/ask-agents.sh
	shellcheck -s bash tests/helpers.bash
	python3 -c 'import ast,pathlib; [ast.parse(p.read_text(),filename=str(p)) for root in ("wt", "workflows", "evals") for p in pathlib.Path(root).glob("*.py")]'

hooks:
	pre-commit install

install:
	./install.sh

install-gui:
	./install.sh --gui

# Платный eval на настоящих Codex и OpenCode, нужен запущенный agterm.
eval:
	evals/ask-agents.sh

eval-gui:
	python3 evals/gui-workflows.py
