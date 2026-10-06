# Cases for the ADLC guard hook (hooks/adlc-guard.sh → adlc_guard.py). Sourced by tests/run.sh.
#   g <A|D> <role|-> <repo> <command>     A = allowed (exit 0) · D = denied (exit 2)
# role is the hook's agent_type ("-" = the main thread, no agent). repo is the cwd:
#   feat = on branch feat/1-x · onmain = on main · track = branch tracking origin/main
#   trunk = clone whose origin default branch is `trunk`
#   matching = on branch feat/2-y in a clone configured push.default=matching
AN=adlc:product-analyst; RV=adlc:adversarial-reviewer; AR=adlc:architect

# ── merge: every shape of it ─────────────────────────────────────────────────────────────
g D - feat 'gh pr merge 5'
g D - feat 'gh pr merge 5 --squash --delete-branch'
g D - feat 'gh -R o/r pr merge 5'
g D - feat 'gh pr view 5 && gh pr merge 5 --auto'
g D - feat 'bash -c "gh pr merge 5"'
g D - feat "sh -lc 'gh pr merge 5 --squash'"
g D - feat 'echo ok; $(gh pr merge 5)'
g D - feat 'x=`gh pr merge 5`'
g D - feat 'timeout 30 gh pr merge 5'
g D - feat 'GH_TOKEN=x gh pr merge 5'
g D - feat 'sudo -u bob gh pr merge 5'
g D - feat 'echo 5 | xargs gh pr merge'
g D - feat 'eval "gh pr merge 5"'
g D - feat '/opt/homebrew/bin/gh pr merge 5'
g D - feat 'if true; then gh pr merge 5; fi'
g D - feat 'f() { gh pr merge 5; }; f'
g D - feat 'function f { gh pr merge 5; }; f'
g D - feat '{ gh pr view 5; gh pr merge 5; }'
g D - feat 'time -p gh pr merge 5'
g D - feat 'xargs -I {} gh pr merge {} < prs.txt'
g D - feat 'timeout -s KILL 30 gh pr merge 5'
g D - feat 'flock /tmp/lock gh pr merge 5'
g D - feat 'sudo --user bob gh pr merge 5'
g D - feat 'eval "$CMD" && gh pr merge 5'
g D - feat 'CMD="gh pr merge 5"; eval "$CMD"'
g D - feat 'CMD="gh pr merge 5"; bash -c "$CMD"'
g A - feat 'eval "$(ssh-agent -s)" && git fetch origin'
g A - feat 'timeout 30 grep -rn git . ; nohup rg bash src'                    # an ARGUMENT named git/bash is not a call
g A - feat 'find . -name "*.sh" -exec grep -l "gh pr merge" {} \;'
g D - feat '(gh pr merge 5) > /tmp/out 2>&1'
g D - feat "gh alias set m 'pr merge' && gh m 5"                              # a new name for the blocked command
g D - feat "gh alias set x --shell 'gh pr merge 5'; gh x"
g D - feat 'gh alias import aliases.yml'
g D - feat '"$GH" alias set m "pr merge"'
g A - feat 'gh alias list'
g D - feat $'bash <<EOF\ngh pr merge 5\nEOF'
g D - feat 'echo "gh pr merge 5" | bash'
g A - feat 'gh pr view 5'
g A - feat 'gh pr list --state merged'

# ── text that only MENTIONS a blocked command is data, not a call ────────────────────────
g D - feat 'gh pr comment 5 --body "run `gh pr merge 5` after approval"'   # backticks in "" execute
g A - feat "gh pr comment 5 --body 'Principal: run \`gh pr merge 5 --squash\` after approval'"
g A - feat 'gh pr comment 5 --body "Principal runs gh pr merge 5; never git push origin main"'
g A - feat $'gh pr comment 5 --body "$(cat <<\'EOF\'\n## Card\nIt\'s done (finally): run `gh pr merge 5` then `git push origin main`.\nEOF\n)"'
g A - feat $'gh issue comment 7 --body-file - <<\'EOF\'\n| a | b |\nnever `git push --force`; `gh pr merge` is Gate 2 && more\nEOF'
g A - feat 'git commit -m "docs: never git push origin main, never gh pr merge"'
g A - feat 'grep -rn "gh pr merge" . | head -5'
g D - feat $'cat <<EOF\n$(gh pr merge 5)\nEOF'                                # unquoted heredoc expands
g A - feat $'cat <<\'EOF\'\n$(gh pr merge 5)\nEOF'

