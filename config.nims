import project.build

const cfgFile = "build.cfg"

task mk_config, "Create config template":
  cfgFile.mkConfigTemplate

task test, "Run all the tests using sqlite backend":
  test "all"

task test_pg, "Run all the tests using postgresql backend":
  testPg "all", cfgFile.readCfg
