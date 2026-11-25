# Checking the chat's answers

Copies the question log to Postgres, works out each figure again from the source tables, and compares. Needs the Cloudflare sign-in and the `happen_demo` database.

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
| **not covered** | No template yet: launches, satisfaction by outcome, persona profiles |
| **not finished** | The page was closed before the answer |
| **error** | The check itself failed |

What is compared: values, how they are shown, record counts, "too few", status against target, changes and their chance readings, shares, the groups listed and their order, trend months, highest and lowest, and the filters and months used.

**A match means the figures the chat was given are right for what it asked for.** A person still has to judge whether it asked for the right thing and worded the answer fairly. Figures in the answer that weren't in the results are flagged separately (`unchecked`).

The SQL comes from fixed templates in [`verify.mjs`](verify.mjs) and never reads the `dash` tables behind the dashboards. It shares their rounding and target rules (`docs/assets/site.js`, `kpis.json`). Tests: `node chat/tests/verify.mjs`.

If data was corrected after a question was asked, a difference may be the correction. The dates are in `qa.v_chat_check`.
