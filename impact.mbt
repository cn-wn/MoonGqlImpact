///|
/// Query and fragment files are resolved independently for each client.
pub(all) struct Client {
  name : String
  sources : Array[Source]
}

///|
#derive(ToJson, FromJson, Eq, Debug)
pub(all) struct Impact {
  client : String
  operation : String
  response_path : Array[String]
  selection : Location
}

///|
#derive(ToJson, FromJson, Eq, Debug)
pub(all) struct Change {
  coordinate : String
  previous_type : String
  proposed_type : String?
  baseline : Location
  proposed : Location?
  impacts : Array[Impact]
}

///|
#derive(ToJson, FromJson, Eq, Debug)
pub(all) struct Report {
  changes : Array[Change]
}

///|
priv struct Catalog {
  fragments : Map[String, (Source, @gql.FragmentDefinition)]
  operations : Map[String, (Source, @gql.Query)]
}

///|
fn catalog(client : Client) -> Catalog raise AnalysisError {
  let fragments = Map([])
  let operations = Map([])
  for source in client.sources {
    source.check_size()
    let doc = @gql.parse_query(source.text) catch {
      GraphQLParseError(message, pos) => raise Invalid(source.at(pos), message)
    }
    if doc.definitions.is_empty() {
      raise Invalid(
        { path: source.path, line: 1, column: 1, },
        "empty operation file",
      )
    }
    for def in doc.definitions {
      match def {
        FragmentDefinition(fragment) => {
          if fragments.contains(fragment.name) {
            raise Invalid(
              source.at(fragment.position),
              "duplicate fragment: \{fragment.name}",
            )
          }
          fragments[fragment.name] = (source, fragment)
        }
        OperationDefinition(QueryOperation(query)) => {
          let at = source.at(query.position)
          guard query.name is Some(name) &&
            query.variable_definitions.is_empty() &&
            query.directives.is_empty() else {
            raise Unsupported(
              at, "use a named query without variables or directives",
            )
          }
          if operations.contains(name) {
            raise Invalid(at, "duplicate operation: \{name}")
          }
          operations[name] = (source, query)
        }
        _ =>
          raise Unsupported(
            { path: source.path, line: 1, column: 1, },
            "only named query operations are supported",
          )
      }
    }
  }
  if operations.is_empty() {
    raise Invalid(
      { path: client.name, line: 1, column: 1, },
      "client must define a named query",
    )
  }
  { fragments, operations, }
}

///|
priv struct Walk {
  schema : Schema
  catalog : Catalog
  changes : Map[String, Change]
  client : String
  operation : String
  seen_fragments : Set[String]
  active : Set[String]
  response_fields : Map[String, String]
  reported : Set[(String, String, Int32, Int32)]
  mut budget : Int32
}

///|
fn validate_selection_directives(
  source : Source,
  directives : Array[@gql.Directive],
) -> Unit raise AnalysisError {
  if directives.is_empty() {
    return
  }
  let seen = Set([])
  for directive in directives {
    let at = source.at(directive.position)
    let name = directive.name
    if name != "skip" && name != "include" {
      raise Unsupported(at, "unsupported selection directive @\{name}")
    }
    if !seen.add_and_check(name) {
      raise Invalid(at, "duplicate @\{name} directive")
    }
    match directive.arguments {
      [("if", BooleanValue(_))] => ()
      [("if", Variable(_))] =>
        raise Unsupported(
          at,
          "@\{name} requires a literal boolean in this profile",
        )
      _ =>
        raise Invalid(at, "@\{name} requires exactly one boolean if argument")
    }
  }
}

