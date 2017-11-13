import boost.typeutils,
       boost.types,
       boost.richstring,
       boost.parsers,
       fp,
       future,
       strutils,
       times,
       securehash

const usePostgreSql = not(defined(testScope) and not defined(testUsePostgres))
when usePostgreSql:
  import db_postgres, postgres
else:
  import db_sqlite

type Conn = DbConn
type Hash = string

data Version, exported, eq, show:
  major: int
  minor: int
  patch = 0

proc `<`(x, y: Version): bool =
  if x.major < y.major:
    true
  elif x.major == y.major and x.minor < y.minor:
    true
  elif x.major == y.major and x.minor == y.minor and x.patch < y.patch:
    true
  else:
    false

proc `<=`(x, y: Version): bool =
  x < y or x == y

data Migration, exported, copy:
  version: Version
  name: string
  sql: SqlQuery

proc toString(m: Migration): string =
  let (m0, m1, p) = (m.version.major, m.version.minor, m.version.patch)
  fmt"$m0.$m1.$p - ${m.name}"

const schemaTable {.strdefine.} = "dbschema_version"

proc hasSchemaTable(conn: Conn): Try[bool] = tryM:
  when usePostgreSql:
    const pgReq = sql"""SELECT EXISTS (
  SELECT 1
  FROM   information_schema.tables
  WHERE  table_schema = ?
  AND    table_name = ?
)
"""
    conn.getValue(pgReq, "public", schemaTable) == "t"
  else:
    const sqliteReq = sql"SELECT name FROM sqlite_master WHERE type='table' AND name=?"
    conn.getAllRows(sqliteReq, schemaTable).len == 1

proc createSchemaTable(conn: Conn): Try[Unit] =
  let ddl = fmt"""
    create table if not exists $schemaTable (
      id ${when usePostgreSql: "bigserial primary key" else: "integer primary key autoincrement"},
      ver_major integer not null,
      ver_minor integer not null,
      ver_patch integer not null,
      name text not null,
      installed_on timestamp not null,
      hash text not null
    )
    """
  tryM conn.exec(sql(ddl))

proc parseQueries(s: SqlQuery): Try[List[SqlQuery]] = tryM do:
  s.string
  .split(";\n")
  .asList
  .map(v => v.strip)
  .filter(v => not v.isNilOrEmpty)
  .map(v => sql(v))

proc inTrn(q: List[SqlQuery]): List[SqlQuery] =
  sql"begin transaction" ^^ q ++ asList(sql("end transaction"))

proc sqlHash(q: SqlQuery): Hash =
  q.string.secureHash.`$`

data MigrationRow, show:
  version: Version
  name: string
  installedOn: Time
  hash: Hash

proc toDb(m: Migration): MigrationRow =
  initMigrationRow(
    m.version,
    m.name,
    getTime(),
    m.sql.sqlHash
  )

proc migrationRow(r: Row): Try[(int, MigrationRow)] = tryM do:
  if r.len != 7:
    raise newException(Exception, "Invalid row")
  let id = strToInt(r[0])
  let row = initMigrationRow(
    initVersion(strToInt(r[1]), strToInt(r[2]), strToInt(r[3])),
    r[4],
    parseFloat(r[5]).fromSeconds,
    r[6]
  )
  (id, row)

proc insert(conn: Conn, m: MigrationRow): Try[Unit] = act do:
  ddl <- tryM fmt"""
    insert into $schemaTable(ver_major, ver_minor, ver_patch, name, installed_on, hash)
    values (?, ?, ?, ?, ${when usePostgreSql: "to_timestamp(?)" else: "?"}, ?)
    """
  tryM conn.exec(
    sql(ddl),
    m.version.major,
    m.version.minor,
    m.version.patch,
    m.name,
    m.installedOn.toSeconds,
    m.hash
  )
  yield ()

proc getLastMigrationRow(conn: Conn): Try[Option[(int, MigrationRow)]] = act do:
  ddl <- tryM fmt """
    select * from $schemaTable order by ver_major desc, ver_minor desc, ver_patch desc limit 1
  """
  conn.getAllRows(sql(ddl))
    .asList.headOption.traverse((r: Row) => r.migrationRow)

proc getMigrationRowByVersion(conn: Conn, version: Version): Try[Option[(int, MigrationRow)]] = act do:
  ddl <- tryM fmt """
    select * from $schemaTable
    where ver_major = ? and ver_minor = ? and ver_patch = ?
    limit 1
  """
  conn.getAllRows(sql(ddl), version.major, version.minor, version.patch)
    .asList.headOption.traverse((r: Row) => r.migrationRow)

type CheckResult {.pure.} = enum
  Ok,
  Applied,
  HashMismatch,
  Outdated

proc verify(r: CheckResult, m: Migration): Try[Unit] = tryM do:
  case r
  of CheckResult.HashMismatch:
    raise newException(
      Exception,
      fmt"""Found hash mismatch in applied migration ${m.toString}"""
    )
  of CheckResult.Outdated:
    raise newException(
      Exception,
      fmt"""Can't apply outdated migration ${m.toString}"""
    )
  of CheckResult.Applied, CheckResult.Ok:
    discard

proc checkMigration(conn: Conn, m: Migration): Try[CheckResult] = act do:
  row <- conn.getMigrationRowByVersion(m.version)
  lastRow <- conn.getLastMigrationRow
  yield row.fold(
    () => lastRow.fold(
      () => CheckResult.Ok,
      r => (if r[1].version < m.version: CheckResult.Ok else: CheckResult.Outdated)
    ),
    row => (if m.sql.sqlHash == row[1].hash: CheckResult.Applied else: CheckResult.HashMismatch)
  )

proc migrate(conn: Conn, migration: Migration): Try[Unit] = catch(
  act do:
    tryM conn.exec(sql"begin transaction")
    chk <- conn.checkMigration(migration)
    chk.verify(migration)
    _ <- (block:
      if chk == CheckResult.Ok:
        act do:
          queries <- migration.sql.parseQueries
          queries.traverse((q: SqlQuery) => tryM conn.exec(q))
          conn.insert(migration.toDb)
          yield ()
      else:
        ().success
    )
    tryM conn.exec(sql"end transaction")
    yield (),
  (e: ref Exception) => (
    tryM do:
      conn.exec(sql"rollback transaction")
      raise e
  )
)

proc migrate*(conn: Conn, migrations: List[Migration]): Try[Unit] = act do:
  initialized <- conn.hasSchemaTable
  (block:
     if not initialized:
       conn.createSchemaTable
     else:
       ().success)
  migrations.sortBy((x: Migration, y: Migration) => cmp(x.version, y.version))
    .traverse((m: Migration) => conn.migrate(m))
  yield ()
