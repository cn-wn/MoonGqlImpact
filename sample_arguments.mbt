///|
priv struct SampleBranch {
  reachable : Bool
  directives : Array[@gql.Directive]
}

///|
priv struct SampleArgumentSite {
  coordinate : String
  response_path : Array[String]
  location : Location
  definitions : Map[String, Argument]
  supplied : Map[String, @gql.Value]
  branch : SampleBranch
}

///|
fn SampleBranch::with_directives(
  self : SampleBranch,
  directives : Array[@gql.Directive],
) -> SampleBranch {
  if directives.is_empty() {
    self
  } else {
    // GraphQL evaluates skip before include at each selection.
    let ordered = [
      ..directives.filter(directive => directive.name == "skip"),
      ..directives.filter(directive => directive.name == "include"),
    ]
    { ..self, directives: [..self.directives, ..ordered], }
  }
}

///|
fn SampleBranch::within(
  self : SampleBranch,
  scope : FragmentScope,
) -> SampleBranch {
  { ..self, reachable: self.reachable && !scope.before.is_empty(), }
}

///|
fn SampleBranch::selected(
  self : SampleBranch,
  variables : Map[String, Json],
) -> Bool raise SampleInputError {
  self.reachable &&
  self.directives.all(directive => {
    let flag = match directive.arguments {
      [("if", BooleanValue(flag))] => flag
      [("if", Variable(name))] =>
        match variables.get(name) {
          Some(True) => true
          Some(False) => false
          _ =>
            raise ValueRejected(
              "/@\{directive.name}/if",
              "expected a non-null Boolean",
            )
        }
      _ => abort("validated selection directive expected")
    }
    if directive.name == "skip" {
      !flag
    } else {
      flag
    }
  })
}

///|
priv suberror SampleArgumentError {
  ArgumentRejected(SampleArgumentSite, String, String)
  ArgumentLimit(SampleArgumentSite, String)
}

///|
/// A missing variable leaves the argument or object field absent, so its
/// location default can apply. An explicit null reaches the type check.
fn Coercion::argument_value(
  self : Coercion,
  definition : Argument,
  supplied : @gql.Value?,
  variables : Map[String, Json],
  path : String,
  depth : Int32,
) -> Json? raise SampleInputError {
  match supplied {
    Some(Variable(name)) if !variables.contains(name) => ()
    Some(value) =>
      return Some(
        self.argument_literal(definition.kind, value, variables, path, depth),
      )
    None => ()
  }
  if definition.default_value is Some(value) {
    return Some(self.default_value(definition.kind, value, path, depth))
  }
  if definition.required() {
    raise ValueRejected(path, "missing required input")
  }
  None
}

///|
fn Coercion::argument_literal(
  self : Coercion,
  kind : @gql.GqlType,
  literal : @gql.Value,
  variables : Map[String, Json],
  path : String,
  depth : Int32,
) -> Json raise SampleInputError {
  self.step(path, depth)
  if literal is Variable(name) {
    // Variables are already coerced against their declaration. The location
    // can impose an additional non-null check when defaults allow placement.
    let value = variables.get(name).unwrap_or(Json::null())
    if kind is NonNullType(_) && value is Null {
      raise ValueRejected(path, "null is not allowed")
    }
    return value
  }
  if literal is NullValue {
    return self.value(kind, Json::null(), path, depth)
  }
  match (nullable(kind), literal) {
    (ListType(inner), _) => {
      let items = match literal {
        ListValue(values) => values
        _ => [literal]
      }
      Json::array(
        items.mapi((i, item) => {
          self.argument_literal(
            inner,
            item,
            variables,
            "\{path}/\{i}",
            depth + 1,
          )
        }),
      )
    }
    (NamedType(name), ObjectValue(entries)) if self.schema.input_objects.get(
        name,
      )
      is Some(object) => {
      let value = self.argument_map(
        object.fields,
        Map(entries),
        variables,
        path,
        depth + 1,
      )
      if value is Object(fields) {
        check_one_of_values(object, fields, path)
      }
      value
    }
    _ => self.default_value(kind, literal, path, depth)
  }
}

///|
fn Coercion::argument_map(
  self : Coercion,
  definitions : Map[String, Argument],
  supplied : Map[String, @gql.Value],
  variables : Map[String, Json],
  path : String,
  depth : Int32,
) -> Json raise SampleInputError {
  let result = Map([])
  for name, definition in definitions {
    let child = path + "/" + name
    self.step(child, depth)
    if self.argument_value(
        definition,
        supplied.get(name),
        variables,
        child,
        depth,
      )
      is Some(value) {
      result[name] = value
    }
  }
  Json::object(result)
}

///|
fn Walk::sample_arguments(
  self : Walk,
  variables : Map[String, Json],
) -> Array[Json?] raise SampleArgumentError {
  let state : Coercion = { schema: self.schema, budget: 100000, }
  self.sample_sites
  .unwrap_or([])
  .map(site => {
    try {
      state.step("", 0)
      if !site.branch.selected(variables) {
        None
      } else {
        Some(
          state.argument_map(site.definitions, site.supplied, variables, "", 0),
        )
      }
    } catch {
      ValueRejected(path, message) =>
        raise ArgumentRejected(site, path, message)
      ValueLimit(path) => raise ArgumentLimit(site, path)
    }
  })
}
