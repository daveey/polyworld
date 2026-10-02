## Optional policy telemetry, buffered per seat like PRINT output.
import std/[json, math, os, tables], bassy, jsony

const
  AnnotationEventLimit* = 2 * 1024
  AnnotationFileLimit* = 2 * 1024 * 1024
  AnnotationCountLimit* = 1000

type
  AnnotationStatus* = enum
    AnnotationAccepted, AnnotationDisabled, AnnotationInvalid,
    AnnotationTooLarge, AnnotationBudgetExceeded, AnnotationWriteFailed
  AnnotationSink* = ref object
    path: string
    file: File
    bytes: int
    events: int
    failed: bool
    status: AnnotationStatus

proc newAnnotationSink*(path: string): AnnotationSink =
  ## Binds one private destination; the file opens only on the first valid event.
  AnnotationSink(path: path)

proc annotationMessage*(status: AnnotationStatus): string =
  ## Explains the status returned by ANNOTATE without raising a policy error.
  case status
  of AnnotationAccepted: ""
  of AnnotationDisabled: "No annotation destination"
  of AnnotationInvalid: "Invalid annotation: expected numeric time, kind, function and a JSON object"
  of AnnotationTooLarge: "Annotation exceeds 2 KiB"
  of AnnotationBudgetExceeded: "Annotations exceed 1000 events or 2 MiB per seat"
  of AnnotationWriteFailed: "Annotation output could not be written"

proc flushOutput(file: File): cint {.importc: "fflush", header: "<stdio.h>".}
proc closeOutput(file: File): cint {.importc: "fclose", header: "<stdio.h>".}

proc close*(sink: AnnotationSink): AnnotationStatus =
  ## Flushes and closes during existing output cleanup; reports storage errors.
  if sink == nil:
    return AnnotationDisabled
  if sink.file != nil:
    # Nim flushFile/close discard stdio errors; preserve them for cleanup reporting.
    if flushOutput(sink.file) != 0:
      sink.failed = true
    if closeOutput(sink.file) != 0:
      sink.failed = true
    sink.file = nil
  sink.path = ""
  if sink.failed: AnnotationWriteFailed else: AnnotationAccepted

proc validParameters(value: JsonNode, depth = 0): bool =
  ## Bounds nesting and excludes non-finite numbers rejected by the platform.
  if depth > 64:
    return false
  case value.kind
  of JFloat:
    result = value.getFloat().classify notin {fcNan, fcInf, fcNegInf}
  of JObject:
    result = true
    for child in value.fields.values:
      if not validParameters(child, depth + 1): return false
  of JArray:
    result = true
    for child in value.elems:
      if not validParameters(child, depth + 1): return false
  else: result = true

proc annotate*(sink: AnnotationSink, time: int32, kind, function, args: string): AnnotationStatus =
  ## Appends to the seat's buffered file, using the same I/O model as PRINT.
  if sink == nil:
    return AnnotationDisabled
  if sink.failed:
    sink.status = AnnotationWriteFailed
    return sink.status
  if sink.path.len == 0:
    sink.status = AnnotationDisabled
    return sink.status
  sink.status = AnnotationInvalid
  if kind.len == 0 or kind.len > 128 or function.len == 0 or function.len > 256:
    return sink.status
  if args.len > AnnotationEventLimit:
    sink.status = AnnotationTooLarge
    return sink.status
  var parameters: JsonNode
  try:
    parameters = parseJson(args)
  except JsonParsingError, ValueError:
    return sink.status
  if parameters.kind != JObject or not validParameters(parameters):
    return sink.status
  let line = "{\"schema_version\":1,\"time\":" & $time &
    ",\"kind\":" & kind.toJson() & ",\"function\":" & function.toJson() &
    ",\"args\":" & $parameters & "}\n"
  if line.len > AnnotationEventLimit:
    sink.status = AnnotationTooLarge
  elif sink.events >= AnnotationCountLimit or sink.bytes + line.len > AnnotationFileLimit:
    sink.status = AnnotationBudgetExceeded
  else:
    try:
      if sink.file == nil:
        createDir(sink.path.parentDir)
        sink.file = open(sink.path, fmWrite)
      sink.file.write(line)
      sink.bytes += line.len
      inc sink.events
      sink.status = AnnotationAccepted
    except IOError, OSError:
      sink.failed = true
      sink.status = AnnotationWriteFailed
  return sink.status

proc addAnnotationFunctions*(host: var Host, sink: AnnotationSink = nil) =
  ## Identical API and work costs in schema, hosted, desktop and browser hosts.
  let emit: ContextHostProc = proc(runtime: Runtime, args: openArray[Value]): Value =
    if sink == nil:
      return Value(ord(AnnotationDisabled))
    var status: AnnotationStatus
    try:
      status = sink.annotate(args[0].asInt, runtime.getString(args[1]),
        runtime.getString(args[2]), runtime.getString(args[3]))
    except BasicError:
      status = AnnotationInvalid
      sink.status = status
    Value(ord(status))
  let message: ContextHostProc = proc(runtime: Runtime, args: openArray[Value]): Value =
    var runtime = runtime
    runtime.putString((if sink == nil: AnnotationDisabled else: sink.status).annotationMessage)
  discard host.addFunction("ANNOTATE", 4, emit, workUnits = 1024)
  discard host.addFunction("ANNOTATE_ERROR$", 0, message, workUnits = 1)
