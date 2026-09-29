import std/[json, math, tables]

const
  MaxStateFields* = 256
  MaxNotes* = 16
  MaxQuestions* = 64
  MaxCriteria* = 16
  MaxKeyLength* = 64
  MaxOracleBytes* = 32 * 1024
  MaxStateNodes = 4096

type
  OracleError* = object of CatchableError
  QuestionKind* = enum
    NoulQuestion, ScoreQuestion, ChoiceQuestion
  Criterion = object
    label, text: string
    fields: seq[(string, string)]
  Question = object
    key, instructions: string
    kind: QuestionKind
    criteria: seq[Criterion]
  OracleDraft = object
    state: JsonNode
    fields, notes, bytes, nodes: int
    questions: seq[Question]
  OracleAnswer* = object
    key*: string
    value*, confidence*: int32
    probabilities*: Table[string, int32]
  Oracle* = ref object
    enabled*: bool
    draft: OracleDraft
    pending*: int32
    tick: int32
    questions: seq[Question]
    completed: int32
    answers: seq[OracleAnswer]

proc newOracle*(enabled = true): Oracle =
  ## Creates structured JEV state without an HTTP client or BASIC runtime.
  Oracle(enabled: enabled, tick: -1)

proc reset*(oracle: Oracle) =
  ## Clears drafts, pending questions, and retained answers.
  oracle.draft = OracleDraft()
  oracle.pending = 0
  oracle.questions.setLen(0)
  oracle.completed = 0
  oracle.answers.setLen(0)
  oracle.tick = -1

proc validKey(key: string): bool =
  ## Bounds names before storing or expanding them into JSON paths.
  key.len > 0 and key.len <= MaxKeyLength

proc reserve(draft: var OracleDraft, bytes: int): bool =
  ## Bounds retained draft strings even before JSON serialization.
  if bytes > MaxOracleBytes - draft.bytes:
    return false
  draft.bytes += bytes
  true

proc setPath(
  node: JsonNode, key: string, value: JsonNode, nodes: var int
) =
  ## Expands dotted keys and bounded array indices into structured state.
  var
    current = node
    position = 0
  while position < key.len:
    var
      name: string
      index = -1
    if key[position] == '[':
      inc position
      index = 0
      let start = position
      while position < key.len and key[position] in {'0' .. '9'}:
        index = index * 10 + ord(key[position]) - ord('0')
        if index >= MaxStateFields:
          raise newException(OracleError, "Oracle array index is too large")
        inc position
      if position == start or position >= key.len or key[position] != ']':
        raise newException(OracleError, "Invalid oracle field path")
      inc position
    else:
      while position < key.len and key[position] notin {'.', '['}:
        name.add key[position]
        inc position
      if name.len == 0:
        raise newException(OracleError, "Invalid oracle field path")
    let final = position == key.len
    if not final and key[position] == '.':
      inc position
      if position == key.len:
        raise newException(OracleError, "Invalid oracle field path")
    let child =
      if final: value
      elif key[position] == '[': newJArray()
      else: newJObject()
    inc nodes
    if nodes > MaxStateNodes:
      raise newException(OracleError, "Oracle state node limit exceeded")
    if index >= 0:
      if current.kind != JArray:
        raise newException(OracleError, "Conflicting oracle field paths")
      while current.len <= index:
        inc nodes
        if nodes > MaxStateNodes:
          raise newException(OracleError, "Oracle state node limit exceeded")
        current.add newJNull()
      if final or current[index].kind == JNull:
        current.elems[index] = child
      current = current[index]
    else:
      if current.kind != JObject:
        raise newException(OracleError, "Conflicting oracle field paths")
      if final or not current.hasKey(name):
        current[name] = child
      current = current[name]

proc state*(oracle: Oracle, key: string, value: JsonNode): int32 =
  ## Adds a bounded fact to this decision's request draft.
  if not validKey(key) or oracle.draft.fields >= MaxStateFields:
    return 0
  if not oracle.draft.reserve(key.len + ($value).len + 8):
    return 0
  if oracle.draft.state == nil:
    oracle.draft.state = newJObject()
  oracle.draft.state.setPath(key, value, oracle.draft.nodes)
  inc oracle.draft.fields
  1

proc note*(oracle: Oracle, text: string): int32 =
  ## Adds one explanatory note to the state.
  if oracle.draft.notes >= MaxNotes:
    return 0
  let key = "notes[" & $oracle.draft.notes & "]"
  result = oracle.state(key, %text)
  if result == 1:
    inc oracle.draft.notes

proc question*(
  oracle: Oracle, key: string, kind: int32, instructions: string
): int32 =
  ## Creates or replaces a typed question in the current draft.
  if not validKey(key) or kind notin 0 .. 2:
    return 0
  if not oracle.draft.reserve(key.len + instructions.len + 64):
    return 0
  let question = Question(
    key: key, kind: QuestionKind(kind), instructions: instructions
  )
  for item in oracle.draft.questions.mitems:
    if item.key == key:
      item = question
      return 1
  if oracle.draft.questions.len >= MaxQuestions:
    return 0
  oracle.draft.questions.add question
  1

