#!/bin/bash
# Host and VM as two git clones that exchange commits over `msb exec --stream`.
# No shared folder, no network: git's own protocol runs through msb's pipe.
#
#   probe.sh WORK_DIR SOURCE_REPO
#
# WORK_DIR holds `msbw` (msb with a throwaway MSB_HOME) and a running VM named
# `syncprobe` with git and a disk at /work. SOURCE_REPO is cloned, never
# changed. See results/sync.out for a run.
set -u
W=$1
SOURCE=$2
VM=syncprobe
REPO=/work/project
G="git -c protocol.ext.allow=always -c fetch.fsckObjects=true"

t() {
  local s e r
  s=$(date +%s.%N)
  timeout 90 "$@"
  r=$?
  e=$(date +%s.%N)
  printf '   [%.2f s, exit %s]\n' "$(echo "$e - $s" | bc)" "$r"
}
vm() { "$W/msbw" exec "$VM" -- sh -c "$1"; }
say() { printf '\n== %s\n' "$1"; }

# Prints a commit holding the working tree as it is (tracked changes and new
# files, not ignored ones) on top of HEAD. Reads only: it works on a copy of
# the index, so the index, HEAD and the files stay as they were.
SNAPSHOT='
snapshot() {
  tmp=$(mktemp)
  cp "$(git rev-parse --git-path index)" "$tmp"
  GIT_INDEX_FILE=$tmp git add -A
  tree=$(GIT_INDEX_FILE=$tmp git write-tree)
  rm -f "$tmp"
  [ "$tree" = "$(git rev-parse "HEAD^{tree}")" ] && return 1
  git commit-tree "$tree" -p HEAD -m "work in progress on $(git branch --show-current)"
}'

rm -rf "$W/host"
git clone -q --no-hardlinks "$SOURCE" "$W/host"
cd "$W/host" || exit 1
git config user.name me
git config user.email me@host.invalid
git config remote.vm.url "ext::$W/msbw exec --stream $VM -- git %s $REPO"
git config remote.vm.fetch '+refs/heads/*:refs/remotes/vm/*'
git config --add remote.vm.fetch '+refs/wip/*:refs/remotes/vm/wip/*'
git config remote.vm.push '+refs/heads/*:refs/remotes/host/*'
vm "rm -rf /work/project /work/wt-* /tmp/mdt-sync-canary-*; git init -q $REPO"
rm -f /tmp/mdt-sync-canary-*

say "1. The whole repository into the VM, host branches arriving as host/*"
t $G push -q vm
say "   Again, nothing new"
t $G push -q vm

say "2. An agent works in a worktree of its own in the VM and commits"
vm "cd $REPO && git worktree add -q -b task1 /work/wt-task1 host/master && cd /work/wt-task1 && echo '# from the VM' >> mix.exs && git commit -qam 'vm: touch mix.exs' && git log --oneline -1"
say "   Its branch into the host, arriving as vm/task1"
t $G fetch -q vm
git for-each-ref --format='   %(refname:short) %(objectname:short)' refs/remotes/vm
say "   Again, nothing new"
t $G fetch -q vm
say "   The host takes it: fast-forward"
git merge -q --ff-only vm/task1 && git log --oneline -1

say "3. Work the agent has not committed: a snapshot, taken without touching its tree"
vm "cd /work/wt-task1 && echo '# half done' >> mix.exs && echo new > NEW_FILE.md && mkdir -p _build && echo junk > _build/ignored && git status --porcelain --ignored | sort > /tmp/before"
vm "cd /work/wt-task1 && $SNAPSHOT
c=\$(snapshot) && git update-ref refs/wip/task1 \$c; git status --porcelain --ignored | sort > /tmp/after; cmp -s /tmp/before /tmp/after && echo '   git status in the VM is the same before and after'; cat /tmp/after | sed 's/^/   /'"
t $G fetch -q vm
echo "   what the host sees in vm/wip/task1, beyond vm/task1:"
git diff --stat vm/task1 vm/wip/task1 | sed 's/^/   /'

