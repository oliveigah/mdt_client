# Written by MDT, read by every bash in the VM (through BASH_ENV and
# /etc/profile.d): the placeholders of the grants MDT holds for this VM.
# They are worthless outside MDT's proxy.
if [ -r /mnt/mdt/env.sh ]; then
  . /mnt/mdt/env.sh
fi
