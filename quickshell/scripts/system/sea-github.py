#!/usr/bin/env python3
"""GitHub contribution grid, streak, and watched-repo status for sea-shell.

Auth (first that works):
  1. `gh auth token` when the GitHub CLI is signed in
  2. $GITHUB_TOKEN / $GH_TOKEN
  3. ~/.config/sea-shell/github-token (one line)

Watched repos: ~/.config/sea-shell/github-repos.json
  ["owner/repo", ...]   — empty list watches nothing; omit file to use your
  first few non-fork repos from the API.

Modes:
  (default)          JSON summary for the bar / desktop / Dev tab
  search <query>     launcher hits: repos, open PRs, issues you own
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

CFG = Path(os.environ.get("HOME", str(Path.home()))) / ".config" / "sea-shell"
CACHE = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "sea-shell"
CACHE_FILE = CACHE / "github.json"
TOKEN_FILE = CFG / "github-token"
REPOS_FILE = CFG / "github-repos.json"
API = "https://api.github.com"
GQL = "https://api.github.com/graphql"


def _write_cache(payload: dict) -> None:
    """Persist success and failure so a revoked token cannot leave a green cache."""
    try:
        CACHE.mkdir(parents=True, exist_ok=True)
        CACHE_FILE.write_text(json.dumps(payload), encoding="utf-8")
    except OSError:
        pass


def _token() -> str:
    env = (os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN") or "").strip()
    if env:
        return env
    try:
        out = subprocess.check_output(
            ["gh", "auth", "token"], stderr=subprocess.DEVNULL, text=True, timeout=4
        ).strip()
        if out:
            return out
    except (FileNotFoundError, subprocess.SubprocessError, OSError):
        pass
    if TOKEN_FILE.is_file():
        try:
            return TOKEN_FILE.read_text(encoding="utf-8").strip().splitlines()[0].strip()
        except OSError:
            pass
    return ""


def _request(url: str, token: str, method: str = "GET", body: dict | None = None) -> dict | list | None:
    data = None if body is None else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "sea-shell",
            "X-GitHub-Api-Version": "2022-11-28",
            **({"Authorization": f"Bearer {token}"} if token else {}),
            **({"Content-Type": "application/json"} if body is not None else {}),
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            return json.loads(raw) if raw else None
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError):
        return None


def _login(token: str) -> str:
    me = _request(f"{API}/user", token)
    if isinstance(me, dict) and me.get("login"):
        return str(me["login"])
    return ""


def _contrib_weeks(token: str, login: str) -> tuple[list[dict], int, int, int]:
    """Return (days[{date,count,level}], today, streak, yearTotal)."""
    query = """
    query($login: String!) {
      user(login: $login) {
        contributionsCollection {
          contributionCalendar {
            totalContributions
            weeks {
              contributionDays { date contributionCount contributionLevel }
            }
          }
        }
      }
    }
    """
    data = _request(GQL, token, method="POST", body={"query": query, "variables": {"login": login}})
    days: list[dict] = []
    year = 0
    if not isinstance(data, dict):
        return days, 0, 0, 0
    try:
        cal = data["data"]["user"]["contributionsCollection"]["contributionCalendar"]
        year = int(cal.get("totalContributions") or 0)
        level_map = {
            "NONE": 0,
            "FIRST_QUARTILE": 1,
            "SECOND_QUARTILE": 2,
            "THIRD_QUARTILE": 3,
            "FOURTH_QUARTILE": 4,
        }
        for week in cal.get("weeks") or []:
            for d in week.get("contributionDays") or []:
                days.append(
                    {
                        "date": d["date"],
                        "count": int(d.get("contributionCount") or 0),
                        "level": level_map.get(d.get("contributionLevel"), 0),
                    }
                )
    except (TypeError, KeyError, ValueError):
        return [], 0, 0, 0

    today_s = date.today().isoformat()
    today_n = 0
    for d in days:
        if d["date"] == today_s:
            today_n = d["count"]
            break

    streak = 0
    # Walk backward from today; a zero today still allows streak if yesterday had commits.
    ordered = sorted(days, key=lambda x: x["date"], reverse=True)
    started = False
    for d in ordered:
        if d["date"] > today_s:
            continue
        if not started:
            if d["date"] == today_s and d["count"] == 0:
                continue  # today empty — streak can still count yesterday
            started = True
        if d["count"] <= 0:
            break
        streak += 1

    return days, today_n, streak, year


def _watched(token: str, login: str) -> list[str]:
    if REPOS_FILE.is_file():
        try:
            raw = json.loads(REPOS_FILE.read_text(encoding="utf-8"))
            if isinstance(raw, list):
                return [str(x).strip() for x in raw if str(x).strip()]
        except (OSError, json.JSONDecodeError):
            pass
    listed = _request(f"{API}/user/repos?per_page=8&sort=pushed&type=owner", token)
    out: list[str] = []
    if isinstance(listed, list):
        for r in listed:
            if not isinstance(r, dict) or r.get("fork"):
                continue
            full = r.get("full_name")
            if full:
                out.append(str(full))
            if len(out) >= 4:
                break
    if not out and login:
        out = [f"{login}/{login}"]
    return out


def _rel_time(iso: str) -> str:
    if not iso:
        return ""
    try:
        ts = datetime.fromisoformat(iso.replace("Z", "+00:00"))
        now = datetime.now(timezone.utc)
        sec = max(0, int((now - ts).total_seconds()))
    except ValueError:
        return ""
    if sec < 60:
        return "just now"
    if sec < 3600:
        return f"{sec // 60}m ago"
    if sec < 86400:
        return f"{sec // 3600}h ago"
    if sec < 86400 * 14:
        return f"{sec // 86400}d ago"
    return ts.astimezone().strftime("%d %b")


def _repo_status(token: str, full: str) -> dict:
    owner, _, name = full.partition("/")
    blank = {
        "repo": full,
        "ok": False,
        "ci": "unknown",
        "prs": 0,
        "issues": 0,
        "stars": 0,
        "forks": 0,
        "lang": "",
        "pushed": "",
        "pushedAt": "",
        "desc": "",
        "url": f"https://github.com/{full}",
    }
    if not owner or not name:
        return blank
    meta = _request(f"{API}/repos/{owner}/{name}", token)
    if isinstance(meta, dict):
        blank["ok"] = True
        blank["stars"] = int(meta.get("stargazers_count") or 0)
        blank["forks"] = int(meta.get("forks_count") or 0)
        blank["issues"] = int(meta.get("open_issues_count") or 0)
        blank["lang"] = str(meta.get("language") or "")
        blank["desc"] = (str(meta.get("description") or ""))[:120]
        blank["pushedAt"] = str(meta.get("pushed_at") or "")
        blank["pushed"] = _rel_time(blank["pushedAt"])
        blank["url"] = str(meta.get("html_url") or blank["url"])
    counted = _request(
        f"{API}/search/issues?q={urllib.parse.quote(f'repo:{owner}/{name} is:pr is:open')}&per_page=1",
        token,
    )
    if isinstance(counted, dict) and "total_count" in counted:
        blank["prs"] = int(counted["total_count"] or 0)
        # open_issues_count includes PRs; peel them off for a clearer Issues figure
        blank["issues"] = max(0, blank["issues"] - blank["prs"])
    runs = _request(f"{API}/repos/{owner}/{name}/actions/runs?per_page=1", token)
    ci = "unknown"
    if isinstance(runs, dict):
        items = runs.get("workflow_runs") or []
        if items:
            conc = (items[0].get("conclusion") or items[0].get("status") or "").lower()
            if conc in ("success", "neutral", "skipped"):
                ci = "ok"
            elif conc in ("failure", "timed_out", "cancelled", "action_required"):
                ci = "fail"
            elif conc in ("in_progress", "queued", "pending", "waiting", "requested"):
                ci = "running"
            else:
                ci = conc or "unknown"
        else:
            ci = "none"
    blank["ci"] = ci
    blank["ok"] = True
    return blank


def _recent_commits(token: str, login: str, limit: int = 8) -> list[dict]:
    """Latest commits by this author (search API — PushEvent payloads often omit messages)."""
    q = urllib.parse.quote(f"author:{login}")
    data = _request(
        f"{API}/search/commits?q={q}&sort=author-date&order=desc&per_page={limit}",
        token,
    )
    out: list[dict] = []
    if not isinstance(data, dict):
        return out
    for it in data.get("items") or []:
        if not isinstance(it, dict):
            continue
        commit = it.get("commit") or {}
        author = commit.get("author") or {}
        repo = (it.get("repository") or {}).get("full_name") or ""
        sha_full = str(it.get("sha") or "")
        msg = (str(commit.get("message") or "").split("\n", 1)[0]).strip()
        if not msg:
            continue
        out.append(
            {
                "sha": sha_full[:7],
                "msg": msg[:100],
                "repo": repo,
                "when": _rel_time(str(author.get("date") or "")),
                "url": str(it.get("html_url") or ""),
            }
        )
        if len(out) >= limit:
            break
    return out


def summary() -> dict:
    token = _token()
    blank = {
        "ok": False,
        "login": "",
        "today": 0,
        "streak": 0,
        "year": 0,
        "days": [],
        "weeks": [],
        "repos": [],
        "commits": [],
        "error": "sign in with gh auth login, or put a token in ~/.config/sea-shell/github-token",
        "fetchedAt": datetime.now(timezone.utc).isoformat(),
    }
    if not token:
        _write_cache(blank)
        return blank
    login = _login(token)
    if not login:
        blank["error"] = "GitHub token was rejected"
        _write_cache(blank)
        return blank
    days, today_n, streak, year = _contrib_weeks(token, login)
    # Last 17 weeks (~4 months) for compact widgets; full year kept in days.
    cut = (date.today() - timedelta(days=17 * 7)).isoformat()
    recent = [d for d in days if d["date"] >= cut]
    weeks: list[list[dict]] = []
    for i in range(0, len(recent), 7):
        weeks.append(recent[i : i + 7])
    repos = [_repo_status(token, r) for r in _watched(token, login)]
    commits = _recent_commits(token, login, limit=8)
    out = {
        "ok": True,
        "login": login,
        "today": today_n,
        "streak": streak,
        "year": year,
        "days": recent,
        "weeks": weeks,
        "repos": repos,
        "commits": commits,
        "error": "",
        "fetchedAt": datetime.now(timezone.utc).isoformat(),
        "url": f"https://github.com/{login}",
    }
    _write_cache(out)
    return out


def search(q: str) -> list[dict]:
    token = _token()
    if not token:
        return [{"type": "hint", "title": "GitHub not signed in", "sub": "gh auth login", "mi": "key"}]
    login = _login(token)
    q = (q or "").strip()
    hits: list[dict] = []
    # Default browse: your open PRs + recent repos
    if q == "":
        prs = _request(
            f"{API}/search/issues?q={urllib.parse.quote(f'is:pr is:open author:{login}')}&per_page=8",
            token,
        )
        if isinstance(prs, dict):
            for it in prs.get("items") or []:
                hits.append(
                    {
                        "type": "gh",
                        "title": it.get("title") or "PR",
                        "sub": f"PR · {it.get('repository_url', '').rsplit('/', 2)[-2]}/"
                        f"{it.get('repository_url', '').rsplit('/', 1)[-1]}",
                        "mi": "merge",
                        "url": it.get("html_url") or "",
                    }
                )
        repos = _request(f"{API}/user/repos?per_page=8&sort=pushed", token)
        if isinstance(repos, list):
            for r in repos:
                if not isinstance(r, dict):
                    continue
                hits.append(
                    {
                        "type": "gh",
                        "title": r.get("full_name") or r.get("name") or "",
                        "sub": (r.get("description") or "repository")[:80],
                        "mi": "folder_code",
                        "url": r.get("html_url") or "",
                    }
                )
        hits.append(
            {
                "type": "act",
                "title": "Dev dashboard",
                "sub": "Super+D · GitHub & AI",
                "mi": "dashboard",
                "exec": "qs -c sea-shell ipc call dashboard dev",
            }
        )
        return hits[:20]

    # Prefixed filters: pr , issue , repo  or free text
    kind = ""
    needle = q
    for prefix, k in (("pr ", "pr"), ("prs ", "pr"), ("issue ", "issue"), ("issues ", "issue"), ("repo ", "repo"), ("repos ", "repo")):
        if q.lower().startswith(prefix):
            kind = k
            needle = q[len(prefix) :].strip()
            break

    if kind in ("", "repo"):
        rs = _request(
            f"{API}/search/repositories?q={urllib.parse.quote(needle or login)}&per_page=8",
            token,
        )
        if isinstance(rs, dict):
            for r in rs.get("items") or []:
                hits.append(
                    {
                        "type": "gh",
                        "title": r.get("full_name") or "",
                        "sub": (r.get("description") or "repository")[:80],
                        "mi": "folder_code",
                        "url": r.get("html_url") or "",
                    }
                )
    if kind in ("", "pr"):
        qs = f"is:pr is:open {needle}" if needle else f"is:pr is:open author:{login}"
        prs = _request(f"{API}/search/issues?q={urllib.parse.quote(qs)}&per_page=8", token)
        if isinstance(prs, dict):
            for it in prs.get("items") or []:
                hits.append(
                    {
                        "type": "gh",
                        "title": it.get("title") or "PR",
                        "sub": "pull request",
                        "mi": "merge",
                        "url": it.get("html_url") or "",
                    }
                )
    if kind in ("", "issue"):
        qs = f"is:issue is:open {needle}" if needle else f"is:issue is:open assignee:{login}"
        iss = _request(f"{API}/search/issues?q={urllib.parse.quote(qs)}&per_page=8", token)
        if isinstance(iss, dict):
            for it in iss.get("items") or []:
                hits.append(
                    {
                        "type": "gh",
                        "title": it.get("title") or "Issue",
                        "sub": "issue",
                        "mi": "bug_report",
                        "url": it.get("html_url") or "",
                    }
                )
    if not hits:
        hits = [{"type": "hint", "title": "no GitHub matches", "sub": q, "mi": "search"}]
    return hits[:24]


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "search":
        q = " ".join(sys.argv[2:])
        print(json.dumps(search(q)))
        return 0
    # Serve any fresh cache (ok or error) so a revoked token does not keep a green
    # summary for four minutes, and failed auth does not hammer the API every tick.
    if "--cache-ok" in sys.argv and CACHE_FILE.is_file():
        try:
            cached = json.loads(CACHE_FILE.read_text(encoding="utf-8"))
            fetched = cached.get("fetchedAt") or ""
            if fetched:
                ts = datetime.fromisoformat(fetched.replace("Z", "+00:00"))
                if datetime.now(timezone.utc) - ts < timedelta(minutes=4):
                    print(json.dumps(cached))
                    return 0
        except (OSError, json.JSONDecodeError, ValueError):
            pass
    print(json.dumps(summary()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
