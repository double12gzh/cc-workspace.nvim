#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
export PATH="${PATH}:${XDG_DATA_HOME:-$HOME/.local/share}/nvim/mason/bin:${HOME}/tools/nvim/bin:/opt/homebrew/bin:/usr/local/bin"

# Clear repo-local GIT_* variables exported by `git commit` / `git push` hooks so child
# `git init` and `git worktree` commands in isolated temp directories never inherit `.git/index`.
if command -v git >/dev/null 2>&1; then
  while IFS= read -r git_var; do
    [ -n "$git_var" ] && unset "$git_var"
  done < <(git rev-parse --local-env-vars 2>/dev/null || true)
fi

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required tool '$cmd' not found on PATH ($PATH)" >&2
    exit 1
  fi
}

live_data_fingerprint() {
  local data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/nvim"
  nvim --headless -u NONE -l - "$data_dir" <<'EOF'
local data_dir = arg[1]

local function file_digest(p)
	local st = vim.uv.fs_lstat(p)
	if not st then
		return "MISSING"
	end
	if st.type ~= "file" then
		return "TYPE:" .. tostring(st.type)
	end
	local fd = vim.uv.fs_open(p, "r", 438)
	local raw = (fd and st.size > 0) and vim.uv.fs_read(fd, st.size, 0) or ""
	if fd then
		vim.uv.fs_close(fd)
	end
	return vim.fn.sha256(raw or "")
end

io.write("projects=" .. file_digest(data_dir .. "/cc-workspace-projects.json") .. "\n")

local hist_root = data_dir .. "/codecompanion-history"
if not vim.uv.fs_lstat(hist_root) then
	io.write("history=MISSING\n")
else
	local hist_entries = {}
	local function walk_hist(dir, rel_prefix)
		local scan = vim.uv.fs_scandir(dir)
		if not scan then
			return
		end
		while true do
			local name, etype = vim.uv.fs_scandir_next(scan)
			if not name then
				break
			end
			local full = dir .. "/" .. name
			local rel = rel_prefix ~= "" and (rel_prefix .. "/" .. name) or name
			if not etype then
				local st = vim.uv.fs_lstat(full)
				etype = st and st.type or "unknown"
			end
			if etype == "directory" then
				table.insert(hist_entries, "D:" .. rel)
				walk_hist(full, rel)
			else
				table.insert(hist_entries, "F:" .. rel .. "=" .. file_digest(full))
			end
		end
	end
	walk_hist(hist_root, "")
	table.sort(hist_entries)
	for _, item in ipairs(hist_entries) do
		io.write("history/" .. item .. "\n")
	end
end

local wt_root = data_dir .. "/cc-worktrees"
if not vim.uv.fs_lstat(wt_root) then
	io.write("worktrees=MISSING\n")
else
	local wt_entries = {}
	local scan = vim.uv.fs_scandir(wt_root)
	if scan then
		while true do
			local rname, rtype = vim.uv.fs_scandir_next(scan)
			if not rname then
				break
			end
			local rfull = wt_root .. "/" .. rname
			if not rtype then
				local st = vim.uv.fs_lstat(rfull)
				rtype = st and st.type or "unknown"
			end
			table.insert(wt_entries, rtype .. ":" .. rname)
			if rtype == "directory" then
				local sub = vim.uv.fs_scandir(rfull)
				if sub then
					while true do
						local bname, btype = vim.uv.fs_scandir_next(sub)
						if not bname then
							break
						end
						if not btype then
							local bst = vim.uv.fs_lstat(rfull .. "/" .. bname)
							btype = bst and bst.type or "unknown"
						end
						table.insert(wt_entries, btype .. ":" .. rname .. "/" .. bname)
					end
				end
			end
		end
	end
	table.sort(wt_entries)
	for _, item in ipairs(wt_entries) do
		io.write("worktrees/" .. item .. "\n")
	end
end
EOF
}