proc criterion*(oracle: Oracle, key, label, text: string): int32 =
  ## Adds one choice label or ordered score criterion.
  for item in oracle.draft.questions.mitems:
    if item.key != key:
      continue
    if item.criteria.len >= MaxCriteria:
      return 0
    if item.kind != ScoreQuestion:
      if not validKey(label):
        return 0
      for existing in item.criteria:
        if existing.label == label:
          return 0
    if not oracle.draft.reserve(label.len + text.len + 16):
      return 0
    item.criteria.add Criterion(label: label, text: text)
    return 1

proc criterionField*(
  oracle: Oracle, key, label, field, text: string
): int32 =
  ## Adds bounded descriptive fields to a choice or yes/no criterion.
  if not validKey(field) or field == "what":
    return 0
  for item in oracle.draft.questions.mitems:
    if item.key != key or item.kind == ScoreQuestion:
      continue
    for criterion in item.criteria.mitems:
      if criterion.label == label and criterion.fields.len < MaxCriteria:
        if not oracle.draft.reserve(field.len + text.len + 16):
          return 0
        criterion.fields.add (field, text)
        return 1

proc requestBody*(oracle: Oracle, model: string): string =
  ## Encodes Jev's state and typed questions without a chat prompt wrapper.
  if oracle.draft.questions.len == 0:
    return
  var questions = newJObject()
  for item in oracle.draft.questions:
    var
      question = %*{"instructions": item.instructions}
      criteria = if item.kind == ScoreQuestion: newJArray() else: newJObject()
    question["type"] = %(case item.kind
      of NoulQuestion: "noul"
      of ScoreQuestion: "score"
      of ChoiceQuestion: "choice")
    for criterion in item.criteria:
      if item.kind == ScoreQuestion:
        criteria.add %criterion.text
      else:
        var value = %criterion.text
        if criterion.fields.len > 0:
          value = %*{"what": criterion.text}
          for (name, text) in criterion.fields:
            if not value.hasKey(name):
              value[name] = %text
            else:
              if value[name].kind != JArray:
                value[name] = %*[value[name]]
              value[name].add %text
        criteria[criterion.label] = value
    question["criteria"] = criteria
    questions[item.key] = question
  result = $(%*{
    "model": model,
    "state": (if oracle.draft.state == nil: newJObject()
      else: oracle.draft.state),
    "questions": questions
  })
  if result.len > MaxOracleBytes:
    result.setLen(0)

proc submit*(oracle: Oracle, id: int32) =
  ## Saves accepted question definitions and clears the submitted draft.
  if id > 0:
    oracle.pending = id
    oracle.questions = oracle.draft.questions
  oracle.draft = OracleDraft()

proc thousandths(node: JsonNode): int32 =
  ## Converts finite API numbers to BASIC's integer thousandths.
  if node == nil or node.kind notin {JInt, JFloat}:
    return -1
  let value = node.getFloat() * 1000
  if classify(value) in {fcNan, fcInf, fcNegInf}:
    return -1
  int32(clamp(round(value), -1_000_000_000.0, 1_000_000_000.0))

proc flatten(oracle: Oracle, document: JsonNode): seq[OracleAnswer] =
  ## Converts only answers matching the submitted question definitions.
  let answers = document{"answers"}
  if answers == nil or answers.kind != JObject:
    return
  for question in oracle.questions:
    let node = answers{question.key}
    if node == nil or node.kind != JObject:
      continue
    var answer = OracleAnswer(
      key: question.key, value: -1,
      confidence: thousandths(node{"confidence"})
    )
    case question.kind
    of NoulQuestion:
      answer.value = thousandths(node{"noul"})
    of ScoreQuestion:
      answer.value = thousandths(node{"score"})
    of ChoiceQuestion:
      let selected = node{"choice"}.getStr()
      for index, criterion in question.criteria:
        if criterion.label == selected:
          answer.value = int32(index)
        let probability = thousandths(node{"probabilities", criterion.label})
        if probability >= 0:
          answer.probabilities[criterion.label] = probability
    if answer.value >= 0:
      result.add answer

proc beginTick*(oracle: Oracle, tick: int32) =
  ## Clears the draft for this decision and resets answers when rewinding.
  if tick < oracle.tick:
    oracle.reset()
  oracle.tick = tick
  oracle.draft = OracleDraft()

proc complete*(oracle: Oracle, id: int32, document: JsonNode) =
  ## Stores structured answers, using nil for failed or malformed responses.
  if id <= 0 or id != oracle.pending:
    return
  oracle.completed = id
  oracle.answers.setLen(0)
  if document != nil:
    oracle.answers = oracle.flatten(document)
  oracle.pending = 0
  oracle.questions.setLen(0)

proc poll*(oracle: Oracle, id: int32): int32 =
  ## Returns the answer count, zero while pending, or minus one on failure.
  if id > 0 and id == oracle.pending:
    return 0
  if id > 0 and id == oracle.completed and oracle.answers.len > 0:
    return int32(oracle.answers.len)
  -1

proc answer*(oracle: Oracle, id: int32, key: string): OracleAnswer =
  ## Reads a named judgment, returning missing values as minus one.
  if id > 0 and id == oracle.completed:
    for answer in oracle.answers:
      if answer.key == key:
        return answer
  OracleAnswer(value: -1, confidence: -1)
