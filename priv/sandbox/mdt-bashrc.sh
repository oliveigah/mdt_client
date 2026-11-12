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
