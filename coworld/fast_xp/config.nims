if projectName() == "gota_worker":
  switch("define", "coworld")
  switch("define", "headless")
  switch("define", "fastXpWorker")
else:
  # HTTP response buffers can outlive their allocating handler thread on shutdown.
  switch("define", "useMalloc")
  # Observatory and its signed artifact URLs require HTTPS.
  switch("define", "ssl")
