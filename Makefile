.PHONY: test lint hooks install

test:
	bats tests

lint:
	zsh -n wt/wt.zsh
	shellcheck install.sh
	shellcheck -s bash tests/helpers.bash

hooks:
	pre-commit install

install:
	./install.sh
