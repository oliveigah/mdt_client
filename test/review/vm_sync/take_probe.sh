#!/bin/bash
# Taking a VM branch's changes into your working tree, never as commits:
# picked files arrive as uncommitted changes, merged three-way with whatever
# you have there, and your branch, your index and your staged work stay as
# they were. Needs no VM: `vm/task1` here is just a ref, as a sync leaves it.
#
#   take_probe.sh WORK_DIR        (a fresh folder; removed and remade)
set -u
W=$1
rm -rf "$W" && mkdir -p "$W" && cd "$W" || exit 1
git init -q -b master . && git config user.name me && git config user.email me@host.invalid

lines() { for i in 1 2 3 4 5 6 7 8 9 10; do echo "$1 line $i"; done; }
lines a > a.txt; lines b > b.txt; lines c > c.txt; echo gone > del.txt; echo mine > s.txt
git add -A && git commit -qm base

# The agent's work, as it would sit under refs/remotes/vm/ after a sync.
git switch -qc task1
sed -i 's/^a line 2$/a line 2, from the vm/' a.txt
sed -i 's/^b line 5$/b line 5, from the vm/' b.txt
sed -i 's/^c line 1$/c line 1, from the vm/' c.txt
echo "a new file from the vm" > new.txt
git rm -q del.txt
git add -A && git commit -qm "vm: several changes"
git switch -q master
git update-ref refs/remotes/vm/task1 task1 && git branch -qD task1

# Your own work in progress on master.
echo "staged by me" >> s.txt && git add s.txt                       # staged
sed -i 's/^a line 9$/a line 9, edited by me/' a.txt                  # unstaged, far from the vm's edit
sed -i 's/^c line 1$/c line 1, edited by me/' c.txt                  # unstaged, same line as the vm's edit

state() { echo "HEAD $(git rev-parse --short HEAD) index $(git write-tree | cut -c1-7) branches $(git for-each-ref refs/heads | wc -l)"; }
before=$(state)
git status --porcelain > "$W/../take.status.before" 2>/dev/null || git status --porcelain > /tmp/take.status.before

# 1. Your working tree as a commit, taken from a copy of the index.
snapshot() {
  tmp=$(mktemp); cp "$(git rev-parse --git-path index)" "$tmp"
  GIT_INDEX_FILE=$tmp git add -A
  tree=$(GIT_INDEX_FILE=$tmp git write-tree); rm -f "$tmp"
  git commit-tree "$tree" -p HEAD -m "before taking from the VM"
}
snap=$(snapshot)

# 2. The merge, computed without touching anything.
out=$(git merge-tree --write-tree --name-only "$snap" refs/remotes/vm/task1)
status=$?
tree=$(echo "$out" | head -1)
echo "merge computed: exit $status (1 = some file conflicts)"
echo "$out" | sed -n '2,$p' | grep -v '^$' | sed 's/^/   /'

# 3. What changed between your tree and the merge, per file: the list to pick from.
echo "files that would change:"
git diff --name-status "$snap" "$tree" | sed 's/^/   /'

# 4. You pick everything but b.txt. Only working files are written.
for path in a.txt c.txt new.txt del.txt; do
  if git cat-file -e "$tree:$path" 2>/dev/null; then
    mkdir -p "$(dirname "$path")" && git cat-file blob "$tree:$path" > "$path"
  else
    rm -f "$path"
  fi
done

echo
echo "after taking a.txt, c.txt, new.txt, del.txt:"
echo "   before: $before"
echo "   after:  $(state)"
echo "   git status:"; git status --porcelain | sed 's/^/      /'
echo "   a.txt, both edits:"; grep -n "vm\|me" a.txt | sed 's/^/      /'
echo "   c.txt, same line on both sides:"; sed -n '1,7p' c.txt | sed 's/^/      /'
echo "   b.txt (not picked) still: $(sed -n 5p b.txt)"
echo "   staged by you, still staged: $(git diff --cached --name-only | tr '\n' ' ')"
echo "   commits on master: $(git rev-list --count master)"

# 5. Undo: your tree as it was.
git restore --source="$snap" --worktree -- a.txt c.txt del.txt && rm -f new.txt
echo
echo "after undo:"
echo "   state: $(state)"
echo "   git status:"; git status --porcelain | sed 's/^/      /'
