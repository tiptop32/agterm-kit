.PHONY: test lint hooks install install-gui install-themes eval eval-gui eval-omp eval-themes

test:
	bats tests

lint:
	zsh -n wt/wt.zsh
	zsh -n wt/gui-bridge.zsh
	shellcheck install.sh wt/agterm-worktrees ask/ask-hook.sh ask/agterm-ask ask/agterm-ask-mcp omp/install.sh omp/agterm-status.sh evals/ask-agents.sh evals/ask-session.sh
	shellcheck -s bash tests/helpers.bash
	python3 -c 'import ast,pathlib; [ast.parse(p.read_text(),filename=str(p)) for root in ("wt", "workflows", "ask", "themes", "evals") for p in pathlib.Path(root).rglob("*.py")]'

hooks:
	pre-commit install

install:
	./install.sh

install-gui:
	./install.sh --gui

install-themes:
	python3 themes/rex.py install

eval-themes:
	python3 themes/eval.py

# Платный eval на настоящих Codex и OpenCode, нужен запущенный agterm.
eval:
	evals/ask-agents.sh

eval-gui:
	python3 evals/gui-workflows.py

eval-omp:
	bun evals/omp-extension.ts
