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
#
# The text has no two backslashes in a row: fish reads them in single
# quotes as one (HostCommands.command). printf makes the backslash of each
# octal escape.
b=$(printf "\134");
f=;
for p in $(printf "%s\n" "$1" | fold -w 2); do
  v=$((0x$p));
  f=$f$b$((v / 64))$((v / 8 % 8))$((v % 8));
done;
d=$(printf "$f.");
d=${d%.};
o=$d;
case $d in
  "~" | "~/"*) if [ -n "$HOME" ]; then d=$HOME${d#"~"}; fi ;;
  "~"*)
    n=${d%%/*};
    n=${n#"~"};
    if t=$(printf "%s" "$n" | tr -d A-Za-z0-9._-) && [ -z "$t" ]; then
      eval "u=~$n";
      d=$u${d#"~$n"};
    fi;
    ;;
esac;
cd "$d" || printf "macterm: cannot cd to %s\n" "$o" >&2;
if [ -n "$SHELL" ]; then exec "$SHELL" -l; else exec /bin/sh; fi;
