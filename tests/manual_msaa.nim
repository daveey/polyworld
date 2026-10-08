## Requires a desktop GL context to check MSAA and shadow pass isolation.

import
  opengl, vmath, windy,
  polyworld/shadows

type MsaaTestError = object of CatchableError

proc integer(parameter: GLenum): GLint =
  ## Reads one integer from the active GL context.
  glGetIntegerv(parameter, result.addr)

proc checkMsaa() =
  ## Verifies real sample buffers, shadow depths, and render state cleanup.
  let window = newWindow(
    "MSAA shadow check",
    ivec2(320, 240),
    vsync = false,
    msaa = msaa4x
  )
  defer:
    window.close()
  window.makeContextCurrent()
  loadExtensions()
  doAssert integer(GL_SAMPLE_BUFFERS) == 1
  doAssert integer(GL_SAMPLES) >= 4
  echo "Window samples: ", integer(GL_SAMPLES)

  initSunShadows()
  let vertices = [vec3(-1, -1, 0), vec3(3, -1, 0), vec3(-1, 3, 0)]
  var vertexArray, vertexBuffer: GLuint
  glGenVertexArrays(1, vertexArray.addr)
  glGenBuffers(1, vertexBuffer.addr)
  defer:
    glDeleteBuffers(1, vertexBuffer.addr)
    glDeleteVertexArrays(1, vertexArray.addr)
  glBindVertexArray(vertexArray)
  glBindBuffer(GL_ARRAY_BUFFER, vertexBuffer)
  glBufferData(
    GL_ARRAY_BUFFER,
    sizeof(vertices),
    unsafeAddr vertices[0],
    GL_STATIC_DRAW
  )
  let location = glGetAttribLocation(sunDepthProgramId(), "vertPos")
  doAssert location >= 0
  glEnableVertexAttribArray(location.GLuint)
  glVertexAttribPointer(
    location.GLuint, 3, cGL_FLOAT, GL_FALSE, 0, nil
  )
  glBindVertexArray(0)

  for blend in [0.0'f, 0.5'f]:
    sunShadowBlend = blend
    for enabled in [false, true]:
      if enabled:
        glEnable(GL_MULTISAMPLE)
      else:
        glDisable(GL_MULTISAMPLE)
      var depths = [-1.0'f, -1.0'f]
      sunDepthPasses(window.size):
        doAssert glIsEnabled(GL_MULTISAMPLE) == GL_FALSE
        doAssert integer(GL_SAMPLE_BUFFERS) == 0
        doAssert integer(GL_SAMPLES) == 0
        doAssert glCheckFramebufferStatus(GL_FRAMEBUFFER) ==
          GL_FRAMEBUFFER_COMPLETE
        bindSunDepth(mat4())
        glBindVertexArray(vertexArray)
        glDrawArrays(GL_TRIANGLES, 0, 3)
        glReadPixels(
          SunShadowMapSize div 2,
          SunShadowMapSize div 2,
          1,
          1,
          GL_DEPTH_COMPONENT,
          cGL_FLOAT,
          depths[sunPassIndex].addr
        )
      doAssert abs(depths[0] - 0.5'f) < 0.00001'f
      if blend == 0:
        doAssert depths[1] == -1
      else:
        doAssert abs(depths[1] - 0.5'f) < 0.00001'f
      doAssert (glIsEnabled(GL_MULTISAMPLE) == GL_TRUE) == enabled
      doAssert integer(GL_FRAMEBUFFER_BINDING) == 0
      doAssert integer(GL_SAMPLES) >= 4
      echo "Shadow depths with window MSAA ", enabled, ": ", depths

  glEnable(GL_MULTISAMPLE)
  var interrupted = false
  try:
    sunDepthPasses(window.size):
      raise newException(MsaaTestError, "Interrupted shadow pass")
  except MsaaTestError:
    interrupted = true
  doAssert interrupted
  doAssert integer(GL_FRAMEBUFFER_BINDING) == 0
  doAssert glIsEnabled(GL_MULTISAMPLE) == GL_TRUE
  doAssert glGetError() == GL_NO_ERROR
  echo "MSAA and shadow isolation passed"

checkMsaa()
