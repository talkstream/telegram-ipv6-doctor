# Contributing

Bug reports of the form "the verdict was wrong on my Mac" are the most valuable thing you can send —
please attach the output of `… _ report` (it is privacy-safe by construction).

## Ground rules for code

- **Bash 3.2.** Stock macOS ships bash 3.2.57 and always will. No associative arrays, no `mapfile`,
  no `${var^^}`, no `EPOCHREALTIME`, no `wait -n`.
- **Zero dependencies.** Only tools present on a clean macOS install.
- `shellcheck -s bash telegram-ipv6-doctor.sh` must be clean.
- `bats tests/doctor.bats` must be green. New behaviour needs a test; new *refusals* definitely need one.
- **Nothing may weaken a safety gate** without a test proving the new gate is at least as strict.
- The tool must never fetch anything at runtime.

## Adding a verdict

A new verdict needs: a numeric rule in `decide()`, strings for both languages in `t()`, a fixture-driven
test, and a row in both READMEs. Verdicts that lead to a mutation need an explicit refusal path too.
