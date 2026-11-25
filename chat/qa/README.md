# Checking the chat's answers

Copies the question log and readers' reports to Postgres, works out each figure again from the source tables, and compares. Needs the Cloudflare sign-in and the `happen_demo` database.

```powershell
node chat/qa/sync_log.mjs
```

```powershell
node chat/qa/verify_log.mjs
```

Then, in pgAdmin:

| View | What it shows |
|---|---|
| `qa.v_chat_verdict` | One row per question: the verdict, and what a person still needs to look at |
| `qa.v_chat_check` | One row per figure requested: what differs, and the SQL |
| `qa.v_chat_log`, `qa.v_chat_call` | The questions, and the requests behind them |

The SQL for each question is also written to a text file, outside this project because it holds people's questions. The script prints the folder.

| Verdict | Meaning |
|---|---|
| **match** | Every comparison agrees with the source tables |
| **mismatch** | At least one differs. Start here |
| **no figure** | The chat gave no figure, or the page refused the request |
| **not covered** | A kind of request with no template yet |
| **not finished** | The page was closed before the answer |
| **error** | The check itself failed |

What is compared: values, how they are shown, record counts, "too few", status against target, changes and their chance readings, shares, the groups listed and their order, trend months, highest and lowest, and the filters and months used. For launches: contacts against expected, the peak, when it was back to normal, each change and its chance reading, and overlapping launches. For outcomes: both groups and whether the gap is beyond chance. For personas: every field of every profile.

Not compared: the events listed beside a result, which come from `events.json`, and fixed notes.

**A match means the figures the chat was given are right for what it asked for.** A person still has to judge whether it asked for the right thing and worded the answer fairly. Figures in the answer that weren't in the results are flagged separately (`unchecked`).

The SQL comes from fixed templates in [`verify.mjs`](verify.mjs) and never reads the `dash` tables behind the dashboards. It shares their rounding and target rules (`docs/assets/site.js`, `kpis.json`). Tests: `node chat/tests/verify.mjs`.

## Readers' reports

`sync_log.mjs` also copies reports (tickets). Review them with:

```powershell
node chat/qa/ticket.mjs
```

Add a number to see one (`node chat/qa/ticket.mjs 1`), then `--status` and `--finding` to record your decision. `--issue` **previews** a public GitHub issue; it is only created with `--publish`. `--close "..."` previews closing it. The issue never holds the question, the answer or the reader's comment.

`daily_check.ps1` copies, checks and shows a message when there is something to review. `-Install` runs it every day.

## Notes

If data was corrected after a question was asked, a difference may be the correction. The dates are in `qa.v_chat_check`.
