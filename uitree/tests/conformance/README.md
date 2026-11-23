# conformance (spec 0.2)

The suite every uitree host must pass, ported from
[uitreefs/tests/conformance](../../../uitreefs/tests/conformance) to draft
0.2: dashed names, `$ui/types`, the 0.2 error codes and event heads.
Workstream W5.

`run` executes each `NN-name.rc` under `uitree-headless`, strips `seq=`,
and diffs against `NN-name.out` (and `NN-name.trace` when present). A
descriptor check reads `$ui/types/*/spec` from the host and checks it
accepts and refuses exactly what they list.

Status: empty. W5 fills it.
