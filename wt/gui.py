#!/usr/bin/env python3
"""Графические действия для wt. Граница git — argv, конфиг — существующий zsh parser."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent


class Failure(Exception):
    pass


def command(args: list[str], *, cwd: str | None = None, timeout: int = 90) -> str:
    try:
        result = subprocess.run(args, cwd=cwd, text=True, capture_output=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise Failure(str(exc)) from exc
    if result.returncode:
        raise Failure(result.stderr.strip() or result.stdout.strip() or f"Команда завершилась с кодом {result.returncode}")
    return result.stdout


def trace(action: str, outcome: str) -> None:
    # Имена задач и пути не попадают в журнал.
    path = Path(os.environ.get("AGTERM_GUI_LOG", str(Path.home() / ".local/state/agterm-kit/gui.jsonl")))
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a") as stream:
            stream.write(json.dumps({"time": datetime.now(timezone.utc).isoformat(), "action": action, "outcome": outcome}) + "\n")
    except OSError as exc:
        # Внешний эффект уже мог произойти. Сбой наблюдаемости не меняет его исход.
        print(f"agterm-kit: не записать журнал {path}: {exc}", file=sys.stderr)


def configuration() -> dict:
    return json.loads(command(["zsh", "-f", str(HERE / "gui-bridge.zsh"), "config"]))


def repository(config: dict, path: str) -> dict:
    matches = [repo for repo in config["repos"] if repo["path"] == path]
    if len(matches) != 1:
        raise Failure("Репозитория нет в wt.conf. Обновите список проектов")
    return matches[0]


def git(repo: str, *args: str) -> str:
    return command(["git", "-C", repo, *args])


def worktrees(repo: str) -> list[dict]:
    # -z не требует разбирать C-экранирование путей с пробелами и переводами строки.
    records, item = [], {}
    for field in git(repo, "worktree", "list", "--porcelain", "-z").split("\0"):
        if not field:
            if item:
                records.append(item)
                item = {}
            continue
        key, _, value = field.partition(" ")
        item[key] = value
    if item:
        records.append(item)
    for item in records:
        item["path"] = item["worktree"]
        item["branch"] = item.get("branch", "").removeprefix("refs/heads/")
        item["main"] = Path(item["path"]).resolve() == Path(repo).resolve()
    return records


def worktree_home(repo: str) -> Path:
    # Та же формула, что _wt_dest в wt.zsh: <родитель клона>/worktrees/<клон>, без симлинков.
    real = Path(repo).resolve()
    return real.parent / "worktrees" / real.name


def registered(repo: str, path: str) -> dict:
    for item in worktrees(repo):
        if item["path"] == path:
            return item
    raise Failure("Worktree больше не зарегистрирован в этом репозитории. Обновите список")


def ctl(*args: str) -> str:
    values = [os.environ.get("AGTERMCTL", "agtermctl"), *args]
    socket = os.environ.get("AGT_SOCKET") or os.environ.get("AGTERM_SOCKET")
    if socket:
        values += ["--socket", socket]
    return command(values)


def session_environment() -> tuple[str, str]:
    return (os.environ.get("AGT_SESSION_ID") or os.environ.get("AGTERM_SESSION_ID", ""),
            os.environ.get("AGT_WINDOW_ID") or os.environ.get("AGTERM_WINDOW_ID", ""))


def agent_command(agent: str, model: str) -> str | None:
    # Программа привязана к созданию сессии, никогда не вводится в чужой line buffer.
    if agent == "none":
        return None
    if agent not in ("claude", "codex"):
        raise Failure("Доступны агенты claude, codex и none")
    executable = ["claude", "--model", model] if agent == "claude" else ["codex"]
    script = shlex.join(executable) + "; exec zsh -l"
    return shlex.join(["zsh", "-lc", script])


def open_session(repo: dict, path: str, agent: str = "claude") -> dict:
    # Даже main clone проверяется по git-реестру: из HTML нельзя открыть произвольный cwd.
    item = registered(repo["path"], path)
    sys.path.insert(0, str(HERE.parent / "workflows"))
    from run import config as workflow_config
    launch = agent_command(agent, workflow_config()["model"])
    # Путь различает одноимённые репозитории из нескольких roots.
    name = repo["name"]
    duplicates = [r for r in configuration()["repos"] if r["name"] == name]
    if len(duplicates) > 1:
        name += " · " + str(Path(repo["path"]).parent)
    args = ["session", "new", "--cwd", path, "--name", item["branch"] or repo["name"],
            "--workspace-name", name, "--create-workspace", "--json"]
    _, window = session_environment()
    if window:
        args += ["--window", window]
    if launch:
        args += ["--command", launch]
    try:
        response = json.loads(ctl(*args))
    except (Failure, ValueError) as exc:
        raise Failure(f"Worktree сохранён: {path}. Не удалось открыть сессию: {exc}") from exc
    return {"path": path, "session": response.get("result", {}).get("id")}


def create(config: dict, repo_path: str, branch: str, agent: str) -> dict:
    repo = repository(config, repo_path)
    agent_command(agent, "opus")  # валидация до git-операций
    if not branch or branch.startswith("-") or branch != branch.strip():
        raise Failure("Введите корректное имя ветки без пробелов по краям")
    git(repo_path, "check-ref-format", "--branch", branch)
    dest = worktree_home(repo_path) / branch
    if not dest.resolve().is_relative_to(worktree_home(repo_path)):
        raise Failure("Путь worktree выходит за каталог worktrees репозитория")
    if dest.exists() or dest.is_symlink():
        item = registered(repo_path, str(dest))
        if item["branch"] != branch:
            raise Failure("Каталог занят worktree другой ветки")
    else:
        command(["zsh", "-f", str(HERE / "gui-bridge.zsh"), "create", repo_path, branch])
    return open_session(repo, str(dest), agent)


def open_paths() -> list[str]:
    # При недоступном agterm отказываем в удалении, а не считаем всё закрытым.
    windows = json.loads(ctl("window", "list", "--json"))["result"]["windows"]
    paths = []
    for window in windows:
        if not window.get("open", True):
            continue
        tree = json.loads(ctl("tree", "--json", "--window", window["id"]))["result"]["tree"]
        for ws in tree.get("workspaces", []):
            for session in ws.get("sessions", []):
                for key in ("cwd", "splitCwd", "scratchCwd"):
                    if session.get(key):
                        paths.append(session[key])
    return paths


def remove(config: dict, repo_path: str, path: str, confirmation: str) -> dict:
    repository(config, repo_path)
    item = registered(repo_path, path)
    if item["main"] or not item["branch"] or "locked" in item or "prunable" in item:
        raise Failure("Основной клон, detached, locked или недоступный worktree удалять нельзя")
    # GUI удаляет только worktree, которые создаёт wt: внутри каталога worktrees репозитория.
    if not Path(path).resolve().is_relative_to(worktree_home(repo_path)):
        raise Failure("Worktree лежит вне каталога worktrees репозитория")
    if confirmation != item["branch"]:
        raise Failure("Для удаления введите точное имя ветки")
    for active in open_paths():
        if Path(active).resolve().is_relative_to(Path(path).resolve()):
            raise Failure("В worktree открыта сессия agterm. Закройте её сами перед удалением")
    if git(path, "status", "--porcelain", "--untracked-files=all").strip():
        raise Failure("В worktree есть незакоммиченные или неотслеживаемые файлы. Удаление запрещено")
    ignored = git(path, "ls-files", "--others", "--ignored", "--exclude-standard", "-z").split("\0")
    for relative in filter(None, ignored):
        candidate, original = Path(path) / relative, Path(repo_path) / relative
        # wt переносит только ссылки на зависимости и копию локальных настроек.
        # Любое другое игнорируемое содержимое может быть единственным экземпляром данных.
        inherited_link = relative.rstrip("/") in (".venv", "node_modules") and candidate.is_symlink() and candidate.resolve() == original.resolve()
        inherited_settings = relative == ".claude/settings.local.json" and original.is_file() and candidate.read_bytes() == original.read_bytes()
        if not inherited_link and not inherited_settings:
            raise Failure(f"В worktree есть игнорируемые данные: {relative}. Сохраните их перед удалением")
    # Обновляем доказательство сохранности коммитов; без сети ничего не удаляем.
    git(repo_path, "fetch", "--quiet", "--prune", "origin")
    head = git(path, "rev-parse", "HEAD").strip()
    remote = git(repo_path, "for-each-ref", "--contains=" + head, "--format=%(refname)", "refs/remotes/origin/").strip()
    if not remote:
        raise Failure("Коммит worktree не сохранён в origin. Сначала отправьте ветку")
    if git(path, "rev-parse", "HEAD").strip() != head or git(path, "status", "--porcelain", "--untracked-files=all").strip():
        raise Failure("Worktree изменился во время проверки. Повторите действие")
    # Ветка остаётся: git branch -d зависит от upstream/base и не даёт того же доказательства.
    # Пользователь может восстановить worktree из неё, игнорируемые файлы защищает git remove.
    git(repo_path, "worktree", "remove", path)
    return {"removed": path, "branch_kept": item["branch"]}


def snapshot(config: dict) -> dict:
    projects = []
    for repo in config["repos"]:
        try:
            items = worktrees(repo["path"])
            projects.append({**repo, "worktrees": items})
        except Failure as exc:
            projects.append({**repo, "worktrees": [], "error": str(exc)})
    return {"projects": projects}


def act(request: dict) -> dict:
    config = configuration()
    action = request.get("action")
    if action == "list":
        return snapshot(config)
    if action == "create":
        return create(config, request["repo"], request["branch"], request.get("agent", "claude"))
    if action == "open":
        return open_session(repository(config, request["repo"]), request["path"], request.get("agent", "claude"))
    if action == "delete":
        return remove(config, request["repo"], request["path"], request.get("confirmation", ""))
    raise Failure("Неизвестное действие")


def project_picker() -> None:
    config = configuration()
    items = [{"id": r["path"], "label": r["name"], "subtitle": r["path"]} for r in config["repos"]]
    if not items:
        raise Failure("Нет проектов. Добавьте repos в wt.conf")
    _, window = session_environment()
    args = [os.environ.get("AGTERMCTL", "agtermctl"), "pick", "--prompt", "Открыть проект с Claude"]
    if window:
        args += ["--window", window]
    socket = os.environ.get("AGT_SOCKET") or os.environ.get("AGTERM_SOCKET")
    if socket:
        args += ["--socket", socket]
    result = subprocess.run(args, input=json.dumps(items), text=True, capture_output=True)
    if result.returncode == 2:
        trace("project", "cancelled")
        return
    if result.returncode:
        raise Failure(result.stderr or "Не удалось открыть список проектов")
    chosen = json.loads(result.stdout)
    if chosen.get("result") == "picked":
        repo = repository(config, chosen["id"])
        open_session(repo, repo["path"])
        trace("project", "opened")


def render(data: dict, message: str = "", selected: str = "", draft: dict | None = None) -> str:
    payload = json.dumps({**data, "message": message, "selected": selected, "draft": draft}, ensure_ascii=False).replace("<", "\\u003c")
    return (HERE / "worktrees.html").read_text().replace("__WORKTREE_DATA__", payload)


def panel() -> None:
    session, window = session_environment()
    if not session:
        raise Failure("Откройте панель через палитру agterm")
    message, selected, draft = "", "", None
    # Каждое действие подтверждается штатным page bridge. HTTP-сервера и долгоживущего
    # фонового сервиса нет; страницу нельзя использовать после закрытия её сессии.
    with tempfile.TemporaryDirectory(prefix="agterm-worktrees-") as directory:
        page = Path(directory) / "index.html"
        while True:
            data = snapshot(configuration())
            page.write_text(render(data, message, selected, draft))
            args = ["session", "overlay", "open", "--html", str(page), "--js", "--chromeless",
                    "--target", session, "--size-percent", "95", "--block"]
            if window:
                args += ["--window", window]
            # Dialog ожидания не ограничен таймаутом subprocess: пользователь может уйти.
            values = [os.environ.get("AGTERMCTL", "agtermctl"), *args]
            socket = os.environ.get("AGT_SOCKET") or os.environ.get("AGTERM_SOCKET")
            if socket:
                values += ["--socket", socket]
            result = subprocess.run(values, capture_output=True, text=True)
            if result.returncode == 2:
                trace("panel", "dismissed")
                return
            if result.returncode:
                raise Failure(result.stderr.strip() or result.stdout.strip())
            outcome = json.loads(result.stdout)
            # --block возвращает page outcome без оболочки result.
            value = outcome.get("value")
            if isinstance(value, str):
                value = json.loads(value)
            if not isinstance(value, dict):
                raise Failure("Страница не вернула действие")
            action = value.get("action")
            selected = value.get("repo", "")
            if action == "refresh":
                message = "Список обновлён"
                draft = None
                continue
            try:
                ctl("session", "hud", "open", "Выполняю действие…", "--hide-after", "120", "--target", session)
                response = act(value)
                trace(action, "success")
                if action in ("open", "create"):
                    return
                message = "Worktree удалён. Ветка сохранена: " + response["branch_kept"]
            except (Failure, OSError, ValueError, KeyError, TypeError) as exc:
                trace(action or "unknown", "error")
                message = str(exc)
                draft = value if action == "create" else None
            finally:
                try:
                    ctl("session", "hud", "close", "--target", session)
                except Failure:
                    pass


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["project", "worktrees", "request", "render"])
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    action = args.mode
    try:
        if args.mode == "render":
            if not args.output:
                raise Failure("render требует --output")
            args.output.write_text(render(snapshot(configuration())))
        elif args.mode == "request":
            request = json.load(sys.stdin)
            action = request.get("action", "unknown")
            print(json.dumps(act(request), ensure_ascii=False))
        elif args.mode == "project":
            project_picker()
        else:
            panel()
        trace(action, "success")
        return 0
    except (Failure, OSError, ValueError, KeyError, TypeError) as exc:
        trace(action, "error")
        print(f"agterm-kit: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
