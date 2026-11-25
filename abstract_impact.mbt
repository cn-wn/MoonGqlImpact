///|
priv struct ResponseSelection {
  name : String
  kind : @gql.GqlType
  arguments : Map[String, @gql.Value]
  parents : Array[String]
}

///|
fn Schema::same_response_type(
  self : Schema,
  a : @gql.GqlType,
  b : @gql.GqlType,
) -> Bool {
  match (a, b) {
    (NonNullType(a), NonNullType(b)) | (ListType(a), ListType(b)) =>
      self.same_response_type(a, b)
    (NamedType(a), NamedType(b)) =>
      a == b || (self.is_composite(a) && self.is_composite(b))
    _ => false
  }
}

///|
fn Schema::exclusive(
  self : Schema,
  left : Array[String],
  right : Array[String],
) -> Bool {
  for i in 0..<left.length() {
    if left[i] != right[i] &&
      self.is_object(left[i]) &&
      self.is_object(right[i]) {
      return true
    }
  }
  false
}

///|
fn Walk::check_response(
  self : Walk,
  key : String,
  selection : ResponseSelection,
  at : Location,
) -> Unit raise AnalysisError {
  let others = match self.response_fields.get(key) {
    Some(others) => others
    None => {
      let others = []
      self.response_fields[key] = others
      others
    }
  }
  for other in others {
    self.budget -= 1
    if self.budget < 0 {
      raise Unsupported(at, "operation exceeds the selection analysis budget")
    }
    let same_call = other.name == selection.name &&
      same_arguments(other.arguments, selection.arguments)
    if !self.schema.same_response_type(other.kind, selection.kind) ||
      (!same_call && !self.schema.exclusive(other.parents, selection.parents)) {
      raise Invalid(at, "conflicting selections for response path \{key}")
    }
    if same_call &&
      other.kind == selection.kind &&
      other.parents == selection.parents {
      return
    }
  }
  others.push(selection)
}

///|
fn Schema::abstract_location(self : Schema, name : String) -> Location? {
  match self.interfaces.get(name) {
    Some(at) => Some(at)
    None => self.unions.get(name).map(union => union.at)
  }
}

///|
fn possible_text(name : String, types : Set[String]) -> String {
  let members = []
  for object_name in types {
    members.push(object_name)
  }
  members.sort()
  name + "{" + members.join(", ") + "}"
}

///|
fn abstract_changes(
  old : Schema,
  next : Schema,
  ordered : Array[Change],
) -> Map[String, Change] {
  let changes = Map([])
  for name, old_types in old.possible {
    guard old.abstract_location(name) is Some(baseline) else { continue }
    let proposed = next.abstract_location(name)
    let next_types = next.possible.get(name).unwrap_or(Set([]))
    let reasons = []
    if !next.is_composite(name) {
      reasons.push(AbstractTypeRemoved.reason())
    }
    for object_name in old_types {
      if !next_types.contains(object_name) {
        reasons.push(AbstractMemberRemoved.reason())
        break
      }
    }
    for object_name in next_types {
      if !old_types.contains(object_name) {
        reasons.push(AbstractMemberAdded.reason())
        break
      }
    }
    if reasons.is_empty() {
      continue
    }
    let change = {
      coordinate: name,
      previous_type: possible_text(name, old_types),
      proposed_type: if next.possible.contains(name) {
        Some(possible_text(name, next_types))
      } else {
        None
      },
      baseline,
      proposed,
      impacts: [],
      reasons: Some(reasons),
    }
    changes[name] = change
    ordered.push(change)
  }
  changes
}

///|
priv struct FragmentScope {
  before : Set[String]
  after : Set[String]
  conditions : Array[String]
}

///|
fn Walk::new_scope(self : Walk, name : String) -> FragmentScope {
  {
    before: self.schema.possible[name],
    after: self.proposed.possible.get(name).unwrap_or(Set([])),
    conditions: [name],
  }
}

///|
fn Walk::visit_condition(
  self : Walk,
  owner : String,
  condition : String,
  path : Array[String],
  at : Location,
  scope : FragmentScope,
) -> FragmentScope raise AnalysisError {
  let previously = self.schema.overlap_for(owner, condition)
  if !self.schema.is_composite(condition) ||
    (owner != condition && previously.is_empty()) {
    raise Invalid(at, "fragment on \{condition} cannot apply to \{owner}")
  }
  let next_condition = self.proposed.possible.get(condition).unwrap_or(Set([]))
  let before = overlap(scope.before, self.schema.possible[condition])
  let after = overlap(scope.after, next_condition)
  let static_impossible = !self.proposed.is_composite(condition) ||
    (
      owner != condition &&
      self.proposed.overlap_for(owner, condition).is_empty()
    )
  let impossible = static_impossible || (!before.is_empty() && after.is_empty())
  let conditions = scope.conditions.copy()
  conditions.push(condition)
  let previously_reachable = if static_impossible && before.is_empty() {
    previously
  } else {
    before
  }
  for name in conditions {
    guard self.abstract_changes.get(name) is Some(change) else { continue }
    let old_types = self.schema.possible[name]
    let new_types = self.proposed.possible.get(name).unwrap_or(Set([]))
    let impacted = []
    if !self.proposed.is_composite(name) &&
      (name == condition || !before.is_empty()) {
      impacted.push(AbstractTypeRemoved)
    }
    for object_name in previously_reachable {
      if !new_types.contains(object_name) && old_types.contains(object_name) {
        impacted.push(AbstractMemberRemoved)
        break
      }
    }
    for object_name in after {
      if !old_types.contains(object_name) && new_types.contains(object_name) {
        impacted.push(AbstractMemberAdded)
        break
      }
    }
    if !impacted.is_empty() {
      if impossible {
        let reasons = change.reasons.unwrap()
        if !reasons.any(reason => reason.code == FragmentNoLongerPossible) {
          reasons.push(FragmentNoLongerPossible.reason())
        }
        impacted.push(FragmentNoLongerPossible)
      }
      self.record_impact(change, path.join("."), path, at, impacted)
    }
  }
  { before, after, conditions, }
}

///|
fn Walk::observe_member_addition(
  self : Walk,
  name : String,
  path : Array[String],
  at : Location,
) -> Unit {
  if self.abstract_changes.get(name) is Some(change) &&
    change.reasons.unwrap().any(reason => reason.code == AbstractMemberAdded) {
    self.record_impact(change, path.join("."), path, at, [AbstractMemberAdded])
  }
}
