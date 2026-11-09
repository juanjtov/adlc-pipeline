# Cases for the ADLC guard hook (hooks/adlc-guard.sh → adlc_guard.py). Sourced by tests/run.sh.
#   g <A|D> <role|-> <repo> <command>     A = allowed (exit 0) · D = denied (exit 2)
# role is the hook's agent_type ("-" = the main thread, no agent). repo is the cwd:
#   feat = on branch feat/1-x · onmain = on main · track = branch tracking origin/main
#   trunk = clone whose origin default branch is `trunk`
#   matching = on branch feat/2-y in a clone configured push.default=matching
#   w <A|D> <role|-> <repo[/subdir]> <tool> <path|->     a file-writing tool call ("-" = it names no file)
#   wr = a repo with docs/adr/, src/ and sub/, and links under docs/: code → ../src, away → out of
#        the repo, latest → adr, app.md → ../src/app.py, dangling.md → a file that is not there
#   nogit = a directory with docs/ in no git work tree
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
g D - feat 'gh pr --subject view merge 5'                                     # gh takes the word after a flag as its value: this is `gh pr merge 5`
g D - feat 'gh pr -s view merge 5'
g D - feat 'gh --foo x pr merge 5'                                            # …at either level
g D - feat 'gh pr --delete-branch --subject x merge 5'
g D - feat 'bash -c "gh pr --body view merge 5"'
g D - feat '"$GH" pr --subject view merge 5'
g D - feat 'echo "gh pr --subject x merge 5" | bash'
g D - feat 'gh alias --shell x set m "pr merge"'
g D - feat 'gh pr --subject "$S" view 5'                                      # after such a flag a computed word may be the subcommand
g A - feat 'gh pr --json title view 5'                                        # a flag first, and no word that could make a blocked call
g A - feat 'gh -R o/r pr view 5 && gh pr view 5 --json title && gh pr list --state open && gh issue view 7 --comments'
g A - feat 'gh pr --help && gh --help && gh pr view --help'
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
g D - onmain 'gh pr --foo checkout 5 && git push'                            # checked out, or `--foo checkout` was a flag and its value: unknown
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
g D - feat 'gh -X DELETE api repos/o/r/git/refs/heads/x'                      # a flag written before `api` is api's flag too
g D - feat 'gh --method=DELETE api repos/o/r/issues/1'
g D - feat 'gh -XDELETE api repos/o/r/issues/1'
g D - feat 'gh -f title=x api repos/o/r/issues'
g D - feat 'gh --input body.json api repos/o/r/issues'
g A - feat 'gh --jq .name api repos/o/r && gh --hostname github.example.com api repos/o/r/issues'
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
g D - feat '"$GH" -X DELETE api repos/o/r/git/refs/heads/x'
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
g D $AN feat 'gh issue --title view close 7'                                  # gh reads this as `gh issue close 7`: a flag before the subcommand can't be checked
g D $AN feat 'gh --foo label issue delete 7 --yes'
g A $AN feat 'gh -R o/r issue view 5 && gh issue view 5 --repo o/r'
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
g A $AN feat '.adlc/scripts/adlc-relabel.sh 5 gate:stories'                  # the relabel script is `gh issue edit` by another name
g A $AN feat 'bash .adlc/scripts/adlc-relabel.sh 5 gate:stories'

# ── adversarial-reviewer: gh pr view|diff|comment, gh issue view, read-only git ───────────
g A $RV feat 'gh pr diff 5 && gh pr view 5 --json comments,body'
g A $RV feat "gh pr comment 5 --body 'finding: \`git push --force\` in deploy.sh — ADLC-ADV: CHANGES'"
g A $RV feat 'gh issue view 12'
g A $RV feat 'git diff origin/main...HEAD -- src/ | head -400'
g D $RV feat 'gh pr review 5 --approve'
g D $RV feat 'gh pr --body view review 5 --approve'                           # `gh pr review`, behind a flag that takes `view` as its value
g D $RV feat 'gh pr edit 5 --add-label adlc:changes-requested'
g D $RV feat 'gh issue edit 12 --add-label stage:qa'
g D $RV feat '.adlc/scripts/adlc-relabel.sh 12 stage:qa'                      # …so the reviewer may not run it either
g D $RV feat '/w/.adlc/scripts/adlc-relabel.sh 12 stage:qa'
g D $RV feat 'bash .adlc/scripts/adlc-relabel.sh 12 stage:qa'
g D $RV feat 'bash -o pipefail .adlc/scripts/adlc-relabel.sh 12 stage:qa'      # an option's value is not the script
g D $RV feat 'bash +x .adlc/scripts/adlc-relabel.sh 12 stage:qa'               # `+x` is an option too
g D $RV feat 'bash "$S/adlc-relabel.sh" 12 stage:qa'                           # a computed prefix, a literal script name
g D $RV feat 'bash $S/adlc-relabel.sh 12 stage:qa'
g D $RV feat 'bash "$PWD/.adlc/scripts/adlc-relabel.sh" 12 stage:qa'
g A $RV feat 'bash -n .adlc/scripts/adlc-relabel.sh'                           # a syntax check runs nothing
g D $RV feat 'git stash'
g D $RV feat 'git checkout main'

