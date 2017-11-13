import unittest,
       db_sqlite,
       fp.list,
       fp.trym,
       fp.option

include ../src/dbschema

suite "SQLITE":

  let m1 = initMigration(
    initVersion(0, 1, 2),
    "Create database",
    sql"""
      -- This is a comment
      create table t1(
        id integer primary key asc, -- and this is a comment too
        name text
      );

      insert into t1 values(1, "a");
      insert into t1 values(2, "b");

      create table t2(
        id integer primary key asc,
        name text
      );
    """
  )

  let m2 = initMigration(
    initVersion(0, 2, 1),
    "Fill table t2",
    sql"""
      insert into t2 values(10, "A");
      insert into t2 values(20, "B");
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

  let conn = db_sqlite.open(":memory:", "", "", "")

  test "Create initial schema":

    check: conn.hasSchemaTable.run == false
    check: conn.migrate(asList(m1)).run == ()
    check: conn.hasSchemaTable.run == true
    check: conn.getAllRows(sql"select * from t1").len == 2
    check: conn.getAllRows(sql"select * from t2").len == 0
    let row = conn.getLastMigrationRow.run.get[1]
    check(
      row.version == m1.version and
      row.name == m1.name and
      row.hash == m1.sql.sqlHash
    )

  test "Update schema":

    check: conn.migrate(asList(m1, m2)).run == ()
    let row = conn.getLastMigrationRow.run.get[1]
    check: row.version == m2.version

  test "Do nothing when schema is up to date":

    check: conn.migrate(asList(m1, m2)).run == ()
    let row = conn.getLastMigrationRow.run.get[1]
    check: row.version == m2.version

  test "Fail on outdated migration":

    expect(Exception): discard conn.migrate(asList(m1, m2, outdated)).run
    let row = conn.getLastMigrationRow.run.get[1]
    check: row.version == m2.version

  test "Fail on hash mismatch":

    expect(Exception): discard conn.migrate(asList(mismatched, m2)).run
    let row = conn.getLastMigrationRow.run.get[1]
    check: row.version == m2.version