///|
fn Walk::visit(
  self : Walk,
  owner : String,
  source : Source,
  set : @gql.SelectionSet,
  path : Array[String],
  depth : Int32,
) -> Unit raise AnalysisError {
  if depth > 128 {
    raise Unsupported(
      source.at(set.span.0),
      "selection expansion exceeds depth 128",
    )
  }
  for selection in set.items {
    self.budget -= 1
    if self.budget < 0 {
      raise Unsupported(
        source.at(set.span.0),
        "operation exceeds 100000 expanded selections",
      )
    }
    match selection {
      FieldSelection(field) => {
        let at = source.at(field.position)
        if !field.arguments.is_empty() {
          raise Unsupported(
            at, "selection arguments are outside the output profile",
          )
        }
        validate_selection_directives(source, field.directives)
        let coordinate = "\{owner}.\{field.name}"
        let next_path = path.copy()
        next_path.push(field.field_alias.unwrap_or(field.name))
        let key = next_path.join(".")
        if self.response_fields.get(key) is Some(previous) &&
          previous != coordinate {
          raise Invalid(at, "conflicting selections for response path \{key}")
        }
        self.response_fields[key] = coordinate
        if field.name == "__typename" {
          if !field.selection_set.items.is_empty() {
            raise Invalid(
              at, "__typename is a scalar and forbids a selection set",
            )
          }
          continue
        }
        guard self.schema.objects[owner].get(field.name) is Some(old) else {
          raise Invalid(at, "baseline field does not exist: \{coordinate}")
        }
        let child = named(old.kind)
        if self.schema.objects.contains(child) ==
          field.selection_set.items.is_empty() {
          raise Invalid(
            at, "object fields require a selection set and scalar fields forbid it",
          )
        }
        if self.changes.get(coordinate) is Some(change) &&
          self.reported.add_and_check((key, at.path, at.line, at.column)) {
          let impact = {
            client: self.client,
            operation: self.operation,
            response_path: next_path,
            selection: at,
          }
          change.impacts.push(impact)
        }
        if !field.selection_set.items.is_empty() {
          self.visit(child, source, field.selection_set, next_path, depth + 1)
        }
      }
      FragmentSpreadSelection(spread) => {
        let at = source.at(spread.position)
        let name = spread.fragment_name
        guard self.catalog.fragments.get(name) is Some((file, fragment)) else {
          raise Invalid(at, "missing fragment: \{name}")
        }
        let On(condition) = fragment.type_condition
        if !fragment.directives.is_empty() {
          raise Unsupported(
            file.at(fragment.position),
            "fragment definition directives are outside the output profile",
          )
        }
        validate_selection_directives(source, spread.directives)
        if condition != owner || self.active.contains(name) {
          raise Invalid(at, "inapplicable or cyclic fragment: \{name}")
        }
        self.seen_fragments.add(name)
        self.active.add(name)
        self.visit(owner, file, fragment.selection_set, path, depth + 1)
        self.active.remove(name)
      }
      InlineFragmentSelection(fragment) => {
        let at = source.at(fragment.position)
        validate_selection_directives(source, fragment.directives)
        if fragment.type_condition is Some(On(condition)) && condition != owner {
          raise Invalid(at, "inapplicable fragment type: \{condition}")
        }
        self.visit(owner, source, fragment.selection_set, path, depth + 1)
      }
    }
  }
}

///|
/// Compare output contracts and locate affected selections in baseline-valid queries.
pub fn analyze_upgrade(
  baseline : Source,
  proposed : Source,
  clients : Array[Client],
) -> Report raise AnalysisError {
  let old = index(baseline)
  let next = index(proposed)
  if old.root != next.root {
    raise Unsupported(
      { path: proposed.path, line: 1, column: 1, },
      "query root renaming is outside the output profile",
    )
  }
  let changes = Map([])
  let ordered = []
  for owner, fields in old.objects {
    for name, field in fields {
      let candidate = match next.objects.get(owner) {
        Some(fields) => fields.get(name)
        None => None
      }
      let base_name = named(field.kind)
      if candidate is Some(new_field) &&
        preserves(field.kind, new_field.kind) &&
        old.objects.contains(base_name) == next.objects.contains(base_name) {
        continue
      }
      let coordinate = "\{owner}.\{name}"
      let change = {
        coordinate,
        previous_type: type_text(field.kind),
        proposed_type: candidate.map(fn(f) { type_text(f.kind) }),
        baseline: field.at,
        proposed: candidate.map(fn(f) { f.at }),
        impacts: [],
      }
      changes[coordinate] = change
      ordered.push(change)
    }
  }
  let names = Set([])
  for client in clients {
    if client.name == "" || names.contains(client.name) {
      raise Invalid(
        { path: client.name, line: 1, column: 1, },
        "empty or duplicate client name",
      )
    }
    names.add(client.name)
    let catalog = catalog(client)
    let seen_fragments = Set([])
    for operation, (file, query) in catalog.operations {
      let walk = {
        schema: old,
        catalog,
        changes,
        client: client.name,
        operation,
        seen_fragments,
        active: Set([]),
        response_fields: Map([]),
        reported: Set([]),
        budget: 100000,
      }
      walk.visit(old.root, file, query.selection_set, [], 0)
    }
    for name, (source, fragment) in catalog.fragments {
      if !seen_fragments.contains(name) {
        raise Invalid(source.at(fragment.position), "unused fragment: \{name}")
      }
    }
  }
  { changes: ordered, }
}

///|
pub extend Location with ToJson::{to_json}

///|
pub extend Location with @json.FromJson::{from_json}

///|
pub extend Location with Eq::{equal, not_equal}

///|
pub extend Location with @debug.Debug::{to_repr}

///|
pub extend Impact with ToJson::{to_json}

///|
pub extend Impact with @json.FromJson::{from_json}

///|
pub extend Impact with Eq::{equal, not_equal}

///|
pub extend Impact with @debug.Debug::{to_repr}

///|
pub extend Change with ToJson::{to_json}

///|
pub extend Change with @json.FromJson::{from_json}

///|
pub extend Change with Eq::{equal, not_equal}

///|
pub extend Change with @debug.Debug::{to_repr}

///|
pub extend Report with ToJson::{to_json}

///|
pub extend Report with @json.FromJson::{from_json}

///|
pub extend Report with Eq::{equal, not_equal}

///|
pub extend Report with @debug.Debug::{to_repr}