# ── architect: gh issue view|comment|edit|list, gh pr view|diff|comment|review, read-only git ──
g A $AR feat 'gh issue list --label stage:build --state open'
g A $AR feat 'gh issue edit 5 --remove-label stage:design --add-label stage:build'
g A $AR feat '.adlc/scripts/adlc-relabel.sh 5 stage:build'
g A $AR feat '.adlc/scripts/adlc-adr-check.sh'                              # a script that calls neither gh nor git: the role limits do not reach it
g A adlc-architect feat 'bash .adlc/scripts/adlc-adr-check.sh docs/adr'
g A $AR feat 'gh pr review 5 --request-changes --body x'
g D $AR feat 'gh pr create --title x'
g D $AR feat 'gh pr --title view create'
g D $AR feat 'git commit -m adr'

# ── role names: a vendored copy matches; another plugin's agent does not ──────────────────
g D product-analyst feat 'git commit -am x'
g D adlc-product-analyst feat 'git commit -am x'                # this repo's copy, as /adlc-init writes it
g D adlc-adversarial-reviewer feat 'gh pr review 5 --approve'
g D adlc-architect feat 'gh pr create --title x'
g A adlc-architect feat 'gh issue edit 5 --remove-label stage:design --add-label stage:build'
g A adlc-builder feat 'git commit -am x && git push -u origin feat/1-x'
g D adlc-builder feat 'gh pr merge 5'
g D adlc-qa-release-ops feat 'git push origin main'
g A adlc-qa-release-ops feat '.adlc/scripts/adlc-relabel.sh 12 gate:deploy'     # QA moves the issue to its terminal gate
g A - feat '.adlc/scripts/adlc-relabel.sh 12 gate:deploy'
g A adlc-other feat 'git commit -am x'                          # not one of the narrow roles: universal blocks only
g A other:architect feat 'git commit -am x'
g A adlc:builder feat 'git commit -am x && git push -u origin feat/1-x'
g D adlc:builder feat 'gh pr merge 5'
g D adlc:qa-release-ops feat 'git push origin main'
g D general-purpose feat 'gh pr merge 5'