# ── push to a protected branch ────────────────────────────────────────────────────────────
g D - feat 'git push origin main'
g D - feat 'git push -u origin main'
g D - feat 'git push origin HEAD:main'
g D - feat 'git push origin feat/1-x:main'
g D - feat 'git push origin HEAD:refs/heads/main'
g D - feat 'git push origin master'
g D - feat 'git -C . push origin main'
g D - feat 'git -c push.default=current push origin main'
g D - feat "git 'push' origin main"
g D - feat 'git push origin feat/1-x main'
g D - feat 'git add -A && git commit -m x && git push origin main'
g D - feat 'git push origin :main'
g D - feat 'git push origin --delete main'
g D - feat 'git push --all origin'
g D - feat 'git push --mirror'
g D - feat "git push origin 'refs/heads/*:refs/heads/*'"
g D - feat 'B=main; git push origin $B'
g D - feat 'git push origin "$(git branch --show-current)"'
g D - onmain 'git push'
g D - onmain 'git push origin HEAD'
g D - feat 'cd ../onmain && git push'
g D - feat 'git -C ../onmain push'
g D - feat 'cd "$SOMEWHERE" && git push'
g D - track 'git push'                                                      # topic tracks origin/main
g D - trunk 'git push origin trunk'                                         # origin's default branch
g D - trunk 'cd "$PWD" && git push origin trunk'                            # …even after a cd it can't follow
g D - feat 'command git push origin main'
g D - feat 'find . -name x -exec git push origin main \;'
g D - feat 'git -c alias.p=push p origin main'

# ── the branch a push leaves from is the one an earlier checkout / cd in the SAME command set ──
g D - feat 'git checkout main && git merge --no-ff feat/1-x && git push'
g D - feat 'git switch main && git push'
g D - feat 'git checkout main && git merge feat/1-x && git push origin HEAD'
g D - feat 'git checkout -b hotfix origin/main && git push'                 # tracks origin/main
g D - feat 'git checkout - && git push'                                      # previous branch: unknown
g D - feat 'git checkout "$B" && git push origin HEAD'
g A - onmain 'git checkout -b feat/5-login && git add -A && git commit -m "feat: login" && git push -u origin HEAD'
g A - onmain 'git switch -c feat/6 && git push -u origin feat/6'
g A - onmain 'git checkout -b feat/7 && git push'
g A - onmain 'gh pr checkout 5 && npm test && git add tests && git commit -m "test: S1-AC2" && git push'
g D - onmain 'gh pr checkout 5 -b main && git push'
g A - feat 'git checkout -- README.md && git push'                           # restores a file; branch unchanged
g A - feat 'git checkout f && git push origin HEAD'                          # `f` is a file here, not a branch
g D - feat 'pushd ../onmain && git push'
g D - onmain '(cd ../feat && ls); git push'                                  # the cd dies with the subshell
g D - onmain 'x=$(cd ../feat && git rev-parse HEAD); git push'
g A - feat '(cd /tmp && ls); git push'
g A - onmain '(cd ../feat && git push)'
g D - feat '(cd ../onmain && git push)'
g D - feat 'GIT_DIR=../onmain/.git git push'
g D - feat 'bash -c "cd ../onmain && git push"'
g A - onmain 'cd ../feat && git push -u origin feat/1-x'

# ── other ways HEAD lands on a protected branch ───────────────────────────────────────────
g D - feat 'git branch -M main && git push -u origin HEAD'
g D - feat 'git rebase feat/1-x main && git push'
g D - feat 'git checkout main -- && git push'                                # `<branch> --` switches
g D - feat 'git checkout -Bmain && git push origin HEAD'                     # glued -B<name>
g D - feat 'git checkout -qB main && git push origin HEAD'
g D - feat 'git symbolic-ref HEAD refs/heads/main && git push'
g D - feat 'git checkout main && git merge feat/1-x && cd src && git push'   # a subdirectory is the same repo
g D - feat 'git -C src checkout main && git merge feat/1-x && git push'
g A - feat 'git branch -m feat/renamed && git push -u origin HEAD'

# ── a step that may have FAILED: past a `;` or a newline the old branch still counts ───────
g D - onmain $'git checkout -b feat/9\ngit add -A\ngit commit -m x\ngit push -u origin HEAD'
g D - onmain 'git checkout feat/1-x; git push -u origin HEAD'
g D - onmain 'gh pr checkout 12; echo fix >> f; git commit -qam fix; git push -q'
g D - onmain 'git checkout -b feat/9 || true; git push'
g A - onmain $'git checkout -b feat/9\ngit add -A\ngit commit -m x\ngit push -u origin feat/9'
g A - feat $'git checkout -b feat/9\ngit push -u origin HEAD'               # failing leaves a feature branch
g A - onmain '(git checkout -b feat/9 && git add -A) && git push -u origin HEAD'

