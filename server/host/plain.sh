# A plain login shell in a folder, for a host with no server of Macterm (the
# user declined the install, or the host has no build). It ends with the
# connection. The app sends it as one line, as attach.sh (see there), after
# its TERM, COLORTERM and TERM_PROGRAM lines (HostCommands.Scripts.plainCommand).
#
# $1: the folder, hex-encoded (two hex digits for each byte), so that it is
# one plain word on the command line and no shell parses it. A ~ or ~name at
# the start becomes the home folder (the same text as
# HostCommands.expandTilde). A folder that is not there gives a "macterm:"
# line, and the shell starts in the home folder.
h=$1;
f=;
while [ -n "$h" ]; do
  v=$((0x${h%"${h#??}"}));
  h=${h#??};
  f=$f\\$((v / 64))$((v / 8 % 8))$((v % 8));
done;
d=$(printf "$f.");
d=${d%.};
o=$d;
case $d in
  "~" | "~/"*) d=$HOME${d#"~"} ;;
  "~"*)
    n=${d%%/*};
    n=${n#"~"};
    if [ -z "$(printf "%s" "$n" | tr -d A-Za-z0-9._-)" ]; then
      eval "u=~$n";
      d=$u${d#"~$n"};
    fi;
    ;;
esac;
cd "$d" || echo "macterm: cannot cd to $o" >&2;
if [ -n "$SHELL" ]; then exec "$SHELL" -l; else exec /bin/sh; fi;
