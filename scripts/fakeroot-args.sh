# Replaces the getopt call of the fakeroot launcher. A container may have no getopt, or one built for another libc.
# Long options become short ones, and "--" is placed before the command, so the loop that follows reads them as before.
opts_done=no
expect_value=no
count=$#
while test $count -gt 0; do
  a=$1; shift; count=$((count - 1))
  if test $opts_done = yes || test $expect_value = yes; then
    expect_value=no
    set -- "$@" "$a"
    continue
  fi
  case "$a" in
    --) opts_done=yes; set -- "$@" -- ;;
    --lib) set -- "$@" -l; expect_value=yes ;;
    --faked) set -- "$@" -f; expect_value=yes ;;
    --fd-base) set -- "$@" -b; expect_value=yes ;;
    --unknown-is-real) set -- "$@" -u ;;
    --version) set -- "$@" -v ;;
    --help) set -- "$@" -h ;;
    -l|-f|-i|-s|-b) set -- "$@" "$a"; expect_value=yes ;;
    -u|-v|-h) set -- "$@" "$a" ;;
    -*) usage ;;
    *) opts_done=yes; set -- "$@" -- "$a" ;;
  esac
done
if test $opts_done = no; then set -- "$@" --; fi
