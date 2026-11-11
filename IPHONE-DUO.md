# iPhone Duo — verified messaging scope

2026-11-12. The multiline AskBar uses an honest Return label and stable composer/Send identifiers. Sending remains the explicit arrow action, with the existing draft, conversation and source settings.

## Verification

- Current Debug passed: `build_sim_2026-11-11T09-53-54-360Z_pid10299_b424cb3d.log` in the XcodeBuildMCP RF log directory. Unsigned Release passed: `sweep/logs/pocketd-152619.log`.
- Full eight-configuration question/draft/send runs: `sweep/dd/duo-qa/tmp/pocketd-question-verified-standard-20261112-023452` and `pocketd-question-verified-accessibility-20261112-023652`. Exact unique drafts survive folding/rotation with the software keyboard; actual Send, disabled-calendar recovery and Close are exercised.
- Closed-portrait outcome supplements: `pocketd-question-verified-standard-20261112-030858` and `pocketd-question-verified-accessibility-20261112-050005`, under the same artifact root. These expose the complete assistant answer above the composer and both terminal Today states.
- Visual acceptance: `sweep/duo-qa/reviews/autonomous-pocketd-final.md` plus `autonomous-pocketd-closure.md`. The latter closes all remaining selected-flow holds and retains the full matrices and complementary AX question captures.
- Read-only persistence: `sweep/duo-qa/reviews/autonomous-core-persistence.md/.json` identifies both original passing-run conversation files, unique questions, assistant replies and timestamps in the retained store.

## Limits

Calendar sources remain off. Earlier empty-calendar wording is an observed assistant reply, not successful calendar retrieval; the latest AX response explicitly says it cannot see the calendar. The folded multiline editor scrolls internally. This selected simulator scope does not certify live calendar access, voice/audio, physical devices, or an independently exercised Return-key newline.