# ── arguments that arrive through a variable ───────────────────────────────────────────────
g D - feat 'G=git; $G push origin main'
g D - feat 'ARGS="origin main"; git push $ARGS'
g D - feat 'S=push; git $S origin main'
g D - feat 'X="push origin main"; git $X'
g D - feat 'GH=gh; $GH pr merge 5'
g D - feat 'X=api; gh $X -X PUT repos/o/r/pulls/5/merge'
g D - feat 'export B=main; git push origin "$B"'
g D - feat 'for b in main; do git push origin $b; done'
g D - feat 'git $SUB origin main'                                            # unknown subcommand
g D - feat 'gh $GROUP merge 5'
g D - feat '"$GIT" push origin main'
g D - feat '$GH pr merge 5'
g D - feat 'git push $REMOTE_AND_REF'
g A - feat 'B=feat/1-x; git push -u origin "$B"'
g A - feat 'R=origin; B=feat/1-x; git push $R $B'
g A - feat 'git push "$REMOTE" feat/1-x'
g A - feat 'git push https://x-access-token:$GH_TOKEN@github.com/o/r.git feat/1-x'
g D - feat 'git push https://x-access-token:$GH_TOKEN@github.com/o/r.git main'
g A - feat '< @() x'                                                         # odd syntax must not crash the parser
g A - feat '"$PYTHON" -m pytest -q'
g D - feat 'retry() { "$@" || "$@"; }; retry gh pr merge 5'                  # a helper that runs its arguments
g D - feat 'run() { echo "+ $*"; "$@"; }; run git push origin main'
g D - feat 'f() { eval "$1"; }; f "gh pr merge 5"'
g D - feat 'X="gh pr merge 5"; echo "$X" | bash -s -- a'
g D - feat $'while read -r c; do $c; done <<\'EOF\'\ngh pr merge 5\nEOF'      # the data comes after its use
g D - feat "gh api graphql -f query=\$'mut\\x61tion { x }'"
g A - feat 'retry() { "$@" || "$@"; }; retry npm test && git push -u origin feat/1-x'
g A - feat 'MSG="never git push origin main"; git commit -m "$MSG"'

# ── a `cd` that does not carry over ────────────────────────────────────────────────────────
g D - onmain '[ -d ../nope ] && cd ../feat; git push'                        # may not have run
g D - onmain 'if [ -d ../feat ]; then cd ../feat; fi; git push'
g D - onmain 'cd ../feat | cat; git push'                                    # a pipeline is a subshell
g D - onmain 'f() { cd ../feat; }; git push'                                 # defining is not calling
g D - feat 'f() { cd ../onmain; }; f; git push'                              # …and calling may go anywhere
g D - onmain '(case a in a) cd ../feat ;; esac); git push'
g A - onmain '[ -d ../feat ] && cd ../feat && git push'

# ── a `cd` that may not have run: the push may leave from where the session was ──────────
g D - onmain "true || cd $GR/feat && git push origin HEAD"                    # `true` succeeded: no cd
g D - onmain "! cd $GR/feat/nope && git push origin HEAD"                     # goes on when the cd FAILED
g D - onmain "true || { cd $GR/feat; } && git push origin HEAD"
g D - onmain "case a in b) cd $GR/feat ;; esac; git push origin HEAD"
g D - onmain "true && cd $GR/feat; (git push origin HEAD)"
g D - onmain "cd $GR/feat & wait; git push origin HEAD"                       # a background job is a subshell
g D - onmain "cd $GR/feat || true & wait; git push origin HEAD"               # …the whole list is
g D - onmain "eval 'cd $GR/feat' & wait; git push origin HEAD"
g D - onmain "cd $GR/feat && (true) & wait; git push origin HEAD"              # the group is part of the & list
g D - onmain "{ cd $GR/feat; true; } & wait; git push origin HEAD"
g D - onmain "cd $GR/feat && { true; } & wait; git push origin HEAD"
g D - onmain "cd $GR/feat || if true; then :; fi & wait; git push origin HEAD"   # the if…fi is part of the & list
g D - onmain "cd $GR/feat && for i in 1; do :; done & wait; git push origin HEAD"
g A - onmain "cd $GR/feat && if true; then :; fi; git push origin HEAD"
g D - onmain "false || eval 'cd $GR/feat' && true || true && git push origin HEAD"   # the eval may not have run
g A - onmain "eval 'cd $GR/feat' && git push origin HEAD"                     # eval runs in this shell
g D - feat "source /dev/stdin <<< 'cd $GR/onmain'; git push origin HEAD"      # …and so does source: the cd carries
g D - onmain "cd $GR/feat && git status & wait; git push origin HEAD"
g D - onmain "env FOO=1 cd $GR/feat && git push origin HEAD"                  # env runs a `cd` program: the shell stays put
g D - onmain "find . -maxdepth 0 -exec cd $GR/feat \\; ; git push origin HEAD"
g A - onmain "command cd $GR/feat && git push origin HEAD"                    # a builtin: this one does move
g A - onmain "cd $GR/feat && git push origin HEAD"
g A - onmain "{ cd $GR/feat && git push origin HEAD; }"
g A - onmain "true && cd $GR/feat && git push -u origin HEAD"

