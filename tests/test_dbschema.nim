import unittest,
       db_sqlite,
       fp.list,
       fp.trym,
       fp.option

include ../src/dbschema

when usePostgres:
  import postgres
  const pgHost {.strdefine.} = ""
  const pgPort {.intdefine.} = 5432
  const pgUser {.strdefine.} = ""
  const pgPass {.strdefine.} = ""
  const pgDb {.strdefine.} = ""

suite "dbschema":

  let m1 = initMigration(
    initVersion(0, 1, 2),
    "Create database",
    sql"""
      -- This is a comment
      create table t1(
        id integer primary key, -- and this is a comment too
        name text
      );

      insert into t1 values(1, 'a');
      insert into t1 values(2, 'b');

      create table t2(
        id integer primary key,
        name text
      );
    """
  )

  let m2 = initMigration(
    initVersion(0, 2, 1),
    "Fill table t2",
    sql"""
      insert into t2 values(10, 'A');
      insert into t2 values(20, 'B');
    """
  )

  let outdated = initMigration(
    initVersion(0, 1, 3),
    "Outdated",
    sql"""
      -- This shouldn't be executed!!!
    """
  )

  let mismatched = m1.copyMigration(
    sql = sql(m1.sql.string & "---;\n")
  )

  const configSchema = "dbschema"
  const configTable = "dbschema_versions"
  const versionsConfig = configSchema & "." & configTable
  let versions = versionsConfig.parseVersionsConfig.run

  when usePostgres:
    let conn = db_postgres.open(
      "",
      pgUser,
      pgPass,
      fmt"host=$pgHost port=$pgPort dbname=$pgDb"
    )
    const pgSchema = configSchema
    # Cleanup and setup
    conn.exec(sql"BEGIN TRANSACTION")
    conn.exec(sql(fmt"DROP SCHEMA IF EXISTS $pgSchema CASCADE"))
    conn.exec(sql(fmt"CREATE SCHEMA $pgSchema"))
    conn.exec(sql(fmt"""GRANT ALL ON SCHEMA $pgSchema TO "${pgUser}""""))
    conn.exec(sql(fmt"GRANT ALL ON SCHEMA $pgSchema TO public"))
    conn.exec(sql"COMMIT TRANSACTION")
    conn.exec(sql(fmt"SET SCHEMA '$pgSchema'"))
  else:
    let conn = db_sqlite.open(":memory:", "", "", "")

  test "Check if db is up to date before migrations":
    check: conn.isMigrationsUpToDate(asList(m1), versionsConfig).run == false

  test "Create initial schema":

    check: conn.hasSchemaTable(versions).run == false
    check: conn.migrate(asList(m1), versionsConfig).run == ()
    check: conn.hasSchemaTable(versions).run == true
    check: conn.getAllRows(sql"select * from t1").len == 2
    check: conn.getAllRows(sql"select * from t2").len == 0
    let row = conn.getLastMigrationRow(versions).run.get[1]
    check(
      row.version == m1.version and
      row.name == m1.name and
      row.hash == m1.sql.sqlHash
    )

  test "Check if db is up to date after first migration":
    check: conn.isMigrationsUpToDate(asList(m1), versionsConfig).run == true
    check: conn.isMigrationsUpToDate(asList(m1, m2), versionsConfig).run == false

  test "Update schema":

    check: conn.migrate(asList(m1, m2), versionsConfig).run == ()
    let row = conn.getLastMigrationRow(versions).run.get[1]
    check: row.version == m2.version

  test "Do nothing when schema is up to date":

    check: conn.migrate(asList(m1, m2), versionsConfig).run == ()
    let row = conn.getLastMigrationRow(versions).run.get[1]
    check: row.version == m2.version

  test "Fail on outdated migration":

    expect(Exception): discard conn.migrate(asList(m1, m2, outdated), versionsConfig).run
    let row = conn.getLastMigrationRow(versions).run.get[1]
    check: row.version == m2.version

  test "Fail on hash mismatch":

    expect(Exception): discard conn.migrate(asList(mismatched, m2), versionsConfig).run
    let row = conn.getLastMigrationRow(versions).run.get[1]
    check: row.version == m2.version
