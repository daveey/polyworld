## Shared policy capabilities; game builders add only their game-specific API.
import bassy, annotations
when defined(coworld):
  import coworld

proc initPolicyHost*(slot = -1): Host =
  ## Schema hosts omit the seat. Hosts without an output destination stay usable.
  result = initHost()
  when defined(coworld):
    result.addAnnotationFunctions(playerAnnotations(slot))
  else:
    result.addAnnotationFunctions()