# ── refspec and option spellings git accepts ───────────────────────────────────────────────
g D - feat 'git push origin :'                                               # the matching refspec
g D - feat 'git subtree push --prefix docs origin main'
g A - feat 'git subtree push --prefix=docs origin gh-pages'
g D - feat 'git push origin HEAD:heads/main'
g D - feat 'git push --mirr'
g D - feat 'git push --al origin'
g D - feat 'git push --force-with-leas origin feat/1-x'
g D - feat 'git push --del origin main'
g A - feat 'git push -oskip-fmt origin feat/1-x'                             # -o<value>, not -f
g A - feat 'git push --push-option ci.skip -- origin feat/1-x'
g A - feat 'git push --follow-tags origin feat/1-x'
g A - feat 'git push --no-force-with-lease origin feat/1-x'
g D - feat 'git push -d origin feat/old main'

# ── git send-pack is `git push` without the porcelain ─────────────────────────────────────
g D - feat 'git send-pack ../origin.git HEAD:refs/heads/main'
g D - feat 'git send-pack --force ../origin.git feat/1-x:main'
g D - feat 'git send-pack ../origin.git'                                     # no refs: every branch both sides have
g D - feat 'git send-pack --all ../origin.git'
g D - feat '"$GIT" send-pack ../origin.git HEAD:refs/heads/main'
g A - feat 'git send-pack ../origin.git feat/1-x'
g D $AN feat 'git send-pack ../origin.git feat/1-x'

# ── force-push ────────────────────────────────────────────────────────────────────────────
g D - feat 'git push --force origin feat/1-x'
g D - feat 'git push origin feat/1-x -f'
g D - feat 'git push --force-with-lease origin feat/1-x'
g D - feat 'git push -uf origin feat/1-x'
g D - feat 'git push origin +feat/1-x'

# ── pushes a Builder legitimately makes ───────────────────────────────────────────────────
g A - feat 'git push -u origin feat/1-x'
g A - feat 'git push origin HEAD'
g A - feat 'git push'
g A - feat 'git push origin HEAD:refs/heads/feat/1-x'
g A - feat 'git push origin feat/maintenance'
g A - feat 'git push origin --delete feat/old'
g A - feat 'git push --tags'
g A - feat 'git push origin tag v1.0'
g A - feat 'git push -o ci.skip origin feat/1-x'
g A - feat 'git add -A && git commit -m "adlc-fix: x" && git push origin feat/1-x'
g D - trunk 'git push origin main'                                          # …and main still is
g A - trunk 'git push origin feat/x'
g A - feat 'git pull origin main && git merge origin/main && git fetch origin main'

# ── gh api / curl: reads pass, writes do not ──────────────────────────────────────────────
g A - feat 'gh api repos/o/r/commits/abc/pulls --jq length'
g A - feat 'gh api -X GET repos/o/r/issues -f state=open'
g D - feat 'gh api -X PUT repos/o/r/pulls/5/merge'
g D - feat 'gh api repos/o/r/pulls/5/merge --method PUT'
g D - feat 'gh api -XPUT repos/o/r/pulls/5/merge'
g D - feat 'gh api repos/o/r/merges -f base=main -f head=feat'
g D - feat 'gh api repos/o/r/git/refs/heads/main -X PATCH -f sha=abc'
g D - feat 'gh api -X "$M" repos/o/r/pulls/5/merge'
g D - feat "gh api graphql -f query='mutation { mergePullRequest(input:{pullRequestId:\"x\"}) { clientMutationId } }'"
g D - feat 'gh api graphql -F query=@q.graphql'
g A - feat "gh api graphql -f query='query { viewer { login } }'"
g A - feat "gh api graphql -f query='query(\$o:String!){repository(owner:\$o,name:\"r\"){id}}' -f o=\"\$OWNER\""
g D - feat 'Q="mutation { mergePullRequest(input:{pullRequestId:\"x\"}) { clientMutationId } }"; gh api graphql -f query="$Q"'
g D - feat 'gh api graphql -f query="$(cat merge.graphql)" -f id=PR_x'
g D - feat 'gh api graphql --input q.json'
g D - feat 'gh api --method=PATCH repos/o/r/pulls/5 --field=state=closed'
g D - feat 'curl -sX PUT -H "Authorization: Bearer $GH_TOKEN" https://api.github.com/repos/o/r/pulls/5/merge'
g D - feat 'curl -sSLX PUT https://api.github.com/repos/o/r/pulls/5/merge'
g D - feat 'curl -X PUT "$GITHUB_API_URL/repos/$GITHUB_REPOSITORY/pulls/5/merge" -H "Authorization: Bearer $GH_TOKEN"'
g D - feat 'curl -XPUT https://api.github.com/repos/o/r/pulls/5/merge'
g D - feat 'curl --request PATCH https://api.github.com/repos/o/r/git/refs/heads/main --data "{}"'
g D - feat 'wget --method PUT https://api.github.com/repos/o/r/pulls/5/merge'
g D - feat 'wget --post-data="{}" https://api.github.com/repos/o/r/merges'
g A - feat 'curl -sSL -H "Accept: application/json" -o out.json https://api.github.com/repos/o/r/pulls/5'
g A - feat 'curl -s -u "x:$GH_TOKEN" https://api.github.com/user'
g D - feat 'curl -s https://API.GITHUB.COM/repos/o/r/pulls/5/merge -X PUT'
g D - feat 'URL=https://api.github.com/repos/o/r/pulls/5/merge; curl -X PUT $URL'
g A - feat 'curl -sG --data-urlencode "q=is:open" https://api.github.com/search/issues'
g D - feat 'curl -X PUT -H "Authorization: Bearer $GH_TOKEN" https://api.github.com/repos/o/r/pulls/5/merge'
g A - feat 'curl -s https://api.github.com/repos/o/r/pulls/5'
g A - feat 'curl -X POST https://example.com/hook -d x'

