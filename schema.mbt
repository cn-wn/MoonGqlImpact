///|
/// A named input file. Paths appear verbatim in diagnostics.
pub(all) struct Source {
  path : String
  text : String
}

///|
#derive(ToJson, FromJson, Eq, Debug)
pub(all) struct Location {
  path : String
  line : Int32
  column : Int32
}

///|
pub(all) suberror AnalysisError {
  Invalid(Location, String)
  Unsupported(Location, String)
}

///|
fn Source::at(self : Source, pos : @gql.Pos) -> Location {
  { path: self.path, line: pos.line, column: pos.column, }
}

///|
priv struct IndexedField {
  kind : @gql.GqlType
  at : Location
}

///|
priv struct Schema {
  root : String
  objects : Map[String, Map[String, IndexedField]]
}

///|
fn named(kind : @gql.GqlType) -> String {
  match kind {
    NamedType(name) => name
    ListType(inner) | NonNullType(inner) => named(inner)
  }
}

///|
fn builtin(name : String) -> Bool {
  match name {
    "String" | "Int" | "Float" | "Boolean" | "ID" => true
    _ => false
  }
}

///|
fn index(source : Source) -> Schema raise AnalysisError {
  let start = { path: source.path, line: 1, column: 1, }
  source.check_size()
  let doc = @gql.parse_schema(source.text) catch {
    GraphQLParseError(message, pos) => raise Invalid(source.at(pos), message)
  }
  let objects = Map([])
  let mut root = None
  for definition in doc.definitions {
    match definition {
      SchemaDef(schema) => {
        let at = source.at(schema.position)
        if root is Some(_) {
          raise Invalid(at, "duplicate schema definition")
        }
        guard schema.query is Some(name) &&
          schema.mutation is None &&
          schema.subscription is None &&
          schema.directives.is_empty() else {
          raise Unsupported(
            at, "only a query root without directives is supported",
          )
        }
        root = Some(name)
      }
      TypeDef(ObjectTypeDef(object)) => {
        let at = source.at(object.position)
        if objects.contains(object.name) ||
          builtin(object.name) ||
          object.name.has_prefix("__") {
          raise Invalid(at, "duplicate or reserved object: \{object.name}")
        }
        if !object.implements_interfaces.is_empty() ||
          !object.directives.is_empty() {
          raise Unsupported(
            at, "interfaces and schema directives are outside the output profile",
          )
        }
        let fields = Map([])
        for field in object.fields {
          let at = source.at(field.position)
          if fields.contains(field.name) || field.name.has_prefix("__") {
            raise Invalid(at, "duplicate or reserved field: \{field.name}")
          }
          if !field.arguments.is_empty() || !field.directives.is_empty() {
            raise Unsupported(
              at, "schema arguments and directives are outside the output profile",
            )
          }
          fields[field.name] = { kind: field.field_type, at, }
        }
        if fields.is_empty() {
          raise Invalid(at, "object must define at least one field")
        }
        objects[object.name] = fields
      }
      _ =>
        raise Unsupported(
          start, "only object definitions, built-in scalars and a query root are supported",
        )
    }
  }
  if root is None &&
    (objects.contains("Mutation") || objects.contains("Subscription")) {
    raise Unsupported(
      start, "implicit mutation and subscription roots are outside the output profile",
    )
  }
  let root = root.unwrap_or("Query")
  if !objects.contains(root) {
    raise Invalid(start, "query root object \{root} is missing")
  }
  for _, fields in objects {
    for _, field in fields {
      let name = named(field.kind)
      if !builtin(name) && !objects.contains(name) {
        raise Invalid(field.at, "undefined output type: \{name}")
      }
    }
  }
  { root, objects, }
}

///|
/// A new output type must preserve every old non-null guarantee and list shape.
fn preserves(old : @gql.GqlType, next : @gql.GqlType) -> Bool {
  match (old, next) {
    (NonNullType(left), NonNullType(right)) => preserves(left, right)
    (NonNullType(_), _) => false
    (_, NonNullType(right)) => preserves(old, right)
    (ListType(left), ListType(right)) => preserves(left, right)
    (NamedType(left), NamedType(right)) => left == right
    _ => false
  }
}

///|
fn type_text(kind : @gql.GqlType) -> String {
  match kind {
    NamedType(name) => name
    ListType(item) => "[\{type_text(item)}]"
    NonNullType(inner) => "\{type_text(inner)}!"
  }
}
