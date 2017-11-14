import ospaths, strutils, tables, sequtils

template dep*(task: untyped): stmt =
  selfExec astToStr(task)

template deps*(task1: untyped, task2: untyped): stmt =
  dep task1
  dep task2

proc mkConfigTemplate*(fName: string) =
  const cfg = """
## `dbschema` project configuration.
##
## It is used for testing with postgresql backend.
## When sqlite backend is used, no configuration required.

# Database host
pg_host = localhost
# Optional database port
# pg_port = 5432
# Database user
pg_user =
# Optional database password
# pg_pass =
# Database name
pg_db   =
"""
  if not fName.fileExists:
    writeFile fName, cfg
  else:
    quit "Config file already exists"

type
  BuildCfg* = ref object
    ## Build configuration
    fName: string ## Configuration file name
    data: TableRef[string, string] ## Configuration data

proc readCfg*(fName: string): BuildCfg =
  new(result)
  result.fName = fName
  result.data = readFile(fName)
  .splitLines
  .filterIt(it.strip != "" and not it.strip.startsWith("#"))
  .mapIt((let r = it.split("="); (r[0].strip, r[1].strip)))
  .newTable

proc get*(c: BuildCfg, name: string, defValue: string = nil, optional = false, isPath = false): string =
  proc fixPath(p: string): string =
    result = p
    if isPath and not p.isNil:
      if p.find(" ") != -1:
        result = "\"" & p & "\""
      else:
        result = p
  var opt = optional or not defValue.isNil
  result = c.data.getOrDefault(name)
  if result.isNil:
    if not opt:
      raise newException(KeyError, "Parameter " & name & " is absent in build configuration " & c.fName)
    else:
      result = defValue
  if isPath and not result.isNil and result.find(" ") != -1:
    result = "\"" & result & "\""

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

proc test*(name: string) =
  if not dirExists "bin":
    mkDir "bin"
  --run
  buildBase true, "bin/test_" & name, "tests/test_" & name

proc testPg*(name: string, cfg: BuildCfg) =
  --d:dbschemaPostgres
  switch("d", "pgHost:" & cfg.get("pg_host"))
  switch("d", "pgPort:" & cfg.get("pg_port", defValue = "5432"))
  switch("d", "pgUser:" & cfg.get("pg_user"))
  switch("d", "pgPass:" & cfg.get("pg_pass", defValue = ""))
  switch("d", "pgDb:" & cfg.get("pg_db"))
  test(name)