# ── ordinary work is untouched ────────────────────────────────────────────────────────────
g A - feat 'npm test && echo done'
g A - feat 'gh pr create --title "feat: x" --body "Closes #5" --base main'
g A - feat 'gh pr edit 5 --add-label lane:fast'
g A - feat 'gh run watch 123 --exit-status'
g A - feat "awk '{print \$1}' f | sort | uniq -c"
g A - feat 'x=(a b c); echo ${x[0]}'
g A - feat 'case "$1" in main) echo m ;; *) echo o ;; esac'
g A - feat 'echo "unterminated'                                              # bash itself rejects it
g A - feat 'eval "$(ssh-agent -s)" && ssh-add ~/.ssh/id_ed25519 && git push -u origin feat/1-x'
g A - feat 'eval "$(pyenv init -)" && pytest -q && gh api repos/o/r/pulls/5/comments'
g A - feat 'curl -fsSL https://example.com/install.sh | bash && git push -u origin feat/1-x'
g A - feat "node -e \"require('child_process').execSync('git log --oneline').toString().split('\\n').forEach(l => rows.push(l))\""
g A - feat 'git commit -m "fix: $'"'"' quoting" && git push -u origin feat/1-x'
g A - feat 'if (( 1 << 3 > 4 )); then echo big; fi; git push -u origin feat/1-x'
g A - feat 'arr=(a "b c" "(" d); echo "${arr[@]}"; git status'
g A - feat 'echo hi # git push origin main'                                  # a comment
g A - feat 'command -v gh && gh --version'
g A - feat $'cat <<-EOF\n\tgit push origin main\n\tEOF'

# ── bash that hides a call from a careless reader ─────────────────────────────────────────
g D - feat 'echo "$( (true); gh pr merge 5 )"'
g D - feat 'echo "$(for ((i=0; i<1; i++)); do gh pr merge 5; done)"'
g D - feat 'out="$(case x in x) gh pr merge 5 ;; esac)"'
g D - feat 'x=$(case a in (a|b) echo 1 ;; *) echo 2 ;; esac); gh pr merge 5'
g D - feat 'x=( $(gh pr merge 5) )'
g D - feat 'arr=("(" b); git push origin main'
g D - feat $'(( y = 1 << 3 ))\ngit push origin main'
g D - feat $'bash <<EOF\nout=\\$(gh pr merge 5)\nEOF'
g D - feat 'bash <<< "gh pr merge 5"'
g D - feat 'cat <(gh pr merge 5)'
g D - feat "echo '/usr/bin/git push origin main' | bash"
g D - feat $'cat <<\'EOF\' | sh\ngit push origin main\nEOF'
g D - feat 'CMD="gh pr merge 5"; $CMD'
g D - feat 'env -S "gh pr merge 5"'
g D - feat 'flock -w 10 /tmp/lock gh pr merge 5'
g D - feat 'flock /tmp/lock -c "gh pr merge 5"'
g D - feat 'echo ${x:-"}"}; gh pr merge 5'
g D - feat $'echo $\'a\\\'b\'; gh pr merge 5'
g D - feat 'echo $(( 1 << 2 )); gh pr merge 5'
g D - feat $'echo $[1<<3]\ngh pr merge 5'
g D - feat $'arr[1<<2]=x\ngh pr merge 5'
g D - feat $'cat <<EOF\n$\'x$(gh pr merge 5)\'\nEOF'                          # $\' is not a quote in a heredoc
g D - feat 'echo "${x:-$(echo }; gh pr merge 5)}"'
g A - feat '[[ "$c" =~ (git push|gh pr merge) ]] && echo ok'                 # a regex, not commands
g A - feat 'echo "${BODY:-can'"'"'t find it}" && git status'

