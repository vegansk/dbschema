import boost.typeutils,
       boost.types,
       boost.richstring,
       boost.parsers,
       fp,
       future,
       strutils,
       times,
       securehash

const usePostgres = defined(dbschemaPostgres)
when usePostgres:
  import db_postgres
  type Conn* = db_postgres.DbConn
  type Row = db_postgres.Row
else:
  import db_sqlite
  type Conn* = db_sqlite.DbConn
  type Row = db_sqlite.Row

type Hash = string
type VersionsConfig = tuple[schema: Option[string], table: string]

proc toString(v: VersionsConfig): string =
  when usePostgres:
    fmt"""${v.schema.map(v => v & ".").getOrElse("")}${v.table}"""
  else:
    v.table

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

data Migration, exported, copy:
  version: Version
  name: string
  sql: SqlQuery

proc toString(m: Migration): string =
  let (m0, m1, p) = (m.version.major, m.version.minor, m.version.patch)
  fmt"$m0.$m1.$p - ${m.name}"

proc hasSchemaTable(conn: Conn, versions: VersionsConfig): Result[bool] = lift:
  when usePostgres:
    let pgReq = fmt"""SELECT EXISTS (
  SELECT 1
  FROM   information_schema.tables
  WHERE  table_schema = ${versions.schema.fold(() => "current_schema()", v => "'" & v & "'")}
  AND    table_name = ?
)
"""
    conn.getValue(sql(pgReq), versions.table) == "t"
  else:
    const sqliteReq = sql"SELECT name FROM sqlite_master WHERE type='table' AND name=?"
    conn.getAllRows(sqliteReq, versions.toString).len == 1

proc createSchemaTable(conn: Conn, versions: VersionsConfig): Result[Unit] =
  let ddl = fmt"""
    create table if not exists ${versions.toString} (
      id ${when usePostgres: "bigserial primary key" else: "integer primary key autoincrement"},
      ver_major integer not null,
      ver_minor integer not null,
      ver_patch integer not null,
      name text not null,
      installed_on timestamp not null,
      hash text not null
    )
    """
  when usePostgres:
    act do:
      versions.schema.fold(
        () => ().success,
        v => lift conn.exec(sql(fmt"create schema if not exists $v"))
      )
      lift conn.exec(sql(ddl))
  else:
    lift conn.exec(sql(ddl))

proc parseQueries(s: SqlQuery): Result[List[SqlQuery]] =
  lift s.string
  .split(";\n")
  .asList
  .map(v => v.strip)
  .filter(v => not v.isNilOrEmpty)
  .map(v => sql(v))

proc sqlHash(q: SqlQuery): Hash =
  result = q.string.replace("\c", "").replace("\L", "").replace("\n", "").secureHash.`$`

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

proc migrationRow(r: Row): Result[(int, MigrationRow)] = lift do:
  if r.len != 7:
    raise newException(Exception, "Invalid row")
  let id = strToInt(r[0])
  let tm =
    when usePostgres:
      times.parse(r[5], "yyyy-MM-dd' 'HH:mm:ss").toTime
    else:
      parseFloat(r[5]).fromSeconds
  let row = initMigrationRow(
    initVersion(strToInt(r[1]), strToInt(r[2]), strToInt(r[3])),
    r[4],
    tm,
    r[6]
  )
  (id, row)

proc insert(conn: Conn, m: MigrationRow, versions: VersionsConfig): Result[Unit] = act do:
  ddl <- lift fmt"""
    insert into ${versions.toString}(ver_major, ver_minor, ver_patch, name, installed_on, hash)
    values (?, ?, ?, ?, ${when usePostgres: "to_timestamp(?)" else: "?"}, ?)
    """
  lift conn.exec(
    sql(ddl),
    m.version.major,
    m.version.minor,
    m.version.patch,
    m.name,
    m.installedOn.toSeconds,
    m.hash
  )
  yield ()

proc getLastMigrationRow(conn: Conn, versions: VersionsConfig): Result[Option[(int, MigrationRow)]] = act do:
  ddl <- lift fmt """
    select * from ${versions.toString} order by ver_major desc, ver_minor desc, ver_patch desc limit 1
  """
  conn.getAllRows(sql(ddl))
    .asList.headOption.traverse((r: Row) => r.migrationRow)

proc getMigrationRowByVersion(conn: Conn, version: Version, versions: VersionsConfig): Result[Option[(int, MigrationRow)]] = act do:
  ddl <- lift fmt """
    select * from ${versions.toString}
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

proc verify(r: CheckResult, m: Migration): Result[Unit] = lift do:
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

proc checkMigration(conn: Conn, m: Migration, versions: VersionsConfig): Result[CheckResult] = act do:
  row <- conn.getMigrationRowByVersion(m.version, versions)
  lastRow <- conn.getLastMigrationRow(versions)
  yield row.fold(
    () => lastRow.fold(
      () => CheckResult.Ok,
      r => (if r[1].version < m.version: CheckResult.Ok else: CheckResult.Outdated)
    ),
    row => (if m.sql.sqlHash == row[1].hash: CheckResult.Applied else: CheckResult.HashMismatch)
  )

proc migrate(conn: Conn, migration: Migration, versions: VersionsConfig): Result[Unit] = catch(
  act do:
    lift conn.exec(sql"begin transaction")
    chk <- conn.checkMigration(migration, versions)
    chk.verify(migration)
    _ <- (block:
      if chk == CheckResult.Ok:
        act do:
          queries <- migration.sql.parseQueries
          queries.traverse((q: SqlQuery) => lift conn.exec(q))
          conn.insert(migration.toDb, versions)
          yield ()
      else:
        ().success
    )
    lift conn.exec(sql"end transaction")
    yield (),
  (e: ref Exception) => (
    lift do:
      conn.exec(sql"rollback transaction")
      raise e
  )
)

proc parseVersionsTable(v: string): Result[VersionsConfig] = lift do:
  let cfg = v.split(".")
  if cfg.len < 1 and cfg.len > 2:
    raise newException(Exception, fmt"Invalid dbschema versions table name '$v'")
  if cfg.len == 1:
    (string.none, cfg[0])
  else:
    (cfg[0].some, cfg[1])

proc migrate*(conn: Conn, migrations: List[Migration], versionsTable: string): Result[Unit] = act do:
  versions <- parseVersionsTable(versionsTable)
  initialized <- conn.hasSchemaTable(versions)
  (block:
     if not initialized:
       conn.createSchemaTable(versions)
     else:
       ().success)
  migrations.sortBy((x: Migration, y: Migration) => cmp(x.version, y.version))
    .traverse((m: Migration) => conn.migrate(m, versions))
  yield ()

proc isMigrationsUpToDate*(conn: Conn, migrations: List[Migration], versionsTable: string): Result[bool] = act do:
  versions <- parseVersionsTable(versionsTable)
  initialized <- conn.hasSchemaTable(versions)

  if not initialized:
    false.success
  else:
    migrations.sortBy((x: Migration, y: Migration) => cmp(y.version, x.version)).headOption.fold(
      () => true.success,
      m => conn.checkMigration(m, versions).fold(
        e => e.failure(bool),
        chk => (chk == CheckResult.Applied).success
      )
    )