# ── /adlc:autopilot (issue 36): the skill splits each step by who the guard lets do it ────
g D adlc-adversarial-reviewer feat 'git fetch origin'            # so the orchestrator fetches before the reviews…
g A adlc-adversarial-reviewer feat 'git diff 1111111..2222222'   # …and the reviewer reads the fix delta
g D adlc-architect feat 'git checkout feat/1-x'                  # so the orchestrator checks the PR branch out for the amendment…
g D adlc-architect feat 'git add docs/adr/0007-x.md && git commit -m "docs(adr): amend 0007"'   # …and commits it
g A adlc-architect feat "gh pr comment 9 --body-file - <<'EOF'
Conforms to ADR 0007.
ADLC-ARCH: PASS
EOF"
g A - onmain 'git fetch origin && git checkout feat/1-x && git add docs/adr/0007-x.md && git commit -m "docs(adr): amend 0007" && git push origin feat/1-x'
g A - feat 'gh issue edit 7 --add-label adlc:autopilot && .adlc/scripts/adlc-relabel.sh 7 stage:design'
g A - feat 'gh pr edit 9 --add-label needs:human && gh pr comment 9 --body "stopped: the cap did not say GO"'
g A - feat '.adlc/scripts/adlc-fix-cap.sh --pr 9'
g A - feat 'gh pr list --state open --json number,headRefName,author'
g A - feat 'gh pr view 9 --json comments --jq ".comments | length"'
g A - feat 'bodies=$(gh pr view 9 --json comments --jq ".comments[4:][].body"); printf "%s\n" "$bodies" | .adlc/scripts/adlc-verdict.sh ADLC-ADV'
g A - feat 'gh pr edit 9 --add-label adlc:changes-requested && .adlc/scripts/adlc-fix-cap.sh --pr 9'
g A - feat 'gh pr edit 9 --remove-label needs:human'
g A - feat 'git fetch origin && base=$(git merge-base refs/remotes/origin/main refs/remotes/origin/feat/1-x) && d=$(git -c core.quotePath=false diff --numstat --no-renames --raw --ignore-submodules=none "$base" refs/remotes/origin/feat/1-x) && [ -n "$d" ] && printf "%s\n" "$d" | .adlc/scripts/adlc-triage.sh'
g D adlc-adversarial-reviewer feat '.adlc/scripts/adlc-relabel.sh 7 gate:deploy'   # so on the fast lane the orchestrator moves the issue
# ── the labels a narrow role may put on an issue (labels.may_add in its contract) ──────────
g A $AN feat 'gh issue edit 5 --add-label gate:stories'
g A $AN feat 'gh issue edit 5 --add-label=gate:stories --remove-label stage:intake'
g D $AN feat 'gh issue edit 5 --add-label stage:design'                         # routing past Gate 1 is the Principal's
g D $AN feat 'gh issue edit 5 --remove-label stage:intake --add-label stage:fast'
g D $AN feat 'gh issue edit 5 --add-label=stage:fast'
g D $AN feat 'gh issue edit 5 --add-label gate:stories,stage:fast'              # a list: every name counts
g D $AN feat 'gh issue edit 5 --add-label gate:stories --add-label adlc:autopilot'   # the opt-in is not the agent's to give
g D $AN feat 'gh issue edit 5 --add-label GATE:STORIES'                         # GitHub matches a label's name without case; the list does not
g D $AN feat 'gh -R o/r issue edit 5 --add-label stage:design'
g D $AN feat 'gh issue edit --add-label stage:design 5'
g D $AN feat 'bash -c "gh issue edit 5 --add-label stage:design"'
g D $AN feat 'gh issue edit 5 --add-label "$L"'                                 # a computed label
g D $AN feat 'gh issue edit 5 --add-label=$L'
g D $AN feat 'L=stage:fast; gh issue edit 5 --add-label $L'                     # resolved, and not on the list
g A $AN feat 'L=gate:stories; gh issue edit 5 --add-label $L'
g D $AN feat 'gh issue edit 5 $EXTRA'                                           # a computed word that may hold the option itself
g D $AN feat 'gh issue edit 5 "$FLAG"'
g D $AN feat 'gh issue edit 5 --add-"$X"'
g D $AN feat 'gh issue edit "$N" --add-label gate:stories'                      # …the issue number included: write it out
g D $AN feat 'echo "--add-label stage:fast" | xargs gh issue edit 5'
g D $AN feat 'gh issue edit 5 --body $BODY'                                     # unquoted: it may split into more options
g A $AN feat 'gh issue edit 5 --body "$BODY" --add-label gate:stories'          # another option's value may be computed
g A $AN feat 'gh issue edit 5 --body="$(cat notes.md)"'
g A $AN feat 'gh issue edit 5 -b"$BODY" --remove-label "$OLD"'
g A $AN feat 'gh issue edit 5 --title "why --add-label stage:fast is wrong" --add-label gate:stories'
g A $AN feat $'gh issue edit 5 --body-file - <<\'EOF\'\nnever --add-label stage:fast\nEOF'
g A $AN feat 'gh issue comment 5 --body "I recommend --add-label stage:fast"'   # a comment adds no label
g D $AN feat '.adlc/scripts/adlc-relabel.sh 5 stage:design'                     # the relabel script: its second argument is the label
g D $AN feat '.adlc/scripts/adlc-relabel.sh 5 stage:fast'
g D $AN feat 'bash .adlc/scripts/adlc-relabel.sh 5 stage:fast'
g D $AN feat '.adlc/scripts/adlc-relabel.sh 5 "$L"'
g D $AN feat '.adlc/scripts/adlc-relabel.sh $ARGS'                              # unquoted: the issue AND the label
g D $AN feat 'echo 5 stage:fast | xargs .adlc/scripts/adlc-relabel.sh'
g D $AN feat 'echo stage:fast | xargs .adlc/scripts/adlc-relabel.sh 5'
g A $AN feat '.adlc/scripts/adlc-relabel.sh "$N" gate:stories'                  # the script takes one word as the issue, whatever it holds
g A $AN feat 'N=5; .adlc/scripts/adlc-relabel.sh $N gate:stories'
g D $AR feat 'gh issue edit 5 --add-label gate:deploy'
g D $AR feat 'gh issue edit 5 --remove-label gate:stories --add-label stage:design'   # the label that follows a gate
g D $AR feat '.adlc/scripts/adlc-relabel.sh 5 stage:qa'
g D adlc-architect feat '.adlc/scripts/adlc-relabel.sh 5 gate:deploy'
g D adlc-product-analyst feat 'gh issue edit 5 --add-label stage:design'
g A adlc-qa-release-ops feat 'gh issue edit 5 --add-label needs:human'          # not a narrow role: its labels are not limited here
g A adlc:builder feat 'gh pr edit 5 --add-label lane:fast'
g A - feat 'gh issue edit 5 --add-label stage:design'                           # the Principal's own session
# the relabel script's two words must each be ONE word for certain
g D $AN feat 'set -- 5 stage:fast; .adlc/scripts/adlc-relabel.sh "$@"'           # "$@" is as many words as it holds
g D $AN feat 'a=(5 stage:fast); .adlc/scripts/adlc-relabel.sh "${a[@]}"'
g D $AN feat $'bash -c \'.adlc/scripts/adlc-relabel.sh "$@"\' _ 5 stage:fast'
g D $AN feat 'f() { .adlc/scripts/adlc-relabel.sh "$@"; }; f 5 stage:fast'
g D $AN feat '.adlc/scripts/adlc-relabel.sh "$1" "$2"'
g D $AN feat '.adlc/scripts/adlc-relabel.sh "$N"'                                # one computed word and no label: not readable as <issue> <label>
g D $AN feat '.adlc/scripts/adlc-relabel.sh "${N:-5}" gate:stories'              # only a plain "$N" is taken as the issue
g D $AN feat '.adlc/scripts/adlc-relabel.sh five gate:stories'
g A $AN feat '.adlc/scripts/adlc-relabel.sh 5'                                   # no label at all: the script refuses that itself
g D $AN feat 'IFS=,; X=5,stage:fast; .adlc/scripts/adlc-relabel.sh $X'           # IFS decides how $X splits, and the guard can't know it
g D $AN feat 'IFS=,; X=5,--add-label,stage:fast; gh issue edit $X'
g D $AN feat 'read IFS <<< ,; X=5,--add-label,stage:fast; gh issue edit $X'
g D $AN feat 'I""FS=,; X=5,--add-label,stage:fast; gh issue edit $X'
g A $AN feat 'gh issue comment 5 --body "IFS is a shell variable" && git status' # the name alone blocks nothing but a label change
# the relabel script behind a shell: any option spelling, and a name the shell expands
g D $AN feat 'bash -euo pipefail .adlc/scripts/adlc-relabel.sh 5 stage:fast'     # `pipefail` is -o's value, not the script
g D $AN feat 'bash -xo pipefail .adlc/scripts/adlc-relabel.sh 5 stage:fast'
g D $AN feat 'bash -n +n .adlc/scripts/adlc-relabel.sh 5 stage:fast'             # +n turns -n off again: the script runs
g D $AN feat 'bash -n -o pipefail +o noexec .adlc/scripts/adlc-relabel.sh 5 stage:fast'
g D $AN feat 'zsh --emulate sh .adlc/scripts/adlc-relabel.sh 5 stage:fast'       # an option's value the guard does not know
g D $AN feat 'bash .adlc/scripts/adlc-relabel.s[h] 5 stage:fast'                 # a glob that matches the script's name
g D $AN feat 'bash .adlc/scripts/adlc-rel* 5 stage:fast'
g D $AN feat 'bash .adlc/scripts/{adlc-relabel.sh,5} stage:fast'                 # a brace that may hold it
g D $RV feat 'bash -euo pipefail .adlc/scripts/adlc-relabel.sh 12 stage:qa'
g D $RV feat 'bash -n +n .adlc/scripts/adlc-relabel.sh 12 stage:qa'
g A $AN feat 'bash -euo pipefail .adlc/scripts/adlc-relabel.sh 5 gate:stories'
g A $AN feat 'bash -xn .adlc/scripts/adlc-relabel.sh 5 stage:fast'               # -n with plain switches only: nothing runs
g D $AN feat '.adlc/scripts/adlc-relabel.s[h] 5 stage:fast'                      # a narrow role's program name: nothing the shell expands
g D $AN feat '.adlc/scripts/{adlc-relabel.sh,5} stage:fast'
g D $AN feat '/opt/homebrew/bin/g[h] issue close 7'
g D $AN feat '=gh issue close 7'                                                 # zsh: `=gh` is the path of gh
g A $AN feat '[ -f README.md ] && gh issue view 5'                               # `[` is a program, not a glob
g A - feat './scripts/build-*.sh && ls'                                          # not a narrow role: untouched
# a flag before the gh subcommand: the label rule cannot be reached around it
g D $AN feat 'gh issue --title view edit 5 --add-label stage:fast'               # gh reads this as `gh issue edit`
g D $AR feat 'gh issue --body view edit 5 --add-label gate:deploy'
g A $AN feat 'gh -R o/r issue edit 5 --add-label gate:stories'