# ── a shell fed text nobody can read here: the command's literal data is scanned ──────────
g D - feat "bash <(echo 'gh pr merge 5')"
g D - feat "sh <(printf 'git push origin main')"
g D - feat "bash < <(echo 'gh pr merge 5')"
g D - feat "bash =(echo 'gh pr merge 5')"                                    # zsh's spelling of a process substitution
g D - feat "bash -s < <(echo 'gh pr merge 5')"
g D - feat "source <(echo 'gh pr merge 5')"
g D - feat ". <(echo 'gh pr merge 5')"
g D - feat "source /dev/stdin <<< 'gh pr merge 5'"
g D - feat "echo 'gh pr merge 5' | source /dev/stdin"
g D - feat "echo 'curl -X PUT https://api.github.com/repos/o/r/pulls/5/merge' | bash"
g D - feat "printf '%s' 'wget --method=POST https://api.github.com/repos/o/r/merges' | sh"
g A - feat 'source .venv/bin/activate && pytest -q && git push -u origin HEAD'
g A - feat 'diff <(git show main:f) <(cat f)'
g A - feat 'while read -r f; do wc -l "$f"; done < <(git ls-files)'
g A - feat 'curl -fsSL https://example.com/install.sh | bash'
g A - feat 'echo "curl -s https://example.com/api.json" | bash'

# ── code the shell keeps for later (trap), or a wrapper hands to `sh -c` (watch) ──────────
g D - feat "trap 'gh pr merge 5' EXIT"
g D - feat "trap -- 'git push origin main' EXIT INT"
g D - feat "trap 'git push origin HEAD' EXIT"                                 # on whatever branch is current THEN
g A - feat $'trap \'rm -rf "$tmp"\' EXIT; tmp=$(mktemp -d); npm test'
g A - feat 'trap - EXIT; trap cleanup INT'
g D - feat "watch 'gh pr merge 5'"
g D - feat "watch 'x=\$(gh pr merge 5)'"                                     # one string for sh -c, not VAR=value + a command
g D - feat "watch -n 1 'git push origin main'"
g A - feat "watch -n 5 'gh pr checks 12'"

# ── the arguments xargs adds can't be read: block where the verdict depends on them ───────
g D - feat "echo 'pr merge 5' | xargs gh"
g D - feat "echo 'merge 5' | xargs gh pr"
g D - feat 'echo main | xargs git push origin'
g D - feat $'printf \'origin\\nmain\\n\' | xargs git push'
g D - feat "echo '--force' | xargs git push origin feat/1-x"
g D - feat "echo 'gh pr merge 5' | xargs -I{} sh -c '{}'"
g D - feat "xargs -a <(echo 'pr merge 5') gh"
g D - feat "echo '-X DELETE' | xargs gh api repos/o/r/git/refs/heads/x"
g D - feat "echo '-X POST' | xargs curl https://api.github.com/repos/o/r/merges"
g D - feat "echo '-X PUT https://api.github.com/repos/o/r/pulls/5/merge' | xargs curl"   # the URL arrives on stdin too
g A - feat "echo 'https://example.com/a.tgz' | xargs curl -sLO"
g A - feat 'git ls-files | xargs wc -l'
g A - feat 'git diff --name-only | xargs git add'
g A - feat "ls | xargs -I{} sh -c 'wc -l {}'"
g A - feat "gh pr list --json number -q '.[].number' | xargs -n1 gh pr view"
g A - feat "gh pr list --json number -q '.[].number' | xargs -I{} gh pr comment {} --body ping"

# ── gh api / curl / push with an argument nobody can read ────────────────────────────────
g D - feat 'gh api repos/o/r/pulls/5/merge $(echo -XPUT)'
g D - feat 'gh api "$(echo -XPUT)" repos/o/r/pulls/5/merge'
g D - feat 'gh api $ENDPOINT'                                                # unquoted: may be `-X DELETE repos/…`
g A - feat 'gh api "$URL" --jq .name'                                        # one quoted word is the endpoint
g A - feat 'gh api "repos/$OWNER/$REPO/pulls/$N/files" --paginate'
g A - feat 'gh api repos/$OWNER/$REPO/pulls'
g D - feat 'gh pr "$SUB" 5'                                                  # may be `merge`
g D - feat 'curl https://api.github.com/repos/o/r/merges $(echo -XPOST)'
g A - feat 'curl -s -H "$AUTH" -o "$OUT" https://api.github.com/repos/o/r/tarball/main'
g D - feat 'git push $(echo origin main)'

