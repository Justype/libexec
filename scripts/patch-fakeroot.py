"""Replace the getopt call of the fakeroot launcher with scripts/fakeroot-args.sh.
usage: patch-fakeroot.py <launcher> <snippet>"""
import sys

path, snippet_path = sys.argv[1], sys.argv[2]
launcher = open(path).read()
snippet = open(snippet_path).read()
start = launcher.index("GETOPTTEST=`getopt -T`")
end_marker = 'eval set -- "$FAKE_TEMP"\n'
end = launcher.index(end_marker) + len(end_marker)
patched = launcher[:start] + snippet + launcher[end:]
if any("getopt" in line for line in patched.splitlines() if not line.lstrip().startswith("#")):
    sys.exit("the fakeroot launcher still calls getopt")
open(path, "w").write(patched)
