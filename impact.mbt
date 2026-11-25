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
  reason_codes : Array[ReasonCode]?
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
  reasons : Array[ChangeReason]?
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
  let paths = Set([])
  for source in client.sources {
    if source.path == "" || !paths.add_and_check(source.path) {
      raise Invalid(
        { path: source.path, line: 1, column: 1, },
        "operation sources require unique nonempty paths within each client",
      )
    }
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
      let def : @gql.QueryDefinition = match def {
        OperationDefinition(SelectionSetOperation(selection_set)) =>
          OperationDefinition(
            QueryOperation({
              position: selection_set.span.0,
              name: None,
              variable_definitions: [],
              directives: [],
              selection_set,
            }),
          )
        _ => def
      }
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
          guard query.directives.is_empty() else {
            raise Unsupported(
              at, "operation directives are outside the output profile",
            )
          }
          let name = query.name.unwrap_or("<anonymous>")
          if operations.contains(name) {
            raise Invalid(at, "duplicate operation: \{name}")
          }
          operations[name] = (source, query)
        }
        _ =>
          raise Unsupported(
            { path: source.path, line: 1, column: 1, },
            "only query operations are supported",
          )
      }
    }
  }
  if operations.is_empty() {
    raise Invalid(
      { path: client.name, line: 1, column: 1, },
      "client must define a query",
    )
  }
  if operations.length() > 1 &&
    operations.get("<anonymous>") is Some((file, query)) {
    raise Invalid(
      file.at(query.position),
      "an anonymous query must be the client's only operation",
    )
  }
  { fragments, operations, }
}

///|
priv struct Walk {
  schema : Schema
  proposed : Schema
  argument_changes : Map[String, Array[ArgumentDiff]]
  input_changes : Map[String, Array[ArgumentDiff]]
  abstract_changes : Map[String, Change]
  catalog : Catalog
  changes : Map[String, Change]
  client : String
  operation : String
  seen_fragments : Set[String]
  active : Set[String]
  response_fields : Map[String, Array[ResponseSelection]]
  reported : Map[(String, String, String, Int32, Int32), Int32]
  variables : Map[String, @gql.VariableDefinition]
  used_variables : Set[String]
  mut budget : Int32
}

///|
fn Walk::validate_selection_directives(
  self : Walk,
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
      [("if", Variable(variable))] => {
        guard self.variables.get(variable) is Some(definition) else {
          raise Invalid(at, "undefined condition variable \{variable}")
        }
        if !variable_fits(definition, NonNullType(NamedType("Boolean")), false) {
          raise Invalid(
            at,
            "condition variable \{variable} must satisfy Boolean!",
          )
        }
        self.used_variables.add(variable)
      }
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
  scope : FragmentScope,
  parents : Array[String],
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
        self.validate_selection_directives(source, field.directives)
        let coordinate = "\{owner}.\{field.name}"
        let next_path = path.copy()
        next_path.push(field.field_alias.unwrap_or(field.name))
        let key = next_path.join(".")
        let arguments = Map([])
        for (name, value) in field.arguments {
          if arguments.contains(name) {
            raise Invalid(at, "duplicate field argument \{name}")
          }
          arguments[name] = value
        }
        let lineage = parents.copy()
        lineage.push(owner)
        if owner == self.schema.root &&
          (field.name == "__schema" || field.name == "__type") {
          raise Unsupported(
            at, "schema introspection fields are outside the query profile",
          )
        }
        if field.name == "__typename" {
          if !arguments.is_empty() || !field.selection_set.items.is_empty() {
            raise Invalid(
              at, "__typename is a scalar and takes no arguments or selection set",
            )
          }
          self.check_response(
            key,
            {
              name: field.name,
              kind: NonNullType(NamedType("String")),
              arguments,
              parents: lineage,
            },
            at,
          )
          continue
        }
        guard self.schema.fields.get(owner) is Some(fields) &&
          fields.get(field.name) is Some(old) else {
          raise Invalid(at, "baseline field does not exist: \{coordinate}")
        }
        self.check_response(
          key,
          { name: field.name, kind: old.kind, arguments, parents: lineage, },
          at,
        )
        self.validate_arguments(old, arguments, at)
        if !self.input_changes.is_empty() &&
          self.proposed.fields.get(owner) is Some(fields) &&
          fields.get(field.name) is Some(proposed) {
          let site = { key, path: next_path, at, }
          for name, argument in old.arguments {
            if proposed.arguments.get(name) is Some(after) &&
              named(argument.kind) == named(after.kind) &&
              self.schema.input_objects.contains(named(argument.kind)) {
              let supplied = match arguments.get(name) {
                Some(value) => Some(value)
                None => argument.default_value
              }
              if supplied is Some(value) {
                self.observe_input(argument.kind, value, site)
              }
            }
          }
        }
        if self.argument_changes.get(coordinate) is Some(diffs) {
          for diff in diffs {
            let reasons = self.affected_argument_reasons(
              diff,
              arguments.get(diff.name),
            )
            if !reasons.is_empty() {
              self.record_impact(diff.change, key, next_path, at, reasons)
            }
          }
        }
        let child = named(old.kind)
        if self.schema.is_composite(child) ==
          field.selection_set.items.is_empty() {
          raise Invalid(
            at, "composite fields require a selection set and leaf fields forbid it",
          )
        }
        if self.changes.get(coordinate) is Some(change) {
          self.record_impact(
            change,
            key,
            next_path,
            at,
            change.reasons.unwrap_or([]).map(reason => reason.code),
          )
        }
        if !field.selection_set.items.is_empty() {
          self.observe_member_addition(child, next_path, at)
          self.visit(
            child,
            source,
            field.selection_set,
            next_path,
            depth + 1,
            self.new_scope(child),
            lineage,
          )
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
        self.validate_selection_directives(source, spread.directives)
        if self.active.contains(name) {
          raise Invalid(at, "cyclic fragment: \{name}")
        }
        self.seen_fragments.add(name)
        self.active.add(name)
        let effective = self.visit_condition(owner, condition, path, at, scope)
        self.visit(
          condition,
          file,
          fragment.selection_set,
          path,
          depth + 1,
          effective,
          parents,
        )
        self.active.remove(name)
      }
      InlineFragmentSelection(fragment) => {
        let at = source.at(fragment.position)
        self.validate_selection_directives(source, fragment.directives)
        let (scope, effective) = match fragment.type_condition {
          Some(On(condition)) =>
            (condition, self.visit_condition(owner, condition, path, at, scope))
          None => (owner, scope)
        }
        self.visit(
          scope,
          source,
          fragment.selection_set,
          path,
          depth + 1,
          effective,
          parents,
        )
      }
    }
  }
}

