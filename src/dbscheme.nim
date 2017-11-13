import boost.typeutils,
       boost.types,
       fp,
       future,
       strutils

const usePostgreSql = not(defined(testScope) and not defined(testUsePostgres))
when usePostgreSql:
  import db_postgres, postgres
else:
  import db_sqlite

data Version, exported:
  major: int
  minor: int
  patch = int.none

data Migration, exported:
  version: Version
  name: string
  sql: SqlQuery

proc parseQueries(s: SqlQuery): Try[List[SqlQuery]] = tryM do:
  s.string
  .split(";\n")
  .asList
  .map(v => v.strip)
  .filter(v => not v.isNilOrEmpty)
  .map(v => sql(v))

proc inTrn(q: List[SqlQuery]): List[SqlQuery] =
  sql"begin transaction" ^^ q ++ asList(sql("end transaction"))

proc migrate(conn: DbConn, migration: Migration): Try[Unit] = act do:
  queries <- migration.sql.parseQueries.map(q => inTrn(q))
  queries.traverse((q: SqlQuery) => tryM conn.exec(q))
  yield ()

proc migrate*(conn: DbConn, migrations: List[Migration]): Try[Unit] = act do:
  migrations.traverse((m: Migration) => conn.migrate(m))
  yield ()
