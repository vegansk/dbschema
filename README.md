# dbschema

[![Build Status](https://travis-ci.org/vegansk/dbschema.svg?branch=master)](https://travis-ci.org/vegansk/dbschema)

Database schema migration library for Nim language.

## Usage

First of all, create the migrations:

```nim
let migrations0 = asList(
  initMigration(initVersion(1, 0), "Create table t1",
    sql"""
      create table t1(
        id integer primary key,
        name text
      );
    """
  ),
  initMigration(initVersion(1, 1), "Create table t2",
    sql"""
      create table t2(
        id integer primary key,
        name text
      );
    """
  )
)

when defined(debug):
  let migrations = migrations0 ++ asList(
    initMigration(initVersion(1, 0, 1), "Insert records to t1",
      sql"""
        insert into t1 values(1, 'a');
        insert into t1 values(2, 'b');
      """
    ),
    initMigration(initVersion(1, 1, 1), "Insert records to t2",
      sql"""
        insert into t2 values(10, 'A');
        insert into t2 values(20, 'B');
      """
    )
  )
else:
  let migrations = migrations0
```

And then just migrate database using already opened connection. Also you must
provide the full name of the table that will contain the migrations configuration.
The configurations schema and the table will be created if needed.

```nim
let conn: DbConn = ???
let migrationsConfig = "schema.schema_migtarions"

conn.migrate(migrations, migrationsConfig).run
```

Also, we can check, if the migration is needed without running it:

```nim
if conn.isMigrationsUpToDate(migrations, migrationsConfig).run:
  # DB is up to date
else:
  # DB is out of date
```

The library can be used in both imperative and functional styles (with `nimfp` library).
Example:

```nim
let theProgram = act do:
  conn <- createConnection()

  conn.migrate(migrations, migrationsConfig)
  
  doSomethingWithConnection(conn)
  
  tryM conn.close
  
  yield ()
  
theProgram.run
```

## DB backends.

For now, `dbschema` supports two backends: sqlite and postgresql. By default, it uses sqlite.
For postgresql backend, use the command line switch `-d:dbschemaPostgres`.