# ── file writes: a role whose contract limits its paths (architect: docs/**; analyst, reviewer: none) ──
w A $AR wr Write "$GR/wr/docs/adr/0002-login.md"                 # an absolute path into the repo's docs/
w A $AR wr Edit "$GR/wr/docs/adr/0001-a.md"
w A $AR wr Write 'docs/adr/0002-login.md'                        # relative to the session's directory
w A $AR wr Write 'docs/new/deep/tree/x.md'                       # directories that do not exist yet
w A $AR wr/sub Write '../docs/guide.md'                          # from a subdirectory: the repo's docs/ …
w D $AR wr/sub Write 'docs/guide.md'                             # … and sub/docs/ is not it
w D $AR wr Write "$GR/wr/src/app.py"
w D $AR wr Edit 'src/app.py'
w D $AR wr Write 'README.md'
w D $AR wr Write 'docs'                                          # the directory itself
w D $AR wr Write 'docsx/a.md'
w D $AR wr Write 'DOCS/adr/x.md'                                 # another spelling is another path
w D $AR wr Write '.adlc/scripts/adlc-relabel.sh'
w D $AR wr Write '.claude/settings.json'
w D $AR wr Write 'docs/../src/app.py'                            # `..`
w D $AR wr Write "$GR/wr/docs/adr/../../.github/workflows/x.yml"
w D $AR wr Write 'docs/nope/../../src/app.py'                    # `..` through a directory that is not there
w D $AR wr Write 'docs/code/app.py'                              # docs/code → ../src: a link out of docs/
w D $AR wr Write 'docs/code/new.py'
w D $AR wr Write 'docs/away/x.md'                                # … and one out of the repository
w D $AR wr Edit 'docs/app.md'                                    # a linked FILE: the write would land on src/app.py
w D $AR wr Write 'docs/dangling.md'                              # … also when its target is not there yet
w A $AR wr Write 'docs/latest/0003-x.md'                         # docs/latest → adr: a link that stays inside
w D $AR wr Write 'docs/code/../adr/x.md'                         # read link-first this is <repo>/adr/x.md: one reading outside is enough
w D $AR wr Write "$GR/outside/docs/x.md"                         # another tree's docs/
w D $AR wr Write '/etc/hosts'
w D $AR wr Write '~/docs/x.md'                                   # the home directory
w D $AR nogit Write 'docs/x.md'                                  # no repository: nothing to measure docs/ from
w D $AR wr Write -                                               # the call names no file: nothing to check
w D $AR wr Write ''
w A $AR wr MultiEdit 'docs/adr/0001-a.md'
w D $AR wr MultiEdit 'src/app.py'
w A $AR wr NotebookEdit 'docs/n.ipynb'                           # NotebookEdit names its file in notebook_path
w D $AR wr NotebookEdit 'src/n.ipynb'
w A adlc-architect wr Write 'docs/adr/x.md'                      # this repo's copy of the agent is the role too
w D adlc-architect wr Write 'src/app.py'
w D architect wr Write 'src/app.py'
w D $AN wr Write 'docs/adr/x.md'                                 # the Analyst and the reviewer write no file
w D $RV wr Edit 'src/app.py'
w D adlc-adversarial-reviewer wr Write 'docs/x.md'
w A adlc:builder wr Write 'src/app.py'                           # not limited here: the diff-scope check judges their paths
w A adlc-builder wr Write "$GR/outside/x"
w A adlc:qa-release-ops wr Edit 'src/app.py'
w A - wr Write 'src/app.py'                                      # the main thread
w A - wr Write -
w A other:architect wr Write 'src/app.py'                        # another plugin's agent
w A adlc-other wr Write 'src/app.py'                             # not one of the roles
w A general-purpose wr Write 'src/app.py'
