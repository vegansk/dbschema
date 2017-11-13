import unittest,
       db_sqlite,
       fp.list,
       fp.trym,
       fp.option

include ../src/dbschema

suite "SQLITE":

  let conn = db_sqlite.open(":memory:", "", "", "")

  test "Create initial scheme":

    let m1 = initMigration(
      initVersion(0, 1, 2),
      "Create database",
      sql"""
        -- This is a comment
        create table t1(
          id integer primary key asc, --and this is a comment too
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
    check: conn.hasSchemaTable.run == false
    check: conn.migrate(asList(m1)).run == ()
    check: conn.hasSchemaTable.run == true
    check: conn.getAllRows(sql"select * from t1").len == 2
    check: conn.getAllRows(sql"select * from t2").len == 0
    let schemas = conn.getAllRows(sql"select * from dbschema_version")
    check: schemas.len == 1
    let row = schemas[0].migrationRow.run[1]
    check(
      row.version == m1.version and
      row.name == m1.name and
      row.hash == m1.sql.sqlHash
    )