# ── reaching the next step does not always prove the one before it succeeded ──────────────
g D - feat 'git branch -M main; git checkout feat/1-x && git checkout -b tmp main; git push origin HEAD'
g D - onmain '! git checkout -b x nonexistent && git push origin HEAD'        # runs on when the checkout FAILED
g D - onmain 'coproc git checkout -b x && git push origin HEAD'
g D - onmain 'true && echo $(git checkout -b y) && git push origin HEAD'      # echo succeeds either way
g D - onmain '(git checkout -b x; true) && git push origin HEAD'
g A - onmain '{ git checkout -b feat/9-x && git add -A; } && git push -u origin HEAD'
g D - onmain 'true || git checkout -b x && git push origin HEAD'              # `true` succeeded: the checkout never ran
g D - onmain 'true || { true && git checkout -b x; } && git push origin HEAD'
g D - onmain 'true || (git checkout -b x) && git push origin HEAD'
g D - onmain '! { git checkout -b x nonexistent; } && git push origin HEAD'
g D - onmain 'true | xargs git switch -c x && git push origin @'              # no input: xargs runs nothing, and succeeds
g D - onmain 'find . -name nomatch -exec git checkout -b x \; && git push origin HEAD'
g D - onmain "trap 'git checkout -b x' EXIT && git push origin @"             # the trap runs after the push
g D - onmain 'git --version checkout -b x && git push origin HEAD'            # prints the version, switches nothing
g D - onmain 'git checkout --help -b x && git push origin HEAD'               # opens the manual, switches nothing
g D - feat 'git config push.default matching --help; git push'               # here --help is a value: the key IS set
g A - onmain 'git checkout -b feat/9-x && { git add -A; git commit -m x; } && git push -u origin feat/9-x'
g A - onmain 'git checkout -b feat/9-x && git commit -am x || echo nothing; git push -u origin feat/9-x'

# ── git config can send a push somewhere else ─────────────────────────────────────────────
g D - feat 'git -c push.default=matching push'
g D - feat 'git -c remote.origin.push=HEAD:refs/heads/main push'
g D - feat 'git --config-env=push.default=X push'
g D - feat 'git config push.default matching; git push'
g D - feat 'git config remote.origin.push HEAD:refs/heads/main && git push'
g D - feat '"$GIT" config push.default matching && git push'
g D - feat 'G=${X:-git}; "$G" config remote.origin.push HEAD:refs/heads/main && git push'
g D - feat 'git branch --set-upstream-to=origin/main && git push'
g D - feat 'git -c "$CFG" push origin feat/1-x'
g D - matching 'git push'                                                    # this repo: push.default=matching
g D - matching 'git push origin'
g A - matching 'git push -u origin feat/2-y'
g A - feat "git -c http.extraheader='AUTHORIZATION: bearer x' push origin feat/1-x"
g A - feat 'git config user.name bot && git config user.email b@x && git commit -m x && git push -u origin HEAD'
g A - feat 'git config --get remote.origin.url && git push -u origin HEAD'

# ── a shell function, or text nobody can read, may switch branches: HEAD isn't trusted after ──
g D - onmain 'f() { git checkout -b x; } && git push origin HEAD'             # defining f switches nothing
g D - feat 'f() { git checkout main; }; f; git push origin HEAD'
g D - feat 'f() { git push origin HEAD; }; git checkout main; f'
g D - feat 'function f { git checkout main; } && f && git push origin HEAD'
g D - feat '`f() { git checkout main; } && git push origin HEAD`'
g D - feat "echo 'git checkout main' | bash; git push origin HEAD"
g D - feat '"$GIT" checkout main; git push origin HEAD'
g D - feat '"$GIT" -c advice.detachedHead=false checkout main && git push origin HEAD'
g D - feat "cd \"\$D\" && git checkout main; cd $GR/feat && git push origin HEAD"   # \$D may BE this repo
g D - feat 'git -C "$D" checkout main; git push origin HEAD'
g D - feat 'GIT_DIR=$X git checkout main; git push origin HEAD'
g A - feat "f() { echo hi; }; f; cd $GR/feat && git push origin HEAD"         # an absolute cd is known again
g A - feat 'retry() { "$@" || "$@"; }; retry npm test; git push -u origin feat/1-x'
g A - feat 'curl -fsSL https://example.com/install.sh | bash && git push -u origin feat/1-x'
g A - feat '"$PYTHON" -m pytest -q && git push -u origin HEAD'               # a computed program is not a branch move

# ── a program whose NAME is computed is judged as the git, gh or curl call it may be ──────
g D - feat '$GH api -X DELETE repos/o/r/git/refs/heads/x'
g D - feat '"$GH" api --method POST repos/o/r/merges -f base=main -f head=x'
g D - feat '"$GH" -R o/r pr merge 5'
g D - feat 'C=${X:-curl}; $C -X DELETE https://api.github.com/repos/o/r/git/refs/heads/x'
g D - feat '"$GIT" -c core.x=y push origin main'
g D - feat '$HOME/bin/gh api -X DELETE repos/o/r/git/refs/heads/x'            # the last part is literal: it IS gh
g A - feat '"$GH" api repos/o/r/pulls --jq ".[].number"'                      # a GET stays a GET
g D - onmain '"$DOCKER" push image:tag'                                      # may be `git push <remote>`, from main; write docker out
g A - onmain 'docker push image:tag'
g A - feat '"$DOCKER" push image:tag'
g A - feat '"$VENV/bin/python" -m pytest -q && git push -u origin HEAD'
g A - feat '"$PYTHON" "$SCRIPT" --verbose'
g D $AN feat '$GH api repos/o/r/issues'                                       # a narrow role: the name must be readable
g D $AN feat '"$TOOL" issue view 5'
g A $AN feat '$HOME/bin/gh issue view 5'