run_hygiene() {
  require_cmd nvim
  local explicit_mode=0
  local files=()
  if [ "$#" -gt 0 ]; then
    explicit_mode=1
    files=("$@")
  else
    while IFS= read -r -d '' line; do
      [ -n "$line" ] && files+=("$line")
    done < <(git -C "$REPO_ROOT" ls-files -z --cached --others --exclude-standard)
  fi
  if [ "${#files[@]}" -eq 0 ]; then
    echo "hygiene: OK (0 file(s) checked)"
    return 0
  fi

  nvim --headless -u NONE -l - "$REPO_ROOT" "$explicit_mode" "${files[@]}" <<'EOF'
local repo_root = arg[1]
local explicit_mode = arg[2] == "1"
local errs = {}

for i = 3, #arg do
	local raw = arg[i]
	local full = raw:sub(1, 1) == "/" and raw or (repo_root .. "/" .. raw)
	local rel = full:sub(1, #repo_root + 1) == (repo_root .. "/") and full:sub(#repo_root + 2) or raw
	local lst = vim.uv.fs_lstat(full)
	if not lst then
		if explicit_mode then
			table.insert(errs, rel .. ": path does not exist")
		end
	elseif lst.type == "link" then
		if not vim.uv.fs_stat(full) then
			table.insert(errs, rel .. ": dangling symlink")
		end
	elseif lst.type == "file" then
		if rel:match("^scripts/.+%.sh$") and bit.band(lst.mode or 0, 73) == 0 then
			table.insert(errs, rel .. ": shell script must have executable bit (+x)")
		end
		local rel_lc = rel:lower()
		local is_png = rel_lc:match("%.png$") ~= nil
		local is_jpg = rel_lc:match("%.jpe?g$") ~= nil
		local is_webp = rel_lc:match("%.webp$") ~= nil
		local fd = vim.uv.fs_open(full, "r", 438)
		if fd then
			local data = lst.size > 0 and vim.uv.fs_read(fd, lst.size, 0) or ""
			vim.uv.fs_close(fd)
			if is_png or is_jpg or is_webp then
				if lst.size == 0 or #data == 0 then
					table.insert(errs, rel .. ": binary image file must be non-empty")
				elseif is_png and (#data < 8 or data:sub(1, 8) ~= "\137PNG\r\n\026\n") then
					table.insert(errs, rel .. ": invalid PNG magic header (expected \\x89PNG\\r\\n\\x1a\\n)")
				elseif is_jpg and (#data < 3 or data:sub(1, 3) ~= "\255\216\255") then
					table.insert(errs, rel .. ": invalid JPEG magic header")
				elseif is_webp and (#data < 12 or data:sub(1, 4) ~= "RIFF" or data:sub(9, 12) ~= "WEBP") then
					table.insert(errs, rel .. ": invalid WebP header")
				end
			elseif data and not data:find("%z") then
				if data:sub(1, 3) == "\239\187\191" then
					table.insert(errs, rel .. ":1: UTF-8 BOM is forbidden")
				end
				if data:find("\r\n", 1, true) then
					table.insert(errs, rel .. ": CRLF line endings are forbidden (expected LF)")
				end
				if #data > 0 and data:sub(-1) ~= "\n" then
					table.insert(errs, rel .. ": missing trailing newline at EOF")
				elseif #data >= 2 and data:sub(-2) == "\n\n" then
					table.insert(errs, rel .. ": multiple trailing blank lines at EOF")
				end

				local scan_data = (#data > 0 and data:sub(-1) ~= "\n") and (data .. "\n") or data
				local lnum = 0
				for line in scan_data:gmatch("(.-)\n") do
					lnum = lnum + 1
					if line:match("[ \t]+$") then
						table.insert(errs, string.format("%s:%d: trailing whitespace", rel, lnum))
					end
					if
						line:match("^<<<<<<< ")
						or line == "======="
						or line:match("^>>>>>>> ")
					then
						table.insert(errs, string.format("%s:%d: merge conflict marker", rel, lnum))
					end
				end

				if rel:match("%.json$") then
					local ok_j, jerr = pcall(vim.json.decode, data)
					if not ok_j then
						table.insert(errs, string.format("%s: invalid JSON (%s)", rel, tostring(jerr)))
					end
				end
			end
		end
	end
end

if #errs > 0 then
	for _, e in ipairs(errs) do
		io.stderr:write("HYGIENE ERROR: " .. e .. "\n")
	end
	os.exit(1)
end
EOF

  local sh_files=()
  local f full
  for f in "${files[@]}"; do
    if [[ "$f" == *.sh ]]; then
      full="$f"
      [[ "$full" != /* ]] && full="$REPO_ROOT/$full"
      if [ -f "$full" ] && [ ! -L "$full" ]; then
        sh_files+=("$full")
      fi
    fi
  done

  if [ "${#sh_files[@]}" -gt 0 ]; then
    bash -n "${sh_files[@]}"
    if command -v shfmt >/dev/null 2>&1; then
      shfmt -d -i 2 -ci "${sh_files[@]}"
    fi
  fi
  echo "hygiene: OK (${#files[@]} file(s) checked)"
}

run_fmt() {
  require_cmd stylua
  local fix_mode=0
  if [ "${1:-}" = "--fix" ]; then
    fix_mode=1
    shift
  fi

  local has_args=0
  if [ "$#" -gt 0 ]; then
    has_args=1
  fi

  local lua_targets=()
  local sh_targets=()
  local f full
  for f in "$@"; do
    full="$f"
    [[ "$full" != /* ]] && full="$REPO_ROOT/$full"
    if [ ! -e "$full" ] && [ ! -L "$full" ]; then
      echo "FMT ERROR: $f: path does not exist" >&2
      exit 1
    fi
    if [[ "$f" == *.lua ]] && [ -f "$full" ] && [ ! -L "$full" ]; then
      lua_targets+=("$full")
    elif [[ "$f" == *.sh ]] && [ -f "$full" ] && [ ! -L "$full" ]; then
      sh_targets+=("$full")
    fi
  done

  if [ "$fix_mode" -eq 1 ]; then
    if [ "$has_args" -eq 1 ]; then
      if [ "${#lua_targets[@]}" -gt 0 ]; then
        stylua --config-path "$REPO_ROOT/stylua.toml" "${lua_targets[@]}"
      fi
      if [ "${#sh_targets[@]}" -gt 0 ] && command -v shfmt >/dev/null 2>&1; then
        shfmt -w -i 2 -ci "${sh_targets[@]}"
      fi
    else
      stylua --respect-ignores --config-path "$REPO_ROOT/stylua.toml" "$REPO_ROOT"
      if command -v shfmt >/dev/null 2>&1; then
        shfmt -w -i 2 -ci "$REPO_ROOT"/scripts/*.sh
      fi
    fi
    echo "fmt --fix: OK"
  else
    if [ "$has_args" -eq 1 ]; then
      if [ "${#lua_targets[@]}" -gt 0 ]; then
        stylua --check --config-path "$REPO_ROOT/stylua.toml" "${lua_targets[@]}"
      fi
    else
      stylua --check --respect-ignores --config-path "$REPO_ROOT/stylua.toml" "$REPO_ROOT"
    fi
    echo "stylua: OK"
  fi
}

run_arch() {
  require_cmd nvim
  nvim --headless -u NONE -l "$REPO_ROOT/scripts/lint_repo.lua"
}

run_commit_msg() {
  require_cmd nvim
  if [ "$#" -eq 0 ]; then
    echo "Usage: $0 commit-msg [--require-coauthor] [--comment-char <char|auto|none>] <commit-msg-file|->" >&2
    exit 2
  fi
  nvim --headless -u NONE -l "$REPO_ROOT/scripts/lint_commit_msg.lua" "$@"
}

run_lsp() {
  require_cmd nvim
  require_cmd lua-language-server

  local tmp_luals
  tmp_luals="$(mktemp -d "${TMPDIR:-/tmp}/cc-ws-luals.XXXXXX")"
  trap 'rm -rf "$tmp_luals"' RETURN

  local vim_rt
  vim_rt="$(nvim --headless -u NONE -l - <<<'io.write(vim.env.VIMRUNTIME)')"

  local luals_out
  luals_out="$(
    VIMRUNTIME="$vim_rt" lua-language-server \
      --check="$REPO_ROOT" \
      --configpath="$REPO_ROOT/.luarc.json" \
      --logpath="$tmp_luals" \
      --checklevel=Warning 2>&1
  )"
  if ! grep -q "Diagnosis complete" <<<"$luals_out"; then
    echo "ERROR: lua-language-server did not complete diagnosis:" >&2
    echo "$luals_out" >&2
    exit 1
  fi

  nvim --headless -u NONE -l - "$REPO_ROOT" "$tmp_luals/check.json" <<'EOF'
local repo_root, check_json = arg[1], arg[2]
local st = vim.uv.fs_stat(check_json)
if not st or st.size == 0 then
	io.stdout:write("lua_ls: OK (0 warnings, 0 errors)\n")
	os.exit(0)
end
local fd = assert(vim.uv.fs_open(check_json, "r", 438))
local raw = vim.uv.fs_read(fd, st.size, 0) or "[]"
vim.uv.fs_close(fd)
local decoded = vim.json.decode(raw)
if type(decoded) ~= "table" or next(decoded) == nil then
	io.stdout:write("lua_ls: OK (0 warnings, 0 errors)\n")
	os.exit(0)
end

local sev_names = { [1] = "ERROR", [2] = "WARN", [3] = "INFO", [4] = "HINT" }
local uris = {}
for uri in pairs(decoded) do
	table.insert(uris, uri)
end
table.sort(uris)

local total = 0
for _, uri in ipairs(uris) do
	local path = vim.uri_to_fname(uri)
	local rel = path:sub(1, #repo_root + 1) == (repo_root .. "/") and path:sub(#repo_root + 2) or path
	for _, d in ipairs(decoded[uri] or {}) do
		total = total + 1
		local pos = (d.range and d.range.start) or { line = 0, character = 0 }
		local sev = sev_names[d.severity or 2] or "WARN"
		io.stderr:write(
			string.format(
				"LUALS %s %s:%d:%d [%s]: %s\n",
				sev,
				rel,
				(pos.line or 0) + 1,
				(pos.character or 0) + 1,
				tostring(d.code or "diagnostic"),
				tostring(d.message or ""):gsub("\n", " ")
			)
		)
	end
end

io.stderr:write(string.format("lua_ls failed with %d diagnostic(s)\n", total))
os.exit(1)
EOF
}

run_test() {
  require_cmd nvim
  local before_fp after_fp
  before_fp="$(live_data_fingerprint)"
  nvim --headless -u NONE -i NONE --noplugin --cmd "set rtp+=${REPO_ROOT}" "+luafile $REPO_ROOT/tests/run_headless.lua"
  after_fp="$(live_data_fingerprint)"
  if [ "$before_fp" != "$after_fp" ]; then
    echo "FATAL: live user Neovim data files were modified during test run!" >&2
    echo "Before:" >&2
    echo "$before_fp" >&2
    echo "After:" >&2
    echo "$after_fp" >&2
    exit 1
  fi
}

mode="${1:-all}"
if [ "$#" -gt 0 ]; then
  shift
fi

case "$mode" in
  hygiene)
    run_hygiene "$@"
    ;;
  fmt)
    run_fmt "$@"
    ;;
  arch)
    run_arch
    ;;
  commit-msg)
    run_commit_msg "$@"
    ;;
  lsp)
    run_lsp
    ;;
  lint)
    run_hygiene
    run_fmt
    run_arch
    run_lsp
    ;;
  test)
    run_test
    ;;
  all)
    before_all="$(live_data_fingerprint)"
    run_hygiene
    run_fmt
    run_arch
    run_lsp
    run_test
    after_all="$(live_data_fingerprint)"
    if [ "$before_all" != "$after_all" ]; then
      echo "FATAL: live user Neovim data files changed during check.sh!" >&2
      exit 1
    fi
    ;;
  *)
    echo "Usage: $0 [all|lint|hygiene|fmt [--fix]|arch|commit-msg [--require-coauthor] <file>|lsp|test] [files...]" >&2
    exit 2
    ;;
esac
