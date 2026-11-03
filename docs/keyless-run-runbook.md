# Measured keyless run: runbook

One measured run of the keyless path on OKE: the key stays in the macOS
Keychain, a pre-stage Job fills the model cache, and the server runs with no
`NGC_API_KEY`. The run checks the five live gates in
[key-path.md](key-path.md#live-gates-still-owed-measured-run).

This run bills. The two earlier runs posted $0.63 and $0.53
([runs](runs/README.md)). The keyless run's cost is unmeasured; it adds a
second pod start to the same model download. The watchdog forces teardown
after 10320 s (the keyless default `WATCHDOG_SEC`): about $6.40 at the kit's
estimate rate of 2.2384 USD/h (`scripts/_lib.sh` `estimate_hourly_cost`), plus
the teardown time.

One terminal. The runner collects gates 1 and 2 itself, in the
`keyless-check` phase between ready and bench, and stops the run (teardown
runs) if either fails.

## 0. Preconditions

| Check | Command | Expect |
|-------|---------|--------|
| macOS with Keychain | `command -v security` | a path |
| Tools | `for t in oci kubectl helm jq python3 curl bc; do command -v $t >/dev/null \|\| echo "missing $t"; done` | no output |
| Code | `git fetch origin && git checkout claude/lucid-ritchie-it468d && git pull` | branch of the keyless pull request, clean tree |
| No leftover cluster | `ls scripts/cluster-info.txt` | "No such file" |
| OCI auth | `oci iam region list >/dev/null && echo ok` | `ok` |

Environment:

```bash
export OCI_COMPARTMENT_ID=ocid1.compartment.oc1..<your-compartment>
```

```bash
export API_ALLOWED_CIDR=<your-public-ipv4>/32
```

`OCI_REGION` defaults to `us-phoenix-1`; set it only to run elsewhere.
Keep `NGC_API_KEY` unset in this shell; the runner ignores it with
`--key-keychain`.

## 1. Offline gate (no spend)

```bash
bash tests/run_measured_test.sh
```

Expect the last line `RESULT: all passed`, with K0 to K8f PASS. Stop on any FAIL.

## 2. Keychain item

Create the item once. With `-w` last, `security` prompts for the key, so it
never lands in shell history:

```bash
security add-generic-password -s nimble-ngc -a "$USER" -w
```

Rehearse the read the run will make. This prints the key's length, never the
key:

```bash
security find-generic-password -w -s nimble-ngc | tr -d '\n' | wc -c
```

Expect a number above 0. If macOS shows an access prompt, choose Always
Allow: the run reads the item twice, about 20 minutes in, and cannot answer
a prompt.

## 3. Preflight (no spend)

```bash
scripts/run_measured.sh --key-keychain nimble-ngc --preflight-only /tmp/preflight-keyless
```

Expect exit 0. `/tmp/preflight-keyless/preflight.log` must hold
`ok: Keychain item present`, `preflight checks passed`, and the line
`step budgets: ... + keyless-check 120s = 9120s; WATCHDOG_SEC=10320s`.
Read-only `oci` calls only.

## 4. Run (bills)

```bash
OUT="docs/runs/$(date -u +%F)-run-3-keyless"
```

```bash
scripts/run_measured.sh --key-keychain nimble-ngc "$OUT"; echo "runner exit: $?"
```

Expect `runner exit: 0`.

Phases: preflight, provision, deploy, ready, keyless-check, bench,
teardown, verify-clean. Follow them in `$OUT/phases.log`. In `$OUT/deploy.log` the
keyless steps appear in this order:

1. `Keyless: creating the NGC Secrets outside Helm (value never shown)...`
2. `Keyless: pre-stage install (Job fills the model cache; replicas 0; ...)`
3. `Keyless: pre-stage Job completed`
4. `Keyless: Secret nvidia-nim-ngc-api deleted before the server starts`
5. `Keyless: serving install (no NGC_API_KEY; ...)`
6. `Keyless check: no nvidia-nim-ngc-api Secret; Deployment env has no NGC_API_KEY`

Leave it running. If you must stop it, Ctrl-C (or closing the terminal)
still tears down: the runner traps the signal. A failed step also tears
down.

## 5. Gates 1 and 2 (the runner's keyless-check phase)

Once the server is Ready, the runner reads the cluster and writes
`$OUT/keyless-evidence.log`. It records names, counts, and NotFound lines
only; no command prints a Secret value, an env value, or the Helm values
(only the length of `ngc.apiKey`). Read it after the run:

```bash
cat "$OUT/keyless-evidence.log"
```

| Line | PASS |
|------|------|
| G1a | `0`: the server's runtime env, via `kubectl exec ... sh -c 'env \| cut -d= -f1 \| grep -cx NGC_API_KEY'` |
| G1b | env names without `NGC_API_KEY` (expected: `NIM_CACHE_PATH`) |
| G1c | `[]` (no `envFrom`) |
| G2 API Secret | `Error from server (NotFound): secrets "nvidia-nim-ngc-api" not found` |
| G2 Secret names | `secret/nvidia-nim-ngc-registry` and Helm's `sh.helm.release.v1.nvidia-nim.v*`; no `ngc-api` |
| S1 | `0` (no key in Helm values, so none in the release Secret) |
| S2 | `0` (no chart Secret in the release manifest) |
| S3 | `NotFound` (Helm removed the Job at the serving install) |
| `gate1:` | `PASS (runtime count 0; pod spec clean)` |
| `gate2:` | `PASS (nvidia-nim-ngc-api NotFound)` |
| `release_secret:` | `PASS (...)` |

How the verdicts are set:

- `gate1` fails on a runtime count above 0, an `NGC_API_KEY` env name, any
  `envFrom`, or unreadable pod env names. If `kubectl exec` is unavailable
  (no `sh` in the image), G1a reads `unavailable` and `gate1` passes on the
  pod spec alone, saying so.
- `gate2` passes only on NotFound. A Secret that exists, or no answer, fails.
- `release_secret` fails on a non-zero `ngc.apiKey` length or any Secret in
  the release manifest. If `helm get` fails it reads `UNKNOWN` and does not
  stop the run; record it as not checked.

`summary.json` (`keyless_gates`) and `receipt.md` ("Keyless gates") carry
the three verdicts.

## 6. Gates 3, 4, 5 (after the runner exits)

Gate 3, no `nvapi-` in the output folder. Exit 1 means no match:

```bash
grep -rlaF 'nvapi-' "$OUT"; echo "grep exit: $?"
```

Supplementary: the three base64 forms of `nvapi-`. A hit needs a look, not
an automatic FAIL:

```bash
grep -rlaE 'bnZhcGkt|52YXBp|udmFwaS1' "$OUT"; echo "grep exit: $?"
```

Gate 4, chat completions returned HTTP 200:

```bash
jq '{ok, n_ok, statuses: [.requests[].status]}' "$OUT/bench.json"
```

Expect `"ok": true`, `"n_ok": 5`, and every status `200`.

Gate 5, no GPU node left. From the runner:

```bash
grep '^- Result:' "$OUT/receipt.md"; jq '.teardown' "$OUT/summary.json"
```

Expect `clean: GPU node pool, cluster and network deleted; verified` and
`"verify_clean": true`. Then an independent read-only count of GPU instances
not yet terminated:

```bash
oci compute instance list --compartment-id "$OCI_COMPARTMENT_ID" --region "${OCI_REGION:-us-phoenix-1}" --all --query "data[?starts_with(shape, 'VM.GPU') && \"lifecycle-state\"!='TERMINATED'] | length(@)"
```

Expect `0`. A `TERMINATING` instance counts; re-run after a few minutes.

## 7. Results

| Gate | Evidence | PASS when |
|------|----------|-----------|
| 1 Server pod env has 0 `NGC_API_KEY` | `keyless-evidence.log` G1a to G1c and `gate1`; `deploy.log` line 6 | `gate1: PASS` |
| 2 No `ngc-api` Secret after pre-stage | `keyless-evidence.log` G2 and `gate2`; `deploy.log` lines 4 and 6 | `gate2: PASS` |
| 3 No `nvapi-` in the output folder | `grep` in step 6 | grep exit 1 |
| 4 Chat completion HTTP 200 | `bench.json` | 5 of 5, all 200 |
| 5 GPU nodes back to 0 | `receipt.md`, `summary.json`, `oci` count | clean, verified, 0 |

Record the run as `docs/runs/<date>-run-3-keyless.md` in the format of the
earlier receipts, with this table filled in. The raw `$OUT` directory stays
out of git (`.gitignore` covers `docs/runs/*/`). `receipt.md` names the key
source: `NGC key source: keychain; keyless serve: yes`.

A README claim about a server that holds no key waits until all five gates
pass.

## 8. If a gate fails

- The run tears itself down on any step failure; check step 6, gate 5, either way.
- `keyless-check` failed (`PHASE keyless-check END ... rc=1`; bench did not
  run): `keyless-evidence.log` names the gate and the evidence.
- Pre-stage failed (`deploy.log`, "NIM FAILURE DIAGNOSTICS"): the Job's
  `describe` and last 200 log lines are in that block. A wrong image tag or
  a failed pull points at the pull Secret; a download error points at the key
  or entitlement.
- Gate 4 failed while gates 1 and 2 passed: the server could not serve from
  the cache without a key. The 1.0.x docs say it should
  ([key-path.md](key-path.md#what-the-docs-establish)). Read the server logs in
  `deploy.log` before changing anything. The two open fixes are a newer
  image pin (re-check its docs first) or `prestage.profile` with
  `NIM_MODEL_PROFILE`. Do not re-run the same configuration.
- Gate 1, 2, or 3 failed: that is a key leak. Record it as FAIL, keep `$OUT`
  out of git, and rotate the NGC key in NGC before anything else.
- Teardown not confirmed (runner exit 1, watchdog left armed): follow the
  runner's printed `oci` delete commands and `$OUT/watchdog.log`.
