import unittest,
       dbscheme,
       db_sqlite,
       fp.list,
       fp.trym,
       fp.option

suite "SQLITE":

  let conn = db_sqlite.open(":memory:", "", "", "")

  test "Create initial scheme":

    let m1 = initMigration(
      initVersion(0, 1, 0.some),
      "Create database",
      sql"""
-- This is a comment
create table t1(
  id integer primary key asc, --and this is a comment too
  name text
);
create table t2(
  id integer primary key asc,
  name text
);
"""
    )

    check: conn.migrate(asList(m1)).run == ()
    check: conn.getAllRows(sql"select * from t1").len == 0
    check: conn.getAllRows(sql"select * from t2").len == 0
