import fp

type Result[T] = Try[T]
template lift(v: untyped): untyped = tryM(v)

include impl/dbschema
