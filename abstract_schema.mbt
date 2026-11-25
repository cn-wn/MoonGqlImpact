///|
priv struct TypeDeclaration {
  at : Location
  parents : Set[String]
}

///|
priv struct UnionDeclaration {
  at : Location
  members : Set[String]
}

///|
fn add_type_names(
  values : Set[String],
  names : Array[String],
  at : Location,
) -> Unit raise AnalysisError {
  for name in names {
    if !values.add_and_check(name) {
      raise Invalid(at, "duplicate member or interface \{name}")
    }
  }
}

///|
fn Schema::is_composite(self : Schema, name : String) -> Bool {
  self.possible.contains(name)
}

///|
fn Schema::is_object(self : Schema, name : String) -> Bool {
  self.fields.contains(name) && !self.interfaces.contains(name)
}

///|
fn Schema::implements(self : Schema, name : String, interface : String) -> Bool {
  match self.interfaces.get(interface) {
    Some(_) =>
      match self.possible.get(name) {
        Some(types) if self.is_object(name) =>
          self.possible[interface].contains(name) && !types.is_empty()
        _ =>
          match self.parents.get(name) {
            Some(parents) => parents.contains(interface)
            None => false
          }
      }
    None => false
  }
}

///|
fn Schema::output_subtype(
  self : Schema,
  expected : @gql.GqlType,
  actual : @gql.GqlType,
) -> Bool {
  match (expected, actual) {
    (NonNullType(a), NonNullType(b)) => self.output_subtype(a, b)
    (NonNullType(_), _) => false
    (_, NonNullType(b)) => self.output_subtype(expected, b)
    (ListType(a), ListType(b)) => self.output_subtype(a, b)
    (NamedType(a), NamedType(b)) =>
      a == b ||
      self.implements(b, a) ||
      (
        self.unions.contains(a) &&
        self.is_object(b) &&
        self.possible[a].contains(b)
      )
    _ => false
  }
}

///|
fn Schema::validate_implementations(
  self : Schema,
  declarations : Map[String, TypeDeclaration],
) -> Unit raise AnalysisError {
  for name, declaration in declarations {
    for parent in declaration.parents {
      guard self.interfaces.get(parent) is Some(_) else {
        raise Invalid(
          declaration.at,
          "\{name} implements undefined interface \{parent}",
        )
      }
      if name == parent || self.parents[parent].contains(name) {
        raise Invalid(
          declaration.at,
          "cyclic interface implementation involving \{name}",
        )
      }
      for inherited in self.parents[parent] {
        if !declaration.parents.contains(inherited) {
          raise Invalid(
            declaration.at,
            "\{name} must also implement inherited interface \{inherited}",
          )
        }
      }
      for field_name, contract in self.fields[parent] {
        guard self.fields[name].get(field_name) is Some(field) else {
          raise Invalid(
            declaration.at,
            "\{name} must define interface field \{parent}.\{field_name}",
          )
        }
        if !self.output_subtype(contract.kind, field.kind) {
          raise Invalid(
            field.at,
            "incompatible implementation of \{parent}.\{field_name}",
          )
        }
        for arg_name, argument in contract.arguments {
          guard field.arguments.get(arg_name) is Some(implementation) &&
            implementation.kind == argument.kind else {
            raise Invalid(
              field.at,
              "incompatible interface argument \{arg_name} on \{name}.\{field_name}",
            )
          }
        }
        for arg_name, argument in field.arguments {
          if !contract.arguments.contains(arg_name) && argument.required() {
            raise Invalid(
              argument.at,
              "additional interface implementation arguments must be optional",
            )
          }
        }
      }
    }
  }
}

///|
fn build_possible_types(
  declarations : Map[String, TypeDeclaration],
  interfaces : Map[String, Location],
  unions : Map[String, UnionDeclaration],
) -> Map[String, Set[String]] raise AnalysisError {
  let possible = Map([])
  for name, _ in interfaces {
    possible[name] = Set([])
  }
  for name, declaration in declarations {
    if interfaces.contains(name) {
      continue
    }
    possible[name] = Set([name])
    for interface in declaration.parents {
      guard interfaces.contains(interface) else {
        raise Invalid(
          declaration.at,
          "\{name} implements undefined interface \{interface}",
        )
      }
      possible[interface].add(name)
    }
  }
  for name, union in unions {
    if union.members.is_empty() {
      raise Invalid(union.at, "union must define at least one object type")
    }
    for object_name in union.members {
      if !declarations.contains(object_name) || interfaces.contains(object_name) {
        raise Invalid(
          union.at,
          "union member \{object_name} must be a defined object",
        )
      }
    }
    possible[name] = union.members
  }
  possible
}

///|
fn overlap(left : Set[String], right : Set[String]) -> Set[String] {
  let both = Set([])
  for name in left {
    if right.contains(name) {
      both.add(name)
    }
  }
  both
}

///|
fn Schema::overlap_for(
  self : Schema,
  parent : String,
  condition : String,
) -> Set[String] {
  match (self.possible.get(parent), self.possible.get(condition)) {
    (Some(left), Some(right)) => overlap(left, right)
    _ => Set([])
  }
}

///|
fn validate_composite_extension(
  at : Location,
  directives : Array[@gql.Directive],
  fields : Array[@gql.SchemaField],
  parents : Array[String],
) -> Unit raise AnalysisError {
  if !directives.is_empty() {
    raise Unsupported(at, "composite extension directives are unsupported")
  }
  if fields.is_empty() && parents.is_empty() {
    raise Invalid(at, "composite extension must add fields or interfaces")
  }
}
