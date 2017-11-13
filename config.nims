import ospaths

proc buildBase(debug: bool, bin: string, src: string) =
  switch("out", (thisDir() & "/" & bin).toExe)
  --nimcache: build
  --threads:on
  if not debug:
    --forceBuild
    --define: release
    --opt: size
  else:
    --define: debug
    --debuginfo
    --debugger: native
    --linedir: on
    --stacktrace: on
    --linetrace: on
    --verbosity: 1

    --NimblePath: src
    --NimblePath: srcdir

  setCommand "c", src

proc test(name: string) =
  if not dirExists "bin":
    mkDir "bin"
  --define: testScope
  --run
  buildBase true, "bin/test_" & name, "tests/test_" & name

task test, "Run all the tests":
  test "all"
