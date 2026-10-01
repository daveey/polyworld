import
  std/[httpclient, json, locks, net, os, strutils, tempfiles, uri],
  crunchy,
  polyworld/policies as policyPackages,
  ./metrics

type
  RunError* = object of CatchableError
    status*: int

const
  FetchTimeoutMs = 10_000

var downloadLocks: array[16, Lock]
for lock in downloadLocks.mitems:
  initLock(lock)

proc reject*(status: int, message: string) =
  ## Raises an HTTP failure without exposing credentials or private source.
  var error = newException(RunError, message)
  error.status = status
  raise error

proc sourceHash(source: string): string =
  ## Computes the artifact's lowercase SHA-256 identifier.
  for value in sha256(source):
    result.add value.toHex(2).toLowerAscii()

proc validateUrl(url: string) =
  ## Requires TLS except for explicitly configured loopback test services.
  let parsed = parseUri(url)
  if parsed.hostname.len == 0 or parsed.username.len > 0 or
      parsed.password.len > 0 or parsed.anchor.len > 0 or
      (parsed.scheme != "https" and not (parsed.scheme == "http" and
      parsed.hostname in ["localhost", "127.0.0.1", "::1"])):
    reject(502, "Policy service returned an unsupported URL")

proc fetch(url: string, headers: HttpHeaders): Response =
  ## Makes one bounded-time request without following credential-bearing redirects.
  validateUrl(url)
  let client = newHttpClient(timeout = FetchTimeoutMs, maxRedirects = 0,
    headers = headers, userAgent = "polyworld-fast-xp/0.1")
  defer: client.close()
  try:
    result = client.get(url)
  except TimeoutError:
    reject(504, "Policy service or artifact download timed out")
  except CatchableError:
    # HTTP exceptions can contain the signed URL, so do not forward or log them.
    reject(502, "Could not reach the policy service or download its artifact")

proc fetchPolicyBytes*(policyRef: string): string =
  ## Authorizes each request, then caches the complete raw-or-ZIP artifact by hash.
  let token = getEnv("FAST_XP_OBSERVATORY_TOKEN")
  if token.len == 0:
    reject(503, "Configure FAST_XP_OBSERVATORY_TOKEN to fetch policy references")
  let
    server = getEnv("FAST_XP_OBSERVATORY_URL", "https://softmax.com/api/observatory").strip(trailing = true, chars = {'/'})
    headers = newHttpHeaders({"Authorization": "Bearer " & token})
  if getEnv("FAST_XP_OBSERVATORY_ELEVATED") == "1":
    headers["X-Use-Elevated-Privileges"] = "true"
  let response = fetch(server & "/v2/policy-files/download?policy_ref=" &
    encodeUrl(policyRef), headers)
  case int(response.code)
  of 200: discard
  of 400: reject(400, "Invalid or ambiguous policy reference; use a policy-version UUID")
  of 404: reject(404, "Policy version not found")
  of 409: reject(409, "Policy version has no downloadable player file")
  of 401, 403:
    reject(502, "Observatory rejected the server credential; check its expiry, scope and elevation")
  else: reject(502, "Observatory policy lookup failed")
  var
    digest, downloadUrl: string
    size: int
  try:
    let metadata = parseJson(response.body)
    digest = metadata["content_hash"].getStr()
    downloadUrl = metadata["download_url"].getStr()
    size = metadata["size_bytes"].getInt()
  except CatchableError:
    reject(502, "Observatory returned invalid policy metadata")
  if digest.len != 64 or digest.find(AllChars - {'0'..'9', 'a'..'f'}) >= 0 or
      size < 1 or size > policyPackages.MaxPackageBytes:
    reject(502, "Policy metadata is invalid or exceeds the game's 16 MiB package limit")
  validateUrl(downloadUrl)
  let
    cache = getEnv("FAST_XP_CACHE_DIR", getCacheDir() / "polyworld-fast-xp" / "policies")
    path = cache / digest
  # Serialize publication of the same hash, without sharing GC-managed data
  # across Mummy threads. Different hashes can download concurrently.
  withLock downloadLocks[parseHexInt(digest[0 .. 0])]:
    createDir(cache)
    setFilePermissions(cache, {fpUserRead, fpUserWrite, fpUserExec})
    if fileExists(path):
      if getFileSize(path) == size:
        let cached = readFile(path)
        if sourceHash(cached) == digest:
          cacheLookup(true)
          return cached
      removeFile(path)
    cacheLookup(false)
    # Never forward the Observatory bearer token or elevation header to S3.
    let artifact = fetch(downloadUrl, newHttpHeaders())
    if artifact.code != Http200:
      reject(502, "Policy artifact download failed; retry to obtain a fresh URL")
    result = artifact.body
    if result.len != size or sourceHash(result) != digest:
      reject(502, "Policy artifact size or SHA-256 did not match Observatory metadata")
    let (file, temporary) = createTempFile("download-", ".part", cache)
    defer:
      file.close()
      if fileExists(temporary):
        removeFile(temporary)
    setFilePermissions(temporary, {fpUserRead, fpUserWrite})
    file.write(result)
    file.flushFile()
    moveFile(temporary, path)
