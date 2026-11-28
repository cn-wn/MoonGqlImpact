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
  arguments : Map[String, Argument]
  kind : @gql.GqlType
  at : Location
}

///|
priv struct Schema {
  root : String
  mutation_root : (String, Location)?
  input_objects : Map[String, InputObject]
  enums : Map[String, Array[String]]
  scalars : Map[String, String?]
  scalar_inputs : Map[String, (Json) -> Bool]
  fields : Map[String, Map[String, IndexedField]]
  parents : Map[String, Set[String]]
  interfaces : Map[String, Location]
  unions : Map[String, UnionDeclaration]
  possible : Map[String, Set[String]]
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
    let arguments = Map([])
    for argument in field.arguments {
      let at = source.at(argument.position)
      if argument.name.has_prefix("__") || arguments.contains(argument.name) {
        raise Invalid(at, "duplicate or reserved argument: \{argument.name}")
      }
      if !argument.directives.is_empty() {
        raise Unsupported(
          at, "argument directives are outside the input profile",
        )
      }
      arguments[argument.name] = {
        kind: argument.value_type,
        default_value: argument.default_value,
        at,
      }
    }
    validate_deprecation(source, field.directives)
    fields[field.name] = { kind: field.field_type, at, arguments, }
  }
}

///|
fn index_enum_values(
  source : Source,
  values : Set[String],
  definitions : Array[@gql.EnumValue],
) -> Unit raise AnalysisError {
  for value in definitions {
    let at = source.at(value.position)
    if value.name.has_prefix("__") || !values.add_and_check(value.name) {
      raise Invalid(at, "duplicate or reserved enum value: \{value.name}")
    }
    validate_deprecation(source, value.directives)
  }
}

///|
fn scalar_specification(
  source : Source,
  directives : Array[@gql.Directive],
) -> String? raise AnalysisError {
  let mut specification = None
  for directive in directives {
    let at = source.at(directive.position)
    if directive.name != "specifiedBy" {
      raise Unsupported(at, "unsupported scalar directive @\{directive.name}")
    }
    if specification is Some(_) {
      raise Invalid(at, "duplicate @specifiedBy directive")
    }
    guard directive.arguments is [("url", StringValue(url))] else {
      raise Invalid(at, "@specifiedBy requires exactly one string url argument")
    }
    specification = Some(url)
  }
  specification
}

