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
  enums : Map[String, String]
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
fn validate_deprecation(
  source : Source,
  directives : Array[@gql.Directive],
) -> Unit raise AnalysisError {
  let mut deprecated = false
  for directive in directives {
    let at = source.at(directive.position)
    if directive.name != "deprecated" {
      raise Unsupported(at, "unsupported schema directive @\{directive.name}")
    }
    if deprecated {
      raise Invalid(at, "duplicate @deprecated directive")
    }
    match directive.arguments {
      [] | [("reason", StringValue(_) | NullValue)] => ()
      _ =>
        raise Invalid(
          at, "@deprecated accepts only an optional string or null reason",
        )
    }
    deprecated = true
  }
}

///|
fn index_fields(
  source : Source,
  fields : Map[String, IndexedField],
  definitions : Array[@gql.SchemaField],
) -> Unit raise AnalysisError {
  for field in definitions {
    let at = source.at(field.position)
    if fields.contains(field.name) || field.name.has_prefix("__") {
      raise Invalid(at, "duplicate or reserved field: \{field.name}")
    }
    if !field.arguments.is_empty() {
      raise Unsupported(at, "schema arguments are outside the output profile")
    }
    validate_deprecation(source, field.directives)
    fields[field.name] = { kind: field.field_type, at, }
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
  let scalars = Set([])
  let enums = Map([])
  let extensions = []
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
      TypeDef(ScalarTypeDef(scalar)) => {
        let at = source.at(scalar.position)
        if !scalar.directives.is_empty() {
          raise Unsupported(
            at, "scalar directives are outside the output profile",
          )
        }
        if builtin(scalar.name) ||
          scalar.name.has_prefix("__") ||
          objects.contains(scalar.name) ||
          enums.contains(scalar.name) ||
          !scalars.add_and_check(scalar.name) {
          raise Invalid(at, "duplicate or reserved scalar: \{scalar.name}")
        }
      }
      TypeDef(EnumTypeDef(enum_type)) => {
        let at = source.at(enum_type.position)
        let name = enum_type.name
        if !enum_type.directives.is_empty() {
          raise Unsupported(
            at, "enum type directives are outside the output profile",
          )
        }
        if builtin(name) ||
          name.has_prefix("__") ||
          enums.contains(name) ||
          scalars.contains(name) ||
          objects.contains(name) {
          raise Invalid(at, "duplicate or reserved enum: \{name}")
        }
        let values = Set([])
        for value in enum_type.values {
          let at = source.at(value.position)
          if value.name.has_prefix("__") || !values.add_and_check(value.name) {
            raise Invalid(at, "duplicate or reserved enum value: \{value.name}")
          }
          validate_deprecation(source, value.directives)
        }
        if values.is_empty() {
          raise Invalid(at, "enum must define at least one value")
        }
        let sorted = []
        for value in values {
          sorted.push(value)
        }
        sorted.sort()
        enums[name] = sorted.join(", ")
      }
      TypeDef(ObjectTypeDef(object)) => {
        let at = source.at(object.position)
        if objects.contains(object.name) ||
          scalars.contains(object.name) ||
          enums.contains(object.name) ||
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
        index_fields(source, fields, object.fields)
        if fields.is_empty() {
          raise Invalid(at, "object must define at least one field")
        }
        objects[object.name] = fields
      }
      TypeExt(ObjectTypeExt(extension)) => extensions.push(extension)
      _ =>
        raise Unsupported(
          start, "only object definitions, object field extensions, scalar and enum definitions and a query root are supported",
        )
    }
  }
  for extension in extensions {
    let at = source.at(extension.position)
    if !extension.implements_interfaces.is_empty() ||
      !extension.directives.is_empty() {
      raise Unsupported(at, "object extensions may only add fields")
    }
    guard objects.get(extension.name) is Some(fields) else {
      raise Invalid(
        at,
        "extension requires an existing object: \{extension.name}",
      )
    }
    if extension.fields.is_empty() {
      raise Invalid(at, "object extension must add at least one field")
    }
    index_fields(source, fields, extension.fields)
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
      if !builtin(name) &&
        !objects.contains(name) &&
        !scalars.contains(name) &&
        !enums.contains(name) {
        raise Invalid(field.at, "undefined output type: \{name}")
      }
    }
  }
  { root, objects, enums, }
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
fn Schema::type_text(self : Schema, kind : @gql.GqlType) -> String {
  match kind {
    NamedType(name) =>
      match self.enums.get(name) {
        Some(values) => name + "{" + values + "}"
        None => name
      }
    ListType(item) => "[\{self.type_text(item)}]"
    NonNullType(inner) => "\{self.type_text(inner)}!"
  }
}
