# Checks that a folder is on the host, before Macterm adds a remote project
# for it (RemoteHosts.checkFolder). The app sends it as one line, as
# attach.sh (see there). With a server, the server runs it (command.run).
# With no server, it runs over the ssh connection.
#
# $1: the folder, hex-encoded, as for plain.sh. A ~ or ~name at the start
# becomes the home folder (the same text as HostCommands.expandTilde).
#
# Exit 0: a shell can cd to the folder. Exit 3: it cannot. Any other
# status means that the check did not run to its end.
b=$(printf "\134");
f=;
for p in $(printf "%s\n" "$1" | fold -w 2); do
  v=$((0x$p));
  f=$f$b$((v / 64))$((v / 8 % 8))$((v % 8));
done;
d=$(printf "$f.");
d=${d%.};
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
cd "$d" 2>/dev/null || exit 3;
exit 0;
