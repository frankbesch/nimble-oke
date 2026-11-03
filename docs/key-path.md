# NGC key path

Where the NGC API key travels, from its source to the cluster, on the
default path and on the keyless path. Line numbers refer to this commit.

Status: the keyless path is built and tested offline only (stubs and
`helm template`). It has not run on a cluster. NVIDIA's 1.0.x docs describe
the pre-stage-then-serve-without-key flow for 1.0.3 (see "What the docs
establish"); it has not been observed on this chart until the live gates at
the end pass.

## Terms

- Key source: where the operator keeps the key (shell env, a key file, or the
  macOS Keychain).
- Release Secret: the Secret Helm writes per release revision
  (`sh.helm.release.v1.<release>.v<N>`). It holds the release record,
  gzip-compressed and base64-encoded.
- Pre-stage: download the model into the cache volume before the server
  starts, in a separate one-shot pod.

## Default path (unchanged; `ngc.keyless: false`)

| # | Hop | Where | Copy of the key |
|---|-----|-------|-----------------|
| 1 | Operator env or key file | `NGC_API_KEY` export, or `--key-file PATH` (mode 600/400) | source |
| 2 | Runner shell variable | `scripts/run_measured.sh:161-162` copies env into the non-exported `NGC_KEY_VALUE` and unsets the env; `:190` reads the key file into the same variable | runner memory |
| 3 | Deploy step env | `scripts/run_measured.sh:508` starts `deploy.sh` with `NGC_API_KEY=...` in its environment; every child of the deploy step inherits it (`prereqs.sh`, `helm`, `kubectl`, `oci`, `curl`). Output passes the redaction filter | deploy step process tree env |
| 4 | Registry probe | `scripts/prereqs.sh:125` sends `$oauthtoken:<key>` to nvcr.io through a curl config on stdin | sent to nvcr.io |
| 5 | Helm values | `scripts/deploy.sh:100` `ngc_values_yaml` prints `ngc.apiKey` into a pipe; helm reads it with `-f -` (dry run at `:341`, install at `:379`) | helm process memory |
| 6 | Helm release Secret | Helm stores the release record in the release Secret: user-supplied values (`Config`, which holds `ngc.apiKey`) and the rendered manifest (both chart Secrets). Source: Helm v3.16.4 `pkg/action/install.go` sets `Config: rawVals`; `pkg/storage/driver/secrets.go` and `util.go` `encodeRelease` (JSON, gzip, base64). One record per revision | **third cluster copy**, twice per revision |
| 7 | `<fullname>-ngc-api` | `helm/templates/secret.yaml`, Opaque, key `NGC_API_KEY` | cluster copy |
| 8 | `<fullname>-ngc-registry` | `helm/templates/secret.yaml`, dockerconfigjson password | cluster copy |
| 9 | Server pod env | `helm/templates/deployment.yaml:59-63` `NGC_API_KEY` from the `-ngc-api` Secret, for the life of the pod | serving pod env |
| 10 | Image pull | kubelet reads the pull Secret to pull from nvcr.io | node |

Finding confirmed: the chart builds both Secrets from `ngc.apiKey`, so the key
passes as a Helm value and lands in the release Secret as a third cluster copy
(values and manifest), in addition to the two chart Secrets.

`scripts/model-cache-manager.sh` does not pre-stage anything. Its `download`
action fails on purpose ("NGC model download is not implemented") unless
`SIMULATE_DOWNLOAD=yes` writes empty placeholder files. It reads
`NGC_API_KEY` only to check that it is set.

Outside the measured path, `scripts/deploy-parallel.sh:125-128` writes the
key to a mode-600 temp values file. Not changed here.

## Keyless path (`--key-keychain SERVICE`, or `--keyless`)

| # | Hop | Where | Copy of the key |
|---|-----|-------|-----------------|
| 1 | Key source | macOS Keychain generic password (preferred), a key file, or env | source |
| 2 | Runner | `--key-keychain`: the runner holds the service name only and drops any `NGC_API_KEY` from env. `--keyless --key-file`: the runner checks the file mode and passes the path; it does not read the file. `--keyless` with env: as the default path (hop 2 above) | none (Keychain, file) |
| 3 | Deploy step env | `scripts/run_measured.sh:504` passes `KEYLESS=1`, `NGC_KEY_KEYCHAIN=<service>` or `NGC_KEY_FILE=<path>`; no `NGC_API_KEY` | none (Keychain, file) |
| 4 | Registry probe | skipped for Keychain and file sources (`scripts/prereqs.sh`); `ngc-secrets.sh check` confirms the source exists without reading the key (`security find-generic-password -s`, no `-w`) | none |
| 5 | Helm values | `scripts/deploy.sh` `keyless_values_yaml` pipes only switches: `ngc.keyless: true`, `ngc.apiKey: ""`, `prestage.enabled`, `replicaCount`. The chart fails to render if `ngc.keyless` is true and `ngc.apiKey` is set | none |
| 6 | Helm release Secret | values and manifest hold no key (no chart Secret is rendered) | none |
| 7 | `<fullname>-ngc-registry` | `scripts/ngc-secrets.sh`: `security ... -w` → `awk` (first line, no newline) → `jq -R` builds the dockerconfigjson → `kubectl create secret generic --type=kubernetes.io/dockerconfigjson --from-file=.dockerconfigjson=/dev/stdin` | cluster copy, kept for the kubelet |
| 8 | `<fullname>-ngc-api` | same pipe into `kubectl create secret generic --from-file=NGC_API_KEY=/dev/stdin` | cluster copy, deleted after pre-stage |
| 9 | Pre-stage Job | `helm/templates/prestage-job.yaml`: the only pod with `NGC_API_KEY` (secretKeyRef); runs `download-to-cache` into the cache PVC and exits | Job pod env, pre-stage window only |
| 10 | API Secret deleted | `scripts/deploy.sh:225` after Helm reports the Job complete; also on every exit path (`on_exit`). The serving install does not start while the Secret exists | removed |
| 11 | Server pod | `ngc.keyless: true` drops the `NGC_API_KEY` env; `verify_keyless_state` (`scripts/deploy.sh:86`) checks the live Deployment env names and the Secret's absence | none |
| 12 | Image pull | kubelet, via the pull Secret | node |

Install order in `deploy_keyless` (`scripts/deploy.sh:210`). `deploy.sh`
first refuses keyless when the release already exists: upgrading a
default-path release would make Helm delete its chart-owned
`<fullname>-ngc-registry`, which by then is the helper's pull Secret.

1. `ngc-secrets.sh create`: pull Secret and API Secret, outside Helm, labelled
   `app.kubernetes.io/instance=<release>` so `scripts/cleanup-nim.sh` removes them.
2. `helm upgrade --install` with `prestage.enabled=true`, `replicaCount=0`,
   `--wait --wait-for-jobs` (cap `PRESTAGE_TIMEOUT`, 1500 s).
3. Delete the API Secret; refuse to continue if it still exists.
4. `helm upgrade` with `prestage.enabled=false`, `replicaCount=1`, `--wait`.
   Helm removes the Job because it is no longer rendered.
5. `verify_keyless_state`.

What still holds the key on the keyless path: the key source, the pull Secret
(any principal that can read Secrets in the namespace can read it), the
kubelet's pull credential on the node, and, during pre-stage only, the API
Secret and the Job pod. The helper never writes the key to stdout, stderr,
argv, or disk. A Keychain read happens twice per deploy (one per Secret).

Not combined with `--autoscale` yet: the Job requests the GPU, so it would
trigger the scale-up inside the deploy step and change what the scale-up
phase measures. The runner refuses the combination.

### Timing defaults

With `--keyless`, the runner's deploy step cap defaults to 3600 s
(pre-stage 1500 s + serve wait 1800 s + margin). The step-budget sum becomes
3600 + 3600 + 900 + 900 = 9000 s, equal to the default `WATCHDOG_SEC`.
The real pre-stage duration is unmeasured.

## Usage

```bash
security add-generic-password -s nimble-ngc -a "$USER" -w
```

The command above prompts for the key; nothing lands in shell history. Then:

```bash
OCI_COMPARTMENT_ID=ocid1.compartment.oc1..<id> scripts/run_measured.sh --key-keychain nimble-ngc docs/runs/<dir>
```

Without the runner:

```bash
KEYLESS=1 NGC_KEY_KEYCHAIN=nimble-ngc scripts/deploy.sh
```

## What the docs establish

The pinned image is `nvcr.io/nim/meta/llama3-8b-instruct:1.0.3`
(`helm/values.yaml` `image`, `helm/Chart.yaml` `appVersion`). NVIDIA
publishes no separate 1.0.3 doc set (`1.0.3/` returns 404; `versions1.json`
lists 1.7.0 and later, plus `1.0.0`). The 1.0.0 doc set covers release 1.0.3:
its release notes have a "Release 1.0.3" entry. Pages read on 2026-11-03:

- R: `large-language-models/1.0.0/release-notes.html`
- G: `large-language-models/1.0.0/getting-started.html`, section "Serving Models from Local Assets"
- U: `large-language-models/1.0.0/utilities.html`
- C: `large-language-models/1.0.0/configuration.html`
- E: `large-language-models/latest/reference/environment-variables.html` (latest = 2.1.4)
- A: `large-language-models/latest/deployment/air-gap-deployment.html` (2.1.4)

| Claim | Status | Evidence |
|-------|--------|----------|
| 1.0.3 supports air-gapped serving | DOCUMENTED | R, Release 1.0.3 summary: "AirGapped support"; "Fixes for model downloading, and cache corruption." |
| 1.0.3 ships `download-to-cache` | DOCUMENTED | G: the section is headed "NIM LLM Version 1.0.3 or later"; U: "Downloads selected or default model profile(s) to NIM cache. Can be used to pre-cache profiles prior to deployment." |
| The flag is `--profiles` / `-p`; no flag downloads the optimal profile | DOCUMENTED, with a doc inconsistency | U and the `-h` output in G: "--profiles [PROFILES ...], -p [PROFILES ...] ... If none are provided, the optimal profile is downloaded." One example in G uses `--profile`. The chart passes `--profiles` only when `prestage.profile` is set; the default passes no flag |
| A 1.0.x server on a filled cache, with no `NGC_API_KEY`, serves without contacting NGC | DOCUMENTED (Docker example only) | G: "If NIM detects a previously loaded profile in the cache, it serves that profile from the cache." and "the cache can be transferred to an air-gapped system to run a NIM without any internet connection or with no connection to the NGC registry. Too see this in action, don't provide the NGC_API_KEY". The example `docker run` has no `NGC_API_KEY` |
| With `NIM_MODEL_PROFILE` unset, the server picks the profile `download-to-cache` chose | DOCUMENTED for the default download | G: "Assuming the command run prior was `download-to-cache`, downloading the optimal profile", followed by a `docker run` with no `NIM_MODEL_PROFILE`. Holds only on the same GPU type; the Job requests the server's GPU |
| `download-to-cache` writes to `NIM_CACHE_PATH` (`/model-cache` in this chart) | INFERRED, not stated | C: `NIM_CACHE_PATH`, default `/opt/nim/.cache`, "Location (in container) where the container caches model artifacts"; volumes row "/opt/nim/.cache (or NIM_CACHE_PATH if present)". No page says the utility itself reads the variable. Every 1.0.x example mounts the cache at `/opt/nim/.cache` |
| NIM 2.x: `NGC_API_KEY` is "Only required when downloading production branch (PB) models from ngc:// repositories" | DOCUMENTED (2.1.4) | E, verbatim |
| Air gap: "you must pre-stage the model using download-to-cache (and optionally create-model-store)"; "do not set NGC_API_KEY or HF_TOKEN" in the air-gapped phase | DOCUMENTED (2.1.4) | A, verbatim |

Doc conflict to note: C lists `NGC_API_KEY` as "Required? Yes" ("You must
set this variable to the value of your personal NGC API key."). G, in the
1.0.3 section, says to leave it out for a pre-filled cache. The 1.0.3 section
is the more specific statement; the live run decides.

What the docs do not establish:

- Kubernetes: every 1.0.x example is `docker run`. Nothing covers a Job that
  fills a PVC and a separate pod that serves from it.
- The `NIM_CACHE_PATH` inference above. If the utility ignores the variable,
  the Job fills `/opt/nim/.cache` inside its own container, the PVC stays
  empty, and the keyless server fails to download (no key). Live gate 4
  catches that; the fix would be to mount the PVC at `/opt/nim/.cache`.
- Pre-stage time on an A10. Unmeasured.

Not NIM behaviour, also unverified on a live cluster: `kubectl create secret
--from-file=KEY=/dev/stdin` reading a pipe; Helm `--wait-for-jobs` failing
fast on a failed Job; the cache PVC (ReadWriteOnce block volume) detaching
from the finished Job pod before the server pod mounts it.

## Live gates still owed (measured run)

1. Server pod env shows 0 `NGC_API_KEY` (`kubectl exec ... env`, or the pod
   spec env names).
2. No `<fullname>-ngc-api` Secret after pre-stage.
3. No `nvapi-` match anywhere in the run's output folder.
4. A chat completion returns HTTP 200.
5. GPU nodes return to 0 after teardown.

No README claim about a credential-free serving pod until these pass.