say "4. Both sides change the same line"
sed -i '$ d' mix.exs && echo '# host edit' >> mix.exs && git commit -qam 'host: edit the last line'
vm "cd /work/wt-task1 && git checkout -q -- . && rm -f NEW_FILE.md && sed -i '\$ d' mix.exs && echo '# vm edit' >> mix.exs && git commit -qam 'vm: edit the last line'"
echo "   sync both ways:"
t $G push -q vm
t $G fetch -q vm
echo "   host working tree after the sync: $(git status --porcelain | wc -l) changed files; on $(git log --oneline -1)"
echo "   host tries to take vm/task1:"
git merge --ff-only vm/task1 2>&1 | tail -1 | sed 's/^/   /'
echo "   the agent rebases onto host/master in the VM:"
vm "cd /work/wt-task1 && git rebase host/master 2>&1 | grep -E 'CONFLICT|error: could not' | sed 's/^/   /'"
echo "   ...resolves it there, and continues:"
vm "cd /work/wt-task1 && printf '# host edit\n# vm edit\n' > /tmp/tail && sed -i '/^<<<<<<<\|^=======\|^>>>>>>>\|^# host edit\|^# vm edit/d' mix.exs && cat /tmp/tail >> mix.exs && git add mix.exs && GIT_EDITOR=true git rebase --continue 2>&1 | tail -1 | sed 's/^/   /'"
t $G fetch -q vm
git merge -q --ff-only vm/task1 && echo "   host fast-forwards: $(git log --oneline -1)" && tail -2 mix.exs | sed 's/^/   /'

say "5. The VM plants hooks and config in its repository; the host syncs and merges"
cp .git/config "$W/host-config.before"
ls .git/hooks | sort > "$W/host-hooks.before"
vm "cd $REPO && for h in pre-receive update post-receive post-update reference-transaction post-checkout post-merge pre-auto-gc; do printf '#!/bin/sh\ntouch /tmp/mdt-sync-canary-%s\n' \$h > .git/hooks/\$h; chmod +x .git/hooks/\$h; done; git config core.fsmonitor 'touch /tmp/mdt-sync-canary-fsmonitor; false'; git config core.pager 'touch /tmp/mdt-sync-canary-pager; cat'; git config core.sshCommand 'touch /tmp/mdt-sync-canary-ssh'; cd /work/wt-task1 && echo '# more' >> mix.exs && git commit -qam 'vm: more'"
echo x >> README.md && git commit -qam 'host: readme'
t $G push -q vm
t $G fetch -q vm
git merge -q vm/task1 -m 'merge vm/task1' && git log --oneline -1 | sed 's/^/   /'
git status >/dev/null; git log -1 >/dev/null
echo "   canaries on the host: $(ls /tmp/mdt-sync-canary-* 2>/dev/null | wc -l)"
echo "   canaries in the VM (its own hooks ran there): $(vm 'ls /tmp/mdt-sync-canary-* 2>/dev/null | wc -l')"
cmp -s .git/config "$W/host-config.before" && echo "   host .git/config: unchanged"
ls .git/hooks | sort | cmp -s - "$W/host-hooks.before" && echo "   host .git/hooks: unchanged"

say "6. The VM offers a tree with a file named .git/config inside"
vm "cd $REPO && b=\$(echo '[core] fsmonitor = evil' | git hash-object -w --stdin) && inner=\$(printf '100644 blob %s\tconfig\n' \$b | git mktree) && tree=\$(printf '040000 tree %s\t.git\n' \$inner | git mktree 2>&1) && c=\$(git commit-tree \$tree -m evil) && git update-ref refs/heads/evil \$c && echo '   made refs/heads/evil' || echo \"   git in the VM refused to build it: \$tree\""
t $G fetch -q vm 2>&1 | tail -3 | sed 's/^/   /'
git rev-parse -q --verify refs/remotes/vm/evil >/dev/null && echo "   vm/evil ARRIVED on the host" || echo "   vm/evil did not arrive on the host"