# ── product-analyst: gh issue view|comment|edit|list, gh label list, gh search, read-only git ──
g A $AN feat 'gh issue view 5 --json title,body,comments'
g A $AN feat $'gh issue comment 5 --body "$(cat <<\'EOF\'\n## Stories\nS1: As a user, I want x (so that y). It\'s `git push`-free.\nADLC-TRIAGE: FULL | needs design\nEOF\n)"'
g A $AN feat 'gh issue edit 5 --remove-label stage:intake --add-label gate:stories'
g A $AN feat 'gh label list && gh search issues "login bug"'
g A $AN feat 'git log --oneline -5 && git status && git branch --show-current'
g A $AN feat 'grep -rn "def login" src | head; ls -la; cat README.md'
g A $AN feat "printf 'src/a.py\n' | .adlc/scripts/adlc-triage.sh"
g A $AN feat 'gh auth status; gh repo view --json nameWithOwner; gh --version'
g A $AN feat 'timeout 20 grep -rn gh docs/'
g D $AN feat 'gh repo delete o/r --yes'
g D $AN feat 'sudo -u bob git commit -am x'
g D $AN feat 'gh pr create --title x --body y'
g D $AN feat 'gh api repos/o/r/issues'
g D $AN feat 'git commit -am x'
g D $AN feat 'git push -u origin feat/1-x'
g D $AN feat 'git branch newbranch'
g D $AN feat 'git remote set-url origin https://x'
g D $AN feat 'git -c core.pager=evil log'
g D $AN feat 'git diff --output=/tmp/x'
g D $AN feat 'gh issue view 5 && git commit -am x'
g D $AN feat 'bash -c "git commit -am x"'
g D $AN feat 'echo ${x:-"}"}; git commit -am x'
g D $AN feat 'x=( $(git commit -am x) )'
g D $AN feat 'echo "unterminated; git commit -am x'                          # unparseable: a role's limits can't be checked
g A $AN feat 'git branch --contains HEAD && git branch -a --list "feat/*"'
g A $AN feat 'gh issue comment 5 --body "${BODY:-can'"'"'t find it}"'
g A $AN feat '[[ "$c" =~ (git push|gh pr merge) ]] && echo ok'
g D $AN feat 'git branch -D feat/1-x'
g A $AN feat 'gh issue list --search "login" --state all'
g D $AN feat 'gh issue delete 7 --yes'                                       # it reads untrusted text: no destructive verbs
g D $AN feat 'gh issue close 7'
g D $AN feat 'gh issue transfer 7 o/other'
g D $AN feat 'gh issue develop 7 --name hotfix --base main'                  # creates a branch
g D $AN feat 'gh issue create --title x --body y'
g D $AN feat 'gh label delete stage:build --yes'
g D $AN feat 'gh label create shiny'

# ── adversarial-reviewer: gh pr view|diff|comment, gh issue view, read-only git ───────────
g A $RV feat 'gh pr diff 5 && gh pr view 5 --json comments,body'
g A $RV feat "gh pr comment 5 --body 'finding: \`git push --force\` in deploy.sh — ADLC-ADV: CHANGES'"
g A $RV feat 'gh issue view 12'
g A $RV feat 'git diff origin/main...HEAD -- src/ | head -400'
g D $RV feat 'gh pr review 5 --approve'
g D $RV feat 'gh pr edit 5 --add-label adlc:changes-requested'
g D $RV feat 'gh issue edit 12 --add-label stage:qa'
g D $RV feat 'git stash'
g D $RV feat 'git checkout main'

# ── architect: gh issue view|comment|edit|list, gh pr view|diff|comment|review, read-only git ──
g A $AR feat 'gh issue list --label stage:build --state open'
g A $AR feat 'gh issue edit 5 --remove-label stage:design --add-label stage:build'
g A $AR feat 'gh pr review 5 --request-changes --body x'
g D $AR feat 'gh pr create --title x'
g D $AR feat 'git commit -m adr'

# ── role names: a vendored copy matches; another plugin's agent does not ──────────────────
g D product-analyst feat 'git commit -am x'
g A other:architect feat 'git commit -am x'
g A adlc:builder feat 'git commit -am x && git push -u origin feat/1-x'
g D adlc:builder feat 'gh pr merge 5'
g D adlc:qa-release-ops feat 'git push origin main'
g D general-purpose feat 'gh pr merge 5'
