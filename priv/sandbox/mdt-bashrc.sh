# shellcheck shell=bash
# Interactive Bash defaults. Kept outside Home so an empty Home works too;
# ~/.bashrc is still read afterwards and can override these preferences.
if [ -r /mnt/mdt/profile.sh ]; then
  # shellcheck source=/dev/null
  . /mnt/mdt/profile.sh
fi

case $- in *i*) ;; *) return ;; esac
if [ "${_MDT_BASHRC_LOADED:-}" = 1 ]; then return; fi
_MDT_BASHRC_LOADED=1

shopt -s histappend checkwinsize
HISTCONTROL=ignoreboth
HISTSIZE=10000
HISTFILESIZE=50000
PS1='\[\e[36m\]mdt\[\e[0m\]:\w\$ '

if [ -r /usr/share/bash-completion/bash_completion ]; then
  # shellcheck source=/dev/null
  . /usr/share/bash-completion/bash_completion
fi

# A project's mirror (/work/NAME) is the user's branch as they committed it,
# kept current by MDT: view only. Said once each time a shell enters one.
_mdt_mirror=""
_mdt_mirror_check() {
  local m found=""
  if [ -r /mnt/mdt/mirrors ]; then
    while IFS= read -r m; do
      [ -n "$m" ] || continue
      case $PWD/ in "$m"/*) found=$m ;; esac
    done </mnt/mdt/mirrors
  fi
  if [ -n "$found" ] && [ "$found" != "$_mdt_mirror" ]; then
    printf '\033[33mmdt: %s is the mirror of the user'"'"'s branch, view only. To change code, work in a worktree of your own: mdt worktree new TASK\033[0m\n' "$found" >&2
  fi
  _mdt_mirror=$found
}
PROMPT_COMMAND="_mdt_mirror_check${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
