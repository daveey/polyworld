## AWM's procedural star field behind the ship, with replay-timed motion.

import
  opengl, vmath,
  sim

const
  VertexSource = staticRead("shaders/night-sky.vert")
  FragmentSource = staticRead("shaders/night-sky.frag")
  ShaderHeader =
    when defined(emscripten):
      "#version 300 es\nprecision highp float;\nprecision highp int;\n"
    else:
      "#version 330 core\n"

type
  StarField* = object
    program, vertexArray: GLuint
    viewLocation, eyeLocation, timeLocation, brightnessLocation: GLint

proc compileStage(kind: GLenum, source: string): GLuint =
  ## Compiles one copied sky shader and releases failed GPU resources.
  result = glCreateShader(kind)
  let sources = allocCStringArray([ShaderHeader & source])
  defer:
    deallocCStringArray(sources)
  glShaderSource(result, 1, sources, nil)
  glCompileShader(result)
  var status: GLint
  glGetShaderiv(result, GL_COMPILE_STATUS, status.addr)
  if status == 0:
    var length: GLint
    glGetShaderiv(result, GL_INFO_LOG_LENGTH, length.addr)
    var log = newString(length)
    glGetShaderInfoLog(result, length, nil, log.cstring)
    glDeleteShader(result)
    raise newException(CrewriftError, "Star field shader failed: " & log)

proc initStarField*(): StarField =
  ## Creates the AWM sky program and its fullscreen triangle vertex array.
  let vertex = compileStage(GL_VERTEX_SHADER, VertexSource)
  defer:
    glDeleteShader(vertex)
  let fragment = compileStage(GL_FRAGMENT_SHADER, FragmentSource)
  defer:
    glDeleteShader(fragment)
  result.program = glCreateProgram()
  glAttachShader(result.program, vertex)
  glAttachShader(result.program, fragment)
  glLinkProgram(result.program)
  var status: GLint
  glGetProgramiv(result.program, GL_LINK_STATUS, status.addr)
  if status == 0:
    var length: GLint
    glGetProgramiv(result.program, GL_INFO_LOG_LENGTH, length.addr)
    var log = newString(length)
    glGetProgramInfoLog(result.program, length, nil, log.cstring)
    glDeleteProgram(result.program)
    raise newException(CrewriftError, "Star field shader link failed: " & log)
  result.viewLocation = glGetUniformLocation(
    result.program,
    "inverseViewProjection"
  )
  result.eyeLocation = glGetUniformLocation(result.program, "cameraEye")
  result.timeLocation = glGetUniformLocation(result.program, "time")
  result.brightnessLocation = glGetUniformLocation(
    result.program,
    "skyBrightness"
  )
  glGenVertexArrays(1, result.vertexArray.addr)

proc close*(field: var StarField) =
  ## Releases the sky program and vertex array while the context is alive.
  glDeleteProgram(field.program)
  glDeleteVertexArrays(1, field.vertexArray.addr)
  field = StarField()

proc draw*(
  field: StarField,
  viewProjection: Mat4,
  eye: Vec3,
  time: float32
) =
  ## Draws stars at the far plane without writing depth over the ship.
  glEnable(GL_DEPTH_TEST)
  glDepthFunc(GL_LEQUAL)
  glDepthMask(GL_FALSE)
  glDisable(GL_STENCIL_TEST)
  glDisable(GL_BLEND)
  glDisable(GL_CULL_FACE)
  glUseProgram(field.program)
  var inverse = viewProjection.inverse
  glUniformMatrix4fv(
    field.viewLocation,
    1,
    GL_FALSE,
    cast[ptr float32](inverse.addr)
  )
  glUniform3f(field.eyeLocation, eye.x, eye.y, eye.z)
  glUniform1f(field.timeLocation, time)
  glUniform1f(field.brightnessLocation, 1)
  glBindVertexArray(field.vertexArray)
  glDrawArrays(GL_TRIANGLES, 0, 3)
  glBindVertexArray(0)
  glDepthMask(GL_TRUE)
  glDepthFunc(GL_LESS)
  glEnable(GL_CULL_FACE)
