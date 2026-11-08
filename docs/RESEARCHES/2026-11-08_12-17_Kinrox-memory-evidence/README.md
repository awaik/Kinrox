# Memory research evidence

Collected 2026-11-08 from the existing Kinrox 0.5.5 (15) process, PID 45801.
The adjacent research report explains the measurements and limitations.

- `environment.json`: version, hardware, OS and source provenance.
- `measure-memory.py`: read-only process inventory and `proc_pid_rusage` sampler.
- `memory-series.jsonl`: 61 samples at approximately two-second intervals.
- `memory-summary.json`: per-role and per-sample-total statistics in MiB.
- `collect-diagnostics.py`: commands used for aggregate diagnostics after sampling.
- `diagnostics-manifest.json`: commands, timestamps and exit codes.
- `vmmap-*.txt`: aggregate memory maps, with home paths redacted.
- `heap-top.txt`: first 110 output lines; long generic type names abbreviated.
- `heap-selected.txt`: selected type families from the complete heap output;
  long generic names abbreviated. Families can overlap and are not additive.
- `leaks.txt`: scan without allocation contents or stack traces; exit code 1
  corresponds to the reported two leaks totaling 112 bytes.
- `validation.json`: checks performed before handing off the report.

The raw heap output was processed in memory and was not saved in full. No
memgraph, account data, media metadata, process arguments or allocation contents
were requested. Numeric pointers in aggregate diagnostics are process-local
addresses, not contents of those allocations.

## Reproduction

Use the actual PID of an existing instance; do not restart it merely to sample.

```sh
python3 -B measure-memory.py --pid <PID> --samples 61 --interval 2
```

Redirect output to a new file outside the existing evidence files. The script
discovers the current Soloist helpers at every sample rather than assuming their
PIDs persist across tracks. Check process counts and errors as well as totals.

`collect-diagnostics.py` is the exact capture script for PID 45801. It saves with
exclusive creation and cannot overwrite existing artifacts. For a future run,
place a copy in a new evidence directory and use the intended instance PID.
Run heap/leak scans after the passive series because diagnostics can perturb
memory residency and timing. These are not guaranteed impact-free inspections.

The source scripts were syntax-checked and the sampler's final reading was
cross-checked against `vmmap` at the same approximate observation boundary.
The owner-reported long session was observed without application-control changes;
window/screen state and user interactions were not controlled or logged.