///|
/// Compare supported input and output contracts and locate affected selections in baseline-valid queries.
pub fn analyze_upgrade(
  baseline : Source,
  proposed : Source,
  clients : Array[Client],
) -> Report raise AnalysisError {
  analyze_upgrade_with_coverage(baseline, proposed, clients).report
}

///|
/// Analyze the same upgrade as analyze_upgrade and record every checked operation.
/// An empty client list yields a schema-only report with empty coverage.
pub fn analyze_upgrade_with_coverage(
  baseline : Source,
  proposed : Source,
  clients : Array[Client],
) -> AnalyzedUpgrade raise AnalysisError {
  let old = index(baseline)
  let next = index(proposed)
  if old.root != next.root {
    raise Unsupported(
      { path: proposed.path, line: 1, column: 1, },
      "query root renaming is outside the output profile",
    )
  }
  let changes = Map([])
  let argument_changes = Map([])
  let ordered = []
  for owner, fields in old.fields {
    for name, field in fields {
      let candidate = match next.fields.get(owner) {
        Some(fields) => fields.get(name)
        None => None
      }
      if candidate is Some(new_field) {
        let diffs = argument_diffs(
          old,
          next,
          "\{owner}.\{name}",
          field,
          new_field,
        )
        if !diffs.is_empty() {
          argument_changes["\{owner}.\{name}"] = diffs
          for diff in diffs {
            ordered.push(diff.change)
          }
        }
      }
      let reasons = output_reasons(old, next, field, candidate)
      if reasons.is_empty() {
        continue
      }
      let coordinate = "\{owner}.\{name}"
      let change = {
        coordinate,
        previous_type: old.type_text(field.kind),
        proposed_type: candidate.map(fn(f) { next.type_text(f.kind) }),
        baseline: field.at,
        proposed: candidate.map(fn(f) { f.at }),
        impacts: [],
        reasons: Some(reasons.map(code => code.reason())),
      }
      changes[coordinate] = change
      ordered.push(change)
    }
  }
  let abstract_changes = abstract_changes(old, next, ordered)
  let input_changes = input_object_diffs(old, next, ordered)
  let names = Set([])
  let coverage = []
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
    let analyzed_operations = []
    for operation, (file, query) in catalog.operations {
      let variables = Map([])
      for definition in query.variable_definitions {
        let at = file.at(definition.position)
        if variables.contains(definition.name) {
          raise Invalid(at, "duplicate variable: \{definition.name}")
        }
        old.check_input_type(definition.var_type, at)
        if definition.default_value is Some(value) &&
          !old.value_fits(definition.var_type, value, Map([])) {
          raise Invalid(
            at,
            "invalid default value for variable \{definition.name}",
          )
        }
        variables[definition.name] = definition
      }
      let walk = {
        schema: old,
        proposed: next,
        argument_changes,
        input_changes,
        abstract_changes,
        catalog,
        changes,
        client: client.name,
        operation,
        seen_fragments,
        active: Set([]),
        response_fields: Map([]),
        reported: Map([]),
        variables,
        used_variables: Set([]),
        budget: 100000,
      }
      walk.visit(
        old.root,
        file,
        query.selection_set,
        [],
        0,
        walk.new_scope(old.root),
        [],
      )
      for name, definition in variables {
        if !walk.used_variables.contains(name) {
          raise Invalid(file.at(definition.position), "unused variable \{name}")
        }
      }
      analyzed_operations.push({
        name: operation,
        location: file.at(query.position),
      })
    }
    for name, (source, fragment) in catalog.fragments {
      if !seen_fragments.contains(name) {
        raise Invalid(source.at(fragment.position), "unused fragment: \{name}")
      }
    }
    coverage.push({
      name: client.name,
      sources: client.sources.map(source => source.path),
      operations: analyzed_operations,
    })
  }
  { report: { changes: ordered, }, coverage, }
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