///|
fn index(
  source : Source,
  scalar_inputs : Map[String, (Json) -> Bool],
) -> Schema raise AnalysisError {
  let start = { path: source.path, line: 1, column: 1, }
  source.check_size()
  let doc = @gql.parse_schema(source.text) catch {
    GraphQLParseError(message, pos) => raise Invalid(source.at(pos), message)
  }
  let fields_by_type = Map([])
  let input_objects = Map([])
  let input_extensions = []
  let declarations = Map([])
  let interfaces = Map([])
  let unions = Map([])
  let interface_extensions = []
  let union_extensions = []
  let scalars = Map([])
  let enums = Map([])
  let enum_values = Map([])
  let enum_extensions = []
  let extensions = []
  let mut root = None
  let mut mutation_root = None
  for definition in doc.definitions {
    match definition {
      SchemaDef(schema) => {
        let at = source.at(schema.position)
        if root is Some(_) {
          raise Invalid(at, "duplicate schema definition")
        }
        guard schema.query is Some(name) &&
          schema.subscription is None &&
          schema.directives.is_empty() else {
          raise Unsupported(
            at, "schema requires a query root and supports a mutation root without directives",
          )
        }
        root = Some(name)
        mutation_root = schema.mutation.map(name => (name, at))
      }
      TypeDef(ScalarTypeDef(scalar)) => {
        let at = source.at(scalar.position)
        let specification = scalar_specification(source, scalar.directives)
        if builtin(scalar.name) ||
          scalar.name.has_prefix("__") ||
          declarations.contains(scalar.name) ||
          unions.contains(scalar.name) ||
          input_objects.contains(scalar.name) ||
          enum_values.contains(scalar.name) ||
          scalars.contains(scalar.name) {
          raise Invalid(at, "duplicate or reserved scalar: \{scalar.name}")
        }
        scalars[scalar.name] = specification
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
          enum_values.contains(name) ||
          scalars.contains(name) ||
          declarations.contains(name) ||
          unions.contains(name) ||
          input_objects.contains(name) {
          raise Invalid(at, "duplicate or reserved enum: \{name}")
        }
        let values = Set([])
        index_enum_values(source, values, enum_type.values)
        if values.is_empty() {
          raise Invalid(at, "enum must define at least one value")
        }
        enum_values[name] = values
      }
      TypeDef(
        ObjectTypeDef(
          { name, position, directives, fields, implements_interfaces, .. },
        ),
      )
      | TypeDef(
        InterfaceTypeDef(
          { name, position, directives, fields, implements_interfaces, .. },
        ),
      ) => {
        let at = source.at(position)
        if declarations.contains(name) ||
          unions.contains(name) ||
          scalars.contains(name) ||
          enum_values.contains(name) ||
          input_objects.contains(name) ||
          builtin(name) ||
          name.has_prefix("__") {
          raise Invalid(at, "duplicate or reserved type: \{name}")
        }
        if !directives.is_empty() {
          raise Unsupported(
            at, "composite type directives are outside the output profile",
          )
        }
        let indexed = Map([])
        index_fields(source, indexed, fields)
        if indexed.is_empty() {
          raise Invalid(
            at, "object or interface must define at least one field",
          )
        }
        let parents = Set([])
        add_type_names(parents, implements_interfaces, at)
        declarations[name] = { at, parents, }
        fields_by_type[name] = indexed
        if definition is TypeDef(InterfaceTypeDef(_)) {
          interfaces[name] = at
        }
      }
      TypeDef(UnionTypeDef(union)) => {
        let at = source.at(union.position)
        let name = union.name
        if declarations.contains(name) ||
          unions.contains(name) ||
          scalars.contains(name) ||
          enum_values.contains(name) ||
          input_objects.contains(name) ||
          builtin(name) ||
          name.has_prefix("__") {
          raise Invalid(at, "duplicate or reserved union: \{name}")
        }
        if !union.directives.is_empty() {
          raise Unsupported(
            at, "union directives are outside the output profile",
          )
        }
        let members = Set([])
        add_type_names(members, union.types, at)
        if members.is_empty() {
          raise Invalid(at, "union must define at least one object type")
        }
        unions[name] = { at, members, }
      }
      TypeDef(InputObjectTypeDef(input)) => {
        let name = input.name
        let at = source.at(input.position)
        if declarations.contains(name) ||
          unions.contains(name) ||
          scalars.contains(name) ||
          enum_values.contains(name) ||
          input_objects.contains(name) ||
          builtin(name) ||
          name.has_prefix("__") {
          raise Invalid(at, "duplicate or reserved input object \{name}")
        }
        let one_of = input_is_one_of(source, input.directives)
        if input.fields.is_empty() {
          raise Invalid(at, "input object must define at least one field")
        }
        let object = { at, fields: Map([]), one_of, }
        index_input_fields(source, object, input.fields)
        input_objects[name] = object
      }
      TypeExt(InputObjectTypeExt(extension)) => input_extensions.push(extension)
      TypeExt(ObjectTypeExt(extension)) => extensions.push(extension)
      TypeExt(EnumTypeExt(extension)) => enum_extensions.push(extension)
      TypeExt(InterfaceTypeExt(extension)) =>
        interface_extensions.push(extension)
      TypeExt(UnionTypeExt(extension)) => union_extensions.push(extension)
      _ =>
        raise Unsupported(
          start, "schema definition is outside the supported query profile",
        )
    }
  }
  for extension in input_extensions {
    let at = source.at(extension.position)
    if extension.directives.any(directive => directive.name == "oneOf") {
      raise Invalid(at, "@oneOf belongs on the input object definition")
    }
    if !extension.directives.is_empty() {
      raise Unsupported(
        at, "input extension directives are outside the input profile",
      )
    }
    guard input_objects.get(extension.name) is Some(object) &&
      !extension.fields.is_empty() else {
      raise Invalid(
        at, "input extension must add fields to an existing input object",
      )
    }
    index_input_fields(source, object, extension.fields)
  }
  for extension in enum_extensions {
    let at = source.at(extension.position)
    if !extension.directives.is_empty() {
      raise Unsupported(at, "enum extensions may only add values")
    }
    guard enum_values.get(extension.name) is Some(values) else {
      raise Invalid(
        at,
        "extension requires an existing enum: \{extension.name}",
      )
    }
    if extension.values.is_empty() {
      raise Invalid(at, "enum extension must add at least one value")
    }
    index_enum_values(source, values, extension.values)
  }
  for name, values in enum_values {
    let sorted = []
    for value in values {
      sorted.push(value)
    }
    sorted.sort()
    enums[name] = sorted
  }
  for extension in extensions {
    let at = source.at(extension.position)
    let name = extension.name
    guard declarations.get(name) is Some(declaration) &&
      !interfaces.contains(name) else {
      raise Invalid(at, "extension requires an existing object: \{name}")
    }
    validate_composite_extension(
      at,
      extension.directives,
      extension.fields,
      extension.implements_interfaces,
    )
    add_type_names(declaration.parents, extension.implements_interfaces, at)
    index_fields(source, fields_by_type[name], extension.fields)
  }
  for extension in interface_extensions {
    let at = source.at(extension.position)
    let name = extension.name
    if !interfaces.contains(name) {
      raise Invalid(at, "extension requires an existing interface: \{name}")
    }
    validate_composite_extension(
      at,
      extension.directives,
      extension.fields,
      extension.implements_interfaces,
    )
    add_type_names(
      declarations[name].parents,
      extension.implements_interfaces,
      at,
    )
    index_fields(source, fields_by_type[name], extension.fields)
  }
  for extension in union_extensions {
    let at = source.at(extension.position)
    guard unions.get(extension.name) is Some(union) else {
      raise Invalid(
        at,
        "extension requires an existing union: \{extension.name}",
      )
    }
    if !extension.directives.is_empty() {
      raise Unsupported(at, "union extension directives are unsupported")
    }
    if extension.types.is_empty() {
      raise Invalid(at, "union extension must add at least one member")
    }
    add_type_names(union.members, extension.types, at)
  }
  if root is None {
    if declarations.contains("Subscription") {
      raise Unsupported(
        start, "implicit subscription roots are outside the supported profile",
      )
    }
    let mutation = "Mutation"
    match declarations.get(mutation) {
      Some(declaration) => mutation_root = Some((mutation, declaration.at))
      None =>
        if scalars.contains(mutation) ||
          enums.contains(mutation) ||
          unions.contains(mutation) ||
          input_objects.contains(mutation) {
          raise Invalid(start, "implicit mutation root must be an object")
        }
    }
  }
  let root = root.unwrap_or("Query")
  if !declarations.contains(root) || interfaces.contains(root) {
    raise Invalid(start, "query root object \{root} is missing")
  }
  if mutation_root is Some((name, at)) {
    if !declarations.contains(name) || interfaces.contains(name) {
      raise Invalid(at, "mutation root object \{name} is missing")
    }
    if name == root {
      raise Invalid(at, "query and mutation roots must be different objects")
    }
  }
  let possible = build_possible_types(declarations, interfaces, unions)
  let parents = Map([])
  for name, declaration in declarations {
    parents[name] = declaration.parents
  }
  let schema = {
    root,
    mutation_root,
    input_objects,
    fields: fields_by_type,
    parents,
    interfaces,
    unions,
    possible,
    enums,
    scalars,
    scalar_inputs,
  }
  let no_variables = Map([])
  for _, fields in fields_by_type {
    for _, field in fields {
      let name = named(field.kind)
      if !builtin(name) &&
        !possible.contains(name) &&
        !scalars.contains(name) &&
        !enums.contains(name) {
        raise Invalid(field.at, "undefined output type: \{name}")
      }
      for name, argument in field.arguments {
        schema.check_input_type(argument.kind, argument.at)
        if argument.default_value is Some(value) &&
          !schema.value_fits(argument.kind, value, no_variables) {
          raise Invalid(
            argument.at,
            "invalid default value for argument \{name}",
          )
        }
      }
    }
  }
  schema.validate_input_objects()
  schema.validate_implementations(declarations)
  schema
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
        Some(values) => name + "{" + values.join(", ") + "}"
        None =>
          match self.scalars.get(name) {
            Some(Some(url)) =>
              name + "@specifiedBy(" + Json::string(url).stringify() + ")"
            _ => name
          }
      }
    ListType(item) => "[\{self.type_text(item)}]"
    NonNullType(inner) => "\{self.type_text(inner)}!"
  }
}
